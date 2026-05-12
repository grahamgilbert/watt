#!/usr/bin/env bash
# Cleanly remove Watt and its privileged helper.
#
# This script must be run as root, since the helper it removes is owned by
# root and lives under /Library/LaunchDaemons. It will refuse to run
# otherwise rather than calling sudo internally — that way the user knows
# exactly what's escalating, and we don't get into trouble in non-
# interactive contexts (CI, sandboxed shells) where sudo can't prompt.
#
# Recommended invocation:
#     sudo ./uninstall.sh
#
# What this does:
#   1. Stops the helper (launchctl bootout).
#   2. Removes the LaunchDaemon plist at /Library/LaunchDaemons.
#   3. Clears the SMAppService approval defaults for the invoking user.
#   4. Removes ~/Library/Application Support/Watt (samples, episodes,
#      reports, on-disk Markdown mirrors) for the invoking user.
#   5. Tells you to drag Watt.app to Trash.
#
# Usage:  sudo ./uninstall.sh           interactive
#         sudo ./uninstall.sh --yes     non-interactive (assume yes to all)

set -euo pipefail

if [[ $EUID -ne 0 ]]; then
    cat >&2 <<EOF
error: uninstall.sh must be run as root.

Re-run as:
    sudo ./uninstall.sh${1:+ $1}

The script removes a LaunchDaemon at /Library/LaunchDaemons that runs as
root, so root is required. We don't call sudo internally because we want
the privilege escalation to be explicit and visible at the call site.
EOF
    exit 1
fi

ASSUME_YES=0
if [[ "${1:-}" == "--yes" || "${1:-}" == "-y" ]]; then
    ASSUME_YES=1
fi

confirm() {
    if (( ASSUME_YES )); then return 0; fi
    local prompt="$1"
    read -rp "$prompt [y/N] " ans
    [[ "${ans,,}" == y* ]]
}

# When run via sudo, $HOME is root's home. The data directory we want to
# clean lives under the *invoking* user's home, available as $SUDO_USER.
TARGET_USER="${SUDO_USER:-$USER}"
TARGET_HOME="$(eval echo "~${TARGET_USER}")"

echo "=== Watt uninstall ==="
echo
echo "About to remove:"
echo "  • The privileged helper at /Library/LaunchDaemons/com.grahamgilbert.watt.helper.plist"
echo "  • ${TARGET_HOME}/Library/Application Support/Watt/ (stored reports + telemetry)"
echo
echo "Watt.app itself stays in /Applications until you drag it to the Trash."
echo
confirm "Proceed?" || { echo "Aborted."; exit 0; }

# 1. Stop / unregister the helper. Errors are non-fatal — the plist may
#    already be gone.
echo
echo "[1/4] Stopping helper…"
/bin/launchctl bootout system/com.grahamgilbert.watt.helper 2>/dev/null \
    || /bin/launchctl unload -w /Library/LaunchDaemons/com.grahamgilbert.watt.helper.plist 2>/dev/null \
    || echo "  (helper was not loaded — nothing to stop)"

# 2. Remove the LaunchDaemon plist that SMAppService wrote at registration.
echo
echo "[2/4] Removing helper plist…"
/bin/rm -f /Library/LaunchDaemons/com.grahamgilbert.watt.helper.plist

# 3. Clear the SMAppService approval cache for the invoking user. Without
#    this, Login Items can keep a stale "approved" entry around.
echo
echo "[3/4] Clearing SMAppService approval cache for ${TARGET_USER}…"
/usr/bin/sudo -u "$TARGET_USER" /usr/bin/defaults delete com.grahamgilbert.watt 2>/dev/null || true

# 4. Wipe the user-level data directory.
USER_DATA="${TARGET_HOME}/Library/Application Support/Watt"
echo
echo "[4/4] Removing ${USER_DATA}…"
if [[ -d "$USER_DATA" ]]; then
    if confirm "  Delete ${USER_DATA} and every report inside it?"; then
        /bin/rm -rf "$USER_DATA"
        echo "  done"
    else
        echo "  skipped (you can rm it manually later)"
    fi
else
    echo "  (already gone)"
fi

echo
echo "Watt's privileged helper has been removed."
echo "To finish:"
echo "  • Quit Watt if it's running (menubar → Quit)."
echo "  • Drag /Applications/Watt.app to the Trash."
