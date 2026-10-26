"""Writes DEFLATE test streams with Python's zlib (an implementation
independent of Mancora's) to Tests/Fixtures/deflate/.

    python3 make_deflate.py <repo-root>

manifest.json records each stream's format and the length and SHA-256 of
the data it decompresses to.
"""

import gzip
import hashlib
import json
import pathlib
import random
import sys
import zlib


def inputs(root):
    license_text = (root / "LICENSE.txt").read_bytes()[:20000]
    rng = random.Random(42)
    runs = b"\x00" * 5000 + bytes(range(256)) * 40 + b"ab" * 3000 + b"\xff" * 300
    return {
        "text": license_text,
        "random": bytes(rng.randrange(256) for _ in range(4096)),
        "runs": runs,
        "empty": b"",
        "byte": b"x",
    }


def main(root):
    out = root / "Tests/Fixtures/deflate"
    out.mkdir(parents=True, exist_ok=True)
    for old in out.iterdir():
        old.unlink()
    manifest = []

    def add(name, fmt, data, original):
        (out / name).write_bytes(data)
        manifest.append({
            "file": name, "format": fmt, "length": len(original),
            "sha256": hashlib.sha256(original).hexdigest(),
        })

    for key, data in inputs(root).items():
        for level in (0, 1, 9):
            add(f"{key}-l{level}.zlib", "zlib", zlib.compress(data, level), data)
        raw = zlib.compressobj(6, zlib.DEFLATED, -15)
        add(f"{key}.deflate", "raw", raw.compress(data) + raw.flush(), data)
        add(f"{key}.gz", "gzip", gzip.compress(data, compresslevel=6, mtime=0), data)
    # Two gzip members back to back decompress to their concatenation.
    text = inputs(root)["text"]
    add("text-two-members.gz", "gzip",
        gzip.compress(text[:7000], mtime=0) + gzip.compress(text[7000:], mtime=0), text)

    (out / "manifest.json").write_text(json.dumps(manifest, indent=1) + "\n")
    print(f"{len(manifest)} deflate fixtures written")


if __name__ == "__main__":
    main(pathlib.Path(sys.argv[1]).resolve())
