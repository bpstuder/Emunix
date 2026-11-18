#!/usr/bin/env bash
# emunix-install's decision logic, without disks: what it refuses, and what it writes when it goes
# through. Every privileged command is a stub on PATH, and mount/umount work on fixture trees, so a
# full run can be checked right down to the loader entries and the first-boot marker.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
INSTALL=$HERE/../configs/rootfs/usr/local/bin/emunix-install
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

CALLS=$TMP/calls
FIXTURES=$TMP/fixtures

# --- stubs -----------------------------------------------------------------------------------
record() { printf '#!/bin/sh\necho "%s $*" >>"%s"\n' "$1" "$CALLS" >"$TMP/$1"; chmod +x "$TMP/$1"; }
record dd
record sgdisk
record udevadm
# systemd-ac-power is the updater unit's ConditionACPower as a command.
cat >"$TMP/systemd-ac-power" <<'EOF'
#!/bin/sh
exit "${AC_POWER:-0}"
EOF
chmod +x "$TMP/systemd-ac-power"
# blockdev also answers --getsize64 with the target's size.
cat >"$TMP/blockdev" <<EOF
#!/bin/sh
echo "blockdev \$*" >>"$CALLS"
case \$* in --getsize64*) echo \${TARGET_BYTES:-21474836480} ;; esac
exit 0
EOF
chmod +x "$TMP/blockdev"

# The source is /dev/vda (13.5 GiB image, partitions up to sector 28311519) and the target /dev/vdb
# (20 GiB, empty). Values match the release image's own geometry.
cat >"$TMP/findmnt" <<'EOF'
#!/bin/sh
case "$*" in *SOURCE*) echo "/dev/vda2" ;; esac
EOF
cat >"$TMP/sfdisk" <<'EOF'
#!/bin/sh
echo "label: gpt"
echo "/dev/vda1 : start=        2048, size=     1048576, type=C12A7328-F81F-11D2-BA4B-00A0C93EC93B, uuid=OLD-ESP, name=\"esp\""
echo "/dev/vda2 : start=     1050624, size=    10485760, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=OLD-A, name=\"rootfs_a\""
echo "/dev/vda3 : start=    11536384, size=    10485760, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=OLD-B, name=\"rootfs_b\""
echo "/dev/vda4 : start=    22022144, size=     4194304, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=OLD-VAR, name=\"var\""
echo "/dev/vda5 : start=    26216448, size=     2095071, type=0FC63DAF-8483-4772-8E79-3D69D8477DE4, uuid=OLD-HOME, name=\"home\""
EOF
cat >"$TMP/lsblk" <<'EOF'
#!/bin/sh
# The script only ever asks these four shapes: <cols> <device>, and the disk list.
cols=$2
dev=${3:-}
case $cols in
  NAME,TYPE) printf 'vda disk\nvdb disk\nsr0 rom\n'; exit 0 ;;
  TYPE) case $dev in /dev/vda|/dev/vdb) echo disk ;; /dev/vd[ab][0-9]) echo part ;; *) exit 1 ;; esac ;;
  pkname) case $dev in /dev/vda2|/dev/vda[0-9]) echo vda ;; /dev/vdb[0-9]) echo vdb ;; *) exit 1 ;; esac ;;
  MAJ:MIN) case $dev in /dev/vda) echo 252:0 ;; /dev/vdb) echo 252:16 ;; *) exit 1 ;; esac ;;
  MODEL) echo "QEMU HARDDISK" ;;
  SIZE) case $dev in /dev/vda) echo 13.5G ;; /dev/vdb) echo 20G ;; *) echo 0G ;; esac ;;
  MOUNTPOINT)
    # One line per partition; a mounted target is what the caller must refuse.
    echo; echo
    [ "${STUB_MOUNTED:-}" = 1 ] && echo /mnt/data
    echo; echo; exit 0
    ;;
  PATH,PARTLABEL)
    printf '/dev/vdb1 esp\n/dev/vdb2 rootfs_a\n/dev/vdb3 rootfs_b\n/dev/vdb4 var\n/dev/vdb5 home\n'; exit 0
    ;;
  PARTUUID) case $dev in
      /dev/vdb1) echo NEW-ESP ;;
      /dev/vdb2) echo NEW-ROOTFS-A ;;
      /dev/vdb3) echo NEW-ROOTFS-B ;;
      /dev/vdb4) echo NEW-VAR ;;
      /dev/vdb5) echo NEW-HOME ;;
      *) exit 1 ;;
    esac ;;
  *) exit 1 ;;
esac
exit 0
EOF
cat >"$TMP/mount" <<EOF
#!/bin/sh
# mount <device> <dir>: copy the fixture tree for that device in, and remember which one it was.
echo "mount \$*" >>"$CALLS"
cp -a "$FIXTURES/\$(basename "\$1")/." "\$2/" || exit 1
basename "\$1" >"\$2/.fixture"
EOF
cat >"$TMP/umount" <<EOF
#!/bin/sh
# umount <dir>: replace the fixture tree with what the mountpoint now holds, the way a real mount
# would carry the edits (including a deletion).
echo "umount \$*" >>"$CALLS"
name=\$(cat "\$1/.fixture") || exit 1
rm -f "\$1/.fixture"
rm -rf "$FIXTURES/\$name"
mkdir -p "$FIXTURES/\$name"
cp -a "\$1/." "$FIXTURES/\$name/"
EOF
chmod +x "$TMP/findmnt" "$TMP/sfdisk" "$TMP/lsblk" "$TMP/mount" "$TMP/umount"

fresh() { # an empty transcript and the target's two filesystems as a fresh copy of the image
  : >"$CALLS"
  rm -rf "$FIXTURES"
  mkdir -p "$FIXTURES/vdb1/loader/entries" "$FIXTURES/vdb4/lib/emunix"
  for slot in a b; do
    printf 'title   Emunix (slot %s)\nlinux   /vmlinuz-linux\ninitrd  /initramfs-linux.img\noptions root=PARTLABEL=rootfs_%s ro rootfstype=ext4 quiet\n' \
      "$slot" "$slot" >"$FIXTURES/vdb1/loader/entries/emunix-$slot.conf"
  done
  : >"$FIXTURES/vdb4/lib/emunix/initialized"
}

run() { # <stdin> <args...> -> the installer's exit status, with output in $TMP/out
  local stdin=$1
  shift
  set +e
  PATH="$TMP:$PATH" "$INSTALL" "$@" <"$stdin" >"$TMP/out" 2>&1
  local rc=$?
  set -e
  echo "$rc"
}

# 1. The whole flow: copy to the end of the last partition, new GUIDs, entries on the target's
#    PARTUUIDs, and the first-boot marker gone so the target grows home itself.
fresh
[ "$(run /dev/null --target /dev/vdb --yes)" = 0 ] || { cat "$TMP/out"; fail "a --yes install should succeed"; }
grep -qx 'dd if=/dev/vda of=/dev/vdb bs=4M count=3456 conv=fsync status=progress' "$CALLS" ||
  { cat "$CALLS"; fail "dd did not copy the image up to its last partition"; }
grep -qx 'sgdisk -e -G /dev/vdb' "$CALLS" || fail "the GPT was not moved and the GUIDs not regenerated"
grep -qx 'blockdev --rereadpt /dev/vdb' "$CALLS" || fail "the target's partition table was not re-read"
grep -q "mount /dev/vdb1 " "$CALLS" || fail "the target's ESP was never mounted"
grep -q "mount /dev/vdb4 " "$CALLS" || fail "the target's /var was never mounted"
grep -q 'root=PARTUUID=NEW-ROOTFS-A ro' "$FIXTURES/vdb1/loader/entries/emunix-a.conf" ||
  fail "slot a's entry does not use the target's PARTUUID"
grep -q 'root=PARTUUID=NEW-ROOTFS-B ro' "$FIXTURES/vdb1/loader/entries/emunix-b.conf" ||
  fail "slot b's entry does not use the target's PARTUUID"
[ ! -e "$FIXTURES/vdb4/lib/emunix/initialized" ] ||
  fail "the target would skip its first boot and never grow home"
grep -q '14495497728 bytes' "$TMP/out" || { cat "$TMP/out"; fail "the plan does not state the bytes written"; }
grep -q 'power off, remove the USB stick' "$TMP/out" || fail "the closing instruction is missing"

# 2. The stick we are running from is never a target.
fresh
rc=$(run /dev/null --target /dev/vda --yes)
[ "$rc" != 0 ] || fail "the running disk was accepted as a target"
grep -q 'the disk we are running from' "$TMP/out" || { cat "$TMP/out"; fail "the refusal does not say why"; }
if grep -q '^dd ' "$CALLS"; then fail "something was written before the refusal"; fi

# 3. A target with a mounted partition is refused.
fresh
rc=$(STUB_MOUNTED=1 run /dev/null --target /dev/vdb --yes)
[ "$rc" != 0 ] || fail "a target with a mounted partition was accepted"
grep -q 'has a mounted partition' "$TMP/out" || { cat "$TMP/out"; fail "the mounted-target refusal is missing"; }
if grep -q '^dd ' "$CALLS"; then fail "something was written to a mounted target"; fi

# 4. A target smaller than the image is refused.
fresh
rc=$(TARGET_BYTES=8000000000 run /dev/null --target /dev/vdb --yes)
[ "$rc" != 0 ] || fail "an 8 GB target was accepted for a 13.5 GiB image"
grep -q 'the image needs 14495497728' "$TMP/out" || { cat "$TMP/out"; fail "the size refusal is missing"; }

# 5. On battery: the same rule the updater's unit carries.
fresh
rc=$(AC_POWER=1 run /dev/null --target /dev/vdb --yes)
[ "$rc" != 0 ] || fail "an install on battery was accepted"
grep -q 'on battery power' "$TMP/out" || { cat "$TMP/out"; fail "the battery refusal is missing"; }

# 6. No terminal, no --yes: the plan is printed, nothing is written. This is the ES-DE entry's path,
#    and the one other disk is found without --target.
fresh
rc=$(run /dev/null)
[ "$rc" != 0 ] || fail "an install with no console to confirm on was accepted"
grep -q 'target  /dev/vdb (QEMU HARDDISK, 20G)' "$TMP/out" ||
  { cat "$TMP/out"; fail "the other disk was not picked as the target"; }
grep -q 'no console to confirm on' "$TMP/out" || { cat "$TMP/out"; fail "the no-console refusal is missing"; }
if grep -q '^dd ' "$CALLS"; then fail "something was written without a confirmation"; fi

# 7. On a console, anything but "yes" aborts. script(1) gives the installer a real terminal.
if command -v script >/dev/null; then
  fresh
  set +e
  printf 'no\n' | PATH="$TMP:$PATH" script -qec "$INSTALL --target /dev/vdb" /dev/null >"$TMP/out" 2>&1
  rc=$?
  set -e
  [ "$rc" != 0 ] || { cat "$TMP/out"; fail "a 'no' at the prompt installed anyway"; }
  grep -q 'aborted' "$TMP/out" || { cat "$TMP/out"; fail "the abort is not reported"; }
  if grep -q '^dd ' "$CALLS"; then fail "something was written after a 'no'"; fi
  # ... and "yes" installs, so the prompt is not a dead end.
  fresh
  set +e
  printf 'yes\n' | PATH="$TMP:$PATH" script -qec "$INSTALL --target /dev/vdb" /dev/null >"$TMP/out" 2>&1
  rc=$?
  set -e
  [ "$rc" = 0 ] || { cat "$TMP/out"; fail "a 'yes' at the prompt did not install"; }
  grep -q '^dd if=/dev/vda of=/dev/vdb' "$CALLS" || fail "a 'yes' at the prompt did not copy"
else
  echo "note: script(1) is not installed, the prompt path is untested"
fi

echo "install: refusals (own disk, mounted, too small, battery, no console) and a full --yes run OK"
