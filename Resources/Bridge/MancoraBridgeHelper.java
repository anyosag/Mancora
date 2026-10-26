// Mancora's Java bridge helper: runs ImageJ (and the ImageJ 1.x plugins and
// Bio-Formats found under -Dplugins.dir) in a separate process, so a plugin
// crash or out-of-memory error never takes Mancora down.
//
//   java -Djava.awt.headless=true -Dplugins.dir=<root> -cp ij.jar:<jars> MancoraBridgeHelper
//
// Protocol: one JSON object per line. Mancora writes requests to stdin,
//   {"id": 1, "method": "run", "params": {...}}
// and the helper answers each on stdout, in order,
//   {"id": 1, "result": {...}}   or   {"id": 1, "error": "message"}
// Everything ImageJ prints (IJ.log in headless mode goes to System.out) is
// captured and returned as the request's "log", so stdout carries only the
// protocol. Images travel as TIFF files, which both sides read and write
// identically.
//
// Methods:
//   hello                                 -> {imagej, java, pluginsDir}
//   commands                              -> {commands: [{name, className}]}
//   run {command, options, inputs[], outputDir}
//                                         -> {outputs[], log, results}
//   macro {code, inputs[], outputDir}     -> {outputs[], log, results, value}
//   shutdown                              -> {} (then exits)
//
// "inputs" are TIFF paths opened in order (the last is the active image);
// every image open afterwards that wasn't an input, plus inputs a command
// changed, is saved as TIFF into outputDir and listed in "outputs".

import ij.IJ;
import ij.ImageJ;
import ij.CompositeImage;
import ij.ImagePlus;
import ij.Macro;
import ij.Menus;
import ij.WindowManager;
import ij.io.FileSaver;
import ij.macro.Interpreter;
import ij.measure.ResultsTable;
import ij.process.LUT;
import java.io.*;
import java.nio.charset.StandardCharsets;
import java.util.*;

public class MancoraBridgeHelper {
    static PrintStream protocol;
    static ByteArrayOutputStream captured = new ByteArrayOutputStream();

    public static void main(String[] args) throws Exception {
        protocol = new PrintStream(new FileOutputStream(FileDescriptor.out), true, "UTF-8");
        PrintStream capture = new PrintStream(captured, true, "UTF-8");
        System.setOut(capture);
        System.setErr(capture);
        Interpreter.batchMode = true;
        if (java.awt.GraphicsEnvironment.isHeadless()) installHeadlessCommands();
        else DialogWatchdog.start();
        BufferedReader in = new BufferedReader(new InputStreamReader(System.in, StandardCharsets.UTF_8));
        String line;
        while ((line = in.readLine()) != null) {
            if (line.trim().isEmpty()) continue;
            Object id = null;
            try {
                Map<String, Object> request = Json.object(Json.parse(line));
                id = request.get("id");
                String method = (String) request.get("method");
                Map<String, Object> params = request.get("params") == null
                    ? new LinkedHashMap<>() : Json.object(request.get("params"));
                Map<String, Object> result = handle(method, params);
                respond(id, result, null);
                if ("shutdown".equals(method)) break;
            } catch (Throwable e) {
                respond(id, null, e.getClass().getSimpleName() + ": " + e.getMessage());
            }
        }
        protocol.flush();
        System.exit(0);
    }

    /**
     * ImageJ 1.x builds its command table while it builds its AWT menus,
     * which it can't do headless. Install the table recorded from a real
     * session (-Dmancora.commands, written by Tools/bridge/CommandTable.java)
     * plus the commands of plugin jars, so IJ.run finds every command.
     */
    static void installHeadlessCommands() throws Exception {
        Hashtable<String, String> table = new Hashtable<>();
        String recorded = System.getProperty("mancora.commands");
        if (recorded != null) {
            for (String line : java.nio.file.Files.readAllLines(new File(recorded).toPath(), StandardCharsets.UTF_8)) {
                if (line.startsWith("#") || line.indexOf('\t') < 0) continue;
                int tab = line.indexOf('\t');
                table.put(line.substring(0, tab), line.substring(tab + 1));
            }
        }
        String dir = System.getProperty("plugins.dir");
        if (dir != null) addPluginJars(new File(dir, "plugins"), table, 0);
        java.lang.reflect.Field field = Menus.class.getDeclaredField("pluginsTable");
        field.setAccessible(true);
        field.set(null, table);
    }

    /** Commands from the plugins.config of jars in plugins/ and one level below, as Menus does. */
    static void addPluginJars(File folder, Hashtable<String, String> table, int depth) {
        File[] files = folder.listFiles();
        if (files == null) return;
        Arrays.sort(files);
        for (File f : files) {
            if (f.isDirectory() && depth == 0) addPluginJars(f, table, 1);
            if (!f.getName().endsWith(".jar")) continue;
            try (java.util.jar.JarFile jar = new java.util.jar.JarFile(f)) {
                java.util.zip.ZipEntry entry = jar.getEntry("plugins.config");
                if (entry == null) continue;
                BufferedReader r = new BufferedReader(new InputStreamReader(jar.getInputStream(entry), StandardCharsets.UTF_8));
                String line;
                while ((line = r.readLine()) != null) {
                    line = line.trim();
                    if (line.isEmpty() || line.startsWith("#")) continue;
                    // menu, "Label", package.Class("argument")
                    int open = line.indexOf('"'), close = open < 0 ? -1 : line.indexOf('"', open + 1);
                    if (close < 0) continue;
                    String label = line.substring(open + 1, close);
                    int comma = line.indexOf(',', close);
                    if (comma < 0 || label.equals("-")) continue;
                    table.put(label, line.substring(comma + 1).trim());
                }
            } catch (IOException e) {
                System.err.println("Skipping plugin jar " + f + ": " + e);
            }
        }
    }

    static void respond(Object id, Map<String, Object> result, String error) {
        Map<String, Object> response = new LinkedHashMap<>();
        response.put("id", id);
        if (error != null) {
            response.put("error", error);
            response.put("log", takeLog());
        } else {
            response.put("result", result);
        }
        protocol.println(Json.write(response));
        protocol.flush();
    }

    static String takeLog() {
        String text = new String(captured.toByteArray(), StandardCharsets.UTF_8);
        captured.reset();
        return text;
    }

    static Map<String, Object> handle(String method, Map<String, Object> params) throws Exception {
        Map<String, Object> result = new LinkedHashMap<>();
        switch (method) {
            case "hello":
                result.put("imagej", IJ.getVersion());
                result.put("java", System.getProperty("java.version"));
                result.put("pluginsDir", System.getProperty("plugins.dir"));
                result.put("pid", ProcessHandle.current().pid());
                return result;
            case "commands": {
                Hashtable<?, ?> table = Menus.getCommands();
                List<Object> commands = new ArrayList<>();
                List<String> names = new ArrayList<>();
                if (table != null) for (Object key : table.keySet()) names.add(String.valueOf(key));
                Collections.sort(names);
                for (String name : names) {
                    Map<String, Object> c = new LinkedHashMap<>();
                    c.put("name", name);
                    c.put("className", String.valueOf(table.get(name)));
                    commands.add(c);
                }
                result.put("commands", commands);
                return result;
            }
            case "run":
            case "macro":
                return runWithImages(method, params);
            case "open":
                return openFile(params);
            case "crash":
                // For tests of the supervisor: die without answering.
                Runtime.getRuntime().halt(3);
                return result;
            case "shutdown":
                return result;
            default:
                throw new IllegalArgumentException("unknown method " + method);
        }
    }

    static Map<String, Object> runWithImages(String method, Map<String, Object> params) throws Exception {
        closeAll();
        resetSettings();
        takeLog();
        ensureResultsPanel();
        ij.plugin.filter.Analyzer.resetCounter();
        List<String> inputs = new ArrayList<>();
        if (params.get("inputs") != null) for (Object o : Json.array(params.get("inputs"))) inputs.add((String) o);
        File outputDir = new File((String) params.get("outputDir"));
        Map<Integer, String> inputIDs = new LinkedHashMap<>();
        Map<Integer, Long> inputStamps = new HashMap<>();
        for (String path : inputs) {
            ImagePlus imp = IJ.openImage(path);
            if (imp == null) throw new IOException("ImageJ could not open " + path);
            Interpreter.addBatchModeImage(imp);
            WindowManager.setTempCurrentImage(imp);
            inputIDs.put(imp.getID(), path);
            inputStamps.put(imp.getID(), fingerprint(imp));
        }
        Map<String, Object> result = new LinkedHashMap<>();
        if (method.equals("run")) {
            String command = (String) params.get("command");
            String options = params.get("options") == null ? "" : (String) params.get("options");
            if (IJ.getInstance() == null && Menus.getCommands() == null) IJ.run("Close All");  // builds the table
            Hashtable<?, ?> table = Menus.getCommands();
            if (table != null && table.get(command) == null)
                throw new IllegalArgumentException("Unrecognized command: \"" + command + "\"");
            // Empty options would make ImageJ treat the call as interactive
            // (asking, for example, whether to process every slice); a space
            // keeps it a macro call that gives no options.
            if (options.isEmpty()) options = " ";
            DialogWatchdog.reset();
            ImagePlus active = WindowManager.getCurrentImage();
            if (active != null) IJ.run(active, command, options);
            else IJ.run(command, options);
            DialogWatchdog.check(command);
            String log = new String(captured.toByteArray(), StandardCharsets.UTF_8);
            if (java.awt.GraphicsEnvironment.isHeadless() && log.contains("java.awt.HeadlessException"))
                throw new IllegalStateException("\"" + command + "\" needs a display (ImageJ builds its dialog even "
                    + "when the options are given); run Mancora with a display, or install Xvfb");
        } else {
            DialogWatchdog.reset();
            // IJ.runMacro, but with the interpreter at hand: headless, its error
            // dialog throws, and the message it was about to show is reported.
            Interpreter interp = new Interpreter();
            String value = null;
            try {
                value = interp.run((String) params.get("code"), params.get("argument") == null ? "" : (String) params.get("argument"));
            } catch (Throwable t) {
                boolean cancelled = Macro.MACRO_CANCELED.equals(t.getMessage());
                if (interp.getErrorMessage() == null && !cancelled) throw t;
                if (interp.getErrorMessage() != null) {
                    result.put("macroError", interp.getErrorMessage());
                    try {
                        java.lang.reflect.Field line = Interpreter.class.getDeclaredField("lineNumber");
                        line.setAccessible(true);
                        result.put("macroErrorLine", line.getInt(interp));
                    } catch (Exception ignored) {
                    }
                    DialogWatchdog.forgetMacroError();
                }
            }
            DialogWatchdog.check("The macro");
            result.put("value", value);
        }
        // Save every image a command created, and the inputs it changed.
        List<Object> outputs = new ArrayList<>();
        int[] ids = WindowManager.getIDList();
        int n = 0;
        if (ids != null) for (int id : ids) {
            ImagePlus imp = WindowManager.getImage(id);
            if (imp == null) continue;
            boolean isInput = inputIDs.containsKey(id);
            if (isInput && inputStamps.get(id) == fingerprint(imp)) continue;
            File out = new File(outputDir, String.format("output-%03d.tif", n++));
            if (!new FileSaver(imp).saveAsTiff(out.getPath()))
                throw new IOException("ImageJ could not save " + imp.getTitle());
            Map<String, Object> o = new LinkedHashMap<>();
            o.put("path", out.getPath());
            o.put("title", imp.getTitle());
            o.put("replaces", isInput ? inputIDs.get(id) : null);
            outputs.add(o);
        }
        result.put("outputs", outputs);
        result.put("results", resultsTable());
        result.put("log", takeLog());
        closeAll();
        return result;
    }

    /**
     * Opens a file in any format ImageJ reads (with Fiji's extra file types,
     * if installed), or with Bio-Formats when it's installed, and saves each
     * image it opens as a TIFF for Mancora.
     */
    static Map<String, Object> openFile(Map<String, Object> params) throws Exception {
        closeAll();
        resetSettings();
        takeLog();
        String path = (String) params.get("path");
        File outputDir = new File((String) params.get("outputDir"));
        List<ImagePlus> opened = new ArrayList<>();
        String reader = "ImageJ";
        DialogWatchdog.reset();
        ImagePlus imp = IJ.openImage(path);
        if (imp != null) {
            opened.add(imp);
            DialogWatchdog.check("Opening " + new File(path).getName());
        }
        Class<?> bf = findClass("loci.plugins.BF");
        if (imp == null && bf != null) {
            // ImageJ's "unsupported format" message doesn't count if Bio-Formats can.
            DialogWatchdog.reset();
            ImagePlus[] all;
            try {
                all = (ImagePlus[]) bf.getMethod("openImagePlus", String.class).invoke(null, path);
            } catch (java.lang.reflect.InvocationTargetException e) {
                // Bio-Formats' own exception says what went wrong.
                Throwable cause = e.getCause() == null ? e : e.getCause();
                throw new IOException("Bio-Formats could not open " + path + ": " + cause, cause);
            }
            if (all != null) for (ImagePlus i : all) if (i != null) opened.add(i);
            reader = "Bio-Formats";
            DialogWatchdog.check("Bio-Formats");
        }
        if (opened.isEmpty())
            throw new IOException("ImageJ could not open " + path + (bf == null ? " (Bio-Formats isn't installed)" : ", nor could Bio-Formats"));
        List<Object> outputs = new ArrayList<>();
        int n = 0;
        for (ImagePlus i : opened) {
            File out = new File(outputDir, String.format("output-%03d.tif", n++));
            if (!new FileSaver(i).saveAsTiff(out.getPath())) throw new IOException("ImageJ could not save " + i.getTitle());
            Map<String, Object> o = new LinkedHashMap<>();
            o.put("path", out.getPath());
            o.put("title", i.getTitle());
            o.put("replaces", null);
            outputs.add(o);
            i.close();
        }
        Map<String, Object> result = new LinkedHashMap<>();
        result.put("outputs", outputs);
        result.put("results", resultsTable());
        result.put("log", takeLog());
        result.put("value", reader);
        closeAll();
        return result;
    }

    /** A class from ImageJ's class path or its plugins folder, or null. */
    static Class<?> findClass(String name) {
        try {
            return Class.forName(name, true, IJ.getClassLoader());
        } catch (Throwable t) {
            return null;
        }
    }

    /**
     * Nobody can answer a dialog here: ImageJ's errors, "Process all
     * slices?" and dialogs a command's options didn't fill in would wait
     * forever. The watchdog closes each one as it appears: questions are
     * answered "No" (the macro default: the current slice only), dialogs
     * wanting input are canceled, and messages are reported as the
     * command's error.
     */
    static final class DialogWatchdog {
        private static final List<String> errors = Collections.synchronizedList(new ArrayList<>());
        private static final List<String> questions = Collections.synchronizedList(new ArrayList<>());
        private static final Set<java.awt.Window> handled = Collections.newSetFromMap(new java.util.WeakHashMap<>());

        static void start() {
            Thread thread = new Thread(() -> {
                while (true) {
                    try { Thread.sleep(100); } catch (InterruptedException e) { return; }
                    for (java.awt.Window w : java.awt.Window.getWindows()) {
                        if (!(w instanceof java.awt.Dialog) || !w.isShowing() || handled.contains(w)) continue;
                        handled.add(w);
                        java.awt.Dialog d = (java.awt.Dialog) w;
                        String text = text(d).trim();
                        String message = text.isEmpty() ? d.getTitle() : text;
                        if (d instanceof ij.gui.GenericDialog) {
                            errors.add("ImageJ asked for input the options didn't give (\"" + d.getTitle() + "\" dialog)");
                            java.awt.EventQueue.invokeLater(() ->
                                d.dispatchEvent(new java.awt.event.WindowEvent(d, java.awt.event.WindowEvent.WINDOW_CLOSING)));
                        } else if (d instanceof ij.gui.YesNoCancelDialog) {
                            questions.add(message);
                            java.awt.EventQueue.invokeLater(d::dispose);  // neither yes nor cancel: no
                        } else {
                            errors.add(message);
                            java.awt.EventQueue.invokeLater(d::dispose);
                        }
                    }
                }
            }, "Mancora dialog watchdog");
            thread.setDaemon(true);
            thread.start();
        }

        static void reset() {
            errors.clear();
            questions.clear();
        }

        /** Drops the macro error dialog: the request reports that error itself. */
        static void forgetMacroError() {
            errors.removeIf(e -> e.endsWith("(\"Macro Error\" dialog)") || e.endsWith("(\"No Image\" dialog)"));
        }

        /** Logs the questions answered, and fails with the messages shown. */
        static void check(String what) {
            synchronized (questions) {
                for (String q : questions) IJ.log("ImageJ asked \"" + q.replace('\n', ' ') + "\"; answered No.");
            }
            synchronized (errors) {
                if (!errors.isEmpty()) throw new IllegalStateException(String.join("\n", errors));
            }
        }

        /** The labels in a dialog, including ImageJ's MultiLineLabel (whose text is private). */
        static String text(java.awt.Container c) {
            StringBuilder b = new StringBuilder();
            for (java.awt.Component k : c.getComponents()) {
                if (k instanceof java.awt.Label) b.append(((java.awt.Label) k).getText()).append('\n');
                else if (k instanceof ij.gui.MultiLineLabel) {
                    try {
                        java.lang.reflect.Field f = ij.gui.MultiLineLabel.class.getDeclaredField("lines");
                        f.setAccessible(true);
                        for (String line : (String[]) f.get(k)) b.append(line).append('\n');
                    } catch (Exception e) {
                        // no text after all
                    }
                } else if (k instanceof java.awt.TextArea) b.append(((java.awt.TextArea) k).getText()).append('\n');
                if (k instanceof java.awt.Container) b.append(text((java.awt.Container) k));
            }
            return b.toString();
        }
    }

    /**
     * Gives ImageJ a Results panel that is never shown. Without one (there's
     * no ImageJ window here) Analyzer keeps only the last row of each
     * Measure, as headless ImageJ does; with it, rows accumulate as on the
     * desktop. Headless Java can't make one, and keeps ImageJ's behavior.
     */
    static void ensureResultsPanel() {
        if (IJ.isResultsWindow() || java.awt.GraphicsEnvironment.isHeadless()) return;
        try {
            IJ.setTextPanel(new ij.text.TextPanel("Results"));
        } catch (Throwable t) {
            // no display after all
        }
    }

    /** A cheap change detector: a hash of every plane, the image's shape and type, and its metadata. */
    static long fingerprint(ImagePlus imp) {
        long h = 1125899906842597L;
        h = 31 * h + imp.getWidth();
        h = 31 * h + imp.getHeight();
        h = 31 * h + imp.getStackSize();
        h = 31 * h + imp.getBitDepth();
        ij.ImageStack stack = imp.getStack();
        for (int i = 1; i <= stack.getSize(); i++) {
            Object pixels = stack.getPixels(i);
            int ph;
            if (pixels instanceof byte[]) ph = Arrays.hashCode((byte[]) pixels);
            else if (pixels instanceof short[]) ph = Arrays.hashCode((short[]) pixels);
            else if (pixels instanceof float[]) ph = Arrays.hashCode((float[]) pixels);
            else if (pixels instanceof int[]) ph = Arrays.hashCode((int[]) pixels);
            else ph = 0;
            h = 31 * h + ph;
        }
        // And what ImageJ saves alongside the pixels: title, calibration and
        // the description (units, spacing, display range), LUTs, labels, info, ROI.
        h = 31 * h + Objects.hashCode(imp.getTitle());
        ij.measure.Calibration cal = imp.getCalibration();
        h = 31 * h + Double.hashCode(cal.pixelWidth);
        h = 31 * h + Double.hashCode(cal.pixelHeight);
        h = 31 * h + Double.hashCode(cal.xOrigin) + 7 * Double.hashCode(cal.yOrigin);
        h = 31 * h + Objects.hashCode(new FileSaver(imp).getDescriptionString());
        LUT[] luts = imp.isComposite() ? ((CompositeImage) imp).getLuts() : new LUT[] { imp.getProcessor().getLut() };
        byte[] reds = new byte[256], greens = new byte[256], blues = new byte[256];
        for (LUT lut : luts) {
            if (lut == null) continue;
            lut.getReds(reds); lut.getGreens(greens); lut.getBlues(blues);
            h = 31 * h + Arrays.hashCode(reds) + 3 * Arrays.hashCode(greens) + 7 * Arrays.hashCode(blues);
            h = 31 * h + Double.hashCode(lut.min) + 7 * Double.hashCode(lut.max);
        }
        h = 31 * h + Double.hashCode(imp.getDisplayRangeMin()) + 7 * Double.hashCode(imp.getDisplayRangeMax());
        h = 31 * h + Arrays.hashCode(stack.getSliceLabels());
        h = 31 * h + Objects.hashCode(imp.getInfoProperty());
        h = 31 * h + (imp.getRoi() == null ? 0 : imp.getRoi().toString().hashCode());
        return h;
    }

    static Map<String, Object> resultsTable() {
        ResultsTable rt = ResultsTable.getResultsTable();
        Map<String, Object> table = new LinkedHashMap<>();
        List<Object> columns = new ArrayList<>();
        List<Object> rows = new ArrayList<>();
        if (rt != null && rt.size() > 0) {
            // By column index: looking a column up by name stops at the first
            // unused heading, which Set Measurements can leave in the middle.
            String[] headings = rt.getHeadings();
            boolean labels = headings.length > 0 && headings[0].equals("Label") && rt.getColumnIndex("Label") < 0;
            List<Integer> indices = new ArrayList<>();
            if (labels) columns.add("Label");
            for (int i = 0; i <= rt.getLastColumn(); i++) {
                if (!rt.columnExists(i)) continue;
                String heading = rt.getColumnHeading(i);
                columns.add(heading == null ? "C" + (i + 1) : heading);
                indices.add(i);
            }
            for (int r = 0; r < rt.size(); r++) {
                List<Object> row = new ArrayList<>();
                if (labels) {
                    String label = null;
                    try { label = rt.getLabel(r); } catch (IllegalArgumentException e) { /* no labels after all */ }
                    row.add(label);
                }
                for (int i : indices) {
                    double v = rt.getValueAsDouble(i, r);
                    // JSON has no NaN or Infinity: those go as Java writes them.
                    if (Double.isNaN(v)) row.add(rt.getStringValue(i, r));
                    else if (Double.isInfinite(v)) row.add(Double.toString(v));
                    else row.add(v);
                }
                rows.add(row);
            }
        }
        table.put("columns", columns);
        table.put("rows", rows);
        return table;
    }

    /**
     * Each request starts from ImageJ's defaults, as a fresh ImageJ would:
     * settings a previous command or macro changed don't carry over.
     */
    static void resetSettings() {
        ij.plugin.filter.Analyzer.setMeasurements(
            ij.measure.Measurements.AREA + ij.measure.Measurements.MEAN + ij.measure.Measurements.MIN_MAX);
        ij.plugin.filter.Analyzer.setPrecision(3);
        ij.Prefs.blackBackground = true;
        ij.Prefs.padEdges = false;
        ij.process.ImageConverter.setDoScaling(true);
        ij.gui.Toolbar.setForegroundColor(java.awt.Color.white);
        ij.gui.Toolbar.setBackgroundColor(java.awt.Color.black);
        ij.gui.Toolbar.setForegroundValue(Double.NaN);
        ij.gui.Toolbar.setBackgroundValue(Double.NaN);
        ij.plugin.frame.RoiManager rm = ij.plugin.frame.RoiManager.getInstance();
        if (rm != null) rm.reset();
    }

    static void closeAll() {
        int[] ids = WindowManager.getIDList();
        if (ids != null) for (int id : ids) {
            ImagePlus imp = WindowManager.getImage(id);
            if (imp != null) {
                imp.changes = false;
                Interpreter.removeBatchModeImage(imp);
                imp.close();
            }
        }
        WindowManager.setTempCurrentImage(null);
    }

    /** Just enough JSON: objects, arrays, strings, numbers, booleans and null. */
    static final class Json {
        private final String s;
        private int i;

        private Json(String s) { this.s = s; }

        static Object parse(String text) {
            Json p = new Json(text);
            Object v = p.value();
            p.space();
            if (p.i != p.s.length()) throw new IllegalArgumentException("trailing characters in JSON");
            return v;
        }

        @SuppressWarnings("unchecked")
        static Map<String, Object> object(Object o) {
            if (!(o instanceof Map)) throw new IllegalArgumentException("expected a JSON object");
            return (Map<String, Object>) o;
        }

        @SuppressWarnings("unchecked")
        static List<Object> array(Object o) {
            if (!(o instanceof List)) throw new IllegalArgumentException("expected a JSON array");
            return (List<Object>) o;
        }

        private void space() { while (i < s.length() && Character.isWhitespace(s.charAt(i))) i++; }

        private Object value() {
            space();
            if (i >= s.length()) throw new IllegalArgumentException("unexpected end of JSON");
            char c = s.charAt(i);
            if (c == '{') {
                i++;
                Map<String, Object> m = new LinkedHashMap<>();
                space();
                if (s.charAt(i) == '}') { i++; return m; }
                while (true) {
                    space();
                    String key = string();
                    space();
                    expect(':');
                    m.put(key, value());
                    space();
                    if (s.charAt(i) == ',') { i++; continue; }
                    expect('}');
                    return m;
                }
            }
            if (c == '[') {
                i++;
                List<Object> a = new ArrayList<>();
                space();
                if (s.charAt(i) == ']') { i++; return a; }
                while (true) {
                    a.add(value());
                    space();
                    if (s.charAt(i) == ',') { i++; continue; }
                    expect(']');
                    return a;
                }
            }
            if (c == '"') return string();
            if (s.startsWith("true", i)) { i += 4; return Boolean.TRUE; }
            if (s.startsWith("false", i)) { i += 5; return Boolean.FALSE; }
            if (s.startsWith("null", i)) { i += 4; return null; }
            int start = i;
            while (i < s.length() && "+-0123456789.eE".indexOf(s.charAt(i)) >= 0) i++;
            if (start == i) throw new IllegalArgumentException("bad JSON at " + start);
            String number = s.substring(start, i);
            if (number.matches("-?\\d+") && number.length() < 18) return Long.parseLong(number);
            return Double.parseDouble(number);
        }

        private void expect(char c) {
            if (i >= s.length() || s.charAt(i) != c) throw new IllegalArgumentException("expected '" + c + "' at " + i);
            i++;
        }

        private String string() {
            expect('"');
            StringBuilder b = new StringBuilder();
            while (true) {
                char c = s.charAt(i++);
                if (c == '"') return b.toString();
                if (c != '\\') { b.append(c); continue; }
                char e = s.charAt(i++);
                switch (e) {
                    case 'n': b.append('\n'); break;
                    case 't': b.append('\t'); break;
                    case 'r': b.append('\r'); break;
                    case 'b': b.append('\b'); break;
                    case 'f': b.append('\f'); break;
                    case 'u': b.append((char) Integer.parseInt(s.substring(i, i + 4), 16)); i += 4; break;
                    default: b.append(e);
                }
            }
        }

        static String write(Object o) {
            StringBuilder b = new StringBuilder();
            write(o, b);
            return b.toString();
        }

        @SuppressWarnings("unchecked")
        private static void write(Object o, StringBuilder b) {
            if (o == null) b.append("null");
            else if (o instanceof String) quote((String) o, b);
            else if (o instanceof Boolean) b.append(o);
            else if (o instanceof Double || o instanceof Float) {
                double d = ((Number) o).doubleValue();
                if (Double.isNaN(d) || Double.isInfinite(d)) b.append("null");
                else b.append(d);
            } else if (o instanceof Number) b.append(o);
            else if (o instanceof Map) {
                b.append('{');
                boolean first = true;
                for (Map.Entry<String, Object> e : ((Map<String, Object>) o).entrySet()) {
                    if (!first) b.append(',');
                    first = false;
                    quote(e.getKey(), b);
                    b.append(':');
                    write(e.getValue(), b);
                }
                b.append('}');
            } else if (o instanceof List) {
                b.append('[');
                boolean first = true;
                for (Object v : (List<Object>) o) {
                    if (!first) b.append(',');
                    first = false;
                    write(v, b);
                }
                b.append(']');
            } else quote(String.valueOf(o), b);
        }

        private static void quote(String s, StringBuilder b) {
            b.append('"');
            for (int k = 0; k < s.length(); k++) {
                char c = s.charAt(k);
                switch (c) {
                    case '"': b.append("\\\""); break;
                    case '\\': b.append("\\\\"); break;
                    case '\n': b.append("\\n"); break;
                    case '\r': b.append("\\r"); break;
                    case '\t': b.append("\\t"); break;
                    default:
                        if (c < 0x20) b.append(String.format("\\u%04x", (int) c));
                        else b.append(c);
                }
            }
            b.append('"');
        }
    }
}
