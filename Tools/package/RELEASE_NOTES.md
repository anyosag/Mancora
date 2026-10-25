The first preview of **Mancora**, a native Swift port of Fiji (ImageJ) for scientific image analysis.

This is an early release: Mancora opens and displays TIFF images and stacks with ImageJ's lookup tables. Analysis, ROIs, macros and plugins come in later releases (see the [roadmap](https://github.com/anyosag/Mancora/blob/main/docs/ROADMAP.md)).

## What's in 0.1.0

- Opens TIFF files the way ImageJ does:
  - 8, 16 and 32-bit grayscale, RGB, palette and 1-bit images
  - stacks and hyperstacks with channels, slices and frames
  - uncompressed, PackBits and LZW compression, in strips or tiles
  - ImageJ calibration and display range
- Displays images through ImageJ's LUTs: the built-in ones (Fire, Ice, Spectrum, …), the 37 LUTs that ship with Fiji, or any `.lut` file.
- Steps through channels, slices and frames.
- Includes the `mancora` command-line tool (`mancora info image.tif`, `mancora lut file.lut`, `mancora --version`).

## Install

| Platform | Download | Notes |
| --- | --- | --- |
| macOS 14 or later (Apple silicon and Intel) | `Mancora-0.1.0-macOS.dmg` | Open the disk image and drag Mancora to Applications. |
| Windows 10 (1809) or later, x64 | `Mancora-0.1.0-Windows-x64-Setup.exe` | Installs for the current user, with no administrator rights needed. A portable `.zip` is also available. |
| Linux x86_64 (command line only) | `mancora-0.1.0-linux-x86_64.tar.gz` | Unpack and run `./mancora`. |

**First launch on macOS:** this preview isn't notarized by Apple yet, so macOS blocks it the first time.
1. Try to open Mancora once.
2. Go to **System Settings ▸ Privacy & Security** and click **Open Anyway** next to the Mancora message.

Alternatively, run `xattr -dr com.apple.quarantine /Applications/Mancora.app` in Terminal.

**First launch on Windows:** the installer isn't code-signed yet, so SmartScreen may warn about it. Click **More info ▸ Run anyway**.

`SHA256SUMS.txt` lists the checksum of every download.

Mancora is free software under the GNU General Public License, version 3 or later.
