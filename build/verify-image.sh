#!/usr/bin/env bash
# Assert a built Emunix disk image is what the build claims: GPT labels, systemd-boot on the
# ESP, the generated fstab, the user and machine-id. Needs root (loop device, mounts).
set -euo pipefail
IMG=${1:?usage: verify-image.sh <emunix.img>}
[ -f "$IMG" ] || { echo "FAIL: $IMG does not exist" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "FAIL: verify-image.sh must run as root (loop devices, mounts)" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-loop.sh
. "$SCRIPT_DIR/lib-loop.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
LOOP=$(attach_image "$IMG")
MNT=$(mktemp -d)
cleanup() {
  set +e
  umount -R "$MNT" 2>/dev/null
  losetup -d "$LOOP" 2>/dev/null
  rmdir "$MNT"
}
trap cleanup EXIT

# 1. Partition table.
for spec in 1:esp 2:rootfs_a 3:rootfs_b 4:var 5:home; do
  sgdisk --info="${spec%%:*}" "$IMG" | grep -q "Partition name: '${spec#*:}'" ||
    fail "partition ${spec%%:*} is not labelled ${spec#*:}"
done

# 2. ESP: bootloader, entries, kernel, initramfs.
mount -o ro "${LOOP}p1" "$MNT"
for f in EFI/systemd/systemd-bootx64.efi loader/loader.conf vmlinuz-linux initramfs-linux.img \
  loader/entries/emunix-a.conf loader/entries/emunix-b.conf; do
  [ -f "$MNT/$f" ] || fail "/$f missing from the ESP"
done
grep -q '^default emunix-a\.conf$' "$MNT/loader/loader.conf" || fail "loader.conf does not default to emunix-a.conf"
for slot in a b; do
  grep -q "root=PARTLABEL=rootfs_$slot ro" "$MNT/loader/entries/emunix-$slot.conf" ||
    fail "emunix-$slot.conf does not boot rootfs_$slot read-only"
done
umount "$MNT"

# 3. rootfs_a: the generated fstab, the user, machine-id, the frontend.
mount -o ro "${LOOP}p2" "$MNT"
for f in etc/fstab etc/machine-id etc/emunix-version etc/hostname usr/bin/retroarch \
  etc/sudoers.d/10-wheel etc/systemd/system/multi-user.target.wants/NetworkManager.service; do
  # -L too: the enabled unit is a symlink to an absolute path in the image, not in this host.
  [ -e "$MNT/$f" ] || [ -L "$MNT/$f" ] || fail "/$f missing from rootfs_a"
done
grep -q '^PARTLABEL=rootfs_a / *ext4 *ro' "$MNT/etc/fstab" || fail "fstab has no read-only rootfs_a root"
grep -q '^PARTLABEL=home .* /storage ' "$MNT/etc/fstab" || fail "fstab has no /storage subvolume"
grep -q '^retrogamer:' "$MNT/etc/passwd" || fail "user retrogamer missing"
grep -q '^wheel:.*retrogamer' "$MNT/etc/group" || fail "retrogamer is not in wheel"
[ -s "$MNT/etc/machine-id" ] || fail "machine-id is empty"
[ "$(readlink "$MNT/etc/systemd/system/default.target")" = /usr/lib/systemd/system/multi-user.target ] ||
  fail "default target is not multi-user.target"
umount "$MNT"

# 4. home: the user's directory and the /storage subvolume live on their own partition.
mount -o ro "${LOOP}p5" "$MNT"
[ -d "$MNT/retrogamer" ] || fail "/home/retrogamer missing from the home partition"
[ -d "$MNT/storage" ] || fail "/storage btrfs subvolume missing"

echo "verified $IMG: 5 labels, systemd-boot + 2 entries, kernel/initramfs, fstab + mounts, retrogamer, machine-id"
