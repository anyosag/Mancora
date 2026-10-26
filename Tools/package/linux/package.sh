#!/usr/bin/env bash
# Builds a self-contained `mancora` command-line tool for Linux (the Swift
# runtime is linked statically) and packs it with the bundled LUTs.
#
#   Tools/package/linux/package.sh [output-dir]
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
out="${1:-$root/dist}"
version="$(tr -d '[:space:]' < "$root/VERSION")"
name="mancora-$version-linux-$(uname -m)"

swift_args=(-c release --package-path "$root" --product mancora --static-swift-stdlib)
swift build "${swift_args[@]}"
bin="$(swift build "${swift_args[@]}" --show-bin-path)"

mkdir -p "$out"
stage="$out/$name"
rm -rf "$stage"
mkdir -p "$stage"
cp "$bin/mancora" "$stage/"
strip "$stage/mancora" 2>/dev/null || true
cp -R "$root/Resources/LUTs" "$stage/LUTs"
cp -R "$root/Resources/Bridge" "$stage/Bridge"
cp "$root/LICENSE.txt" "$root/THIRD_PARTY_NOTICES.md" "$stage/"

"$stage/mancora" --version
"$stage/mancora" info "$root/Tests/Fixtures/tiff/ij-hyperstack-16bit.tif" > /dev/null

tar -C "$out" -czf "$out/$name.tar.gz" "$name"
echo "==> $out/$name.tar.gz"
