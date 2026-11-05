#!/bin/bash
set -euo pipefail
[[ "${GITHUB_ACTIONS:-}" == true && -n "${RUNNER_TEMP:-}" ]] || exit 0
security delete-keychain "$RUNNER_TEMP/watt-signing/signing.keychain-db" 2>/dev/null || true
rm -rf "$RUNNER_TEMP/watt-signing"
