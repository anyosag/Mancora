#!/usr/bin/env bash
# Opens a 2 GB ImageJ-style 16-bit stack (256 planes of 2048×2048) fully and as
# a virtual stack, and reports wall time, CPU time and peak memory.
#
#   Tools/bench/virtual-stack.sh <path-to-mancora> [scratch-dir]
#
# Needs python3 with numpy and tifffile to write the stack (once).
set -euo pipefail
mancora="$1"
dir="${2:-${TMPDIR:-/tmp}/mancora-bench}"
stack="$dir/stack-2gb.tif"
mkdir -p "$dir"
if [[ ! -f "$stack" ]]; then
    python3 - "$stack" <<'PY'
import sys, numpy as np, tifffile
n, h, w = 256, 2048, 2048
m = tifffile.memmap(sys.argv[1], shape=(n, h, w), dtype=np.uint16, imagej=True)
y, x = np.mgrid[0:h, 0:w]
base = ((x * 3 + y * 5) & 0xFFFF).astype(np.uint16)
for k in range(n):
    m[k] = base + np.uint16(k * 100)
m.flush()
PY
fi
for mode in "--virtual" "--virtual --scan" "--scan"; do
    python3 - "$mancora" info $mode "$stack" <<'PY'
import resource, subprocess, sys, time
start = time.time()
out = subprocess.run(sys.argv[1:], capture_output=True, text=True, check=True).stdout
r = resource.getrusage(resource.RUSAGE_CHILDREN)
peak = r.ru_maxrss // 1024 if sys.platform != "darwin" else r.ru_maxrss // (1 << 20)
lines = [l for l in out.splitlines() if l.startswith(("opened", "scanned"))]
print(f"info {' '.join(sys.argv[3:-1]):17} wall {time.time() - start:5.1f}s  user {r.ru_utime:4.1f}s  "
      f"sys {r.ru_stime:4.1f}s  peak RSS {peak} MB  | " + "; ".join(lines))
PY
done
