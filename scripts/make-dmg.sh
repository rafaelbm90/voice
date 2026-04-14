#!/bin/zsh
# Build a distributable DMG from dist/Voice.app.
# Prefers `create-dmg` (brew install create-dmg); falls back to hdiutil.

set -euo pipefail

root=${0:A:h:h}
cd "$root"

app=${1:-dist/Voice.app}
[[ -d "$app" ]] || { echo "missing $app — run scripts/build-app.sh first"; exit 1; }

VERSION=${VERSION:-$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist" 2>/dev/null || echo 0.0.0)}
dmg="dist/Voice-$VERSION.dmg"
rm -f "$dmg"

if command -v create-dmg >/dev/null 2>&1; then
  echo "==> create-dmg → $dmg"
  create-dmg \
    --volname "Voice $VERSION" \
    --window-size 500 320 \
    --icon-size 96 \
    --icon "Voice.app" 140 160 \
    --app-drop-link 360 160 \
    --hide-extension "Voice.app" \
    "$dmg" "$app"
else
  echo "==> hdiutil fallback → $dmg (install create-dmg for prettier layout)"
  staging=$(mktemp -d)
  trap 'rm -rf "$staging"' EXIT
  cp -R "$app" "$staging/"
  ln -s /Applications "$staging/Applications"
  hdiutil create -volname "Voice $VERSION" -srcfolder "$staging" \
    -fs HFS+ -format UDZO -ov "$dmg"
fi

shasum -a 256 "$dmg"
echo "==> done: $dmg"
