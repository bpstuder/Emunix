#!/usr/bin/env bash
# Attach a disk image as a loop device with its partitions. Inside the build container there is
# no udev, so the /dev nodes for the partitions are created from sysfs. Requires root.
attach_image() { # <image> -> prints the loop device
  local img=$1 loop part dev
  loop=$(losetup --find --show -P "$img")
  for part in /sys/class/block/"${loop#/dev/}"p*; do
    [ -e "$part" ] || continue
    dev=/dev/$(basename "$part")
    [ -e "$dev" ] || mknod "$dev" b "$(cut -d: -f1 "$part/dev")" "$(cut -d: -f2 "$part/dev")"
  done
  echo "$loop"
}
