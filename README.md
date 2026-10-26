<p align="center"><img src="Resources/Branding/mancora-lockup.svg" alt="Mancora" width="420"></p>

# Mancora

Mancora is a native Swift port of [Fiji](https://fiji.sc) (ImageJ) for
scientific image analysis. It's built for macOS first (SwiftUI, Metal,
Accelerate) and also ships natively on Windows (WinUI 3). A headless
command-line tool runs on Linux.

> **Status: 0.2.0, a preview.** Mancora opens, saves and analyzes TIFF
> images, stacks and hyperstacks as ImageJ does: selections, measurements,
> filters and thresholds. It also runs ImageJ macros natively. Fiji's
> plugins, installed from Fiji's update sites, run in ImageJ inside a Java
> helper. The macOS app and the command line have all of this. Windows
> has a simple viewer and the command line. See the
> [roadmap](docs/ROADMAP.md) for what comes next.

## Installing

Download the installer for your system from the
[releases page](https://github.com/anyosag/Mancora/releases):

- **macOS 14 or later** (Apple silicon and Intel): `Mancora-<version>-macOS.dmg`.
  Open it and drag Mancora to Applications. The preview isn't notarized
  yet, so the first time, open it once, then click **Open Anyway** in
  **System Settings ▸ Privacy & Security**.
- **Windows 10 (1809) or later, x64**: `Mancora-<version>-Windows-x64-Setup.exe`.
  It installs for the current user, with no administrator rights needed.
  The installer isn't signed yet; if SmartScreen warns, choose
  **More info ▸ Run anyway**. A portable `.zip` is also available.
- **Linux** (command line only): `mancora-<version>-linux-x86_64.tar.gz`.

The installers are built by `.github/workflows/release.yml` with the
scripts in `Tools/package/`.

## Releasing

Releases are automatic:
1. In a pull request, set the new version in `VERSION` and in
   `MancoraVersion.number` (`Sources/MancoraCore/MancoraVersion.swift`). A
   test fails if the two disagree.
2. Optionally, describe the release in `docs/releases/<version>.md`.
3. Merge the pull request into `main`.

The release workflow then builds and smoke-tests the macOS, Windows and
Linux installers. It publishes them as GitHub release `v<version>`, with the
release notes, auto-generated change notes and checksums. Versions below 1.0
are marked as pre-releases.

A version is only ever released once, so other merges into `main` don't
create a release.

## Layout

| Path | What it is |
| --- | --- |
| `Package.swift`, `Sources/` | The platform-neutral Swift packages, which build on macOS, Windows and Linux: `MancoraCore` (image model, LUTs, display mapping), `MancoraIO` (TIFF, LUT and ROI files), `MancoraProcess` (filters, statistics, thresholds), `MancoraCommands` (ImageJ's commands and option strings), `MancoraMacro` (the macro language), `MancoraBridge` (ImageJ or Fiji in a Java helper), `MancoraFiji` (installs Fiji and keeps it up to date), `MancoraPlugins` (Fiji update sites), `MancoraUpdate` and `MancoraSupport`, and the `mancora` CLI. |
| `Apps/macOS/` | The macOS app shell (SwiftUI). |
| `Apps/Windows/` | The Windows app: a small native Win32 viewer until the WinUI 3 shell arrives in Phase 5. |
| `Resources/` | LUTs, macros and sample scripts carried over from Fiji, and the Mancora brand assets in `Resources/Branding/`. |
| `Tests/` | Swift Testing suites and their fixtures. |
| `Tools/fixtures/` | Scripts that regenerate test fixtures with ImageJ, tifffile and ImageMagick. |
| `legacy/fiji/` | The original Fiji top-level project, kept as a reference. |

## Building

You need Swift 6.2 or later: Xcode 26 on macOS, or a
[swift.org toolchain](https://www.swift.org/install/) on Windows and Linux.

```sh
swift build
swift test
swift run mancora info path/to/image.tif
swift run mancora lut Resources/LUTs/mpl-viridis.lut
swift run mancora --headless -macro analyze.ijm "an argument"
swift run mancora -eval 'print(getVersion());'
```

ImageJ macros run natively. A macro that uses something only ImageJ has
(plots, overlays, dialogs, Fiji plugins) runs in ImageJ instead, through
the Java bridge.

### Fiji behind the bridge

The bridge runs a Java helper. Once Fiji is installed, the helper runs
inside it: Fiji's bundled Java, Fiji's class path (`jars/`, `plugins/` and
their subfolders, with the options Fiji's own launcher gives) and ImageJ2
with its legacy layer, so ImageJ 1.x is Fiji's patched `ij.jar` and
Fiji's commands are all there: ImageJ 1.x plugins, SciJava commands
(TrackMate, Labkit, the Script Editor), and scripts in every installed
language.

```sh
swift run mancora fiji install                      # the latest Fiji for this computer, Java included
swift run mancora fiji status                       # version, location, last update check
swift run mancora fiji update --check               # what Fiji's update sites changed
swift run mancora fiji update                       # apply it (or stage it while a helper runs)
swift run mancora fiji auto-update off              # on by default: checked at most once a day
swift run mancora bridge menus                      # Fiji's menus, ImageJ 1.x and SciJava alike
swift run mancora bridge command "Process > Filters > Gaussian Blur..." sigma=2 in.tif
swift run mancora bridge script analyze.groovy threshold=0.5 in.tif
```

Fiji comes from `https://downloads.imagej.net/fiji/latest/`, which publishes
one archive per platform with Java bundled (`fiji-latest-macos-arm64-jdk.zip`,
`fiji-latest-macos64-jdk.zip`, `fiji-latest-linux64-jdk.zip`,
`fiji-latest-linux-arm64-jdk.zip`, `fiji-latest-win64-jdk.zip`), each beside
its SHA-256 (`<archive>.sha256`). The download is checked against it,
unpacked into a staging folder and renamed into place, in
`~/Library/Application Support/Mancora/Fiji` on macOS and
`$XDG_DATA_HOME/mancora/Fiji` (`~/.local/share/mancora/Fiji`) on Linux, or
`MANCORA_FIJI_HOME`. Fiji is downloaded on the user's computer, not
shipped with Mancora.

Updates come from the update sites Fiji's own `db.xml.gz` enables, read
by Mancora's port of Fiji's updater. They're applied to a copy of the
installation (hard links, so it costs only the new files), every
download checked against the site's checksum, and the copy is swapped in
by renaming: at once when no helper is running, else before the next
helper starts. Nothing changes the installation in place, so it's never
half updated. Files Fiji's own updater (run inside the helper) leaves in
`update/` are applied the same way, as Fiji's launcher would.

Requests run in batch, as tests need them: dialogs ImageJ shows are closed
by a watchdog and reported as errors. A bridge (or a single request) made
interactive shows ImageJ's dialogs and plugins' own windows (TrackMate's
wizard, Labkit) for the user instead; on macOS the helper then has a Dock
icon, named Fiji. Images a plugin's window goes on using stay open in the
helper.

Without Fiji, the bridge runs plain ImageJ 1.54p, which the parity tests
pin:

```sh
swift run mancora bridge setup                      # ImageJ 1.54p for the Java bridge (needs Java 11+)
swift run mancora update-sites known                # update sites Mancora knows by name
swift run mancora update-sites add IJPB-plugins     # or: add <name> <url>
swift run mancora update-sites update --dry-run     # what would change
swift run mancora update-sites update               # download, verify and install
swift run mancora bridge open image.czi out.tif     # any format ImageJ or Bio-Formats reads
```

The plain bridge's folder (`MANCORA_BRIDGE_HOME`, by default in your user's
application data) is laid out like Fiji's, with the same `db.xml.gz`, and
`mancora update-sites` manages it. Its ImageJ update site starts out
disabled, because the plain bridge runs ImageJ 1.x alone.

Run the viewer with:

```sh
swift run --package-path Apps/macOS     # macOS
swift run --package-path Apps/Windows   # Windows
```

To build installers locally, run `Tools/package/macos/package.sh`,
`Tools/package/windows/package.ps1` or `Tools/package/linux/package.sh`.
The output goes to `dist/`.

## Tests and fixtures

The tests compare Mancora with independent implementations rather than
with code written alongside it:

- Every bundled LUT and every built-in LUT is checked against what ImageJ
  1.54p's `LutLoader` produces.
- TIFF files written by ImageJ, tifffile and ImageMagick (libtiff) cover
  both byte orders; 1, 8, 16 and 32-bit and RGB data; strips and tiles; and
  none, PackBits and LZW compression, with and without the horizontal
  predictor.
- Malformed files (IFD loops, truncated data, huge dimensions, corrupt LZW,
  decompression bombs) must fail with an error and never crash.
- Every native command and a corpus of macros also run in ImageJ 1.54p
  through the Java bridge (`MancoraParityTests`, which needs a JDK and the
  path of ImageJ's jar in `MANCORA_TEST_IJ_JAR`). Their images, logs,
  errors and results must match.
- Update sites replay decisions recorded from Fiji's own updater
  (`Tools/parity/updater`): every file's status and action, the installed
  folder and the bytes of `db.xml.gz`. With `MANCORA_NETWORK_TESTS=1`,
  plugins are installed from Fiji's real sites and run through the bridge,
  and the latest Fiji is downloaded, run behind the bridge (an ImageJ 1.x
  command, SciJava commands and scripts, Fiji's menus) and checked for
  updates (`FijiNetworkTests`; `MANCORA_TEST_FIJI_DOWNLOADS` can name a
  folder already holding the archive and its `.sha256`).

`Tools/fixtures/generate.sh` regenerates the fixtures.

## License

Mancora is free software under the GNU General Public License, version 3
or later (see `LICENSE.txt`), like the Fiji project it comes from. Bundled
third-party material is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Mancora builds on the work of Wayne Rasband (ImageJ), Johannes Schindelin
(Fiji), Curtis Rueden and the whole ImageJ and Fiji community.
