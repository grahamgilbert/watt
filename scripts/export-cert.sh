#!/usr/bin/env bash
# Exports a single Developer ID Application certificate (the one issued
# 2026-05-12) plus its private key as a base64-encoded .p12 suitable for the
# APP_CERTIFICATES_P12 GitHub Actions secret.
#
# macOS's `security` tool has no per-item filter on `export`, so this script:
#   1. Bulk-exports every identity in your login keychain to an interim p12.
#   2. Decrypts that p12 to PEM via openssl.
#   3. Walks the PEM blocks, computes SHA-1 of each certificate, and picks the
#      one whose fingerprint matches the target.
#   4. Pairs that cert with its private key (matched by localKeyID).
#   5. Rebuilds a single-identity p12 containing only that cert+key.
#   6. Base64-encodes it and prints/copies the secrets you need.
#
# Usage:
#   scripts/export-cert.sh                   # writes /tmp/watt-cert.p12
#   scripts/export-cert.sh /path/out.p12     # custom output
#
# Keychain Access will prompt you to allow access to the private keys when
# `security export` runs. Click "Always Allow" once and it will let the whole
# export through.

set -euo pipefail

# SHA-1 fingerprint of the Developer ID Application cert issued 2026-05-12.
TARGET_SHA1="18A687194D07AC069212F2D2B05E007B07F26CF5"
OUT_P12="${1:-/tmp/watt-cert.p12}"

TMPDIR="$(mktemp -d)"
trap 'rm -rf "$TMPDIR"' EXIT

INTERIM_PW="$(openssl rand -base64 24)"
FINAL_PW="$(openssl rand -base64 24)"

echo "[1/5] Bulk-exporting all identities from login keychain..."
# `security export` walks every private key's ACL one at a time. Clicking
# "Always Allow" only grants the *one* key currently being prompted, so on a
# keychain with several keys you get re-prompted forever. Pre-authorizing the
# security tool via the partition list does it in one shot.
echo "      Pre-authorizing the 'security' tool against your keychain."
echo "      You'll be asked for your macOS login password once."
read -rsp "      login keychain password: " KC_PW
echo
security set-key-partition-list \
    -S apple-tool:,apple:,unsigned: \
    -s \
    -k "$KC_PW" \
    login.keychain-db >/dev/null 2>&1 || {
        echo "FATAL: set-key-partition-list rejected the password." >&2
        exit 1
    }
unset KC_PW

security export \
    -k login.keychain-db \
    -t identities \
    -f pkcs12 \
    -P "$INTERIM_PW" \
    -o "$TMPDIR/all.p12"

echo "[2/5] Decrypting to PEM bundle..."
openssl pkcs12 \
    -in "$TMPDIR/all.p12" \
    -nodes \
    -passin "pass:$INTERIM_PW" \
    -out "$TMPDIR/all.pem" \
    >/dev/null

echo "[3/5] Selecting cert with SHA-1 $TARGET_SHA1..."
python3 - "$TMPDIR/all.pem" "$TMPDIR/cert.pem" "$TMPDIR/key.pem" "$TARGET_SHA1" <<'PYEOF'
import subprocess, sys

src, cert_out, key_out, target = sys.argv[1:5]
target = target.upper()

class Block:
    __slots__ = ("type", "localKeyID", "pem_lines")
    def __init__(self):
        self.type = None
        self.localKeyID = None
        self.pem_lines = []
    @property
    def pem(self):
        return "\n".join(self.pem_lines) + "\n"

blocks = []
pending_keyid = None
cur = None

with open(src) as f:
    for line in f:
        line = line.rstrip("\n")
        s = line.strip()
        if cur is None and s.startswith("localKeyID:"):
            pending_keyid = s.split("localKeyID:", 1)[1].strip()
        elif line.startswith("-----BEGIN "):
            cur = Block()
            cur.type = line.replace("-----BEGIN ", "").replace("-----", "").strip()
            cur.localKeyID = pending_keyid
            cur.pem_lines.append(line)
        elif line.startswith("-----END ") and cur is not None:
            cur.pem_lines.append(line)
            blocks.append(cur)
            cur = None
            pending_keyid = None
        elif cur is not None:
            cur.pem_lines.append(line)

# Find cert by SHA-1
target_cert = None
for b in blocks:
    if b.type == "CERTIFICATE":
        r = subprocess.run(
            ["openssl", "x509", "-noout", "-fingerprint", "-sha1"],
            input=b.pem.encode(), capture_output=True, text=True, check=True,
        )
        fp = r.stdout.strip().split("=", 1)[1].replace(":", "").upper()
        if fp == target:
            target_cert = b
            break

if target_cert is None:
    print(f"FATAL: no cert matching SHA-1 {target} in keychain export", file=sys.stderr)
    sys.exit(1)

# Find matching private key
target_key = next(
    (b for b in blocks
     if "KEY" in b.type
     and b.localKeyID is not None
     and b.localKeyID == target_cert.localKeyID),
    None,
)
if target_key is None:
    print(f"FATAL: no private key with localKeyID {target_cert.localKeyID}", file=sys.stderr)
    sys.exit(1)

with open(cert_out, "w") as f:
    f.write(target_cert.pem)
with open(key_out, "w") as f:
    f.write(target_key.pem)

print(f"      matched cert (localKeyID={target_cert.localKeyID})")
PYEOF

echo "[4/5] Building filtered single-identity p12..."
openssl pkcs12 \
    -export \
    -in "$TMPDIR/cert.pem" \
    -inkey "$TMPDIR/key.pem" \
    -out "$OUT_P12" \
    -passout "pass:$FINAL_PW" \
    -name "Developer ID Application: Graham Gilbert (9D8XP85393)" \
    >/dev/null

echo "[5/5] Encoding for GitHub..."
B64="$(base64 -i "$OUT_P12")"
echo "$B64" > "$OUT_P12.b64"

cat <<EOF

================================================================
  Two values to paste into GitHub → Settings → Secrets → Actions
================================================================

Secret name: APP_CERTIFICATES_P12_PASSWORD
Value:       $FINAL_PW

Secret name: APP_CERTIFICATES_P12
Value:       (copied to clipboard; also written to $OUT_P12.b64)

Sanity check on the new p12:
$(openssl pkcs12 -in "$OUT_P12" -nokeys -passin "pass:$FINAL_PW" 2>/dev/null \
  | openssl x509 -noout -subject -fingerprint -sha1)

After saving both secrets to GitHub, delete the local files:
    rm '$OUT_P12' '$OUT_P12.b64'
EOF

if command -v pbcopy >/dev/null 2>&1; then
    printf '%s' "$B64" | pbcopy
    echo "(base64 is on your clipboard, ready to paste)"
fi
