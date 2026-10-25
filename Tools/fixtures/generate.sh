#!/usr/bin/env bash
# Regenerates Tests/Fixtures with writers independent of Mancora:
#   - ImageJ 1.54p (LUT goldens and ImageJ-written TIFFs)
#   - tifffile + imagecodecs and ImageMagick (the TIFF matrix)
#
# Requires: Java 11+, python3 with venv, ImageMagick's `convert`, network
# access to Maven Central and PyPI.
#
#   Tools/fixtures/generate.sh
set -euo pipefail

root="$(cd "$(dirname "$0")/../.." && pwd)"
cache="$root/Tools/fixtures/.cache"
mkdir -p "$cache"

ij_version=1.54p
ij_jar="$cache/ij-$ij_version.jar"
if [[ ! -f "$ij_jar" ]]; then
    base="https://repo1.maven.org/maven2/net/imagej/ij/$ij_version"
    curl -fsSL "$base/ij-$ij_version.jar" -o "$ij_jar"
    echo "$(curl -fsSL "$base/ij-$ij_version.jar.sha1")  $ij_jar" | sha1sum -c -
fi

if [[ ! -x "$cache/venv/bin/python" ]]; then
    python3 -m venv "$cache/venv"
    "$cache/venv/bin/pip" install --quiet tifffile imagecodecs numpy
fi

java -Djava.awt.headless=true -cp "$ij_jar" "$root/Tools/fixtures/ImageJFixtures.java" "$root"
"$cache/venv/bin/python" -I "$root/Tools/fixtures/make_tiffs.py" "$root"
