#!/usr/bin/env bash
# Builds Mancora.app (universal: Apple silicon and Intel) and a DMG.
#
#   Tools/package/macos/package.sh [output-dir]
#
# Signs ad hoc unless MACOS_SIGN_IDENTITY names a Developer ID certificate in
# the keychain. Ad-hoc builds aren't notarized; see README.md for how to open
# them the first time.
set -euo pipefail

root="$(cd "$(dirname "$0")/../../.." && pwd)"
out="${1:-$root/dist}"
version="$(tr -d '[:space:]' < "$root/VERSION")"
build="$(git -C "$root" rev-list --count HEAD 2>/dev/null || echo 1)"
identity="${MACOS_SIGN_IDENTITY:--}"

echo "==> Building Mancora $version ($build), universal"
swift_args=(-c release --package-path "$root/Apps/macOS" --arch arm64 --arch x86_64)
swift build "${swift_args[@]}"
bin="$(swift build "${swift_args[@]}" --show-bin-path)"

echo "==> Assembling Mancora.app"
mkdir -p "$out"
app="$out/Mancora.app"
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
cp "$bin/MancoraApp" "$app/Contents/MacOS/Mancora"
sed -e "s/@VERSION@/$version/g" -e "s/@BUILD@/$build/g" \
    "$root/Tools/package/macos/Info.plist" > "$app/Contents/Info.plist"
plutil -lint "$app/Contents/Info.plist"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir "$work/AppIcon.iconset"
cp "$root"/Resources/Branding/AppIcon.appiconset/icon_*.png "$work/AppIcon.iconset/"
iconutil -c icns "$work/AppIcon.iconset" -o "$app/Contents/Resources/AppIcon.icns"

cp -R "$root/Resources/LUTs" "$app/Contents/Resources/LUTs"
cp "$root/LICENSE.txt" "$root/THIRD_PARTY_NOTICES.md" "$app/Contents/Resources/"

echo "==> Signing ($identity)"
sign_args=(--force --options runtime --sign "$identity")
[[ "$identity" != "-" ]] && sign_args+=(--timestamp)
codesign "${sign_args[@]}" "$app"
codesign --verify --strict --verbose=2 "$app"
lipo -archs "$app/Contents/MacOS/Mancora"

echo "==> Smoke test"
"$app/Contents/MacOS/Mancora" --smoke-test "$root/Tests/Fixtures/tiff/ij-hyperstack-16bit.tif"

echo "==> Creating the disk image"
dmg="$out/Mancora-$version-macOS.dmg"
mkdir "$work/dmg"
cp -R "$app" "$work/dmg/"
ln -s /Applications "$work/dmg/Applications"
rm -f "$dmg"
# hdiutil occasionally fails with "Resource busy" on CI machines; retry.
for attempt in 1 2 3; do
    hdiutil create -volname "Mancora $version" -srcfolder "$work/dmg" -fs HFS+ -format UDZO -ov "$dmg" && break
    [[ $attempt == 3 ]] && exit 1
    sleep 5
done
hdiutil verify "$dmg"

echo "==> Update install test"
# Install the DMG's app over a copy of this one, as Check for Updates does.
mkdir "$work/installed"
ditto "$app" "$work/installed/Mancora.app"
"$app/Contents/MacOS/Mancora" --install-test "$dmg" "$work/installed/Mancora.app"
codesign --verify --strict "$work/installed/Mancora.app"
[[ "$(defaults read "$work/installed/Mancora.app/Contents/Info.plist" CFBundleShortVersionString)" == "$version" ]]
[[ "$identity" != "-" ]] && codesign --sign "$identity" --timestamp "$dmg"

echo "==> $dmg"
