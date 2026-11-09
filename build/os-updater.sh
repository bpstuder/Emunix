#!/usr/bin/env bash
# os-updater: minimal A/B updater skeleton (M2)
# Checks a remote version file; if newer, downloads rootfs.img into inactive slot.
set -euo pipefail

# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-update.sh
. "$(dirname "$0")/lib-update.sh"

REPO_URL="${EMUNIX_REPO_URL:-https://example.invalid/emunix}"
REMOTE_VER=$(curl -fsSL "$REPO_URL/version" 2>/dev/null || echo "")
LOCAL_VER=$(cat /etc/emunix-version 2>/dev/null || echo "")

if ! needs_update "$LOCAL_VER" "$REMOTE_VER"; then
  echo "No update available ($LOCAL_VER)."
  exit 0
fi

echo "Update available: $LOCAL_VER -> $REMOTE_VER"
# TODO: download rootfs.img to inactive slot, flip boot entry, reboot
echo "Not implemented yet (M2)."
exit 0
