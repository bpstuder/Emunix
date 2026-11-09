#!/usr/bin/env bash
# Assert the built rootfs is what the build claims. Reads the ext4 image with debugfs,
# so it works without loop devices or root. Extend the list as the build grows.
set -euo pipefail
IMG=${1:?usage: verify-image.sh <rootfs.img>}
[ -f "$IMG" ] || { echo "FAIL: $IMG does not exist" >&2; exit 1; }

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
expect_file() { # <path in image>
  debugfs -R "stat $1" "$IMG" 2>/dev/null | grep -q 'Inode:' || fail "$1 missing from $IMG"
}

expect_file /boot/vmlinuz-linux
expect_file /boot/initramfs-linux.img
expect_file /etc/fstab
expect_file /usr/bin/retroarch

echo "verified $IMG: kernel, initramfs, fstab, retroarch"
