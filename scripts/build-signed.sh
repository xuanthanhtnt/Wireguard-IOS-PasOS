#!/bin/bash
# Optional signed build. Needs these repository secrets:
#   IOS_CERTIFICATE_P12_BASE64  base64 of your signing certificate (.p12)
#   IOS_CERTIFICATE_PASSWORD    password of the .p12
#   IOS_PROFILE_APP_BASE64      base64 of the provisioning profile of the app
#   IOS_PROFILE_EXT_BASE64      base64 of the provisioning profile of the network extension
# Bundle IDs, team and app group are read from the profiles. Both App IDs need the
# "Network Extensions" and "App Groups" capabilities.
#
# usage: scripts/build-signed.sh <version> <build-number> <output-dir>
set -euo pipefail

VERSION="$1"
BUILD_NUMBER="$2"
OUT_DIR="$3"
TMP="${RUNNER_TEMP:-$(mktemp -d)}"
KEYCHAIN="$TMP/wgvpn-signing.keychain-db"
KEYCHAIN_PASSWORD="$(openssl rand -hex 16)"
PROFILES_DIR="$HOME/Library/MobileDevice/Provisioning Profiles"
mkdir -p "$PROFILES_DIR" "$OUT_DIR"

echo "$IOS_CERTIFICATE_P12_BASE64" | base64 --decode > "$TMP/cert.p12"
security create-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security set-keychain-settings -lut 21600 "$KEYCHAIN"
security unlock-keychain -p "$KEYCHAIN_PASSWORD" "$KEYCHAIN"
security import "$TMP/cert.p12" -P "$IOS_CERTIFICATE_PASSWORD" -A -t cert -f pkcs12 -k "$KEYCHAIN"
security set-key-partition-list -S apple-tool:,apple: -s -k "$KEYCHAIN_PASSWORD" "$KEYCHAIN" >/dev/null
security list-keychains -d user -s "$KEYCHAIN" $(security list-keychains -d user | sed 's/"//g')
IDENTITY="$(security find-identity -v -p codesigning "$KEYCHAIN" | head -1 | awk '{print $2}')"
[ -n "$IDENTITY" ] || { echo "::error::No signing identity in the .p12"; exit 1; }

read_profile() {
  local b64="$1" name="$2"
  echo "$b64" | base64 --decode > "$TMP/$name.mobileprovision"
  security cms -D -i "$TMP/$name.mobileprovision" > "$TMP/$name.plist"
  local uuid
  uuid="$(/usr/libexec/PlistBuddy -c 'Print UUID' "$TMP/$name.plist")"
  cp "$TMP/$name.mobileprovision" "$PROFILES_DIR/$uuid.mobileprovision"
  echo "$uuid"
}
pb() { /usr/libexec/PlistBuddy -c "Print $1" "$2" 2>/dev/null || true; }

APP_PROFILE="$(read_profile "$IOS_PROFILE_APP_BASE64" app)"
EXT_PROFILE="$(read_profile "$IOS_PROFILE_EXT_BASE64" ext)"
TEAM="$(pb 'TeamIdentifier:0' "$TMP/app.plist")"
APP_ID="$(pb 'Entitlements:application-identifier' "$TMP/app.plist")"
APP_BUNDLE_ID="${APP_ID#"$TEAM".}"
APP_GROUP="$(pb 'Entitlements:com.apple.security.application-groups:0' "$TMP/app.plist")"
[ -n "$APP_GROUP" ] || APP_GROUP="group.$APP_BUNDLE_ID"
EXT_ID="$(pb 'Entitlements:application-identifier' "$TMP/ext.plist")"
EXT_BUNDLE_ID="${EXT_ID#"$TEAM".}"
if [ "$EXT_BUNDLE_ID" != "$APP_BUNDLE_ID.network-extension" ]; then
  echo "::error::The extension profile must be for $APP_BUNDLE_ID.network-extension (got $EXT_BUNDLE_ID)"
  exit 1
fi

if [ -n "$(pb 'ProvisionsAllDevices' "$TMP/app.plist")" ]; then
  METHOD=enterprise
elif [ -n "$(pb 'ProvisionedDevices:0' "$TMP/app.plist")" ]; then
  if [ "$(pb 'Entitlements:get-task-allow' "$TMP/app.plist")" = "true" ]; then METHOD=development; else METHOD=ad-hoc; fi
else
  METHOD=app-store
fi
echo "Team $TEAM, app $APP_BUNDLE_ID, group $APP_GROUP, export method $METHOD"

xcodebuild -project WGVPN.xcodeproj -scheme WGVPN -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build/DerivedDataSigned \
  -archivePath build/WGVPN.xcarchive \
  MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
  APP_BUNDLE_ID="$APP_BUNDLE_ID" APP_GROUP_ID="$APP_GROUP" DEVELOPMENT_TEAM="$TEAM" \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$IDENTITY" \
  WGVPN_APP_PROFILE="$APP_PROFILE" WGVPN_EXT_PROFILE="$EXT_PROFILE" \
  OTHER_CODE_SIGN_FLAGS="--keychain $KEYCHAIN" \
  -quiet archive

cat > "$TMP/ExportOptions.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>method</key><string>$METHOD</string>
  <key>teamID</key><string>$TEAM</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>$IDENTITY</string>
  <key>stripSwiftSymbols</key><true/>
  <key>compileBitcode</key><false/>
  <key>provisioningProfiles</key>
  <dict>
    <key>$APP_BUNDLE_ID</key><string>$APP_PROFILE</string>
    <key>$APP_BUNDLE_ID.network-extension</key><string>$EXT_PROFILE</string>
  </dict>
</dict>
</plist>
PLIST

xcodebuild -exportArchive -archivePath build/WGVPN.xcarchive \
  -exportOptionsPlist "$TMP/ExportOptions.plist" -exportPath build/export
cp build/export/*.ipa "$OUT_DIR/WGVPN-$VERSION-signed-$METHOD.ipa"
ls -la "$OUT_DIR"
security delete-keychain "$KEYCHAIN" || true
