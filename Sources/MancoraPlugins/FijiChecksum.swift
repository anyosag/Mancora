public import MancoraIO
import MancoraSupport

/// The checksums Fiji's updater records for files (a port of
/// `net.imagej.updater.util.UpdaterUtil.getDigest` and its stream filters,
/// BSD-2-Clause, Copyright (C) 2009 - 2025 Board of Regents of the
/// University of Wisconsin-Madison, Broad Institute of MIT and Harvard, and
/// Max Planck Institute of Molecular Cell Biology and Genetics).
///
/// They are SHA-1 digests, but not of the file as it is:
/// - a jar's digest covers each entry's name and contents, the entries
///   sorted by name, with comment lines dropped from `.properties` files and
///   the manifest left out, so rebuilding a jar doesn't change it;
/// - any other file's digest covers its path (relative to the Fiji folder)
///   and then its contents.
public enum FijiChecksum {
    /// The checksum the updater records for `path` with `contents`.
    public static func digest(path: String, contents: [UInt8]) throws(MancoraIOError) -> String {
        if path.hasSuffix(".jar") { return try jarDigest(contents) }
        var sha = SHA1()
        sha.update(asciiBytes(path))
        sha.update(contents)
        return hexString(sha.finalize())
    }

    /// The checksums older updaters recorded for a jar (`getObsoleteDigests`),
    /// which a database may still list among a file's previous versions.
    public static func obsoleteDigests(path: String, contents: [UInt8]) throws(MancoraIOError) -> [String] {
        guard path.hasSuffix(".jar") else { return [] }
        return [
            try jarDigest(contents, properties: true, manifests: true, keepOnlyMainClass: false),
            try jarDigest(contents, properties: true, manifests: false, keepOnlyMainClass: false),
            try jarDigest(contents, properties: false, manifests: false, keepOnlyMainClass: false),
        ]
    }

    /// `getJarDigest(file, treatPropertiesSpecially, treatManifestsSpecially, keepOnlyMainClassInManifest)`.
    public static func jarDigest(
        _ jar: [UInt8], properties: Bool = true, manifests: Bool = true, keepOnlyMainClass: Bool = true
    ) throws(MancoraIOError) -> String {
        let entries = try ZipContents.read(jar)
        // JarEntryComparator: String.compareTo, by UTF-16 code unit.
        let sorted = entries.enumerated().sorted { a, b in
            let x = Array(a.element.name.utf16), y = Array(b.element.name.utf16)
            return x.lexicographicallyPrecedes(y) || (x == y && a.offset < b.offset)
        }.map(\.element)
        var sha = SHA1()
        for entry in sorted {
            sha.update(asciiBytes(entry.name))
            var data = entry.data
            if properties && entry.name.hasSuffix(".properties") { data = skipHashedLines(data) }
            if manifests && entry.name == "META-INF/MANIFEST.MF" { data = filterManifest(data, keepOnlyMainClass: keepOnlyMainClass) }
            sha.update(data)
        }
        return hexString(sha.finalize())
    }

    /// `String.getBytes("ASCII")`: characters outside ASCII become `?`.
    static func asciiBytes(_ s: String) -> [UInt8] {
        s.unicodeScalars.map { $0.value < 128 ? UInt8($0.value) : 0x3F }
    }

    /// `SkipHashedLines`: drops lines starting with `#` (the date in a
    /// properties file's comment), keeping their newline. As in the
    /// updater, a comment line that is just `#` leaves the next line's start
    /// unrecognized, so a comment right after it stays.
    static func skipHashedLines(_ input: [UInt8]) -> [UInt8] {
        var position = 0
        var atLineStart = true
        func raw() -> Int {
            guard position < input.count else { return -1 }
            defer { position += 1 }
            return Int(input[position])
        }
        func read() -> Int {
            var ch = raw()
            if atLineStart {
                if ch == 35 {  // '#'
                    repeat { ch = read() } while ch != 10 && ch != -1
                } else {
                    atLineStart = false
                }
            } else if ch == 10 {
                atLineStart = true
            }
            return ch
        }
        var out: [UInt8] = []
        out.reserveCapacity(input.count)
        while true {
            let ch = read()
            if ch < 0 { break }
            out.append(UInt8(ch))
        }
        return out
    }

    /// Manifest headers the updater ignores: they change with every build.
    static let skippedHeaders: Set<String> = [
        "ARCHIVER-VERSION", "BUILT-BY", "BUILD-JDK", "CLASS-PATH", "CREATED-BY", "IMPLEMENTATION-BUILD",
    ]

    /// `FilterManifest`: the manifest's lines without the build-specific
    /// headers. With `keepOnlyMainClass` it means to keep only `Main-Class`,
    /// but compares an upper-cased line with "Main-Class:", so it keeps
    /// nothing; the updater's checksums depend on that.
    static func filterManifest(_ input: [UInt8], keepOnlyMainClass: Bool) -> [UInt8] {
        var out = ""
        for line in readLines(String(decoding: input, as: UTF8.self)) {
            if keepOnlyMainClass {
                if line.uppercased().hasPrefix("Main-Class:") { out += line + "\n" }
                continue
            }
            if let colon = line.firstIndex(of: ":"), colon != line.startIndex,
                skippedHeaders.contains(line[..<colon].uppercased())
            {
                continue
            }
            out += line + "\n"
        }
        return Array(out.utf8)
    }

    /// `BufferedReader.readLine`: lines ended by \n, \r or \r\n; no empty last line.
    static func readLines(_ text: String) -> [String] {
        var lines: [String] = []
        var current = ""
        var previousCR = false
        for scalar in text.unicodeScalars {
            if scalar == "\n" {
                if !previousCR { lines.append(current) }
                current = ""
                previousCR = false
            } else if scalar == "\r" {
                lines.append(current)
                current = ""
                previousCR = true
            } else {
                current.unicodeScalars.append(scalar)
                previousCR = false
            }
        }
        if !current.isEmpty { lines.append(current) }
        return lines
    }
}
