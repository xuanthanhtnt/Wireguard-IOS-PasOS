#!/bin/bash
# Packs a built WGVPN.app into an .ipa, ad-hoc signed with its entitlements.
# The ad-hoc signature is what TrollStore needs; AltStore / SideStore / Sideloadly / ESign
# replace it with your own certificate when installing.
#
# usage: scripts/package-ipa.sh path/to/WGVPN.app output.ipa [app-group-id]
set -euo pipefail

APP="$1"
OUT="$2"
APP_GROUP="${3:-group.com.wgvpn.app}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

case "$OUT" in
  /*) ;;
  *) OUT="$PWD/$OUT" ;;
esac
mkdir -p "$(dirname "$OUT")"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/Payload"
cp -R "$APP" "$WORK/Payload/"
BUNDLE="$WORK/Payload/$(basename "$APP")"

sed "s/\$(APP_GROUP_ID)/$APP_GROUP/g" "$ROOT/WGVPN/WGVPN.entitlements" > "$WORK/app.entitlements"
sed "s/\$(APP_GROUP_ID)/$APP_GROUP/g" "$ROOT/WGVPNTunnel/WGVPNTunnel.entitlements" > "$WORK/ext.entitlements"

# Remove leftovers that would break signing
find "$BUNDLE" -name "_CodeSignature" -type d -prune -exec rm -rf {} + || true
find "$BUNDLE" -name "*.entitlements" -delete || true

for APPEX in "$BUNDLE"/PlugIns/*.appex; do
  [ -d "$APPEX" ] || continue
  codesign --force --sign - --timestamp=none --entitlements "$WORK/ext.entitlements" "$APPEX"
done
codesign --force --sign - --timestamp=none --entitlements "$WORK/app.entitlements" "$BUNDLE"

echo "Entitlements of the app:"
codesign -d --entitlements - "$BUNDLE" 2>/dev/null || true

rm -f "$OUT"
(cd "$WORK" && /usr/bin/zip -qry "$OUT" Payload)
ls -la "$OUT"
