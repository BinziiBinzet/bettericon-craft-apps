#!/bin/bash
set -euo pipefail
export COPYFILE_DISABLE=1
here="$(cd "$(dirname "$0")" && pwd)"
repo="$(dirname "$here")"
out="${1:?Usage: build.sh OUTPUT_DIRECTORY [BetterIcon checkout, or a ZIP of its branding and hover strips]}"
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
input="${2:-$repo}"
/usr/bin/python3 "$repo/Shared/prepare_packs.py" "$resources" "$input"
# Each pack's download size, for the offer a new installation makes. pack-sizes.py writes it from the pack artwork.
cp -X "$here/PackSizes.tsv" "$resources/Catalog/pack-sizes.tsv"
catalog="$(tr -d '\r' < "$resources/Catalog/packs.tsv" | shasum -a 256 | cut -d ' ' -f 1)"
sizes="$(tr -d '\r' < "$here/PackSizes.tsv")"
if [[ $'\n'"$sizes"$'\n' != *$'\n#catalog\t'"$catalog"$'\n'* ]]; then
    echo "warning: macOS/PackSizes.tsv was made for another pack catalog. Run macOS/pack-sizes.py on a checkout with the artwork." >&2
fi
mkdir -p "$app/Contents/Helpers"
for target in arm64 amd64; do
    (cd "$repo/Shared/packstore"; CGO_ENABLED=0 GOOS=darwin GOARCH="$target" go build -trimpath -ldflags="-s -w" -o "$stage/packs-$target" .)
done
xcrun lipo -create "$stage/packs-arm64" "$stage/packs-amd64" -output "$app/Contents/Helpers/packstore"
/usr/bin/codesign --force --sign - --timestamp=none "$app/Contents/Helpers/packstore"
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
