#!/usr/bin/env bash
# Attach a disk image as a loop device with its partitions. Inside the build container there is
# no udev, so the /dev nodes for the partitions are created from sysfs. Requires root.
attach_image() { # <image> -> prints the loop device
  local img=$1 loop part dev maj min
  loop=$(losetup --find --show -P "$img")
  for part in /sys/class/block/"${loop#/dev/}"p*; do
    [ -e "$part" ] || continue
    dev=/dev/$(basename "$part")
    maj=$(cut -d: -f1 "$part/dev")
    min=$(cut -d: -f2 "$part/dev")
    # A node left over from an earlier loop device that had the same name carries the wrong
    # device number, and mounting it fails with "Can't open blockdev": recreate it unless it
    # already points at this partition.
    if [ "$(stat -c %t:%T "$dev" 2>/dev/null)" != "$(printf '%x:%x' "$maj" "$min")" ]; then
      rm -f "$dev"
      mknod "$dev" b "$maj" "$min"
    fi
  done
  echo "$loop"
}
