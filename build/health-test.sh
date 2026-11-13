#!/usr/bin/env bash
# Prove the boot health check on real boots. Slot b is given the kind of broken /etc/fstab a bad
# image can ship -- a mount line whose filesystem type cannot work -- so its boots die at
# local-fs.target and never reach multi-user.target:
#   boot 1 records attempt 1 and lands in emergency mode;
#   boot 2 records attempt 2, emunix-boot-health fails, and the rollback clears the counter, points
#   the loader back at slot a, marks b bad and reboots;
#   boot 3 comes up on slot a with /etc/emunix-version unchanged, and the counter clears after a
#   normal boot -- so a good boot does not roll back, and the rollback cannot loop.
#
# Requires root (loop mount), qemu-system-x86, edk2-ovmf, expect, socat, gptfdisk, e2fsprogs.
# Usage: health-test.sh <emunix.img> [evidence-dir]
set -euo pipefail
IMG=${1:?usage: health-test.sh <emunix.img> [evidence-dir]}
OUT=${2:-$(dirname "$0")/../evidence}
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "health-test.sh must run as root (loop mount)" >&2; exit 1; }
OVMF=/usr/share/edk2/x64
[ -f "$OVMF/OVMF_CODE.4m.fd" ] || { echo "edk2-ovmf is not installed ($OVMF)" >&2; exit 1; }
command -v expect socat >/dev/null || { echo "expect and socat are required" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-loop.sh
. "$SCRIPT_DIR/lib-loop.sh"

mkdir -p "$OUT"
LOG=$OUT/m2-health.log
WORK=$(mktemp -d)
DISK=$WORK/disk.img
LOOP=
ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
SOCK=$WORK/qmp.sock
cleanup() {
  pkill -f "[q]emu-system-x86_64" 2>/dev/null || true
  umount -R -l "$WORK" 2>/dev/null || true
  losetup -d "$LOOP" 2>/dev/null || true
  for m in "$WORK/a" "$WORK/b" "$WORK/esp" "$WORK/var"; do rmdir "$m" 2>/dev/null || true; done
  # Never let rm -rf recurse into a partition that is still mounted: it would delete the
  # filesystem inside.
  if ! mountpoint -q "$WORK/a" 2>/dev/null && ! mountpoint -q "$WORK/b" 2>/dev/null &&
     ! mountpoint -q "$WORK/esp" 2>/dev/null && ! mountpoint -q "$WORK/var" 2>/dev/null; then
    rm -rf "$WORK"
  else
    printf 'warning: %s is still mounted; leaving it in place\n' "$WORK" >&2
  fi
}
trap cleanup EXIT
: >"$LOG"
echo "image $IMG, accel $ACCEL" | tee -a "$LOG"

# --- the disk under test: slot b is a copy of the good slot, with a broken fstab ------------
cp --sparse=always "$IMG" "$DISK"
LOOP=$(attach_image "$DISK")
mkdir -p "$WORK/a" "$WORK/b" "$WORK/esp" "$WORK/var"
mount "${LOOP}p2" "$WORK/a"
mount "${LOOP}p3" "$WORK/b"
cp -a "$WORK/a/." "$WORK/b/"
V1=$(cat "$WORK/a/etc/emunix-version")
# A wrong filesystem type fails immediately, so the boot does not sit through a device timeout;
# /var and /boot keep working, which is what lets the counter and the loader be updated.
printf 'PARTLABEL=home /mnt/nosuch ext4 defaults 0 2\n' >>"$WORK/b/etc/fstab"
mount "${LOOP}p4" "$WORK/var"
mkdir -p "$WORK/var/lib/emunix"
: >"$WORK/var/lib/emunix/initialized"   # firstboot (card 05) is not under test here
umount "$WORK/var"
mount "${LOOP}p1" "$WORK/esp"
printf 'default emunix-b.conf\ntimeout 3\n' >"$WORK/esp/loader/loader.conf"
umount "$WORK/esp"
umount "$WORK/a" "$WORK/b"
cp "$OVMF/OVMF_VARS.4m.fd" "$WORK/OVMF_VARS.fd"
losetup -d "$LOOP"
LOOP=

# --- one QEMU boot per mode -----------------------------------------------------------------
cat >"$WORK/boot.exp" <<'EXPECT'
set img   [lindex $argv 0]
set log   [lindex $argv 1]
set code  [lindex $argv 2]
set vars  [lindex $argv 3]
set accel [lindex $argv 4]
set sock  [lindex $argv 5]
set cmds  [lindex $argv 6]
set tag   [lindex $argv 7]
set mode  [lindex $argv 8]
set timeout 420
log_file -a $log
proc qmp {json} {
  global sock
  catch {exec socat -t 2 - UNIX-CONNECT:$sock << "{\"execute\":\"qmp_capabilities\"}\n$json\n"}
}
spawn qemu-system-x86_64 -machine q35 -accel $accel -m 3072 -smp 4 -vga none \
  -device bochs-display -display none \
  -qmp unix:$sock,server,nowait \
  -drive if=pflash,format=raw,readonly=on,file=$code \
  -drive if=pflash,format=raw,file=$vars \
  -drive file=$img,format=raw,if=virtio -no-reboot \
  -serial stdio
if {$mode eq "emergency"} {
  expect {
    -re {You are in emergency mode|Give root password|Maintenance mode} {}
    -re {Bailing out|Kernel panic|No bootable device} { puts stderr "panic before userspace"; exit 1 }
    timeout { puts stderr "the broken boot never reached emergency mode"; exit 1 }
  }
  # A guest stuck in emergency mode can ignore the ACPI power button, so ask it and then make
  # sure: the counter was flushed by emunix-health, so ending QEMU loses nothing.
  after 2000
  qmp "{\"execute\":\"system_powerdown\"}"
  after 3000
  qmp "{\"execute\":\"quit\"}"
  expect { eof {} timeout { puts stderr "QEMU did not exit"; exit 1 } }
  exit 0
}
if {$mode eq "reboot"} {
  expect {
    -re {slot .* did not boot; the loader now defaults to slot} {}
    -re {Bailing out|Kernel panic} { puts stderr "panic before the rollback"; exit 1 }
    -re {You are in emergency mode|Give root password} {
      puts stderr "the rollback did not happen: the boot went to emergency mode"; exit 1 }
    -re {login: } { puts stderr "the rollback did not happen: a login prompt appeared"; exit 1 }
    eof {}
    timeout { puts stderr "the guest did not reboot itself"; exit 1 }
  }
  expect { eof {} timeout { puts stderr "the guest did not exit after the reboot"; exit 1 } }
  exit 0
}
# shell: the healthy boot, where the loader and the counter must stay alone
expect {
  -re {login: } { send "retrogamer\r" }
  -re {Bailing out|Kernel panic|No bootable device} { puts stderr "boot failed before userspace"; exit 1 }
  timeout { puts stderr "no login prompt"; exit 1 }
}
expect -re {[Pp]assword: }
send "retrogamer\r"
expect {
  -re {\[retrogamer@[^]]*\]\$} {}
  -re {Login incorrect} { puts stderr "the shipped password was rejected"; exit 1 }
  timeout { puts stderr "no shell after login"; exit 1 }
}
send "sudo -v\r"
expect -re {[Pp]assword for [^:\r\n]*: |[Pp]assword: }
send "retrogamer\r"
expect -re {\[retrogamer@[^]]*\]\$}
set f [open $cmds]
set line [read $f]
close $f
send "$line\r"
expect {
  -re {[Pp]assword for [^:\r\n]*: } { send "retrogamer\r"; exp_continue }
  -re $tag {}
  timeout { puts stderr "the commands did not finish"; exit 1 }
}
after 2000
qmp "{\"execute\":\"system_powerdown\"}"
expect { eof {} timeout { puts stderr "the VM did not power off"; exit 1 } }
exit 0
EXPECT

boot() { # <mode> <cmds file> <end marker>
  set +e
  expect "$WORK/boot.exp" "$DISK" "$LOG" "$OVMF/OVMF_CODE.4m.fd" "$WORK/OVMF_VARS.fd" \
    "$ACCEL" "$SOCK" "$2" "$3" "$1"
  local rc=$?
  set -e
  rm -f "$SOCK"
  [ "$rc" -eq 0 ] || { echo "FAIL: boot '$1' did not finish (expect rc=$rc)" >&2; echo "transcript: $LOG" >&2; exit 1; }
}

# The state straight off the disk after a boot: the counter, the bad marker, the loader default
# and the diagnostic log the card asks for. This is what a returned device is diagnosed from.
state() { # <label>
  LOOP=$(attach_image "$DISK")
  mkdir -p "$WORK/esp" "$WORK/var"
  mount -o ro "${LOOP}p1" "$WORK/esp"
  mount -o ro "${LOOP}p4" "$WORK/var"
  {
    echo "$1 counter: $(cat "$WORK/var/lib/emunix/boot-attempts" 2>/dev/null || echo missing)"
    echo "$1 bad: $(cat "$WORK/var/lib/emunix/bad" 2>/dev/null || echo none)"
    echo "$1 loader: $(tr '\n' ' ' <"$WORK/esp/loader/loader.conf")"
    echo "$1 update log:"
    tail -n 6 "$WORK/var/log/emunix-update.log" 2>/dev/null || echo "(no update log)"
  } | tee -a "$LOG"
  umount "$WORK/esp" "$WORK/var"
  losetup -d "$LOOP"
  LOOP=
}

# --- boot 1: the broken slot, first unfinished attempt --------------------------------------
echo "=== boot 1: the broken slot, attempt 1" | tee -a "$LOG"
boot emergency "" ""
state AFTER-BOOT1

# --- boot 2: the broken slot, second unfinished attempt -> automatic rollback ---------------
echo "=== boot 2: the broken slot, attempt 2, rollback" | tee -a "$LOG"
boot reboot "" ""
state AFTER-BOOT2

# --- boot 3: the previous slot, healthy, no further rollback --------------------------------
echo "=== boot 3: slot a, healthy" | tee -a "$LOG"
cat >"$WORK/t3" <<'EOF'
echo "ROOT-B3: $(grep -o 'root=[^ ]*' /proc/cmdline)"
echo "VERSION-B3: $(cat /etc/emunix-version)"
echo "STATUS-B3: $(sudo emunix-slot status | tr '\n' ' ')"
echo "COUNTER-B3: $(cat /var/lib/emunix/boot-attempts)"
sleep 40
echo "COUNTER-CLEARED-B3: $(cat /var/lib/emunix/boot-attempts)"
echo "DEFAULT-B3: $(sudo sed -n 's/^default[[:space:]][[:space:]]*//p' /boot/loader/loader.conf)"
echo UPDATELOG-B3:
sudo tail -n 8 /var/log/emunix-update.log
echo HEALTH-B3-""END
EOF
tr '\n' ';' <"$WORK/t3" | sed 's/;$//' >"$WORK/cmds3"
boot shell "$WORK/cmds3" "HEALTH-B3-END"
state AFTER-BOOT3

# --- the claims, read back out of the transcript and the disk state --------------------------
fail() { echo "FAIL: $*" >&2; echo "transcript: $LOG" >&2; exit 1; }
grep -aq 'You are in emergency mode' "$LOG" || fail "boot 1 did not land in emergency mode"
grep -aq 'AFTER-BOOT1 counter: 1' "$LOG" || fail "boot 1 did not record attempt 1"
grep -aq 'AFTER-BOOT1 loader: default emunix-b.conf' "$LOG" ||
  fail "boot 1 rolled back: the loader moved on the first unfinished attempt"
grep -aq 'AFTER-BOOT1 bad: none' "$LOG" || fail "boot 1 marked a slot bad"

grep -aq 'AFTER-BOOT2 counter: 0' "$LOG" || fail "boot 2 left the attempt counter at 2"
grep -aq 'AFTER-BOOT2 bad: b' "$LOG" || fail "boot 2 did not mark slot b bad"
grep -aq 'AFTER-BOOT2 loader: default emunix-a.conf' "$LOG" ||
  fail "boot 2 did not point the loader back at slot a"
grep -aq 'did not boot; default is emunix-a.conf' "$LOG" ||
  fail "the rollback was not logged to /var/log/emunix-update.log"
grep -aq 'reboot requested' "$LOG" ||
  fail "the rollback did not finish requesting the reboot"

grep -aq 'ROOT-B3: root=PARTLABEL=rootfs_a' "$LOG" || fail "boot 3 did not come up on slot a"
grep -aq "VERSION-B3: $V1" "$LOG" || fail "boot 3 changed /etc/emunix-version"
grep -aq 'STATUS-B3: active: a default: emunix-a.conf' "$LOG" ||
  fail "boot 3 did not report slot a as the active slot and default"
grep -aq 'bad: b' "$LOG" || fail "boot 3 lost the bad marker"
grep -aq 'COUNTER-B3: 1' "$LOG" || fail "boot 3 did not start from a cleared counter"
grep -aq 'COUNTER-CLEARED-B3: 0' "$LOG" || fail "a healthy boot did not clear the counter"
grep -aq 'DEFAULT-B3: emunix-a.conf' "$LOG" || fail "a healthy boot changed the loader default"
# A third rollback would have flipped the loader again and marked slot a bad; neither happened.
grep -aq 'AFTER-BOOT3 loader: default emunix-a.conf' "$LOG" ||
  fail "a healthy boot rolled back: the loader moved again"
grep -aq 'AFTER-BOOT3 bad: b' "$LOG" || fail "a healthy boot rolled back: the wrong slot is marked bad"
grep -aq 'AFTER-BOOT3 counter: 0' "$LOG" || fail "the counter was not clear after the healthy boot"

echo "emunix boot health: two failed boots roll back to the other slot, a normal boot does not"
echo "transcript: $LOG"
