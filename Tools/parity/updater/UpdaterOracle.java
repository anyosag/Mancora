/*
 * Builds an installation and three update sites, runs the real ImageJ
 * updater (net.imagej:imagej-updater) over them, and records what it
 * decides: every file's status and action, the conflicts it reports, the
 * folder after installing, and the db.xml.gz it writes. Mancora's
 * MancoraPluginsTests replay the same steps and must reach the same results.
 *
 * Usage: java -cp <imagej-updater + scijava-common + this> \
 *            net.imagej.updater.UpdaterOracle <output folder>
 *
 * It lives in the updater's package for FileObject.setVersion. See README.md.
 */
package net.imagej.updater;

import com.sun.net.httpserver.HttpServer;

import java.io.*;
import java.net.InetSocketAddress;
import java.nio.charset.StandardCharsets;
import java.nio.file.*;
import java.security.MessageDigest;
import java.text.SimpleDateFormat;
import java.util.*;
import java.util.jar.*;
import java.util.zip.*;

import net.imagej.updater.FileObject.Action;
import net.imagej.updater.FileObject.Status;
import net.imagej.updater.util.Progress;
import net.imagej.updater.util.UpdaterUtil;

public class UpdaterOracle {

	/** The Last-Modified every site serves: 2024-07-01 12:00:00 GMT. */
	static final long LAST_MODIFIED = 1719835200000L;

	static File out, root, sites;
	static String base;
	static StringBuilder json = new StringBuilder();

	public static void main(String[] args) throws Exception {
		try {
			run(args);
		} catch (Throwable t) {
			t.printStackTrace();
			System.exit(1);
		}
		System.exit(0);
	}

	static void run(String[] args) throws Exception {
		out = new File(args[0]);
		root = new File(out, "root");
		sites = new File(out, "sites");
		deleteRecursively(out);
		root.mkdirs();
		sites.mkdirs();

		buildScenario();

		// Serve the sites as an HTTP server would, with a fixed Last-Modified.
		HttpServer server = HttpServer.create(new InetSocketAddress("127.0.0.1", 0), 0);
		server.createContext("/", exchange -> {
			File file = new File(sites, exchange.getRequestURI().getPath().substring(1));
			if (!file.isFile()) {
				exchange.sendResponseHeaders(404, -1);
				exchange.close();
				return;
			}
			byte[] body = Files.readAllBytes(file.toPath());
			SimpleDateFormat http = new SimpleDateFormat("EEE, dd MMM yyyy HH:mm:ss zzz", Locale.US);
			http.setTimeZone(TimeZone.getTimeZone("GMT"));
			exchange.getResponseHeaders().add("Last-Modified", http.format(new Date(LAST_MODIFIED)));
			exchange.sendResponseHeaders(200, body.length);
			exchange.getResponseBody().write(body);
			exchange.close();
		});
		server.start();
		base = "http://127.0.0.1:" + server.getAddress().getPort() + "/";

		// The installation's own database: the sites, as a template.
		String localDB = new String(Files.readAllBytes(new File(out, "local-db.xml").toPath()), StandardCharsets.UTF_8);
		writeGzip(new File(root, "db.xml.gz"), localDB.replace("@BASE@", base).getBytes(StandardCharsets.UTF_8));

		// Keep a copy of the folder as it starts, for the tests.
		copyRecursively(root, new File(out, "initial"));
		new File(out, "initial/db.xml.gz").delete();

		json.append("{\n");
		json.append("\"lastModified\": " + LAST_MODIFIED + ",\n");
		checksums();

		// 1. Read the sites and checksum the folder; mark what an update does.
		FilesCollection files = load();
		record("refresh", files);

		// 2. What the planned files need is installed too.
		List<String> conflicts = new ArrayList<>();
		for (Conflicts.Conflict c : new Conflicts(files).getConflicts(false))
			if (!(c instanceof Conflicts.Notice)) conflicts.add(c.getFilename() + ": " + c.getConflict());
		json.append("\"resolveConflicts\": " + strings(conflicts) + ",\n");
		record("resolved", files);

		// 3. Install, move into place, write db.xml.gz.
		Installer installer = new Installer(files, QUIET);
		installer.start();
		installer.moveUpdatedIntoPlace();
		files.write();
		tree("installed");
		database("installedDatabase");

		// 4. Read everything again.
		files = load();
		record("afterInstall", files);

		// 5. Disable Beta: its files go back to Alpha's versions or away.
		files.deactivateUpdateSite(files.getUpdateSite("Beta", true));
		record("betaDisabled", files);
		installer = new Installer(files, QUIET);
		installer.start();
		installer.moveUpdatedIntoPlace();
		files.write();
		tree("betaRemoved");
		database("betaRemovedDatabase");

		files = load();
		record("final", files);
		json.append("\"end\": true\n}\n");
		Files.write(new File(out, "expected.json").toPath(), json.toString().getBytes(StandardCharsets.UTF_8));
		server.stop(0);
	}

	static FilesCollection load() throws Exception {
		// The checksum cache keys on timestamps to the second: a file replaced
		// within a second of being checksummed would keep its old checksum.
		new File(root, ".checksums").delete();
		FilesCollection files = new FilesCollection(root);
		files.setActivePlatforms("linux64");
		String warnings = files.downloadIndexAndChecksum(QUIET);
		List<String> sitesWithWarnings = new ArrayList<>();
		for (UpdateSite site : files.getUpdateSites(true))
			if (warnings.contains("site '" + site.getName() + "'")) sitesWithWarnings.add(site.getName());
		files.markForUpdate(false);
		json.append("\"warnings" + (++loads) + "\": " + strings(sitesWithWarnings) + ",\n");
		return files;
	}

	static int loads = 0;

	static final Progress QUIET = new Progress() {
		@Override public void setTitle(String title) {}
		@Override public void setCount(int count, int total) {}
		@Override public void addItem(Object item) {}
		@Override public void setItemCount(int count, int total) {}
		@Override public void itemDone(Object item) {}
		@Override public void done() {}
	};

	static void record(String step, FilesCollection files) {
		List<FileObject> list = new ArrayList<>();
		for (FileObject f : files) list.add(f);
		list.sort(Comparator.comparing(f -> f.filename));
		json.append("\"" + step + "\": [\n");
		for (int i = 0; i < list.size(); i++) {
			FileObject f = list.get(i);
			List<String> overridden = new ArrayList<>(f.overriddenUpdateSites.keySet());
			json.append("  {\"filename\": " + str(f.filename) + ", \"status\": " + str(f.getStatus().name()) +
				", \"action\": " + str(f.getAction().toString()) + ", \"site\": " + str(f.updateSite) +
				", \"local\": " + str(f.localFilename) + ", \"overridden\": " + strings(overridden) + "}" +
				(i + 1 < list.size() ? "," : "") + "\n");
		}
		json.append("],\n");
		List<String> conflicts = new ArrayList<>();
		for (Conflicts.Conflict c : files.getConflicts()) conflicts.add(c.getFilename());
		json.append("\"" + step + "Conflicts\": " + strings(conflicts) + ",\n");
	}

	/** Every file in the folder, with its SHA-1 and whether it's executable. */
	static void tree(String step) throws Exception {
		List<String> paths = new ArrayList<>();
		listFiles(root, "", paths);
		Collections.sort(paths);
		json.append("\"" + step + "\": [\n");
		for (int i = 0; i < paths.size(); i++) {
			File f = new File(root, paths.get(i));
			json.append("  {\"path\": " + str(paths.get(i)) + ", \"sha1\": " + str(sha1(Files.readAllBytes(f.toPath()))) +
				", \"executable\": " + f.canExecute() + "}" + (i + 1 < paths.size() ? "," : "") + "\n");
		}
		json.append("],\n");
	}

	static void database(String step) throws Exception {
		ByteArrayOutputStream bytes = new ByteArrayOutputStream();
		try (InputStream in = new GZIPInputStream(new FileInputStream(new File(root, "db.xml.gz")))) {
			in.transferTo(bytes);
		}
		json.append("\"" + step + "\": " + str(bytes.toString("UTF-8").replace(base, "@BASE@")) + ",\n");
	}

	static void listFiles(File dir, String prefix, List<String> paths) {
		for (File f : dir.listFiles()) {
			String path = prefix + f.getName();
			if (f.isDirectory()) listFiles(f, path + "/", paths);
			else if (!path.equals("db.xml.gz") && !path.equals(".checksums")) paths.add(path);
		}
	}

	// -- Checksums --

	/** Jars whose .properties and manifests take every path through the updater's filters. */
	static void checksums() throws Exception {
		File dir = new File(out, "checksums");
		dir.mkdirs();
		Map<String, byte[]> cases = new LinkedHashMap<>();
		cases.put("properties.jar", rawJar(new String[][] {
			{ "a.properties", "#date\n#\n#after-bare-hash\nkey=value\n# indented\n\n#last" },
			{ "b.properties", "no comments\r\n#crlf comment\r\nx=1\r\n" },
			{ "c.properties", "" },
			{ "d.txt", "#not a properties file\n" },
		}));
		cases.put("manifest.jar", rawJar(new String[][] {
			{ "META-INF/MANIFEST.MF", "Manifest-Version: 1.0\r\nBuilt-By: me\r\nCreated-By: Maven\r\nMain-Class: org.Main\r\n"
				+ "Class-Path: a.jar\r\n b.jar\r\nimplementation-build: 42\r\nBuild-Jdk: 21\r\nArchiver-Version: 3\r\n"
				+ "Implementation-Title: t\r\n:odd\r\nno colon\r\n\r\nName: x\r\n" },
			{ "z/Last.class", "zz" },
			{ "A/First.class", "aa" },
			{ "a/lower.class", "lower" },
			{ "dir/", null },
		}));
		cases.put("bare-manifest.jar", rawJar(new String[][] {
			{ "META-INF/MANIFEST.MF", "Main-Class: x\nBuilt-By: y" },
		}));
		cases.put("empty.jar", rawJar(new String[][] {}));
		json.append("\"checksums\": [\n");
		int i = 0;
		for (Map.Entry<String, byte[]> e : cases.entrySet()) {
			File f = new File(dir, e.getKey());
			Files.write(f.toPath(), e.getValue());
			List<String> obsolete = UpdaterUtil.getObsoleteDigests("jars/" + e.getKey(), f);
			json.append("  {\"file\": " + str(e.getKey()) + ", \"digest\": " + str(UpdaterUtil.getDigest("jars/" + e.getKey(), f)) +
				", \"plain\": " + str(UpdaterUtil.getJarDigest(f, false, false, false)) + ", \"obsolete\": " + strings(obsolete) + "},\n");
			i++;
		}
		// Other files: the path counts, as ASCII.
		File text = new File(dir, "file.txt");
		Files.write(text.toPath(), "contents\n".getBytes(StandardCharsets.UTF_8));
		for (String path : new String[] { "macros/file.txt", "macros/caf\u00e9.txt", "macros/\uD83D\uDE00.txt", "file.txt" }) {
			json.append("  {\"file\": \"file.txt\", \"path\": " + str(path) + ", \"digest\": " + str(UpdaterUtil.getDigest(path, text)) + "},\n");
		}
		json.append("  {\"file\": null}\n],\n");
	}

	/** A jar written entry by entry, no manifest added: deflated, a null value is a directory. */
	static byte[] rawJar(String[][] entries) throws Exception {
		ByteArrayOutputStream bytes = new ByteArrayOutputStream();
		try (ZipOutputStream zip = new ZipOutputStream(bytes)) {
			for (String[] entry : entries) {
				ZipEntry z = new ZipEntry(entry[0]);
				z.setTime(1600000000000L);
				zip.putNextEntry(z);
				if (entry[1] != null) zip.write(entry[1].getBytes(StandardCharsets.UTF_8));
				zip.closeEntry();
			}
		}
		return bytes.toByteArray();
	}

	// -- The scenario --

	static FilesCollection alpha = new FilesCollection(null), beta = new FilesCollection(null);

	static void buildScenario() throws Exception {
		alpha.removeUpdateSite("ImageJ");
		beta.removeUpdateSite("ImageJ");

		// Installed, with metadata: the description keeps its whitespace.
		byte[] installed = jar("installed", 1);
		FileObject f = site(alpha, "jars/installed.jar", installed, 20231001000000L);
		f.description = "  A jar & its\n  description  ";
		f.addAuthor("Ann Author");
		f.addLink("https://example.org/installed");
		f.addCategory("Testing");
		local("jars/installed.jar", installed);

		// Updateable: the local copy is the previous version, under its old name.
		byte[] updOld = jar("updateable", 1), updNew = jar("updateable", 2);
		f = site(alpha, "jars/updateable-2.0.jar", updNew, 20231101000000L);
		f.addPreviousVersion(digest("jars/updateable-1.0.jar", updOld), 20230101000000L, "jars/updateable-1.0.jar", 20231101000000L);
		local("jars/updateable-1.0.jar", updOld);

		// Locally modified.
		site(alpha, "plugins/Modified_Plugin.jar", jar("modified", 1), 20231001000000L);
		local("plugins/Modified_Plugin.jar", jar("modified", 99));

		// New since Alpha was last read (its timestamp is 20240101000000), and not.
		site(alpha, "macros/new-macro.ijm", "print(\"new\");\n".getBytes(StandardCharsets.UTF_8), 20240601000000L);
		site(alpha, "macros/declined.ijm", "print(\"declined\");\n".getBytes(StandardCharsets.UTF_8), 20230601000000L);

		// Obsolete: installed, and not.
		byte[] obsolete = jar("obsolete", 1);
		f = obsoleteSite(alpha, "plugins/Obsolete_Plugin.jar");
		f.addPreviousVersion(digest("plugins/Obsolete_Plugin.jar", obsolete), 20220101000000L, null, 20230101000000L);
		local("plugins/Obsolete_Plugin.jar", obsolete);
		f = obsoleteSite(alpha, "plugins/Obsolete_Gone.jar");
		f.addPreviousVersion(digest("plugins/Obsolete_Gone.jar", jar("gone", 1)), 20220101000000L, null, 20230101000000L);

		// Platform-specific files: only linux64 is active.
		f = site(alpha, "jars/linux64/native-lib.jar", jar("native-linux", 1), 20240601000000L);
		f.addPlatform("linux64");
		f = site(alpha, "jars/win64/native-lib.jar", jar("native-win", 1), 20240601000000L);
		f.addPlatform("win64");

		// A new file whose dependency is old and not installed.
		f = site(alpha, "jars/needs-dep.jar", jar("needs-dep", 1), 20240601000000L);
		f.addDependency("jars/dep-lib-3.1.jar", 20230101000000L, false);
		site(alpha, "jars/dep-lib-3.1.jar", jar("dep-lib", 1), 20230101000000L);

		// Shadowed: Beta's version wins over Alpha's.
		byte[] sharedA = jar("shared", 1), sharedB = jar("shared", 2);
		site(alpha, "jars/shared.jar", sharedA, 20231001000000L);
		site(beta, "jars/shared.jar", sharedB, 20240201000000L);
		local("jars/shared.jar", sharedA);
		site(beta, "scripts/Beta_Script.py", "print('beta')\n".getBytes(StandardCharsets.UTF_8), 20240201000000L);

		// A versioned file nobody installed.
		site(alpha, "jars/Jama-1.0.2.jar", jar("jama", 2), 20210101000000L);

		// Two local versions of one file.
		byte[] multiOld = jar("multi", 1), multiNew = jar("multi", 2);
		f = site(alpha, "jars/multi-2.0.jar", multiNew, 20231001000000L);
		f.addPreviousVersion(digest("jars/multi-1.0.jar", multiOld), 20230101000000L, "jars/multi-1.0.jar", 20231001000000L);
		local("jars/multi-1.0.jar", multiOld);
		local("jars/multi-2.0.jar", multiNew);

		// The site records the digest an older updater computed.
		byte[] oldDigest = jar("old-digest", 1);
		f = site(alpha, "jars/old-digest.jar", oldDigest, 20231001000000L);
		File tmp = File.createTempFile("old-digest", ".jar");
		Files.write(tmp.toPath(), oldDigest);
		f.current.checksum = UpdaterUtil.getJarDigest(tmp, true, false, false);
		tmp.delete();
		local("jars/old-digest.jar", oldDigest);

		// A launcher.
		f = site(alpha, "ImageJ-linux64", "#!/bin/sh\necho launcher\n".getBytes(StandardCharsets.UTF_8), 20240601000000L);
		f.executable = true;
		f.addPlatform("linux64");

		// Local only.
		local("plugins/My_Own.jar", jar("my-own", 1));
		local("macros/local.ijm", "print(\"mine\");\n".getBytes(StandardCharsets.UTF_8));

		// The sites' indexes, as the updater writes them for a site.
		writeSite("Alpha", alpha);
		writeSite("Beta", beta);
		// "Gone" has no index at all.

		String localDB = "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n" +
			"<pluginRecords>\n" +
			"    <disabled-update-site name=\"ImageJ\" url=\"https://update.imagej.net/\" official=\"true\" timestamp=\"0\"/>\n" +
			"    <update-site name=\"Alpha\" url=\"@BASE@Alpha/\" official=\"false\" timestamp=\"20240101000000\"/>\n" +
			"    <update-site name=\"Beta\" url=\"@BASE@Beta\" official=\"false\" timestamp=\"0\"/>\n" +
			"    <update-site name=\"Gone\" url=\"@BASE@Gone/\" official=\"false\" timestamp=\"0\"/>\n" +
			"    <disabled-update-site name=\"Off\" url=\"@BASE@Off/\" official=\"false\" timestamp=\"0\"/>\n" +
			"</pluginRecords>\n";
		Files.write(new File(out, "local-db.xml").toPath(), localDB.getBytes(StandardCharsets.UTF_8));

		// Fixed modification times, oldest first, so "newest" is well defined.
		long t = 1700000000000L;
		List<String> paths = new ArrayList<>();
		listFiles(root, "", paths);
		Collections.sort(paths);
		StringBuilder mtimes = new StringBuilder("{\n");
		for (int i = 0; i < paths.size(); i++) {
			long mtime = t + i * 60000L;
			new File(root, paths.get(i)).setLastModified(mtime);
			mtimes.append("  " + str(paths.get(i)) + ": " + mtime + (i + 1 < paths.size() ? "," : "") + "\n");
		}
		mtimes.append("}\n");
		Files.write(new File(out, "mtimes.json").toPath(), mtimes.toString().getBytes(StandardCharsets.UTF_8));
	}

	static Map<FileObject, byte[]> contents = new HashMap<>();

	static FileObject site(FilesCollection collection, String filename, byte[] data, long timestamp) throws Exception {
		String site = collection == alpha ? "Alpha" : "Beta";
		FileObject f = new FileObject(site, filename, data.length, digest(filename, data), timestamp, Status.INSTALLED);
		collection.add(f);
		File download = new File(sites, site + "/" + filename + "-" + timestamp);
		download.getParentFile().mkdirs();
		Files.write(download.toPath(), data);
		return f;
	}

	static FileObject obsoleteSite(FilesCollection collection, String filename) {
		FileObject f = new FileObject(collection == alpha ? "Alpha" : "Beta", filename, -1, null, 0, Status.OBSOLETE_UNINSTALLED);
		collection.add(f);
		return f;
	}

	static void local(String path, byte[] data) throws Exception {
		File file = new File(root, path);
		file.getParentFile().mkdirs();
		Files.write(file.toPath(), data);
	}

	static void writeSite(String name, FilesCollection collection) throws Exception {
		File db = new File(sites, name + "/db.xml.gz");
		db.getParentFile().mkdirs();
		new XMLFileWriter(collection).write(new GZIPOutputStream(new FileOutputStream(db)), false);
	}

	/**
	 * A small jar: a manifest with build-specific headers, a .properties
	 * file with a date comment, a directory entry, stored and deflated
	 * classes, in an order that isn't sorted.
	 */
	static byte[] jar(String name, int variant) throws Exception {
		ByteArrayOutputStream bytes = new ByteArrayOutputStream();
		Manifest manifest = new Manifest();
		manifest.getMainAttributes().put(Attributes.Name.MANIFEST_VERSION, "1.0");
		manifest.getMainAttributes().putValue("Built-By", "someone-" + variant);
		manifest.getMainAttributes().putValue("Created-By", "Maven " + variant);
		manifest.getMainAttributes().putValue("Implementation-Title", name);
		try (JarOutputStream jar = new JarOutputStream(bytes)) {
			long time = 1600000000000L + variant * 1000L;
			// Written by hand: JarOutputStream would stamp it with the current time.
			ZipEntry manifestEntry = new ZipEntry(JarFile.MANIFEST_NAME);
			manifestEntry.setTime(time);
			jar.putNextEntry(manifestEntry);
			manifest.write(jar);
			jar.closeEntry();
			ZipEntry dir = new ZipEntry("org/example/" + name + "/");
			dir.setTime(time);
			jar.putNextEntry(dir);
			jar.closeEntry();
			ZipEntry props = new ZipEntry("org/example/" + name + "/build.properties");
			props.setTime(time);
			jar.putNextEntry(props);
			jar.write(("#Generated on day " + variant + "\n#\n#kept\nname=" + name + "\nversion=" + (variant % 2) + "\n")
				.getBytes(StandardCharsets.ISO_8859_1));
			jar.closeEntry();
			byte[] classBytes = new byte[300];
			new Random(name.hashCode() * 31L + variant).nextBytes(classBytes);
			ZipEntry stored = new ZipEntry("org/example/" + name + "/Stored.class");
			stored.setMethod(ZipEntry.STORED);
			stored.setSize(classBytes.length);
			CRC32 crc = new CRC32();
			crc.update(classBytes);
			stored.setCrc(crc.getValue());
			stored.setTime(time);
			jar.putNextEntry(stored);
			jar.write(classBytes);
			jar.closeEntry();
			ZipEntry deflated = new ZipEntry("org/example/" + name + "/A.class");
			deflated.setTime(time);
			jar.putNextEntry(deflated);
			for (int i = 0; i < 20; i++) jar.write(("class " + name + " part " + i + "\n").getBytes(StandardCharsets.UTF_8));
			jar.closeEntry();
		}
		return bytes.toByteArray();
	}

	static String digest(String path, byte[] data) throws Exception {
		File tmp = File.createTempFile("digest", path.endsWith(".jar") ? ".jar" : ".bin");
		Files.write(tmp.toPath(), data);
		String result = UpdaterUtil.getDigest(path, tmp);
		tmp.delete();
		return result;
	}

	// -- Helpers --

	static String sha1(byte[] data) throws Exception {
		StringBuilder sb = new StringBuilder();
		for (byte b : MessageDigest.getInstance("SHA-1").digest(data)) sb.append(String.format("%02x", b & 0xff));
		return sb.toString();
	}

	static void writeGzip(File file, byte[] data) throws IOException {
		try (OutputStream o = new GZIPOutputStream(new FileOutputStream(file))) {
			o.write(data);
		}
	}

	static String str(String s) {
		if (s == null) return "null";
		StringBuilder sb = new StringBuilder("\"");
		for (char c : s.toCharArray()) {
			if (c == '"' || c == '\\') sb.append('\\').append(c);
			else if (c == '\n') sb.append("\\n");
			else if (c == '\t') sb.append("\\t");
			else if (c == '\r') sb.append("\\r");
			else if (c < 0x20 || c > 0x7e) sb.append(String.format("\\u%04x", (int) c));
			else sb.append(c);
		}
		return sb.append('"').toString();
	}

	static String strings(List<String> list) {
		StringBuilder sb = new StringBuilder("[");
		for (int i = 0; i < list.size(); i++) sb.append(i > 0 ? ", " : "").append(str(list.get(i)));
		return sb.append("]").toString();
	}

	static void deleteRecursively(File f) {
		File[] children = f.listFiles();
		if (children != null) for (File c : children) deleteRecursively(c);
		f.delete();
	}

	static void copyRecursively(File from, File to) throws IOException {
		if (from.isDirectory()) {
			to.mkdirs();
			for (File c : from.listFiles()) copyRecursively(c, new File(to, c.getName()));
		} else {
			Files.copy(from.toPath(), to.toPath(), StandardCopyOption.COPY_ATTRIBUTES);
		}
	}
}
