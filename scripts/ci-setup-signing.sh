#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && -n "${RUNNER_TEMP:-}" && -n "${GITHUB_ENV:-}" ]] || exit 1
for name in BUILD_CERTIFICATE_BASE64 P12_PASSWORD APPLE_TEAM_ID APPLE_ID APPLE_ID_PASSWORD; do
  [[ -n "${!name:-}" ]] || { echo "Missing release secret: $name" >&2; exit 1; }
done
[[ "$APPLE_TEAM_ID" =~ ^[A-Z0-9]{10}$ ]] || exit 1
umask 077
signing_dir="$RUNNER_TEMP/watt-signing"
mkdir -p "$signing_dir"
export WATT_SIGNING_DIRECTORY="$signing_dir"
python3 - <<'PYTHON'
import base64,os,pathlib
pathlib.Path(os.environ['WATT_SIGNING_DIRECTORY'],'certificate.p12').write_bytes(base64.b64decode(''.join(os.environ['BUILD_CERTIFICATE_BASE64'].split()),validate=True))
PYTHON
keychain="$signing_dir/signing.keychain-db"
password=$(openssl rand -base64 32)
printf '::add-mask::%s\n' "$password"
security create-keychain -p "$password" "$keychain"
security set-keychain-settings -lut 21600 "$keychain"
security unlock-keychain -p "$password" "$keychain"
security import "$signing_dir/certificate.p12" -P "$P12_PASSWORD" -t cert -f pkcs12 -k "$keychain" -T /usr/bin/codesign -T /usr/bin/security
security set-key-partition-list -S apple-tool:,apple:,codesign: -k "$password" "$keychain" >/dev/null
security list-keychains -d user -s "$keychain"
identity=$(security find-identity -v -p codesigning "$keychain" | sed -nE 's/.* ([A-F0-9]{40}) "Developer ID Application: .*\('"$APPLE_TEAM_ID"'\)".*/\1/p')
[[ "$identity" =~ ^[A-F0-9]{40}$ ]] || { echo 'Expected exactly one valid Developer ID Application identity matching team.' >&2; exit 1; }
xcrun notarytool store-credentials watt-release --keychain "$keychain" --apple-id "$APPLE_ID" --team-id "$APPLE_TEAM_ID" --password "$APPLE_ID_PASSWORD"
printf 'WATT_SIGNING_IDENTITY=%s\nWATT_TEAM_ID=%s\nWATT_KEYCHAIN=%s\n' "$identity" "$APPLE_TEAM_ID" "$keychain" >> "$GITHUB_ENV"
