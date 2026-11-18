#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
out="${1:?Usage: build.sh OUTPUT_DIRECTORY [Windows-1.21.0.zip or artwork checkout]}"
mkdir -p "$out"
out="$(cd "$out" && pwd)"
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$here/Info.plist")"
minimum="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' "$here/Info.plist")"
dmg="$out/BetterIcon-$version-macOS.dmg"
if [[ -e "$out/BetterIcon.app" || -e "$dmg" ]]; then
    echo "Choose an output directory without an existing BetterIcon.app or disk image." >&2
    exit 1
fi
stage="$(mktemp -d "${TMPDIR:-/tmp}/bettericon-build.XXXXXXXX")"
trap 'rm -rf "$stage"' EXIT
app="$stage/install/BetterIcon.app"
resources="$app/Contents/Resources"
mkdir -p "$app/Contents/MacOS" "$resources/Web" "$stage/BetterIcon.iconset"
cp -X "$here/Info.plist" "$app/Contents/"
cp -X "$here"/Web/* "$resources/Web/"
cp -X "$repo/LICENSE" "$resources/LICENSE"
input="${2:-}"
default_zip="$(dirname "$repo")/bettericon-windows-builds/1.21.0-final/BetterIcon-Craft-Apps-Windows-1.21.0.zip"
if [[ -z "$input" && -s "$default_zip" ]]; then input="$default_zip"; fi
if [[ -n "$input" ]]; then
    /usr/bin/ruby "$here/prepare-artwork.rb" "$resources" "$repo" "$input"
else
    /usr/bin/ruby "$here/prepare-artwork.rb" "$resources" "$repo"
fi
for px in 16 32 128 256 512; do
    for scale in 1 2; do
        n=$((px*scale))
        suffix=""
        if [[ $scale == 2 ]]; then suffix="@2x"; fi
        src="$resources/Brand/betterIcon_icon_sage_dark.png"
        if [[ $n -le 32 ]]; then src="$resources/Brand/32px/betterIcon_icon_sage_dark.png"; fi
        /usr/bin/sips -z "$n" "$n" "$src" --out "$stage/BetterIcon.iconset/icon_${px}x${px}${suffix}.png" >/dev/null
    done
done
/usr/bin/iconutil -c icns "$stage/BetterIcon.iconset" -o "$resources/BetterIcon.icns"
for arch in arm64 x86_64; do
    xcrun swiftc -swift-version 5 -O -target "$arch-apple-macos$minimum" -I "$here/Native" "$here"/Sources/*.swift -o "$stage/BetterIcon-$arch"
done
xcrun lipo -create "$stage/BetterIcon-arm64" "$stage/BetterIcon-x86_64" -output "$app/Contents/MacOS/BetterIcon"
/usr/bin/codesign --force --sign - --timestamp=none "$app"
/usr/bin/codesign --verify --deep --strict "$app"
ln -s /Applications "$stage/install/Applications"
/usr/bin/hdiutil create -quiet -volname "BetterIcon" -fs HFS+ -format UDZO -srcfolder "$stage/install" "$stage/BetterIcon.dmg"
/usr/bin/hdiutil verify -quiet "$stage/BetterIcon.dmg"
/usr/bin/ditto --noextattr --noqtn "$app" "$out/BetterIcon.app"
mv "$stage/BetterIcon.dmg" "$dmg"
echo "$out/BetterIcon.app"
echo "$dmg"
