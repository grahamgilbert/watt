#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
: "${WATT_SIGNING_IDENTITY:?Configure signing first}"
: "${WATT_KEYCHAIN:?Configure signing first}"
: "${WATT_TEAM_ID:?Configure signing first}"
# Apple ticket delivery can briefly fail after a successful notarization.
retry_ticket() {
  local attempt
  for attempt in 1 2 3; do
    if "$@"; then return 0; fi
    if [[ "$attempt" == 3 ]]; then return 1; fi
    echo "Apple ticket request failed; retrying in 10 seconds ($attempt/3)." >&2
    sleep 10
  done
}
version=$(cat VERSION)
app="$PWD/dist/Watt.app"
helper="$app/Contents/Library/HelperTools/WattEnergyHelper"
helper_identifier="com.grahamgilbert.Watt.EnergyHelper"
zsh scripts/build-app.sh release
architectures=$(lipo -archs "$app/Contents/MacOS/Watt")
[[ " $architectures " == *" arm64 "* && " $architectures " == *" x86_64 "* ]] || { echo "Release must contain both architectures" >&2; exit 1; }
helper_architectures=$(lipo -archs "$helper")
[[ " $helper_architectures " == *" arm64 "* && " $helper_architectures " == *" x86_64 "* ]] || { echo "Energy helper must contain both release architectures" >&2; exit 1; }
# Sign the fixed privileged daemon before sealing the containing app.
codesign --force --options runtime --timestamp --keychain "$WATT_KEYCHAIN" --identifier "$helper_identifier" --sign "$WATT_SIGNING_IDENTITY" "$helper"
codesign --verify --strict "$helper"
codesign -dv --verbose=4 "$helper" 2> "$RUNNER_TEMP/watt-helper-signature.txt"
grep -Fx "Identifier=$helper_identifier" "$RUNNER_TEMP/watt-helper-signature.txt"
grep -Fx "TeamIdentifier=$WATT_TEAM_ID" "$RUNNER_TEMP/watt-helper-signature.txt"
python3 scripts/nested_signing.py "$app/Contents/Frameworks/Sparkle.framework" "$WATT_SIGNING_IDENTITY" "$WATT_KEYCHAIN"
codesign --force --options runtime --timestamp --keychain "$WATT_KEYCHAIN" --sign "$WATT_SIGNING_IDENTITY" "$app"
codesign --verify --deep --strict "$app"
codesign -dv --verbose=4 "$app" 2> "$RUNNER_TEMP/watt-signature.txt"
grep -Fx "TeamIdentifier=$WATT_TEAM_ID" "$RUNNER_TEMP/watt-signature.txt"
swift scripts/verify-helper-signature.swift "$app" "$WATT_TEAM_ID"
ditto -c -k --keepParent "$app" "$RUNNER_TEMP/Watt-notarization.zip"
xcrun notarytool submit "$RUNNER_TEMP/Watt-notarization.zip" --keychain "$WATT_KEYCHAIN" --keychain-profile watt-release --wait --output-format json > "$RUNNER_TEMP/watt-app-notary.json"
python3 -c 'import json,sys; r=json.load(open(sys.argv[1])); sys.exit(0 if r.get("status")=="Accepted" else "App notarization failed; inspect notary submission.")' "$RUNNER_TEMP/watt-app-notary.json"
retry_ticket xcrun stapler staple "$app"
retry_ticket xcrun stapler validate "$app"
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
retry_ticket xcrun stapler staple "$dmg"
retry_ticket xcrun stapler validate "$dmg"
(cd dist && shasum -a 256 "Watt-$version.dmg" > "Watt-$version.dmg.sha256")
