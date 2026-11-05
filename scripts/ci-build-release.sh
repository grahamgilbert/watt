#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${WATT_SIGNING_IDENTITY:?Configure signing first}"
: "${WATT_KEYCHAIN:?Configure signing first}"
: "${WATT_TEAM_ID:?Configure signing first}"
version=$(cat VERSION)
app="$PWD/dist/Watt.app"
zsh scripts/build-app.sh release
lipo "$app/Contents/MacOS/Watt" -verify_arch arm64 x86_64
codesign --force --options runtime --timestamp --keychain "$WATT_KEYCHAIN" --sign "$WATT_SIGNING_IDENTITY" "$app"
codesign --verify --deep --strict "$app"
codesign -dv --verbose=4 "$app" 2> "$RUNNER_TEMP/watt-signature.txt"
grep -F "TeamIdentifier=$WATT_TEAM_ID" "$RUNNER_TEMP/watt-signature.txt"
ditto -c -k --keepParent "$app" "$RUNNER_TEMP/Watt-notarization.zip"
xcrun notarytool submit "$RUNNER_TEMP/Watt-notarization.zip" --keychain "$WATT_KEYCHAIN" --keychain-profile watt-release --wait --output-format json > "$RUNNER_TEMP/watt-app-notary.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r.get("status")=="Accepted" else "App notarization failed; inspect notary submission.")' "$RUNNER_TEMP/watt-app-notary.json"
xcrun stapler staple "$app"
xcrun stapler validate "$app"
spctl --assess --type execute --verbose=2 "$app"
staging="$RUNNER_TEMP/watt-dmg"
mkdir -p "$staging"
ditto "$app" "$staging/Watt.app"
ln -s /Applications "$staging/Applications"
dmg="$PWD/dist/Watt-$version.dmg"
hdiutil create -volname Watt -srcfolder "$staging" -ov -format UDZO "$dmg"
codesign --timestamp --keychain "$WATT_KEYCHAIN" --sign "$WATT_SIGNING_IDENTITY" "$dmg"
xcrun notarytool submit "$dmg" --keychain "$WATT_KEYCHAIN" --keychain-profile watt-release --wait --output-format json > "$RUNNER_TEMP/watt-dmg-notary.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r.get("status")=="Accepted" else "DMG notarization failed; inspect notary submission.")' "$RUNNER_TEMP/watt-dmg-notary.json"
xcrun stapler staple "$dmg"
xcrun stapler validate "$dmg"
(cd dist && shasum -a 256 "Watt-$version.dmg" > "Watt-$version.dmg.sha256")
