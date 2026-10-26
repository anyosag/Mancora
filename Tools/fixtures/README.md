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
| `roi/*.roi`, `roi/RoiSet.zip` | ImageJ 1.54p `RoiEncoder` and the ROI Manager's own `saveMultiple()` (`RoiFixtures.java`): every ROI type, plus a few patched older-version files |
| `roi/golden.json` | `RoiFixtures.java`: each ROI as `RoiDecoder` reads it back, with `Roi.getMask()` and `ImageProcessor.fill(roi)` |
| `roi/mancora/RoiSet.zip` | Mancora's `RoiSet.encode`, from the ROIs described in `golden.json` |
| `roi/mancora/verified.json` | `RoiFixtures.java`: the ROI Manager's `openZip()` on Mancora's zip, compared ROI by ROI with its own |

### ROI files in both directions

`RoiFixtures.java` writes ImageJ's ROIs and their masks, and then checks
the ROI set Mancora wrote. When Mancora's ROI encoding changes, its
`committedSetIsCurrent` test fails; refresh both files with:

```sh
MANCORA_UPDATE_ROI_FIXTURES=1 swift test --filter committedSetIsCurrent
java -Djava.awt.headless=true -cp ij-1.54p.jar Tools/fixtures/RoiFixtures.java .
```

The second command rewrites `roi/mancora/verified.json`, which the
`imageJReadsMancorasSet` test checks (including the zip's CRC, so it can't
go stale). The zip's dates are fixed, so the fixtures only change when
the ROIs do.

The pixel patterns are defined three times, and the definitions must agree:
`make_tiffs.py`, `ImageJFixtures.java`, and `Tests/MancoraIOTests/Patterns.swift`.

One deliberate difference from ImageJ is tested explicitly: `cividis.txt`
stores 0–1 floats. ImageJ truncates them to 0 or 1, and Mancora scales them
to 0–255.
