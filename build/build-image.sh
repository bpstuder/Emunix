#!/usr/bin/env bash
# M0 image build: pacstrap an Arch rootfs into an ext4 image.
# Requires: arch-install-scripts, e2fsprogs, squashfs-tools (optional)
set -euo pipefail

SUDO=""
if command -v sudo >/dev/null 2>&1; then SUDO="sudo"; fi

ARCH_SNAPSHOT="${ARCH_SNAPSHOT:-latest}"
WORK="${WORK:-$(pwd)/work}"
OUT="${OUT:-$(pwd)/out}"
ROOTFS_SIZE="${ROOTFS_SIZE:-8G}"

mkdir -p "$WORK" "$OUT"
ROOTFS_IMG="$OUT/rootfs.img"
rm -f "$ROOTFS_IMG"

# 1. create empty ext4 image
truncate -s "$ROOTFS_SIZE" "$ROOTFS_IMG"
mkfs.ext4 -L emunix-root "$ROOTFS_IMG"

# 2. mount + pacstrap
MNT="$WORK/mnt"
mkdir -p "$MNT"
$SUDO mount -o loop "$ROOTFS_IMG" "$MNT"
trap '$SUDO umount "$MNT" 2>/dev/null || true' EXIT

PKGS=$(cat profiles/base.txt profiles/handheld-common.txt | sed 's/#.*//' | grep -v '^[[:space:]]*$' | tr '\n' ' ')
$SUDO pacstrap -c "$MNT" $PKGS

# 3. copy configs
$SUDO cp -a configs/fstab "$MNT/etc/fstab" 2>/dev/null || true

echo "Built $ROOTFS_IMG"
echo "Next: build boot.tar.zst (kernel+initramfs) from $MNT/boot"
