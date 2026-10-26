# Test fixtures

`generate.sh` rebuilds everything in `Tests/Fixtures/`. The data comes from
writers that share no code with Mancora, so a bug in Mancora's reader can't
be hidden by the same bug in a test helper.

| Output | Written by |
| --- | --- |
| `luts-golden.json` | ImageJ 1.54p `LutLoader`: every file in `Resources/LUTs/` and ImageJ's built-in LUTs |
| `tiff/ij-*.tif` | ImageJ 1.54p `FileSaver`: hyperstack, LUT, stack, float and RGB files, and `ij-metadata-*` with every metadata record (Info, labels, ranges, LUTs, ROI, overlay, properties) in both byte orders |
| `tiff/tf-*.tif` | tifffile + imagecodecs: byte orders, bit depths (including float16/64 and 16-bit RGB), strips, tiles, planar data, PackBits, LZW, Deflate, both predictors, BigTIFF |
| `tiff/im-*.tif` | ImageMagick (libtiff): LZW and Deflate tiles, PackBits, 16-bit big-endian and 1-bit images |
| `tiff/manifest.json` | `make_tiffs.py`: the pattern each `tf-`/`im-` file holds |
| `deflate/*` | `make_deflate.py`, Python's zlib: raw, zlib and gzip streams at several levels |

The pixel patterns are defined three times, and the definitions must agree:
`make_tiffs.py`, `ImageJFixtures.java`, and `Tests/MancoraIOTests/Patterns.swift`.

One deliberate difference from ImageJ is tested explicitly: `cividis.txt`
stores 0–1 floats. ImageJ truncates them to 0 or 1, and Mancora scales them
to 0–255.

## ImageJ reopen parity

`Tools/parity/tiff-reopen.sh <mancora>` checks the writer against ImageJ
itself (CI runs it): ImageJ saves a varied set of images, `mancora convert`
re-saves them and every TIFF fixture, and ImageJ opens each original and
copy and compares layout, pixels, calibration, LUTs, display ranges, labels,
Info, properties, selection and overlay. Everything ImageJ saved must match.
The report also lists the fixtures ImageJ can only open through Mancora
(tiles, BigTIFF, float16/64, the floating-point predictor) and the few its
own reader decodes differently (predictor 3, planar Deflate 16-bit RGB,
PackBits 1-bit, and multi-page 16-bit RGB, which `Opener.openImage` leaves
as plain slices although File ▸ Open shows the same composite as Mancora).
