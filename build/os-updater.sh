#!/usr/bin/env bash
# emunix-os-updater: fetch a signed update manifest, verify it, download the image, write the
# inactive rootfs slot, and point the loader at it. Runs as root from emunix-os-updater.service.
#
#   --dry-run   print the plan (version, url, target partition, bytes) and change nothing
#
# Safety: the active slot comes from the running root (emunix-slot active) and the run aborts
# when it cannot be determined; nothing is written to a slot before the whole image is downloaded
# and its sha256/size match the signed manifest. The release artifact is a GPT disk image, so its
# rootfs_a partition is streamed into the inactive slot and the kernel/initramfs are read from its
# esp partition. A failed run leaves the active slot untouched.
#
# The ESP is shared by both slots, so a rootfs-only update would keep booting the old kernel. The
# two files are replaced per file (temp name, fsync, rename, fsync) and EFI/ and loader/ are never
# touched. A power cut in the rename window can still leave a mismatched kernel/initramfs pair,
# which no slot can recover -- the residual risk of updating the ESP.
set -euo pipefail

# shellcheck disable=SC1090   # the library path is overridable for tests
. "${EMUNIX_LIB:-/usr/local/lib/emunix/lib-update.sh}"

# GitHub's "latest release" asset URL is stable across tags, so a device finds the newest manifest
# without a per-version default. The manifest's own image.url is absolute and points at the release.
REPO_URL="${EMUNIX_REPO_URL:-https://github.com/bpstuder/Emunix/releases/latest/download}"
CACHE_DIR="${EMUNIX_CACHE_DIR:-/var/cache/emunix}"
PUBKEY="${EMUNIX_UPDATE_PUBKEY:-/etc/emunix/update.pub}"
VERSION_FILE="${EMUNIX_VERSION_FILE:-/etc/emunix-version}"
SLOT_BIN="${EMUNIX_SLOT_BIN:-/usr/local/bin/emunix-slot}"
LOCK_FILE="${EMUNIX_LOCK_FILE:-/run/emunix/os-updater.lock}"
LOG_FILE="${EMUNIX_UPDATE_LOG:-/var/log/emunix-update.log}"
ESP_DIR="${EMUNIX_ESP_DIR:-/boot}"
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
# -C - can only resume a file shorter than the artifact: a complete-but-wrong one (a run that died
# after the download, or a bad mirror) answers the range at EOF with 416 and every later run would
# fail before the hash was checked. Trust a cached file that matches the manifest, drop anything
# else that is not resumable, and resume a genuine partial.
if [ -f "$file" ] && verify_image "$file" "$sha256" "$size" 2>/dev/null; then
  printf 'emunix-os-updater: %s is already downloaded and matches the manifest\n' "$file"
else
  if [ -f "$file" ] && [ "$(stat -c %s "$file")" -ge "$size" ]; then
    rm -f "$file"
  fi
  curl -fSL -C - -o "$file" "$url" || die "cannot download $url"
  verify_image "$file" "$sha256" "$size" || die "the downloaded image does not match the manifest; $target was not touched"
fi

# The release artifact is a full GPT disk image; the slot needs only its rootfs_a partition. Stream
# that partition into the slot so the 13.5 GiB raw image never touches /var (2 GiB): the manifest
# pins the compressed bytes, and zstd reads exactly those bytes. A non-.zst artifact is a bare
# rootfs image and is written whole.
esp_img=
if [[ $name == *.zst ]]; then
  raw_size=$(zstd -lv "$file" | sed -n 's/.*Decompressed Size:.*(\([0-9]\+\) B).*/\1/p')
  [ -n "$raw_size" ] || die "cannot read the decompressed size of $file"
  # partx reads the backup GPT at the end of the image, so the probe file must have the real size;
  # it is sparse, so only the 2 MiB that hold the primary table costs space.
  prefix=$CACHE_DIR/.gpt.img
  truncate -s "$raw_size" "$prefix"
  # dd stops at 2 MiB, so zstd is killed by SIGPIPE; that is the normal end of a streamed read, not
  # a failure. Suspend pipefail so dd's own status is what the checks below see.
  set +o pipefail
  probe_rc=0
  zstd -dc "$file" | dd of="$prefix" bs=1M count=2 conv=notrunc status=none || probe_rc=$?
  set -o pipefail
  [ "$probe_rc" -eq 0 ] || die "cannot read the partition table from $file"
  parts=$(partx --show --output START,SECTORS,NAME --noheadings "$prefix" 2>/dev/null || true)
  rm -f "$prefix"
  entry=$(awk '$3=="rootfs_a" {print $1, $2}' <<<"$parts")
  esp_entry=$(awk '$3=="esp" {print $1, $2}' <<<"$parts")
  [ -n "$entry" ] || die "no rootfs_a partition in $file"
  [ -n "$esp_entry" ] || die "no esp partition in $file"
  read -r start sectors _ <<<"$entry"
  read -r esp_start esp_sectors _ <<<"$esp_entry"
  set +o pipefail
  write_rc=0
  zstd -dc "$file" | dd bs=1M skip=$((start * 512)) count=$((sectors * 512)) \
    iflag=skip_bytes,count_bytes,fullblock of="$target" conv=fsync status=none || write_rc=$?
  set -o pipefail
  [ "$write_rc" -eq 0 ] || die "writing $target failed"
  # The ESP is mostly empty; conv=sparse keeps only the files' clusters on /var.
  esp_img=$CACHE_DIR/.esp.img
  set +o pipefail
  esp_rc=0
  zstd -dc "$file" | dd bs=1M skip=$((esp_start * 512)) count=$((esp_sectors * 512)) \
    iflag=skip_bytes,count_bytes,fullblock of="$esp_img" conv=sparse status=none || esp_rc=$?
  set -o pipefail
  [ "$esp_rc" -eq 0 ] || die "cannot read the esp partition from $file"
  rm -f "$file"
else
  dd if="$file" of="$target" bs=4M conv=fsync status=none || die "writing $target failed"
  rm -f "$file"
  printf 'note: %s is not a GPT disk image; the ESP and kernel were not updated\n' "$name"
fi

# e2fsck -f on hash-verified bytes: -y so a non-interactive service never hangs on a prompt.
e2fsck -f -y "$target" || die "$target does not validate after the write; the boot entry was not changed"

# The kernel and initramfs live on the ESP, which both slots share: without this a release that
# changes the kernel would leave the device booting the old one. Only those two files are
# replaced, each atomically (temp name, fsync, rename, fsync); EFI/ and loader/ are never touched.
if [ -n "$esp_img" ]; then
  command -v mcopy >/dev/null 2>&1 || die "mcopy (mtools) is not installed; cannot update the ESP"
  mcopy -o -i "$esp_img" ::vmlinuz-linux "$TMP/vmlinuz-linux" ||
    die "no vmlinuz-linux in the artifact ESP"
  mcopy -o -i "$esp_img" ::initramfs-linux.img "$TMP/initramfs-linux.img" ||
    die "no initramfs-linux.img in the artifact ESP"
  rm -f "$esp_img"
  [ -d "$ESP_DIR" ] || die "$ESP_DIR is not mounted"
  # The temp copies coexist with the files they replace, so both must fit plus headroom.
  need=$(( $(stat -c %s "$TMP/vmlinuz-linux") + $(stat -c %s "$TMP/initramfs-linux.img") ))
  need=$((need + need / 10))
  avail=$(df -B1 --output=avail "$ESP_DIR" | tail -n1)
  [ "$avail" -ge "$need" ] || die "not enough free space on $ESP_DIR: $avail bytes available, need $need"
  # The old kernel is kept so a failed initramfs rename can put the pair back together.
  cp -f "$ESP_DIR/vmlinuz-linux" "$TMP/vmlinuz-linux.old" || die "cannot back up vmlinuz-linux"
  for f in vmlinuz-linux initramfs-linux.img; do
    install -m 0644 "$TMP/$f" "$ESP_DIR/.$f.new" || die "cannot stage $f on $ESP_DIR"
    sync -f "$ESP_DIR/.$f.new"
  done
  mv -f "$ESP_DIR/.vmlinuz-linux.new" "$ESP_DIR/vmlinuz-linux" || die "cannot replace vmlinuz-linux"
  sync -f "$ESP_DIR"
  if ! mv -f "$ESP_DIR/.initramfs-linux.img.new" "$ESP_DIR/initramfs-linux.img"; then
    mv -f "$TMP/vmlinuz-linux.old" "$ESP_DIR/vmlinuz-linux"
    sync -f "$ESP_DIR"
    die "cannot replace initramfs-linux.img; the old kernel was restored"
  fi
  sync -f "$ESP_DIR"
fi
"$SLOT_BIN" next "$inactive" || die "could not point the loader at slot $inactive"

msg="Emunix $version is staged on slot $inactive. Reboot to apply it."
printf '%s\n' "$msg"
printf '%s %s\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" "$msg" >>"$LOG_FILE" 2>/dev/null || true
# ES-DE has no external notification IPC (its popup queue is internal to the frontend), so the
# message also goes to the console and the update log; a real in-frontend popup needs an ES-DE patch.
printf '%s\n' "$msg" >/dev/tty1 2>/dev/null || true
printf 'emunix-os-updater: staged %s on slot %s (%s)\n' "$version" "$inactive" "$target"
