#!/usr/bin/env bash
# Boot the image with a synthetic gamepad passed through QEMU's virtio-input-host
# and prove the controller pipeline inside the guest: udev tags the pad
# (ID_INPUT_JOYSTICK + uaccess), the session unit points SDL at the shipped
# gamecontrollerdb, and ES-DE adds the controller.
#
# The pad is a uinput device on the host (see tests/test-emunix-pads.sh for the
# mapping evidence); this proves the image's udev + SDL + ES-DE chain, not a
# specific physical pad.
#
# Requires root (loop mount), qemu-system-x86, edk2-ovmf, expect.
# Usage: pads-test.sh <emunix.img> <host-evdev> [evidence-dir]
set -euo pipefail
IMG=${1:?usage: pads-test.sh <emunix.img> <host-evdev> [evidence-dir]}
EVDEV=${2:?host evdev path, e.g. /dev/input/event12}
OUT=${3:-$(dirname "$0")/../evidence}
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }
[ -e "$EVDEV" ] || { echo "no host evdev $EVDEV" >&2; exit 1; }
OVMF=/usr/share/edk2/x64
[ -f "$OVMF/OVMF_CODE.4m.fd" ] || { echo "edk2-ovmf is not installed ($OVMF)" >&2; exit 1; }
command -v expect >/dev/null || { echo "expect is required" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "pads-test.sh must run as root (loop mount)" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-loop.sh
. "$SCRIPT_DIR/lib-loop.sh"
WORK=$(mktemp -d)
VARS=$WORK/OVMF_VARS.fd
MNT=$WORK/mnt
LOG=$OUT/m3-pads.log
LOOP=
trap 'umount -R "$MNT" 2>/dev/null || true; losetup -d "${LOOP:-}" 2>/dev/null || true; rm -rf "$WORK"' EXIT
mkdir -p "$OUT"
: >"$LOG"

# Skip firstboot (it would replace the shipped password) and leave the guest a
# probe script to run on the serial console.
cp --sparse=always "$IMG" "$WORK/disk.img"
LOOP=$(attach_image "$WORK/disk.img")
mkdir -p "$MNT"
mount "${LOOP}p4" "$MNT"
mkdir -p "$MNT/lib/emunix"
: >"$MNT/lib/emunix/initialized"
umount "$MNT"
mount "${LOOP}p5" "$MNT"
cat >"$MNT/retrogamer/pads-probe.sh" <<'PROBE'
#!/bin/bash
# Guest-side controller probe (written by build/pads-test.sh).
export XDG_RUNTIME_DIR=/run/user/$(id -u)
echo PAD-UDEV
for e in /sys/class/input/event*; do
  n=$(cat "$e/device/name" 2>/dev/null || true)
  case "$n" in
    *X-Box* | *"Wireless Controller"*)
      echo "DEV $e: $n"
      udevadm info -p "$e" | grep -E 'E: (ID_INPUT_JOYSTICK|TAGS)='
      ;;
  esac
done
echo PAD-BYID
ls -l /dev/input/by-id/ 2>/dev/null || true
echo PAD-ENV
systemctl --user show emunix-session -p Environment
systemctl --user start emunix-session
for _ in $(seq 60); do pgrep -x es-de >/dev/null && break; sleep 2; done
sleep 8
echo PAD-ESDE
grep -i 'Added controller' /home/retrogamer/ES-DE/logs/es_log.txt | tail -5
echo PAD-EVIDENCE-END
PROBE
umount "$MNT"
losetup -d "$LOOP"
LOOP=

cp "$OVMF/OVMF_VARS.4m.fd" "$VARS"
ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm

expect -f - "$WORK/disk.img" "$LOG" "$OVMF/OVMF_CODE.4m.fd" "$VARS" "$ACCEL" "$EVDEV" <<'EXPECT'
set img   [lindex $argv 0]
set log   [lindex $argv 1]
set code  [lindex $argv 2]
set vars  [lindex $argv 3]
set accel [lindex $argv 4]
set evdev [lindex $argv 5]
set timeout 900
log_file $log
spawn qemu-system-x86_64 -machine q35 -accel $accel -m 3072 -smp 4 -vga none \
  -device bochs-display -display none \
  -device virtio-input-host-pci,evdev=$evdev \
  -drive if=pflash,format=raw,readonly=on,file=$code \
  -drive if=pflash,format=raw,file=$vars \
  -drive file=$img,format=raw,if=virtio -snapshot -no-reboot \
  -serial stdio
expect {
  -re {login: } { send "retrogamer\r" }
  -re {Bailing out|Kernel panic|No bootable device} { puts stderr "boot failed before userspace"; exit 1 }
  eof { puts stderr "qemu exited before the login prompt"; exit 1 }
  timeout { puts stderr "timeout waiting for a login prompt"; exit 1 }
}
expect -re {[Pp]assword: }
send "retrogamer\r"
expect {
  -re {\[retrogamer@emunix[^]]*\]\$ } {}
  -re {login: } { puts stderr "retrogamer could not log in"; exit 1 }
  timeout { puts stderr "no shell prompt after login"; exit 1 }
}
send "bash /home/retrogamer/pads-probe.sh\r"
expect {
  -re {PAD-EVIDENCE-END} {}
  -re {login: } { puts stderr "retrogamer could not log in"; exit 1 }
  timeout { puts stderr "no controller evidence"; exit 1 }
}
expect -re {\[retrogamer@emunix[^]]*\]\$ }
send "sudo poweroff\r"
expect {
  -re {assword for} { send "retrogamer\r"; exp_continue }
  eof {}
  timeout { puts stderr "system did not power off"; exit 1 }
}
EXPECT
echo "pads test transcript: $LOG"
grep -q 'ID_INPUT_JOYSTICK=1' "$LOG" || { echo "FAIL: the pad was not tagged ID_INPUT_JOYSTICK" >&2; exit 1; }
grep -q 'TAGS=.*uaccess' "$LOG" || { echo "FAIL: the pad was not tagged uaccess" >&2; exit 1; }
grep -q 'SDL_GAMECONTROLLERCONFIG_FILE=/usr/share/emunix/gamecontrollerdb.txt' "$LOG" ||
  { echo "FAIL: the session does not point SDL at the shipped gamecontrollerdb" >&2; exit 1; }
grep -q 'Added controller' "$LOG" || { echo "FAIL: ES-DE did not add the controller" >&2; exit 1; }
echo "pads test: udev tags, session env and ES-DE detection OK"
