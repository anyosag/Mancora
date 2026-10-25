<p align="center"><img src="Resources/Branding/mancora-lockup.svg" alt="Mancora" width="420"></p>

# Mancora

Mancora is a native Swift port of [Fiji](https://fiji.sc) (ImageJ) for
scientific image analysis. It's built for macOS first (SwiftUI, Metal,
Accelerate) and also ships natively on Windows (WinUI 3). A headless
command-line tool runs on Linux.

> **Status: Phase 0, the skeleton.** The core reads ImageJ LUTs and TIFF
> stacks and hyperstacks, and a minimal macOS viewer shows them. See the
> [roadmap](docs/ROADMAP.md) for what comes next.

## Layout

| Path | What it is |
| --- | --- |
| `Package.swift`, `Sources/` | The platform-neutral Swift packages: `MancoraCore` (image model, LUTs, display mapping), `MancoraIO` (LUT and TIFF readers) and the `mancora` CLI. They build on macOS, Windows and Linux. |
| `Apps/macOS/` | The macOS app shell (SwiftUI). |
| `Apps/Windows/` | The Windows app shell (WinUI 3), from Phase 5. |
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

On macOS, run the viewer with:

```sh
swift run --package-path Apps/macOS
```

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
