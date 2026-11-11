#!/usr/bin/env bash
# Prove /etc is writable on the read-only root and owned by the slot: boot 1 writes /etc/hostname
# and a NetworkManager profile, boot 2 still has both with the root still read-only, and a boot
# from the other root slot starts from that image's /etc again.
#
# The image's rootfs_b ships empty, so the slot switch copies rootfs_a into rootfs_b first: that
# is what an A/B update does to the inactive slot. Requires root (loop mount), qemu-system-x86,
# edk2-ovmf, expect, socat, gptfdisk. Usage: etc-overlay-test.sh <emunix.img> [evidence-dir]
set -euo pipefail
IMG=${1:?usage: etc-overlay-test.sh <emunix.img> [evidence-dir]}
OUT=${2:-$(dirname "$0")/../evidence}
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "etc-overlay-test.sh must run as root (loop mount)" >&2; exit 1; }
OVMF=/usr/share/edk2/x64
[ -f "$OVMF/OVMF_CODE.4m.fd" ] || { echo "edk2-ovmf is not installed ($OVMF)" >&2; exit 1; }
command -v expect socat >/dev/null || { echo "expect and socat are required" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-loop.sh
. "$SCRIPT_DIR/lib-loop.sh"

mkdir -p "$OUT"
LOG=$OUT/m0-etc-overlay.log
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
# so the copy is marked initialized and the shipped password keeps working.
MNT=$WORK/mnt
mkdir -p "$MNT"
LOOP=$(attach_image "$DISK")
mount "${LOOP}p4" "$MNT"
mkdir -p "$MNT/lib/emunix"
: >"$MNT/lib/emunix/initialized"
umount "$MNT"
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

# --- Boot 1: write /etc twice, the two ways that matter (hostname, NetworkManager).
cat >"$WORK/cmds1" <<'EOF'
echo "ROOT-MOUNT: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /)"; echo "ETC-MOUNT: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /etc)"; echo emunix-overlay-test | sudo tee /etc/hostname; echo "WROTE-HOSTNAME: $(cat /etc/hostname)"; sudo nmcli connection add type wifi con-name emunix-test ssid emunix-test; echo "NM-CON-ADD-RC=$?"; sudo ls -l /etc/NetworkManager/system-connections/; echo "OVERLAY-TREE-B1: $(sudo find /var/lib/emunix/overlay -maxdepth 4 | sort | tr '\n' ' ')"; echo ETC-OVERLAY-BOOT1-END
EOF
boot "boot 1: write /etc on the read-only root" "$WORK/cmds1" "ETC-OVERLAY-BOOT1-END"

# --- Boot 2: both writes must be back, from /var, with / still read-only.
cat >"$WORK/cmds2" <<'EOF'
echo "ROOT-MOUNT: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /)"; echo "ETC-MOUNT: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /etc)"; echo "HOSTNAME-FILE: $(cat /etc/hostname)"; echo "HOSTNAME-RUNNING: $(hostnamectl hostname)"; echo "NM-PROFILES-B2: $(nmcli -g NAME connection show | tr '\n' ' ')"; systemctl show -p ActiveState -p Result emunix-etc-overlay; echo ETC-OVERLAY-BOOT2-END
EOF
boot "boot 2: reboot, nothing written since" "$WORK/cmds2" "ETC-OVERLAY-BOOT2-END"

# --- Slot switch: an update writes the image into the inactive slot and points the loader at it.
echo "=== slot switch: rootfs_a -> rootfs_b" | tee -a "$LOG"
LOOP=$(attach_image "$DISK")
mkdir -p "$WORK/a" "$WORK/b" "$WORK/esp"
mount "${LOOP}p2" "$WORK/a"
mount "${LOOP}p3" "$WORK/b"
cp -a "$WORK/a/." "$WORK/b/"
umount "$WORK/a" "$WORK/b"
mount "${LOOP}p1" "$WORK/esp"
printf 'default emunix-b.conf\ntimeout 3\n' >"$WORK/esp/loader/loader.conf"
umount "$WORK/esp"
losetup -d "$LOOP"

# --- Boot 3: the other slot sees its own /etc; slot a's writes are still on /var, untouched.
cat >"$WORK/cmds3" <<'EOF'
echo "ROOT-MOUNT: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /)"; echo "ETC-MOUNT: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /etc)"; echo "HOSTNAME-FILE: $(cat /etc/hostname)"; echo "NM-PROFILES-B3: $(nmcli -g NAME connection show | tr '\n' ' ')"; echo "SLOT-A-ETC-HOSTNAME: $(sudo sed -n 1p /var/lib/emunix/overlay/etc/a/upper/hostname)"; echo ETC-OVERLAY-BOOT3-END
EOF
boot "boot 3: the other root slot" "$WORK/cmds3" "ETC-OVERLAY-BOOT3-END"

# --- The claims, read back out of the transcript.
fail() { echo "FAIL: $*" >&2; echo "transcript: $LOG" >&2; exit 1; }
grep -q 'ROOT-MOUNT: / .* ext4 ro' "$LOG" || fail "the root is not read-only"
grep -q 'ETC-MOUNT: /etc .* overlay .*upperdir=/var/lib/emunix/overlay/etc/a/upper' "$LOG" ||
  fail "/etc is not an overlay over slot a's upper directory"
grep -q 'WROTE-HOSTNAME: emunix-overlay-test' "$LOG" || fail "the hostname write bounced"
grep -q 'NM-CON-ADD-RC=0' "$LOG" || fail "nmcli could not add a profile"
grep -q 'emunix-test.nmconnection' "$LOG" || fail "no keyfile was written to /etc/NetworkManager"
grep -q 'HOSTNAME-FILE: emunix-overlay-test' "$LOG" || fail "the hostname did not survive the reboot"
grep -q 'HOSTNAME-RUNNING: emunix-overlay-test' "$LOG" || fail "the hostname did not come back at boot"
grep -q 'NM-PROFILES-B2: .*emunix-test' "$LOG" || fail "the NetworkManager profile did not survive the reboot"
grep -q 'ActiveState=active' "$LOG" || fail "the overlay unit is not active after the reboot"
grep -q 'ETC-MOUNT: /etc .*overlay .*upperdir=/var/lib/emunix/overlay/etc/b/upper' "$LOG" ||
  fail "slot b did not get its own upper directory"
grep -q 'HOSTNAME-FILE: emunix' "$LOG" || fail "slot b did not start from the image's /etc"
if grep -q 'NM-PROFILES-B3: .*emunix-test' "$LOG"; then fail "slot b inherited slot a's NetworkManager profile"; fi
grep -q 'SLOT-A-ETC-HOSTNAME: emunix-overlay-test' "$LOG" || fail "slot a's writes were not left on /var"

echo "/etc overlay: ro root with a writable /etc, hostname and NM profile survive a reboot, slot b starts fresh"
echo "transcript: $LOG"
