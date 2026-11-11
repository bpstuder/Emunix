#!/usr/bin/env bash
# Prove emunix-slot on a real boot: `next b` survives the reboot and shows up in the kernel
# cmdline, `once a` boots slot a for exactly one boot, and the boot after that follows the
# default again. The image ships rootfs_b empty, so the slot switch copies rootfs_a into it
# first: that is what an A/B update does to the inactive slot.
# Requires root (loop mount), qemu-system-x86, edk2-ovmf, expect, socat, gptfdisk.
# Usage: slot-test.sh <emunix.img> [evidence-dir]
set -euo pipefail
IMG=${1:?usage: slot-test.sh <emunix.img> [evidence-dir]}
OUT=${2:-$(dirname "$0")/../evidence}
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "slot-test.sh must run as root (loop mount)" >&2; exit 1; }
OVMF=/usr/share/edk2/x64
[ -f "$OVMF/OVMF_CODE.4m.fd" ] || { echo "edk2-ovmf is not installed ($OVMF)" >&2; exit 1; }
command -v expect socat >/dev/null || { echo "expect and socat are required" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-loop.sh
. "$SCRIPT_DIR/lib-loop.sh"

mkdir -p "$OUT"
LOG=$OUT/m1-slot.log
WORK=$(mktemp -d)
DISK=$WORK/disk.img
ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
SOCK=$WORK/qmp.sock
trap 'pkill -f "[q]emu-system-x86_64" 2>/dev/null || true; umount -R "$WORK" 2>/dev/null || true; rm -rf "$WORK"' EXIT
: >"$LOG"
echo "image $IMG, accel $ACCEL" | tee -a "$LOG"

cp --sparse=always "$IMG" "$DISK"
cp "$OVMF/OVMF_VARS.4m.fd" "$WORK/OVMF_VARS.fd"

# firstboot (card 05) replaces the shipped password and grows the disk; this test needs neither,
# so the copy is marked initialized and the shipped password keeps working. rootfs_b gets a copy
# of rootfs_a, which is the state after an update has written the inactive slot.
MNT=$WORK/mnt
mkdir -p "$MNT" "$WORK/a" "$WORK/b" "$WORK/esp"
LOOP=$(attach_image "$DISK")
mount "${LOOP}p4" "$MNT"
mkdir -p "$MNT/lib/emunix"
: >"$MNT/lib/emunix/initialized"
umount "$MNT"
mount "${LOOP}p2" "$WORK/a"
mount "${LOOP}p3" "$WORK/b"
cp -a "$WORK/a/." "$WORK/b/"
umount "$WORK/a" "$WORK/b"
# The default is slot a, whichever way the image left it.
mount "${LOOP}p1" "$WORK/esp"
printf 'default emunix-a.conf\ntimeout 3\n' >"$WORK/esp/loader/loader.conf"
umount "$WORK/esp"
losetup -d "$LOOP"

# One QEMU boot: log in, validate sudo once, run the command line from a file, wait for its end
# marker, power the VM down. The commands come from a file so Tcl never sees a quote.
cat >"$WORK/boot.exp" <<'EXPECT'
set img   [lindex $argv 0]
set log   [lindex $argv 1]
set code  [lindex $argv 2]
set vars  [lindex $argv 3]
set accel [lindex $argv 4]
set sock  [lindex $argv 5]
set cmds  [lindex $argv 6]
set tag   [lindex $argv 7]
set timeout 900
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
expect {
  -re {login: } { send "retrogamer\r" }
  -re {Bailing out|Kernel panic|No bootable device} { puts stderr "boot failed before userspace"; exit 1 }
  timeout { puts stderr "no login prompt"; exit 1 }
}
expect -re {[Pp]assword: }
send "retrogamer\r"
expect {
  -re {\[retrogamer@[^]]*\]\$ } {}
  -re {Login incorrect} { puts stderr "the shipped password was rejected"; exit 1 }
  timeout { puts stderr "no shell after login"; exit 1 }
}
send "sudo -v\r"
# sudo prompts "password for <user>:" (not just "Password:") on the first use in a boot.
expect -re {[Pp]assword for [^:\r\n]*: |[Pp]assword: }
send "retrogamer\r"
expect -re {\[retrogamer@[^]]*\]\$ }
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
expect {
  eof {}
  timeout { puts stderr "the VM did not power off"; exit 1 }
}
exit 0
EXPECT

boot() { # <name> <cmds file> <end marker>
  echo "=== $1" | tee -a "$LOG"
  set +e
  expect "$WORK/boot.exp" "$DISK" "$LOG" "$OVMF/OVMF_CODE.4m.fd" "$WORK/OVMF_VARS.fd" \
    "$ACCEL" "$SOCK" "$2" "$3"
  local rc=$?
  set -e
  rm -f "$SOCK"
  [ "$rc" -eq 0 ] || { echo "FAIL: $1 did not finish (expect rc=$rc)" >&2; echo "transcript: $LOG" >&2; exit 1; }
}

# One short line per fact, each tagged with its boot: the serial transcript carries ANSI escapes
# and long lines, so every claim is a short unique substring, never an anchored line.
boot_probe() { # <boot> -> the shell that prints the root, status' three fields and the slot file
  # shellcheck disable=SC2016 # the $(...) must reach the guest's shell unexpanded
  printf 'echo "ROOT-%s: $(grep -o "root=[^ ]*" /proc/cmdline)"; sudo emunix-slot status >/tmp/slot-status; echo "ACTIVE-%s: $(sed -n "s/^active: //p" /tmp/slot-status)"; echo "DEFAULT-%s: $(sed -n "s/^default: //p" /tmp/slot-status)"; echo "ONESHOT-%s: $(sed -n "s/^oneshot: //p" /tmp/slot-status)"; echo "SLOTFILE-%s: $(cat /run/emunix/active_slot)";' \
    "$1" "$1" "$1" "$1" "$1"
}

# --- Boot 1: slot a is running and default; `next b` rewrites loader.conf.
cat >"$WORK/cmds1" <<EOF
$(boot_probe BOOT1) echo "NEXT-BOOT1: \$(sudo emunix-slot next b 2>&1)"; echo "LOADER-CONF-BOOT1: \$(sudo cat /boot/loader/loader.conf | tr '\\n' ' ')"; echo SLOT-BOOT1-END
EOF
boot "boot 1: next b" "$WORK/cmds1" "SLOT-BOOT1-END"

# --- Boot 2: the loader followed the default; the one-shot is now slot a.
cat >"$WORK/cmds2" <<EOF
$(boot_probe BOOT2) echo "ONCE-BOOT2: \$(sudo emunix-slot once a 2>&1)"; sudo emunix-slot status >/tmp/slot2; echo "ONESHOT-AFTER-BOOT2: \$(sed -n 's/^oneshot: //p' /tmp/slot2)"; echo SLOT-BOOT2-END
EOF
boot "boot 2: after next b, once a" "$WORK/cmds2" "SLOT-BOOT2-END"

# --- Boot 3: the one-shot took over for exactly one boot.
cat >"$WORK/cmds3" <<EOF
$(boot_probe BOOT3) echo SLOT-BOOT3-END
EOF
boot "boot 3: the one-shot boot" "$WORK/cmds3" "SLOT-BOOT3-END"

# --- Boot 4: back on the default, without anyone touching the loader.
cat >"$WORK/cmds4" <<EOF
$(boot_probe BOOT4) echo SLOT-BOOT4-END
EOF
boot "boot 4: falls back to the default" "$WORK/cmds4" "SLOT-BOOT4-END"

# --- The claims, read back out of the transcript.
fail() { echo "FAIL: $*" >&2; echo "transcript: $LOG" >&2; exit 1; }
grep -aq 'ROOT-BOOT1: root=PARTLABEL=rootfs_a' "$LOG" || fail "boot 1 did not run slot a"
grep -aq 'ACTIVE-BOOT1: a' "$LOG" || fail "status did not report slot a as running"
grep -aq 'DEFAULT-BOOT1: emunix-a.conf' "$LOG" || fail "status did not report emunix-a.conf as the default"
grep -aq 'ONESHOT-BOOT1: none' "$LOG" || fail "status invented a pending one-shot"
grep -aq 'SLOTFILE-BOOT1: a' "$LOG" || fail "status did not write this boot's slot to /run/emunix/active_slot"
grep -aq 'NEXT-BOOT1: default: emunix-b.conf (slot b)' "$LOG" || fail "next b did not report the new default"
grep -aq 'LOADER-CONF-BOOT1: default emunix-b.conf timeout 3' "$LOG" ||
  fail "loader.conf is not 'default emunix-b.conf' + the untouched timeout line"

grep -aq 'ROOT-BOOT2: root=PARTLABEL=rootfs_b' "$LOG" ||
  fail "the boot after 'next b' did not come up on slot b"
grep -aq 'ACTIVE-BOOT2: b' "$LOG" || fail "status does not report slot b as running after the switch"
grep -aq 'DEFAULT-BOOT2: emunix-b.conf' "$LOG" || fail "status lost the default after the switch"
grep -aq 'SLOTFILE-BOOT2: b' "$LOG" || fail "active_slot was not updated to b"
grep -aq 'ONESHOT-AFTER-BOOT2: emunix-a.conf' "$LOG" ||
  fail "status does not report the pending one-shot entry"

grep -aq 'ROOT-BOOT3: root=PARTLABEL=rootfs_a' "$LOG" || fail "the one-shot did not boot slot a"
grep -aq 'ACTIVE-BOOT3: a' "$LOG" || fail "the one-shot boot did not report slot a"
grep -aq 'ONESHOT-BOOT3: none' "$LOG" || fail "the one-shot was still pending after it was used"
grep -aq 'DEFAULT-BOOT3: emunix-b.conf' "$LOG" || fail "the one-shot changed the default"

grep -aq 'ROOT-BOOT4: root=PARTLABEL=rootfs_b' "$LOG" ||
  fail "the boot after the one-shot did not fall back to the default slot b"
grep -aq 'ACTIVE-BOOT4: b' "$LOG" || fail "status does not report slot b after the fallback"

echo "emunix-slot: next b -> boot b, once a -> one boot on a, then the default b again"
echo "transcript: $LOG"
