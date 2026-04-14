#!/bin/zsh
# Ad-hoc sign Voice.app. Free, no Apple Developer ID required.
# Homebrew Cask installs will bypass Gatekeeper via quarantine removal.
# DMG users will see a one-time warning; see README for workaround.
#
# For Developer ID signing, set IDENTITY to your cert CN:
#   IDENTITY="Developer ID Application: Your Name (TEAMID)" zsh scripts/sign.sh

set -euo pipefail

root=${0:A:h:h}
cd "$root"

app=${1:-dist/Voice.app}
[[ -d "$app" ]] || { echo "missing $app — run scripts/build-app.sh first"; exit 1; }

IDENTITY=${IDENTITY:--}
entitlements="Resources/Voice.entitlements"

echo "==> signing $app with identity=$IDENTITY"

# Strip any prior signature, then sign from inside out.
find "$app" -name '*.bundle' -type d -print0 2>/dev/null | while IFS= read -r -d '' b; do
  codesign --remove-signature "$b" 2>/dev/null || true
  codesign --force --sign "$IDENTITY" "$b"
done

codesign --remove-signature "$app" 2>/dev/null || true

sign_args=(--force --sign "$IDENTITY" --entitlements "$entitlements")
if [[ "$IDENTITY" != "-" ]]; then
  sign_args+=(--options runtime --timestamp)
fi

codesign "${sign_args[@]}" "$app"

echo "==> verifying"
codesign --verify --deep --strict --verbose=2 "$app"

echo "==> spctl assessment (ad-hoc will be rejected — expected)"
spctl -a -vv "$app" || true

echo "==> done"
