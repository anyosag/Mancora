"""Writes the PNG, GIF and image-ZIP fixtures with encoders written here from
the specifications, independent of Mancora (Python's zlib and zipfile, a
hand-written PNG filter/Adam7 writer and a hand-written GIF LZW encoder).

    python3 -I make_formats.py <repo-root>

Every file gets an entry in Tests/Fixtures/<format>/manifest.json saying
what it stores: the samples as written (`stored`), and, for files ImageJ
converts on opening (alpha, 16-bit RGB, low bit depths, animated GIFs), what
ImageJ 1.54p opens (`expect`). Patterns must match
Tests/MancoraIOTests/Patterns.swift.
"""

import json
import math
import pathlib
import struct
import sys
import zipfile
import zlib

W, H = 37, 23


def p8(x, y, k=0):
    return (x * 7 + y * 13 + k * 50) & 255


def p16(x, y, k=0):
    return (x * 311 + y * 1009 + k * 5003) & 0xFFFF


def rgb(x, y, k=0):
    return ((x * 8 + k * 20) & 255, (y * 10) & 255, (x * 3 + y * 5) & 255)


def alpha(x, y):
    # Every alpha value appears, including 0 and 255.
    return (x * 29 + y * 37) & 255


def hexs(values, width):
    return "".join(format(v, "0%dx" % width) for v in values)


# --- PNG -------------------------------------------------------------------

def chunk(kind, data):
    body = kind + data
    return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)


def pack_row(samples, depth):
    """Packs one row of samples (already flattened per pixel) at `depth` bits."""
    if depth == 8:
        return bytes(samples)
    if depth == 16:
        return b"".join(struct.pack(">H", s) for s in samples)
    out = bytearray()
    acc = 0
    nbits = 0
    for s in samples:
        acc = (acc << depth) | s
        nbits += depth
        if nbits == 8:
            out.append(acc)
            acc = 0
            nbits = 0
    if nbits:
        out.append(acc << (8 - nbits))
    return bytes(out)


def paeth(a, b, c):
    p = a + b - c
    pa, pb, pc = abs(p - a), abs(p - b), abs(p - c)
    if pa <= pb and pa <= pc:
        return a
    return b if pb <= pc else c


def filter_row(kind, row, prev, bpp):
    out = bytearray([kind])
    for i, v in enumerate(row):
        a = row[i - bpp] if i >= bpp else 0
        b = prev[i] if prev is not None else 0
        c = prev[i - bpp] if prev is not None and i >= bpp else 0
        if kind == 0:
            f = v
        elif kind == 1:
            f = v - a
        elif kind == 2:
            f = v - b
        elif kind == 3:
            f = v - ((a + b) >> 1)
        else:
            f = v - paeth(a, b, c)
        out.append(f & 255)
    return bytes(out)


ADAM7 = [(0, 0, 8, 8), (4, 0, 8, 8), (0, 4, 4, 8), (2, 0, 4, 4), (0, 2, 2, 4), (1, 0, 2, 2), (0, 1, 1, 2)]


def png(width, height, depth, color_type, pixel, interlace=False, filters=None, palette=None, trns=None,
        extra=(), idat_split=None, level=9):
    """`pixel(x, y)` returns a tuple of samples. `filters(y)` picks each row's filter."""
    channels = {0: 1, 2: 3, 3: 1, 4: 2, 6: 4}[color_type]
    bpp = max(1, channels * depth // 8)
    filters = filters or (lambda y: y % 5)
    raw = bytearray()

    def rows(xs, ys):
        prev = None
        for n, y in enumerate(ys):
            samples = []
            for x in xs:
                samples.extend(pixel(x, y))
            row = pack_row(samples, depth)
            raw.extend(filter_row(filters(n), row, prev, bpp))
            prev = row

    if interlace:
        for x0, y0, dx, dy in ADAM7:
            xs = list(range(x0, width, dx))
            ys = list(range(y0, height, dy))
            if xs and ys:
                rows(xs, ys)
    else:
        rows(list(range(width)), list(range(height)))
    data = zlib.compress(bytes(raw), level)
    out = b"\x89PNG\r\n\x1a\n"
    out += chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, depth, color_type, 0, 0, 1 if interlace else 0))
    for kind, body in extra:
        out += chunk(kind, body)
    if palette is not None:
        out += chunk(b"PLTE", bytes(c for entry in palette for c in entry))
    if trns is not None:
        out += chunk(b"tRNS", trns)
    if idat_split:
        for i in range(0, len(data), idat_split):
            out += chunk(b"IDAT", data[i:i + idat_split])
    else:
        out += chunk(b"IDAT", data)
    out += chunk(b"IEND", b"")
    return out


# Java2D's SrcOver of a non-premultiplied ARGB pixel onto opaque white, as
# Opener.openUsingImageIO composites: each component is mul8(a, c) +
# mul8(255 - a, 255), mul8 being Java2D's rounded a*c/255 table.
def mul8(a, c):
    return (a * c + 127) // 255


def over_white(c, a):
    return mul8(a, c) + mul8(255 - a, 255)


def to8(v16):
    """ComponentColorModel's 16-bit to 8-bit scaling: round(v * 255 / 65535)."""
    return (2 * v16 + 257) // 514


def f32(x):
    return struct.unpack("<f", struct.pack("<f", x))[0]


def linear_to_srgb(i, top):
    """OpenJDK's ColorModel.getLinearRGB8TosRGB8LUT (top 255) and
    getLinearRGB16TosRGB8LUT (top 65535), in Java's float arithmetic. ImageIO
    reads gray PNGs with alpha in the linear CS_GRAY space, so drawing them
    onto an sRGB image goes through this table."""
    v = f32(f32(float(i)) / f32(float(top)))
    if v <= f32(0.0031308):
        out = f32(v * f32(12.92))
    else:
        out = f32(f32(f32(1.055) * f32(v ** (1.0 / 2.4))) - f32(0.055))
    return int(math.floor(f32(f32(out * f32(255.0)) + f32(0.5))))


def write_pngs(out):
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.png"):
        old.unlink()
    manifest = []

    def add(name, data, stored, expect=None, **info):
        (out / name).write_bytes(data)
        entry = {"file": name, "width": info.pop("width", W), "height": info.pop("height", H), "stored": stored}
        if expect:
            entry["expect"] = expect
        entry.update(info)
        manifest.append(entry)

    coords = [(x, y) for y in range(H) for x in range(W)]

    # Grayscale, every filter type in turn, 8 and 16 bits.
    add("gray8.png", png(W, H, 8, 0, lambda x, y: (p8(x, y),)), {"pattern": "p8"})
    add("gray8-paeth.png", png(W, H, 8, 0, lambda x, y: (p8(x, y),), filters=lambda y: 4), {"pattern": "p8"})
    add("gray8-split-idat.png", png(W, H, 8, 0, lambda x, y: (p8(x, y),), idat_split=7,
                                     extra=[(b"tEXt", b"Comment\x00made by make_formats.py"),
                                            (b"pHYs", struct.pack(">IIB", 3937, 3937, 1))]),
        {"pattern": "p8"})
    add("gray16.png", png(W, H, 16, 0, lambda x, y: (p16(x, y),)), {"pattern": "p16"})
    for depth in (1, 2, 4):
        shift = 8 - depth
        add(f"gray{depth}.png", png(W, H, depth, 0, lambda x, y, s=shift: (p8(x, y) >> s,)),
            {"pattern": "p8", "shift": shift})

    # Interlaced (Adam7), including sizes with empty passes.
    add("gray8-interlaced.png", png(W, H, 8, 0, lambda x, y: (p8(x, y),), interlace=True), {"pattern": "p8"})
    add("gray16-interlaced.png", png(W, H, 16, 0, lambda x, y: (p16(x, y),), interlace=True), {"pattern": "p16"})
    add("rgb8-interlaced.png", png(W, H, 8, 2, lambda x, y: rgb(x, y), interlace=True), {"pattern": "rgb"})
    add("gray8-interlaced-3x2.png", png(3, 2, 8, 0, lambda x, y: (p8(x, y),), interlace=True), {"pattern": "p8"},
        width=3, height=2)
    add("gray8-interlaced-1x1.png", png(1, 1, 8, 0, lambda x, y: (p8(x, y),), interlace=True), {"pattern": "p8"},
        width=1, height=1)

    # Palettes: full, short, low bit depth, interlaced low bit depth.
    full = [((i * 5) & 255, (255 - i), (i * 3) & 255) for i in range(256)]
    add("palette8.png", png(W, H, 8, 3, lambda x, y: (p8(x, y),), palette=full),
        {"pattern": "p8", "palette": hexs([c for e in full for c in e], 2)})
    short = [((i * 40) & 255, (i * 23) & 255, 200 - i) for i in range(100)]
    add("palette8-short.png", png(W, H, 8, 3, lambda x, y: (p8(x, y) % 100,), palette=short),
        {"pattern": "p8", "modulo": 100, "palette": hexs([c for e in short for c in e], 2)})
    sixteen = [((i * 17) & 255, 255 - i * 17, (i * 50) & 255) for i in range(16)]
    add("palette4.png", png(W, H, 4, 3, lambda x, y: (p8(x, y) >> 4,), palette=sixteen),
        {"pattern": "p8", "shift": 4, "palette": hexs([c for e in sixteen for c in e], 2)})
    add("palette4-interlaced.png", png(W, H, 4, 3, lambda x, y: (p8(x, y) >> 4,), palette=sixteen, interlace=True),
        {"pattern": "p8", "shift": 4, "palette": hexs([c for e in sixteen for c in e], 2)})
    two = [(10, 20, 30), (250, 128, 0)]
    add("palette1.png", png(W, H, 1, 3, lambda x, y: (p8(x, y) >> 7,), palette=two),
        {"pattern": "p8", "shift": 7, "palette": hexs([c for e in two for c in e], 2)})

    # RGB, 8 and 16 bits per sample (16-bit RGB opens as a 3-channel composite).
    add("rgb8.png", png(W, H, 8, 2, lambda x, y: rgb(x, y)), {"pattern": "rgb"})
    add("rgb16.png", png(W, H, 16, 2, lambda x, y: (p16(x, y, 0), p16(x, y, 1), p16(x, y, 2))),
        {"pattern": "p16x3"})

    # Alpha: composited on white, as ImageJ does; the result is RGB.
    def composite(get, a16=False):
        values = []
        for x, y in coords:
            r, g, b, a = get(x, y)
            values.append(over_white(r, a) << 16 | over_white(g, a) << 8 | over_white(b, a))
        return {"type": "rgb8", "pixels": hexs(values, 6)}

    def gray(v, top=255):
        return (linear_to_srgb(v, top),) * 3

    add("rgba8.png", png(W, H, 8, 6, lambda x, y: rgb(x, y) + (alpha(x, y),)), {"pattern": "rgba"},
        composite(lambda x, y: rgb(x, y) + (alpha(x, y),)))
    add("graya8.png", png(W, H, 8, 4, lambda x, y: (p8(x, y), alpha(x, y))), {"pattern": "graya"},
        composite(lambda x, y: gray(p8(x, y)) + (alpha(x, y),)))
    # 16-bit samples with alpha are rounded to 8 bits first.
    a16 = lambda x, y: (alpha(x, y) * 251) & 0xFFFF
    add("rgba16.png", png(W, H, 16, 6, lambda x, y: (p16(x, y, 0), p16(x, y, 1), p16(x, y, 2), a16(x, y))),
        {"pattern": "rgba16"},
        composite(lambda x, y: (to8(p16(x, y, 0)), to8(p16(x, y, 1)), to8(p16(x, y, 2)), to8(a16(x, y)))))
    add("graya16.png", png(W, H, 16, 4, lambda x, y: (p16(x, y), a16(x, y))), {"pattern": "graya16"},
        composite(lambda x, y: gray(p16(x, y), 65535) + (to8(a16(x, y)),)))
    trns_palette = [(i, 255 - i, (i * 7) & 255) for i in range(256)]
    trns_alpha = bytes((i * 11) & 255 for i in range(256))
    add("palette8-trns.png", png(W, H, 8, 3, lambda x, y: (p8(x, y),), palette=trns_palette, trns=trns_alpha),
        {"pattern": "p8"},
        composite(lambda x, y: trns_palette[p8(x, y)] + (trns_alpha[p8(x, y)],)))
    # A tRNS colour key on gray and RGB images: ImageIO turns it into alpha.
    add("gray8-trns.png", png(W, H, 8, 0, lambda x, y: (p8(x, y),), trns=struct.pack(">H", 91)),
        {"pattern": "p8"},
        composite(lambda x, y: gray(p8(x, y)) + (0 if p8(x, y) == 91 else 255,)))
    # Every 8- and 16-bit gray level, opaque, to pin the linear-to-sRGB tables down.
    add("graya8-levels.png", png(256, 1, 8, 4, lambda x, y: (x, 255)), {"pattern": "levels"},
        {"type": "rgb8", "pixels": hexs([linear_to_srgb(v, 255) * 0x10101 for v in range(256)], 6)},
        width=256, height=1)
    levels16 = bytes(c for v in range(65536) for c in (linear_to_srgb(v, 65535),) * 3)
    add("graya16-levels.png", png(256, 256, 16, 4, lambda x, y: (y * 256 + x, 65535), level=6), {"pattern": "levels16"},
        {"type": "rgb8", "crc32": zlib.crc32(levels16)}, width=256, height=256)
    key = rgb(5, 3)
    add("rgb8-trns.png", png(W, H, 8, 2, lambda x, y: rgb(x, y), trns=struct.pack(">HHH", *key)),
        {"pattern": "rgb"},
        composite(lambda x, y: rgb(x, y) + (0 if rgb(x, y) == key else 255,)))

    (out / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")


# --- GIF -------------------------------------------------------------------

class Bits:
    def __init__(self):
        self.out = bytearray()
        self.acc = 0
        self.n = 0

    def write(self, code, size):
        self.acc |= code << self.n
        self.n += size
        while self.n >= 8:
            self.out.append(self.acc & 255)
            self.acc >>= 8
            self.n -= 8

    def done(self):
        if self.n:
            self.out.append(self.acc & 255)
        return bytes(self.out)


def lzw(indices, min_size):
    clear, eoi = 1 << min_size, (1 << min_size) + 1
    bits = Bits()

    def reset():
        return {}, eoi + 1, min_size + 1

    table, next_code, size = reset()
    bits.write(clear, size)
    prefix = None
    for v in indices:
        if prefix is None:
            prefix = v
            continue
        key = (prefix, v)
        if key in table:
            prefix = table[key]
            continue
        bits.write(prefix, size)
        if next_code < 4096:
            table[key] = next_code
            if next_code == (1 << size) and size < 12:
                size += 1
            next_code += 1
        else:
            bits.write(clear, size)
            table, next_code, size = reset()
        prefix = v
    if prefix is not None:
        bits.write(prefix, size)
    bits.write(eoi, size)
    data = bits.done()
    blocks = bytearray([min_size])
    for i in range(0, len(data), 255):
        part = data[i:i + 255]
        blocks.append(len(part))
        blocks.extend(part)
    blocks.append(0)
    return bytes(blocks)


def table_bits(n):
    bits = 1
    while (1 << bits) < n:
        bits += 1
    return bits


def color_table(colors):
    bits = table_bits(len(colors))
    padded = list(colors) + [(0, 0, 0)] * ((1 << bits) - len(colors))
    return bits, bytes(c for e in padded for c in e)


class Frame:
    def __init__(self, indices, x=0, y=0, w=W, h=H, local=None, interlace=False, dispose=None, transparent=None,
                 delay=10):
        self.indices, self.x, self.y, self.w, self.h = indices, x, y, w, h
        self.local, self.interlace, self.dispose, self.transparent, self.delay = local, interlace, dispose, transparent, delay


def interlaced_rows(h):
    order = []
    for start, step in ((0, 8), (4, 8), (2, 4), (1, 2)):
        order.extend(range(start, h, step))
    return order


def gif(width, height, frames, global_colors=None, background=0, loop=True, gce=True):
    out = bytearray(b"GIF89a")
    flags = 0x70
    gct = b""
    if global_colors is not None:
        bits, gct = color_table(global_colors)
        flags |= 0x80 | (bits - 1)
    out += struct.pack("<HHBBB", width, height, flags, background, 0)
    out += gct
    if loop and len(frames) > 1:
        out += b"\x21\xff\x0bNETSCAPE2.0\x03\x01\x00\x00\x00"
    for f in frames:
        if gce and (f.dispose is not None or f.transparent is not None or len(frames) > 1):
            packed = ((f.dispose or 0) << 2) | (1 if f.transparent is not None else 0)
            out += struct.pack("<BBBBHBB", 0x21, 0xF9, 4, packed, f.delay, f.transparent or 0, 0)
        packed = 0
        lct = b""
        colors = global_colors
        if f.local is not None:
            bits, lct = color_table(f.local)
            packed |= 0x80 | (bits - 1)
            colors = f.local
        if f.interlace:
            packed |= 0x40
        out += struct.pack("<BHHHHB", 0x2C, f.x, f.y, f.w, f.h, packed)
        out += lct
        rows = interlaced_rows(f.h) if f.interlace else range(f.h)
        indices = [f.indices[r * f.w + c] for r in rows for c in range(f.w)]
        out += lzw(indices, max(2, table_bits(len(colors))))
    out += b"\x3b"
    return bytes(out)


def gray_table(n=256):
    return [(i * 255 // (n - 1),) * 3 for i in range(n)]


def write_gifs(out):
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.gif"):
        old.unlink()
    manifest = []
    full = [((i * 5) & 255, (255 - i), (i * 3) & 255) for i in range(256)]

    def flat(f, w=W, h=H):
        return [f(x, y) for y in range(h) for x in range(w)]

    def add(name, data, expect, **info):
        (out / name).write_bytes(data)
        entry = {"file": name, "width": info.pop("width", W), "height": info.pop("height", H), "expect": expect}
        entry.update(info)
        manifest.append(entry)

    def lut_hex(colors):
        padded = list(colors) + [(0, 0, 0)] * (256 - len(colors))
        return hexs([e[0] for e in padded] + [e[1] for e in padded] + [e[2] for e in padded], 2)

    p = flat(p8)
    # Single images open as 8-bit with the colour table as the LUT.
    add("gray.gif", gif(W, H, [Frame(p)], gray_table()),
        {"type": "gray8", "planes": [hexs(p, 2)], "lut": lut_hex(gray_table())})
    add("palette.gif", gif(W, H, [Frame(p)], full),
        {"type": "gray8", "planes": [hexs(p, 2)], "lut": lut_hex(full)})
    sixteen = [((i * 17) & 255, 255 - i * 17, (i * 50) & 255) for i in range(16)]
    q = flat(lambda x, y: p8(x, y) >> 4)
    add("palette16.gif", gif(W, H, [Frame(q)], sixteen),
        {"type": "gray8", "planes": [hexs(q, 2)], "lut": lut_hex(sixteen)})
    two = [(10, 20, 30), (250, 128, 0)]
    b = flat(lambda x, y: p8(x, y) >> 7)
    add("two-colors.gif", gif(W, H, [Frame(b)], two),
        {"type": "gray8", "planes": [hexs(b, 2)], "lut": lut_hex(two)})
    add("interlaced.gif", gif(W, H, [Frame(p, interlace=True)], full),
        {"type": "gray8", "planes": [hexs(p, 2)], "lut": lut_hex(full)})
    add("local-table.gif", gif(W, H, [Frame(q, local=sixteen)], None),
        {"type": "gray8", "planes": [hexs(q, 2)], "lut": lut_hex(sixteen)})
    add("transparent.gif", gif(W, H, [Frame(p, transparent=3)], full),
        {"type": "gray8", "planes": [hexs(p, 2)], "lut": lut_hex(full)})
    # Noise fills the LZW table several times over.
    seed = 12345
    noise = []
    for _ in range(128 * 96):
        seed = (seed * 1103515245 + 12345) & 0x7FFFFFFF
        noise.append((seed >> 16) & 255)
    add("noise.gif", gif(128, 96, [Frame(noise, w=128, h=96)], full),
        {"type": "gray8", "planes": [hexs(noise, 2)], "lut": lut_hex(full)}, width=128, height=96)

    # Animated GIFs open as RGB stacks, composed as GIF_Reader's decoder does.
    def rgb_of(colors, idx):
        r, g, b = colors[idx]
        return r << 16 | g << 8 | b

    frames = [flat(lambda x, y, k=k: p8(x, y, k)) for k in range(3)]
    add("animated.gif", gif(W, H, [Frame(f) for f in frames], full),
        {"type": "rgb8", "planes": [hexs([rgb_of(full, v) for v in f], 6) for f in frames]})
    add("animated-gray.gif", gif(W, H, [Frame(f) for f in frames], gray_table()),
        {"type": "gray8", "planes": [hexs(f, 2) for f in frames]})
    other = [(255 - i, (i * 9) & 255, i) for i in range(256)]
    add("animated-local.gif", gif(W, H, [Frame(frames[0]), Frame(frames[1], local=other, interlace=True)], full),
        {"type": "rgb8", "planes": [hexs([rgb_of(full, v) for v in frames[0]], 6),
                                    hexs([rgb_of(other, v) for v in frames[1]], 6)]})

    # Sub-rectangles, every disposal method and transparency. The expected
    # frames follow GifDecoder exactly (see GIF_Reader.java): transparent
    # pixels are drawn black, the disposal method is read doubled (so
    # method 1 restores the background, and only when that colour isn't 0,
    # while 2 and 3 keep the previous frame), and a frame without a GCE
    # keeps the previous one's settings.
    palette = [(i, (i * 3) & 255, 255 - i) for i in range(256)]
    background = 7
    scene = [
        Frame(flat(lambda x, y: p8(x, y)), dispose=1),
        Frame([(x * 5 + y) & 255 for y in range(8) for x in range(10)], x=4, y=3, w=10, h=8, dispose=2, transparent=13),
        Frame([(x + y * 9) & 255 for y in range(6) for x in range(12)], x=20, y=10, w=12, h=6, dispose=3),
        Frame([(x * 3 + y * 2) & 255 for y in range(5) for x in range(5)], x=1, y=15, w=5, h=5, dispose=1),
    ]
    expected = []
    last_dispose = 0
    last_rect = None
    last_image = None
    last_bg = 0
    transparency = False
    trans_index = 0
    dispose = 0
    bg_color = rgb_of(palette, background)
    for n, f in enumerate(scene, start=1):
        # Every frame of an animation gets a graphic control extension.
        # GifDecoder reads the disposal method as (packed & 0x1c) >> 1, twice
        # its value: 1 then restores the background, 2 and 3 keep the frame.
        dispose = (f.dispose or 0) * 2
        transparency = f.transparent is not None
        trans_index = f.transparent or 0
        act = list(palette)
        if bg_color != 0 and background == trans_index:
            bg_color = 0
        if transparency:
            act[trans_index] = (0, 0, 0)
        dest = [0] * (W * H)
        if last_dispose > 0:
            if last_dispose == 3:
                k = n - 2
                last_image = expected[k - 1] if k > 0 else None
            if last_image is not None:
                dest = list(last_image)
                if last_dispose == 2 and last_bg != 0:
                    x0, y0, w0, h0 = last_rect
                    for yy in range(max(0, y0), min(H, y0 + h0)):
                        for xx in range(max(0, x0), min(W, x0 + w0)):
                            dest[yy * W + xx] = last_bg
        for i in range(f.h):
            line = i + f.y
            if line < H:
                for j in range(f.w):
                    if f.x + j < W:
                        dest[line * W + f.x + j] = rgb_of(act, f.indices[i * f.w + j])
        expected.append(dest)
        last_dispose, last_rect, last_image, last_bg = dispose, (f.x, f.y, f.w, f.h), dest, bg_color
    add("animated-disposal.gif", gif(W, H, scene, palette, background=background),
        {"type": "rgb8", "planes": [hexs(e, 6) for e in expected]})

    (out / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")


# --- ZIP -------------------------------------------------------------------

def write_zips(root):
    out = root / "Tests/Fixtures/zip"
    out.mkdir(parents=True, exist_ok=True)
    for old in out.glob("*.zip"):
        old.unlink()
    tiff = root / "Tests/Fixtures/tiff"

    def write(name, entries, method=zipfile.ZIP_DEFLATED):
        with zipfile.ZipFile(out / name, "w", method) as z:
            for entry, data in entries:
                info = zipfile.ZipInfo(entry, date_time=(2020, 1, 1, 0, 0, 0))
                info.compress_type = method
                z.writestr(info, data)

    stack = (tiff / "ij-stack-8bit.tif").read_bytes()
    write("stack.zip", [("ij-stack-8bit.tif", stack)])
    write("stack-stored.zip", [("ij-stack-8bit.tif", stack)], zipfile.ZIP_STORED)
    write("hyperstack.zip", [("hyper.tif", (tiff / "ij-hyperstack-16bit.tif").read_bytes()),
                             ("notes.txt", b"only the first entry counts")])
    write("rois.zip", [("0001-0002.roi", (root / "Tests/Fixtures/roi/ellipse.roi").read_bytes())])
    write("text.zip", [("readme.txt", b"no image here")])
    write("dicom.zip", [("image.dcm", b"\0" * 132)])


def main(root):
    write_pngs(root / "Tests/Fixtures/png")
    write_gifs(root / "Tests/Fixtures/gif")
    write_zips(root)


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]).resolve())
