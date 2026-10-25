# Test fixtures

`generate.sh` rebuilds everything in `Tests/Fixtures/`. The data comes from
writers that share no code with Mancora, so a bug in Mancora's reader can't
be hidden by the same bug in a test helper.

| Output | Written by |
| --- | --- |
| `luts-golden.json` | ImageJ 1.54p `LutLoader`: every file in `Resources/LUTs/` and ImageJ's built-in LUTs |
| `tiff/ij-*.tif` | ImageJ 1.54p `FileSaver`: hyperstack, LUT, stack, float and RGB files |
| `tiff/tf-*.tif` | tifffile + imagecodecs: byte orders, bit depths, strips, tiles, planar data, PackBits, LZW, predictor |
| `tiff/im-*.tif` | ImageMagick (libtiff): LZW tiles, PackBits, 16-bit big-endian and 1-bit images |
| `tiff/manifest.json` | `make_tiffs.py`: the pattern each `tf-`/`im-` file holds |

The pixel patterns are defined three times, and the definitions must agree:
`make_tiffs.py`, `ImageJFixtures.java`, and `Tests/MancoraIOTests/Patterns.swift`.

One deliberate difference from ImageJ is tested explicitly: `cividis.txt`
stores 0–1 floats. ImageJ truncates them to 0 or 1, and Mancora scales them
to 0–255.
