#!/usr/bin/env bash
# Regenerates Tests/MancoraPluginsTests/Fixtures/updater with the real ImageJ
# updater: compiles imagej-updater from source (the commit below), runs
# UpdaterOracle.java and copies its output into the test fixtures.
#
# Needs git, a JDK (11+) and network access to GitHub and maven.scijava.org.
set -euo pipefail
COMMIT=f44d9d3af361ee849d65a36812afe70975075fb8   # imagej-updater 2.0.4-SNAPSHOT
SCIJAVA=2.99.2
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(cd "$HERE/../../.." && pwd)
WORK=${WORK:-$(mktemp -d)}
echo "Working in $WORK"

if [ ! -d "$WORK/imagej-updater" ]; then
  git clone -q https://github.com/imagej/imagej-updater "$WORK/imagej-updater"
fi
git -C "$WORK/imagej-updater" checkout -q "$COMMIT"
JAR="$WORK/scijava-common-$SCIJAVA.jar"
[ -f "$JAR" ] || curl -fsSL -o "$JAR" \
  "https://maven.scijava.org/content/groups/public/org/scijava/scijava-common/$SCIJAVA/scijava-common-$SCIJAVA.jar"

# The updater, without its UI and command plugins (they need more of SciJava).
mkdir -p "$WORK/classes" "$WORK/stubs/net/imagej"
printf 'package net.imagej;\npublic interface ImageJPlugin extends org.scijava.plugin.SciJavaPlugin {}\n' > "$WORK/stubs/net/imagej/ImageJPlugin.java"
printf 'package net.imagej;\npublic interface ImageJService extends org.scijava.service.SciJavaService {}\n' > "$WORK/stubs/net/imagej/ImageJService.java"
cd "$WORK/imagej-updater/src/main/java"
sources=("$WORK/stubs/net/imagej/ImageJPlugin.java" "$WORK/stubs/net/imagej/ImageJService.java")
for f in net/imagej/updater/*.java net/imagej/updater/util/*.java net/imagej/updater/action/*.java; do
  case "$f" in
    *CheckForUpdates*|*CommandLine*|*DefaultUpdateService*|*PromptUserToUpdate*|*/UpdateService.java|*UpToDate*|*AvailableSites*) ;;
    *) sources+=("$f") ;;
  esac
done
javac -nowarn -d "$WORK/classes" -cp "$JAR" "${sources[@]}" "$HERE/UpdaterOracle.java"

# Java's default time zone decides the updater's timestamps; the tests use UTC.
java -Duser.timezone=UTC -cp "$WORK/classes:$JAR" net.imagej.updater.UpdaterOracle "$WORK/out"

DEST="$REPO/Tests/MancoraPluginsTests/Fixtures/updater"
rm -rf "$DEST"
mkdir -p "$DEST"
cp -r "$WORK/out/initial" "$WORK/out/sites" "$WORK/out/checksums" "$WORK/out/local-db.xml" \
  "$WORK/out/mtimes.json" "$WORK/out/expected.json" "$DEST/"
echo "Fixtures written to $DEST"
