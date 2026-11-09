#!/usr/bin/env bash
# os-updater: minimal A/B updater skeleton (M2)
# Checks a remote version file; if newer, downloads rootfs.img into inactive slot.
set -euo pipefail

ACTIVE=$(cat /run/emunix/active_slot 2>/dev/null || echo a)
if [ "$ACTIVE" = "a" ]; then INACTIVE=b; else INACTIVE=a; fi

REPO_URL="${EMUNIX_REPO_URL:-https://example.invalid/emunix}"
REMOTE_VER=$(curl -fsSL "$REPO_URL/version" 2>/dev/null || echo "")
LOCAL_VER=$(cat /etc/emunix-version 2>/dev/null || echo "")

if [ -z "$REMOTE_VER" ] || [ "$REMOTE_VER" = "$LOCAL_VER" ]; then
  echo "No update available ($LOCAL_VER)."
  exit 0
fi

echo "Update available: $LOCAL_VER -> $REMOTE_VER"
# TODO: download rootfs.img to inactive slot, flip boot entry, reboot
echo "Not implemented yet (M2)."
exit 0
