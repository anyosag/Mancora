"""Writes the TIFF test matrix with two writers independent of Mancora:
tifffile (with imagecodecs) and ImageMagick (libtiff).

    python3 make_tiffs.py <repo-root>

Every file gets an entry in Tests/Fixtures/tiff/manifest.json naming the pixel
pattern it holds. Patterns must match Tests/MancoraIOTests/Patterns.swift.
"""

import json
import pathlib
import subprocess
import sys
import tempfile

import numpy as np
import tifffile

W, H = 37, 23  # odd sizes exercise partial strips and clipped 16×16 tiles


def pattern(name, k=0):
    y, x = np.mgrid[0:H, 0:W]
    if name == "p8":
        return ((x * 7 + y * 13 + k * 50) & 255).astype(np.uint8)
    if name == "p16":
        return ((x * 311 + y * 1009 + k * 5003) & 0xFFFF).astype(np.uint16)
    if name == "s16":  # stored signed; Mancora shifts it back to p16
        return (pattern("p16", k).astype(np.int32) - 32768).astype(np.int16)
    if name == "f32":
        return (x * 0.25 - y * 0.5 + k * 100).astype(np.float32)
    if name == "u32":
        return (x * 100003 + y * 7 + k).astype(np.uint32)
    if name == "rgb":
        r = (x * 8 + k * 20) & 255
        g = (y * 10) & 255
        b = (x * 3 + y * 5) & 255
        return np.stack([r, g, b], axis=-1).astype(np.uint8)
    if name == "bits":
        return (x + y) % 3 == 0
    raise ValueError(name)


def main(root):
    out = root / "Tests/Fixtures/tiff"
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("tf-*.tif"):
        old.unlink()
    for old in out.glob("im-*.tif"):
        old.unlink()
    manifest = []

    def add(name, pattern_name, ptype, planes=1, **expect):
        entry = {"file": name, "pattern": pattern_name, "type": ptype, "planes": planes, "width": W, "height": H}
        entry.update(expect)
        manifest.append(entry)

    # --- tifffile -----------------------------------------------------------
    def tf(name, data, pattern_name, ptype, planes=1, expect=None, **kw):
        kw.setdefault("metadata", None)
        tifffile.imwrite(out / name, data, **kw)
        add(name, pattern_name, ptype, planes, **(expect or {}))

    lzw_pred = dict(compression="lzw", predictor=2)
    for order, tag in (("<", "le"), (">", "be")):
        tf(f"tf-gray8-none-{tag}.tif", pattern("p8"), "p8", "gray8", byteorder=order, rowsperstrip=5)
        tf(f"tf-gray8-lzw-pred-{tag}.tif", pattern("p8"), "p8", "gray8", byteorder=order, **lzw_pred)
        tf(f"tf-gray16-lzw-pred-{tag}.tif", pattern("p16"), "p16", "gray16", byteorder=order, **lzw_pred)
        tf(f"tf-gray16-tiles-lzw-pred-{tag}.tif", pattern("p16"), "p16", "gray16",
           byteorder=order, tile=(16, 16), **lzw_pred)
        tf(f"tf-float32-none-{tag}.tif", pattern("f32"), "f32", "gray32Float", byteorder=order)
        tf(f"tf-rgb-lzw-pred-{tag}.tif", pattern("rgb"), "rgb", "rgb8",
           byteorder=order, photometric="rgb", **lzw_pred)

    tf("tf-gray8-lzw.tif", pattern("p8"), "p8", "gray8", compression="lzw")
    tf("tf-gray8-packbits-be.tif", pattern("p8"), "p8", "gray8", byteorder=">", compression="packbits")
    tf("tf-gray8-tiles-none.tif", pattern("p8"), "p8", "gray8", tile=(16, 16))
    tf("tf-gray8-tiles-lzw-pred-be.tif", pattern("p8"), "p8", "gray8", byteorder=">", tile=(16, 16), **lzw_pred)
    tf("tf-gray16-none-be.tif", pattern("p16"), "p16", "gray16", byteorder=">", rowsperstrip=4)
    tf("tf-gray16-packbits.tif", pattern("p16"), "p16", "gray16", compression="packbits")
    tf("tf-int16-lzw.tif", pattern("s16"), "p16", "gray16", compression="lzw", expect={"signed": True})
    tf("tf-float32-lzw-be.tif", pattern("f32"), "f32", "gray32Float", byteorder=">", compression="lzw")
    tf("tf-float32-tiles.tif", pattern("f32"), "f32", "gray32Float", tile=(16, 16))
    tf("tf-uint32-none.tif", pattern("u32"), "u32", "gray32Float")
    tf("tf-rgb-none.tif", pattern("rgb"), "rgb", "rgb8", photometric="rgb")
    planar = np.moveaxis(pattern("rgb"), -1, 0)  # separate planes want (samples, H, W)
    tf("tf-rgb-planar-none-be.tif", planar, "rgb", "rgb8", byteorder=">",
       photometric="rgb", planarconfig="separate")
    tf("tf-rgb-planar-lzw-pred.tif", planar, "rgb", "rgb8", photometric="rgb",
       planarconfig="separate", **lzw_pred)
    tf("tf-rgb-tiles-lzw.tif", pattern("rgb"), "rgb", "rgb8", photometric="rgb", tile=(16, 16), compression="lzw")
    rgba = np.concatenate([pattern("rgb"), np.full((H, W, 1), 200, np.uint8)], axis=-1)
    tf("tf-rgba-none.tif", rgba, "rgb", "rgb8", photometric="rgb", extrasamples=["unassalpha"])
    tf("tf-gray8-miniswhite.tif", pattern("p8"), "p8", "gray8", photometric="miniswhite",
       expect={"lutInverted": True})
    colormap = np.stack([np.arange(256), 255 - np.arange(256), (np.arange(256) * 3) & 255]).astype(np.uint16) * 257
    tf("tf-palette-lzw.tif", pattern("p8"), "p8", "gray8", photometric="palette", colormap=colormap,
       compression="lzw", expect={"lut": "palette"})
    pages = np.stack([pattern("p8", k) for k in range(3)])
    tf("tf-pages-gray8-lzw.tif", pages, "p8", "gray8", planes=3, photometric="minisblack", compression="lzw")
    pages = np.stack([pattern("rgb", k) for k in range(2)])
    tf("tf-pages-rgb-be.tif", pages, "rgb", "rgb8", planes=2, byteorder=">", photometric="rgb")

    # Deflate, with the horizontal (2) and floating-point (3) predictors.
    for order, tag in (("<", "le"), (">", "be")):
        tf(f"tf-gray16-zlib-pred-{tag}.tif", pattern("p16"), "p16", "gray16", byteorder=order,
           compression="zlib", predictor=2)
        tf(f"tf-float32-zlib-fpred-{tag}.tif", pattern("f32"), "f32", "gray32Float", byteorder=order,
           compression="zlib", predictor=3)
        tf(f"tf-float64-zlib-fpred-{tag}.tif", pattern("f32").astype(np.float64), "f32", "gray32Float",
           byteorder=order, compression="zlib", predictor=3)
        tf(f"tf-float16-zlib-fpred-{tag}.tif", pattern("f32").astype(np.float16), "f32", "gray32Float",
           byteorder=order, compression="zlib", predictor=3)
    tf("tf-gray8-zlib.tif", pattern("p8"), "p8", "gray8", compression="zlib", rowsperstrip=7)
    tf("tf-gray8-tiles-zlib-be.tif", pattern("p8"), "p8", "gray8", byteorder=">", tile=(16, 16),
       compression="zlib", compressionargs={"level": 9})
    tf("tf-float32-tiles-zlib-fpred.tif", pattern("f32"), "f32", "gray32Float", tile=(16, 16),
       compression="zlib", predictor=3)
    tf("tf-float64-none-be.tif", pattern("f32").astype(np.float64), "f32", "gray32Float", byteorder=">")
    tf("tf-float16-none.tif", pattern("f32").astype(np.float16), "f32", "gray32Float")
    tf("tf-rgb-zlib-pred.tif", pattern("rgb"), "rgb", "rgb8", photometric="rgb", compression="zlib", predictor=2)
    tf("tf-rgb-planar-zlib-be.tif", planar, "rgb", "rgb8", byteorder=">", photometric="rgb",
       planarconfig="separate", compression="zlib")

    # 16-bit RGB(A) opens as one channel per sample; sample c of page j holds p16 plane 3j + c.
    def rgb16(samples, page=0):
        return np.stack([pattern("p16", page * samples + c) for c in range(samples)], axis=-1)

    tf("tf-rgb48-none.tif", rgb16(3), "p16", "gray16", planes=3, photometric="rgb",
       expect={"channels": 3})
    tf("tf-rgb48-lzw-pred-be.tif", rgb16(3), "p16", "gray16", planes=3, byteorder=">", photometric="rgb",
       expect={"channels": 3}, **lzw_pred)
    tf("tf-rgb48-planar-zlib.tif", np.moveaxis(rgb16(3), -1, 0), "p16", "gray16", planes=3, photometric="rgb",
       planarconfig="separate", compression="zlib", expect={"channels": 3})
    tf("tf-rgb48-tiles-zlib-pred.tif", rgb16(3), "p16", "gray16", planes=3, photometric="rgb", tile=(16, 16),
       compression="zlib", predictor=2, expect={"channels": 3})
    tf("tf-rgba64-none-be.tif", rgb16(4), "p16", "gray16", planes=4, byteorder=">", photometric="rgb",
       extrasamples=["unassalpha"], expect={"channels": 4})
    pages = np.stack([rgb16(3, j) for j in range(2)])
    tf("tf-pages-rgb48-zlib.tif", pages, "p16", "gray16", planes=6, photometric="rgb", compression="zlib",
       expect={"channels": 3})

    # BigTIFF: 64-bit offsets, 20-byte IFD entries.
    tf("tf-bigtiff-gray16-none.tif", pattern("p16"), "p16", "gray16", bigtiff=True, rowsperstrip=5)
    tf("tf-bigtiff-float32-zlib-fpred-be.tif", pattern("f32"), "f32", "gray32Float", bigtiff=True,
       byteorder=">", compression="zlib", predictor=3)
    tf("tf-bigtiff-rgb-tiles-lzw.tif", pattern("rgb"), "rgb", "rgb8", bigtiff=True, photometric="rgb",
       tile=(16, 16), compression="lzw")
    pages = np.stack([pattern("p8", k) for k in range(3)])
    tf("tf-bigtiff-pages-gray8-zlib-be.tif", pages, "p8", "gray8", planes=3, bigtiff=True, byteorder=">",
       photometric="minisblack", compression="zlib")

    # --- ImageMagick (libtiff) ----------------------------------------------
    with tempfile.TemporaryDirectory() as tmp:
        tmp = pathlib.Path(tmp)

        def im(name, raw, depth, fmt, args, pattern_name, ptype, **expect):
            src = tmp / "in.raw"
            src.write_bytes(raw)
            subprocess.run(
                ["convert", "-size", f"{W}x{H}", "-depth", str(depth), f"{fmt}:{src}", *args, str(out / name)],
                check=True,
            )
            add(name, pattern_name, ptype, **expect)

        p8 = pattern("p8").tobytes()
        # ImageMagick reads raw input little-endian; -endian MSB applies to the output.
        p16 = pattern("p16").astype("<u2").tobytes()
        rgb = pattern("rgb").tobytes()
        im("im-gray8-lzw-tiles.tif", p8, 8, "gray",
           ["-compress", "LZW", "-define", "tiff:tile-geometry=16x16"], "p8", "gray8")
        im("im-gray8-packbits.tif", p8, 8, "gray", ["-compress", "RLE"], "p8", "gray8")
        im("im-gray16-lzw-pred-be.tif", p16, 16, "gray",
           ["-endian", "MSB", "-compress", "LZW", "-define", "tiff:predictor=2"], "p16", "gray16")
        im("im-rgb-lzw.tif", rgb, 8, "rgb", ["-compress", "LZW"], "rgb", "rgb8")
        im("im-gray8-zip.tif", p8, 8, "gray", ["-compress", "Zip"], "p8", "gray8")
        im("im-gray16-zip-pred-be.tif", p16, 16, "gray",
           ["-endian", "MSB", "-compress", "Zip", "-define", "tiff:predictor=2"], "p16", "gray16")
        im("im-rgb-zip-tiles.tif", rgb, 8, "rgb",
           ["-compress", "Zip", "-define", "tiff:tile-geometry=16x16"], "rgb", "rgb8")
        bits = np.where(pattern("bits"), 255, 0).astype(np.uint8).tobytes()
        im("im-bilevel-minisblack.tif", bits, 8, "gray",
           ["-type", "bilevel", "-depth", "1", "-compress", "None", "-define", "tiff:photometric=min-is-black"],
           "bits", "gray8")
        im("im-bilevel-miniswhite-packbits.tif", bits, 8, "gray",
           ["-type", "bilevel", "-depth", "1", "-compress", "RLE", "-define", "tiff:photometric=min-is-white"],
           "bits", "gray8", lutInverted=True, invertPattern=True)

    (out / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
    print(f"{len(manifest)} TIFF fixtures written")


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]).resolve())
