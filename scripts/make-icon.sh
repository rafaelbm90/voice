#!/bin/zsh
# Generate AppIcon.icns from voice_logo.png (1024x1024 source).
# Requires: sips, iconutil (both shipped with macOS).

set -euo pipefail

root=${0:A:h:h}
src=${1:-$root/voice_logo.png}
out=${2:-$root/Resources/AppIcon.icns}
iconset=$(mktemp -d)/AppIcon.iconset

trap 'rm -rf "${iconset:h}"' EXIT

mkdir -p "$iconset"

sizes=(16 32 64 128 256 512 1024)
for sz in $sizes; do
  sips -z $sz $sz "$src" --out "$iconset/icon_${sz}x${sz}.png" >/dev/null
done

# Retina @2x variants for 16-512
cp "$iconset/icon_32x32.png"   "$iconset/icon_16x16@2x.png"
cp "$iconset/icon_64x64.png"   "$iconset/icon_32x32@2x.png"
cp "$iconset/icon_256x256.png" "$iconset/icon_128x128@2x.png"
cp "$iconset/icon_512x512.png" "$iconset/icon_256x256@2x.png"
cp "$iconset/icon_1024x1024.png" "$iconset/icon_512x512@2x.png"
rm "$iconset/icon_64x64.png" "$iconset/icon_1024x1024.png"

iconutil -c icns "$iconset" -o "$out"
echo "wrote $out"
