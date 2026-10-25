# Mancora roadmap

Mancora reimplements Fiji/ImageJ natively in Swift. It's optimized for macOS,
with a native Windows port and a headless Linux CLI. Existing Fiji Java
plugins keep working during the transition through a bridge.

## Architecture

### Packages

The root `Package.swift` holds platform-neutral code only:

| Module | Purpose | May import |
| --- | --- | --- |
| `MancoraCore` | Pixel model, stacks, hyperstacks, calibration, LUTs, `DisplayMapper`; later ROIs | Swift standard library, `FoundationEssentials` |
| `MancoraIO` | `ByteReader`, LUT reader, TIFF reader; later OME-TIFF, OME-Zarr | Core, `FoundationEssentials` |
| `MancoraProcessing` | Filters, conversions, measurements (Phase 2) | Core |
| `MancoraCommands` | ImageJ command table (`"Gaussian Blur..."` + option strings), which drives menus, macro `run()`, the recorder and the bridge (Phase 2) | Core, Processing |
| `MancoraMacro` | ImageJ macro language interpreter (Phase 3) | Core, Commands |
| `MancoraBridge` | Java plugin bridge client (Phase 4) | Core, IO |
| `MancoraCAPI` | A small C interface, kept as a fallback for non-Swift shells | Core, IO |
| `MancoraAccelerate`, `MancoraMetal` | Fast paths that compile to nothing off macOS (`#if canImport`) | Core, Apple frameworks |
| `mancora` (CLI) | Headless use, including batch macros on Linux clusters | everything platform-neutral |

The app shells are separate packages, so their dependencies never reach
the core:

- `Apps/macOS/`: SwiftUI and AppKit, Metal rendering, Sparkle updates. It
  starts as a SwiftPM executable; Phase 1 adds an XcodeGen `project.yml`.
- `Apps/Windows/`: WinUI 3 via swift-winrt, with Direct3D 11 drawing into
  a SwapChainPanel. D3D11 is enough for showing images.

Swift settings: Swift 6 language mode everywhere, with `ExistentialAny`,
`InternalImportsByDefault` and `MemberImportVisibility` turned on. The app
targets use `defaultIsolation(MainActor.self)`. The core has no default
isolation and uses `Sendable` value types. The macro interpreter will run on
its own thread, because it's synchronous and blocks waiting on the UI.

### Data model

- **Pixel types:** `gray8`, `gray16`, `gray32Float`, `rgb8`, as in ImageJ.
  - RGB is stored as a `UInt32` with value `0xAARRGGBB`, which is BGRA in
    little-endian memory, the layout Metal, DXGI and Core Graphics take
    directly.
  - Signed 16-bit data is stored unsigned with a −32768 value calibration;
    32-bit integers become float.
- **`Plane`:** one 2D plane. **`ImageStack`:** same-sized planes in
  channel → Z → time order.
- **`Hyperstack`** (ImageJ's `ImagePlus`): a copy-on-write value holding:
  - the stack and its `HyperstackDimensions`
  - `Calibration`
  - per-channel `ChannelDisplay` (LUT, display range, visibility)
  - a `CompositeMode`
- Indices are 0-based inside, and 1-based only at the macro and UI boundary.

From Phase 1, planes move to page-aligned storage so Metal can use them
without copying. Virtual (lazy) and memory-mapped stacks follow, with
64-bit indexing throughout.

### Processing

The CPU code in the core defines correct behavior. It's ported from
ImageJ1's public-domain source so edge handling, kernels and rounding match
ImageJ.

Faster Accelerate, Metal and Direct3D versions register per operation and
pixel type, and each one states whether it's bit-exact or within a
tolerance. Cross-check tests compare every fast path against the CPU
version.

Measurements and thresholds always run on the CPU, and Core Image is
never used for numeric work, because of its color management and
half-float intermediates.

### Java bridge

Fiji's plugin ecosystem (Bio-Formats, TrackMate, TrakEM2, …) runs in a
**separate helper process** (a trimmed JRE plus Fiji's jars), with pixels in
shared memory and commands as JSON, in the style of SciJava Appose. It
doesn't run in-process through JNI, for these reasons:

- A JVM crash or out-of-memory error can't take Mancora down, and the helper
  can be restarted.
- Java's UI toolkit (AWT) never shares an event loop with AppKit or WinUI.
- The macOS app needs no JIT entitlements.

The same helper serves as the reference oracle for ImageJ parity tests.

## Phases

Each phase ends with a pass/fail test.

### P0: Skeleton (this milestone)

- SwiftPM packages, the `mancora` CLI, the macOS viewer stub, and CI on
  macOS, Windows and Linux.
- The LUT reader handles NIH Image, raw and text formats.
- The TIFF reader handles:
  - 1, 8, 16 and 32-bit and RGB data
  - strips and tiles
  - none, PackBits and LZW compression, with the predictor
  - multi-page files and ImageJ hyperstack metadata

**Exit:** CI is green on all three operating systems. All bundled LUTs match
ImageJ, the TIFF fixture matrix passes, and the macOS stub shows a TIFF with
a LUT.

**Release 0.1.0** ships this milestone as installers built by
`.github/workflows/release.yml`:
- a universal, ad-hoc-signed `Mancora.app` in a DMG
- a per-user Windows installer with an interim Win32 viewer and the CLI
- a static Linux CLI tarball

Merging a `VERSION` bump into `main` publishes the next release
automatically. Developer ID signing and notarization, and Windows code
signing, follow in P7.

### P1: macOS viewer

- Adds:
  - Deflate, BigTIFF, and ImageJ's private metadata tags 50838/50839
    (per-channel LUTs and ranges, ROIs, overlays)
  - TIFF saving, and virtual and memory-mapped stacks
  - the Metal renderer, C/Z/T sliders, and brightness/contrast with ImageJ's
    Auto algorithm
  - an XcodeGen app bundle with the Mancora icon, and nightly ad-hoc signed
    builds
- A time-boxed Windows test: show a core image in a WinUI SwapChainPanel
  through swift-winrt.

**Exit:** Fiji reopens Mancora-saved hyperstacks identically, and a 2 GB
16-bit 4D stack scrolls smoothly.

### P2: ImageJ1 essentials

- Adds:
  - all ROI types, `.roi` and `RoiSet.zip` files, and the ROI Manager
  - measurements, Analyze Particles and the results table
  - type conversions, the core filters, the 16 threshold methods and
    Z-project
  - the command table and the macro recorder

**Exit:** automated comparison against Fiji running headless (through the
bridge helper), exact for integer results and within tolerance for float.

### P3: Macro language

- Port ImageJ's public-domain Tokenizer and Interpreter, with batch mode
  and the built-in functions.

**Exit:** the bundled macros and a test corpus give the same results as
ImageJ, and `mancora --headless -macro` works on Linux.

### P4: Java bridge

- Bio-Formats and selected Fiji plugins appear in Mancora's menus.

**Exit:** killing the helper loses no data, and it restarts automatically.

### P5: Windows shell

- WinUI 3 app with Direct3D 11 rendering, built on the same core.

**Exit:** everything from P1–P3 works on Windows, and the same test suite
passes.

### P6: Native formats

- OME-TIFF with pyramids, OME-Zarr 0.4/0.5 (zstd and blosc), CZI, LIF, ND2.

**Exit:** the OME sample images open with the same dimensions, calibration
and channels that Bio-Formats reports.

### P7: Distribution

- macOS: Developer ID signing, hardened runtime, notarization, DMG, and
  Sparkle 2 updates.
- Windows: MSIX with Trusted Signing, and a WinGet manifest.
- No Mac App Store, because the app is GPL.

## Hardest parts

- **Macro fidelity:** about 400 built-in functions, `run()` option strings
  that need command-level parity, number formatting, batch mode, and
  "active image" semantics.
- **Exact pixel parity** for ROI masks (ImageJ's `PolygonFiller`) and
  filters, which measurements depend on.
- **Bio-Formats breadth**, until the native readers in P6 cover the common
  formats.
- **The Java bridge on Windows**, and packaging a trimmed JRE.
- **WinUI via swift-winrt:** its main sponsor's priorities have shifted, so
  Mancora may need to maintain it. The C interface keeps a C#/C++ shell
  possible.

## Licensing

Mancora is GPL-3.0-or-later, matching Fiji. ImageJ1 is public domain, so
porting its algorithms is unrestricted. Fiji plugins licensed GPL-2-only
are never ported; they run only through the bridge. Bundled third-party
material is listed in `THIRD_PARTY_NOTICES.md`.
