#!/usr/bin/env bash
# ImageJ reopen parity for Mancora's TIFF writer:
#   1. ImageJ saves a varied set of images (TiffReopen.java make)
#   2. `mancora convert` re-saves each of them and every TIFF test fixture
#   3. ImageJ opens each original and copy and compares them
#
# Files ImageJ saved must reopen identically. For third-party fixtures the
# report also lists the files ImageJ can only open through Mancora, and any
# that ImageJ's own reader decodes differently.
#
#   Tools/parity/tiff-reopen.sh <path-to-mancora> [ij.jar]
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
mancora="$1"
ij_version=1.54p
ij_jar="${2:-$root/Tools/fixtures/.cache/ij-$ij_version.jar}"
if [[ ! -f "$ij_jar" ]]; then
    mkdir -p "$(dirname "$ij_jar")"
    base="https://repo1.maven.org/maven2/net/imagej/ij/$ij_version"
    curl -fsSL "$base/ij-$ij_version.jar" -o "$ij_jar"
    echo "$(curl -fsSL "$base/ij-$ij_version.jar.sha1")  $ij_jar" | sha1sum -c -
fi

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/originals" "$work/copies"
java_run=(java -Djava.awt.headless=true -cp "$ij_jar" "$root/Tools/parity/TiffReopen.java")

"${java_run[@]}" make "$work/originals"
cp "$root"/Tests/Fixtures/tiff/*.tif "$work/originals/"
for original in "$work"/originals/*.tif; do
    name="$(basename "$original")"
    if [[ "$name" == *-be.tif ]]; then
        "$mancora" convert "$original" "$work/copies/$name" --big-endian
    else
        "$mancora" convert "$original" "$work/copies/$name"
    fi
done

# Strict: everything ImageJ wrote (the generated set and the ij-* fixtures).
strict=(ij- 8bit- 16bit- 32bit- rgb- stack- timeseries- hyperstack- composite-)
"${java_run[@]}" compare "$work/originals" "$work/copies" "${strict[@]}"
