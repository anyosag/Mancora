<p align="center"><img src="Resources/Branding/mancora-lockup.svg" alt="Mancora" width="420"></p>

# Mancora

Mancora is a native Swift port of [Fiji](https://fiji.sc) (ImageJ) for
scientific image analysis. It's built for macOS first (SwiftUI, Metal,
Accelerate) and also ships natively on Windows (WinUI 3). A headless
command-line tool runs on Linux.

> **Status: 0.1.0, the first preview.** Mancora opens TIFF images, stacks
> and hyperstacks and shows them through ImageJ's LUTs, on macOS and
> Windows. See the [roadmap](docs/ROADMAP.md) for what comes next.

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
| `Package.swift`, `Sources/` | The platform-neutral Swift packages: `MancoraCore` (image model, LUTs, display mapping), `MancoraIO` (LUT and TIFF readers) and the `mancora` CLI. They build on macOS, Windows and Linux. |
| `Apps/macOS/` | The macOS app shell (SwiftUI). |
| `Apps/Windows/` | The Windows app: a small native Win32 viewer until the WinUI 3 shell arrives in Phase 5. |
| `Resources/` | LUTs, macros and sample scripts carried over from Fiji, and the Mancora brand assets in `Resources/Branding/`. |
| `Tests/` | Swift Testing suites and their fixtures. |
| `Tools/fixtures/` | Scripts that regenerate test fixtures with ImageJ, tifffile and ImageMagick. |
| `legacy/fiji/` | The original Fiji top-level project, kept as a reference and for the future Java plugin bridge. |

## Building

You need Swift 6.2 or later: Xcode 26 on macOS, or a
[swift.org toolchain](https://www.swift.org/install/) on Windows and Linux.

```sh
swift build
swift test
swift run mancora info path/to/image.tif
swift run mancora lut Resources/LUTs/mpl-viridis.lut
```

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

`Tools/fixtures/generate.sh` regenerates the fixtures.

## License

Mancora is free software under the GNU General Public License, version 3
or later (see `LICENSE.txt`), like the Fiji project it comes from. Bundled
third-party material is listed in [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).

Mancora builds on the work of Wayne Rasband (ImageJ), Johannes Schindelin
(Fiji), Curtis Rueden and the whole ImageJ and Fiji community.
