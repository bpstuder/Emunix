#!/usr/bin/env bash
# emunix-os-updater: fetch a signed update manifest, verify it, download the image, write the
# inactive rootfs slot, and point the loader at it. Runs as root from emunix-os-updater.service.
#
#   --dry-run   print the plan (version, url, target partition, bytes) and change nothing
#
# Safety: the active slot comes from the running root (emunix-slot active) and the run aborts
# when it cannot be determined; nothing is written to a slot before the whole image is downloaded
# and its sha256/size match the signed manifest. A failed run leaves the active slot untouched.
set -euo pipefail

# shellcheck disable=SC1090   # the library path is overridable for tests
. "${EMUNIX_LIB:-/usr/local/lib/emunix/lib-update.sh}"

REPO_URL="${EMUNIX_REPO_URL:-https://example.invalid/emunix}"
CACHE_DIR="${EMUNIX_CACHE_DIR:-/var/cache/emunix}"
PUBKEY="${EMUNIX_UPDATE_PUBKEY:-/etc/emunix/update.pub}"
VERSION_FILE="${EMUNIX_VERSION_FILE:-/etc/emunix-version}"
SLOT_BIN="${EMUNIX_SLOT_BIN:-/usr/local/bin/emunix-slot}"
LOCK_FILE="${EMUNIX_LOCK_FILE:-/run/emunix/os-updater.lock}"
LOG_FILE="${EMUNIX_UPDATE_LOG:-/var/log/emunix-update.log}"
DRY_RUN=0

die() {
  printf 'emunix-os-updater: %s\n' "$*" >&2
  printf '%s emunix-os-updater: %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$*" >>"$LOG_FILE" 2>/dev/null || true
  exit 1
}

usage() { printf 'usage: emunix-os-updater [--dry-run]\n' >&2; exit 1; }

while [ $# -gt 0 ]; do
  case $1 in
    --dry-run) DRY_RUN=1 ;;
    *) usage ;;
  esac
  shift
done

# One run at a time: a second invocation while the first holds the lock is a no-op, not a failure.
mkdir -p "$(dirname "$LOCK_FILE")"
exec 9>"$LOCK_FILE"
flock -n 9 || { printf 'emunix-os-updater: %s is held; another run is in progress\n' "$LOCK_FILE"; exit 0; }

[ -x "$SLOT_BIN" ] || die "$SLOT_BIN is not installed"
active=$("$SLOT_BIN" active) || die "cannot determine the running slot from the root partition"
case $active in
  a) inactive=b ;;
  b) inactive=a ;;
  *) die "the running slot '$active' is not a or b; refusing to guess the inactive slot" ;;
esac

local_ver=$(cat "$VERSION_FILE" 2>/dev/null || true)

REPO_URL=${REPO_URL%/}
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
manifest=$TMP/emunix.json
signature=$TMP/emunix.json.minisig
curl -fsSL -o "$manifest" "$REPO_URL/emunix.json" || die "cannot fetch $REPO_URL/emunix.json"
curl -fsSL -o "$signature" "$REPO_URL/emunix.json.minisig" || die "cannot fetch $REPO_URL/emunix.json.minisig"

# The signature gate comes before any version comparison: a manifest that does not verify is a
# failure even when the version it carries is not newer than the installed one.
verify_manifest "$manifest" "$signature" "$PUBKEY" || die "the manifest signature does not verify against $PUBKEY"
remote_ver=$(manifest_string "$manifest" version)
if ! needs_update "$local_ver" "$remote_ver"; then
  printf 'No update available (installed %s, remote %s).\n' "${local_ver:-none}" "$remote_ver"
  exit 0
fi
check_update "$manifest" "$signature" "$PUBKEY" || die "the manifest was refused; nothing downloaded"

version=$remote_ver
url=$(manifest_string "$manifest" url)
sha256=$(manifest_string "$manifest" sha256)
size=$(manifest_number "$manifest" size)

target=${EMUNIX_PARTITION_DIR:-/dev/disk/by-partlabel}/rootfs_$inactive
[ -b "$target" ] || die "$target is not a block device"

if [ "$DRY_RUN" -eq 1 ]; then
  printf 'dry run: %s -> %s\n' "${local_ver:-none}" "$version"
  printf '  url:    %s\n' "$url"
  printf '  target: %s\n' "$target"
  printf '  bytes:  %s\n' "$size"
  exit 0
fi

mkdir -p "$CACHE_DIR"
avail=$(df -B1 --output=avail "$CACHE_DIR" | tail -n1)
# A full /var would break the /etc overlay, so keep 10% headroom over the image.
need=$((size + size / 10))
[ "$avail" -ge "$need" ] || die "not enough free space on $CACHE_DIR: $avail bytes available, need $need"

name=$(basename "$url")
file=$CACHE_DIR/$name
curl -fSL -C - -o "$file" "$url" || die "cannot download $url"
verify_image "$file" "$sha256" "$size" || die "the downloaded image does not match the manifest; $target was not touched"

dd if="$file" of="$target" bs=4M conv=fsync status=none || die "writing $target failed"
# e2fsck -f on hash-verified bytes: -y so a non-interactive service never hangs on a prompt.
e2fsck -f -y "$target" || die "$target does not validate after the write; the boot entry was not changed"
"$SLOT_BIN" next "$inactive" || die "could not point the loader at slot $inactive"

msg="Emunix $version is staged on slot $inactive. Reboot to apply it."
printf '%s\n' "$msg"
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >>"$LOG_FILE" 2>/dev/null || true
# ES-DE has no external notification IPC (its popup queue is internal to the frontend), so the
# message also goes to the console and the update log; a real in-frontend popup needs an ES-DE patch.
printf '%s\n' "$msg" >/dev/tty1 2>/dev/null || true
printf 'emunix-os-updater: staged %s on slot %s (%s)\n' "$version" "$inactive" "$target"
