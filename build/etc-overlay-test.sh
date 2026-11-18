#!/usr/bin/env bash
# Prove /etc belongs to the device and not to the root slot, over two A/B cycles.
#
# Cycle 1 boots the image on slot a, writes the settings a user writes (hostname, a Wi-Fi profile,
# a new password), then installs an image into slot b — fresh ext4, the image's rootfs, and a
# marker file in its /etc that the device never wrote — and boots it: every setting is still there,
# the marker from the new image is visible, and the shipped password no longer authenticates.
# Cycle 2 re-images slot a and boots back to it: the same properties again. That second cycle is
# the one that used to fail: a slot-keyed upper carries the previous lower's generation and the
# mount dies with "Stale file handle".
#
# Requires root (loop mount), qemu-system-x86, edk2-ovmf, expect, socat, gptfdisk, e2fsprogs.
# Usage: etc-overlay-test.sh <emunix.img> [evidence-dir]
set -euo pipefail
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-qemu.sh
. "$SCRIPT_DIR/lib-qemu.sh"
require_qemu_allowed

IMG=${1:?usage: etc-overlay-test.sh <emunix.img> [evidence-dir]}
OUT=${2:-$(dirname "$0")/../evidence}
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "etc-overlay-test.sh must run as root (loop mount)" >&2; exit 1; }
OVMF=/usr/share/edk2/x64
[ -f "$OVMF/OVMF_CODE.4m.fd" ] || { echo "edk2-ovmf is not installed ($OVMF)" >&2; exit 1; }
for c in expect socat mkfs.ext4; do
  command -v "$c" >/dev/null || { echo "$c is required" >&2; exit 1; }
done

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
# The password the user sets in cycle 1; it must be the one that logs in on both updates after it.
USERPW=cycle1pw
cleanup() {
  pkill -f "[q]emu-system-x86_64" 2>/dev/null || true
  umount -R "$WORK" 2>/dev/null || true
  # Detach only this image's loop device: a leftover one keeps the 13.5 GiB copy alive.
  for l in $(losetup -j "$DISK" -O NAME --noheadings 2>/dev/null); do
    losetup -d "$l" 2>/dev/null || true
  done
  rm -rf "$WORK"
}
trap cleanup EXIT
: >"$LOG"
echo "image $IMG, accel $ACCEL" | tee -a "$LOG"

cp --sparse=always "$IMG" "$DISK"
cp "$OVMF/OVMF_VARS.4m.fd" "$WORK/OVMF_VARS.fd"

# firstboot grows the disk and seeds /storage; this test needs neither, so the copy is marked
# initialized and the shipped password keeps working.
MNT=$WORK/mnt
mkdir -p "$MNT"
LOOP=$(attach_image "$DISK")
mount "${LOOP}p4" "$MNT"
mkdir -p "$MNT/lib/emunix"
: >"$MNT/lib/emunix/initialized"
umount "$MNT"
losetup -d "$LOOP"

# One QEMU boot: log in, validate sudo once, run the command line from a file, wait for its end
# marker, power the VM down. The commands come from a file so Tcl never sees a quote. The shipped
# password is always tried first: <shipped-ok> says whether that attempt must succeed (a fresh
# image) or be rejected (after the user changed it), and <pw> is the password that must work.
cat >"$WORK/boot.exp" <<'EXPECT'
set img   [lindex $argv 0]
set log   [lindex $argv 1]
set code  [lindex $argv 2]
set vars  [lindex $argv 3]
set accel [lindex $argv 4]
set sock  [lindex $argv 5]
set cmds  [lindex $argv 6]
set tag   [lindex $argv 7]
set pw    [lindex $argv 8]
set shipped_ok [lindex $argv 9]
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
if {$shipped_ok} {
  expect {
    -re {\[retrogamer@[^]]*\]\$ } {}
    -re {Login incorrect} { puts stderr "the shipped password does not log in"; exit 1 }
    timeout { puts stderr "no shell after login"; exit 1 }
  }
} else {
  expect {
    -re {Login incorrect} { puts "shipped password rejected" }
    -re {\[retrogamer@[^]]*\]\$ } { puts stderr "the shipped password still logs in"; exit 1 }
    timeout { puts stderr "no verdict on the shipped password"; exit 1 }
  }
  expect -re {login: }
  send "retrogamer\r"
  expect -re {[Pp]assword: }
  send "$pw\r"
  expect {
    -re {\[retrogamer@[^]]*\]\$ } {}
    -re {Login incorrect} { puts stderr "the user's password does not log in"; exit 1 }
    timeout { puts stderr "no shell with the user's password"; exit 1 }
  }
}
send "sudo -v\r"
# sudo prompts "password for <user>:" (not just "Password:") on the first use in a boot.
expect -re {[Pp]assword for [^:\r\n]*: |[Pp]assword: }
send "$pw\r"
expect -re {\[retrogamer@[^]]*\]\$ }
set f [open $cmds]
set line [read $f]
close $f
send "$line\r"
# The end marker on its own line: the echoed command line carries it too.
expect {
  -re "\n$tag" {}
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

boot() { # <name> <cmds file> <end marker> <password> <shipped-ok 1|0>
  echo "=== $1" | tee -a "$LOG"
  set +e
  expect "$WORK/boot.exp" "$DISK" "$LOG" "$OVMF/OVMF_CODE.4m.fd" "$WORK/OVMF_VARS.fd" \
    "$ACCEL" "$SOCK" "$2" "$3" "$4" "$5"
  local rc=$?
  set -e
  rm -f "$SOCK"
  [ "$rc" -eq 0 ] || { echo "FAIL: $1 did not finish (expect rc=$rc)" >&2; echo "transcript: $LOG" >&2; exit 1; }
}

# An image update writes a fresh image into the inactive slot: new ext4 (new UUID), the current
# image's rootfs, and a marker in its /etc that the device has never written. Anything the user set
# must survive from the device-wide upper; anything they never touched must come from here.
reimage() { # <slot> <marker text>
  local slot=$1 marker=$2 part other loop src=$WORK/src mnt=$WORK/mnt
  case $slot in
    a) part=p2; other=p3 ;;
    b) part=p3; other=p2 ;;
  esac
  loop=$(attach_image "$DISK")
  mkdir -p "$mnt" "$src"
  mkfs.ext4 -q -F -L "rootfs_$slot" "${loop}$part"
  mount "${loop}$part" "$mnt"
  mount -o ro "${loop}$other" "$src"
  cp -a "$src/." "$mnt/"
  umount "$src"
  printf '%s\n' "$marker" >"$mnt/etc/emunix-image-marker"
  chmod 0644 "$mnt/etc/emunix-image-marker"
  umount "$mnt"
  losetup -d "$loop"
}

flip() { # <slot> -> points the loader at the slot, the way an update does
  local loop
  loop=$(attach_image "$DISK")
  mkdir -p "$WORK/esp"
  mount "${loop}p1" "$WORK/esp"
  printf 'default emunix-%s.conf\ntimeout 3\n' "$1" >"$WORK/esp/loader/loader.conf"
  umount "$WORK/esp"
  losetup -d "$loop"
}

# --- Cycle 1, boot 1 (slot a): the settings a user makes on a running device.
cat >"$WORK/cmds1" <<'EOF'
echo "ROOT-MOUNT-B1: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /)"; echo "ETC-MOUNT-B1: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /etc)"; echo emunix-cycle1 | sudo tee /etc/hostname; sudo hostnamectl set-hostname emunix-cycle1; echo "WROTE-HOSTNAME: $(cat /etc/hostname)"; sudo nmcli connection add type wifi con-name emunix-cycle1 ssid emunix-cycle1; echo "NM-CON-ADD-RC=$?"; echo 'retrogamer:cycle1pw' | sudo chpasswd; echo "SET-PASSWORD-RC=$?"; echo "PASSWD-STATUS-B1: $(sudo passwd -S retrogamer)"; echo "UPPER-TREE-B1: $(sudo find /var/lib/emunix/etc -maxdepth 3 | sort | tr '\n' ' ')"; echo ETC-OVERLAY-BOOT1-END
EOF
boot "boot 1: slot a, write /etc" "$WORK/cmds1" ETC-OVERLAY-BOOT1-END retrogamer 1

# --- Cycle 1, image slot b and boot it.
echo "=== cycle 1: image slot b, flip the loader to it" | tee -a "$LOG"
reimage b "new image in cycle 1"
flip b
cat >"$WORK/cmds2" <<'EOF'
echo "ROOT-MOUNT-B2: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /)"; echo "ETC-MOUNT-B2: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /etc)"; echo "HOSTNAME-FILE-B2: $(cat /etc/hostname)"; echo "HOSTNAME-RUNNING-B2: $(hostnamectl hostname)"; echo "NM-PROFILES-B2: $(nmcli -g NAME connection show | tr '\n' ' ')"; echo "MARKER-B2: $(cat /etc/emunix-image-marker)"; echo "PASSWD-STATUS-B2: $(sudo passwd -S retrogamer)"; echo "UPPER-TREE-B2: $(sudo find /var/lib/emunix/etc -maxdepth 3 | sort | tr '\n' ' ')"; systemctl show -p ActiveState -p Result emunix-etc-overlay; echo ETC-OVERLAY-BOOT2-END
EOF
boot "boot 2: slot b, the image installed in cycle 1" "$WORK/cmds2" ETC-OVERLAY-BOOT2-END "$USERPW" 0

# --- Cycle 2, image slot a again and boot it: the cycle that used to lose /etc.
echo "=== cycle 2: image slot a, flip the loader back to it" | tee -a "$LOG"
reimage a "new image in cycle 2"
flip a
cat >"$WORK/cmds3" <<'EOF'
echo "ROOT-MOUNT-B3: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /)"; echo "ETC-MOUNT-B3: $(findmnt -no TARGET,SOURCE,FSTYPE,OPTIONS /etc)"; echo "HOSTNAME-FILE-B3: $(cat /etc/hostname)"; echo "HOSTNAME-RUNNING-B3: $(hostnamectl hostname)"; echo "NM-PROFILES-B3: $(nmcli -g NAME connection show | tr '\n' ' ')"; echo "MARKER-B3: $(cat /etc/emunix-image-marker)"; echo "PASSWD-STATUS-B3: $(sudo passwd -S retrogamer)"; echo "UPPER-TREE-B3: $(sudo find /var/lib/emunix/etc -maxdepth 3 | sort | tr '\n' ' ')"; systemctl show -p ActiveState -p Result emunix-etc-overlay; echo ETC-OVERLAY-BOOT3-END
EOF
boot "boot 3: slot a again, the image installed in cycle 2" "$WORK/cmds3" ETC-OVERLAY-BOOT3-END "$USERPW" 0

# --- The claims, read back out of the transcript.
fail() { echo "FAIL: $*" >&2; echo "transcript: $LOG" >&2; exit 1; }
for b in 1 2 3; do
  grep -q "ROOT-MOUNT-B$b: / .* ext4 ro" "$LOG" || fail "boot $b: the root is not read-only"
  grep -q "ETC-MOUNT-B$b: /etc .* overlay .*upperdir=/var/lib/emunix/etc/upper,workdir=/var/lib/emunix/etc/work,index=off" "$LOG" ||
    fail "boot $b: /etc is not the device-wide overlay"
done
if grep -q 'upperdir=/var/lib/emunix/overlay/etc/[ab]/' "$LOG"; then
  fail "the /etc upper is still keyed by the root slot"
fi
grep -q 'WROTE-HOSTNAME: emunix-cycle1' "$LOG" || fail "the hostname write bounced"
grep -q 'NM-CON-ADD-RC=0' "$LOG" || fail "nmcli could not add a Wi-Fi profile"
grep -q 'SET-PASSWORD-RC=0' "$LOG" || fail "the user's password was not set"
grep -q 'PASSWD-STATUS-B1: retrogamer P ' "$LOG" || fail "passwd -S retrogamer is not P on boot 1"
grep -q 'ActiveState=active' "$LOG" || fail "the overlay unit is not active after the update"

# Cycle 1: the settings are kept, and the marker from the new image is what /etc shows.
grep -q 'HOSTNAME-FILE-B2: emunix-cycle1' "$LOG" || fail "boot 2: the hostname did not survive the update"
grep -q 'HOSTNAME-RUNNING-B2: emunix-cycle1' "$LOG" || fail "boot 2: the hostname did not come back at boot"
grep -q 'NM-PROFILES-B2: .*emunix-cycle1' "$LOG" || fail "boot 2: the Wi-Fi profile did not survive the update"
grep -q 'MARKER-B2: new image in cycle 1' "$LOG" || fail "boot 2: the new image's /etc file is not visible"
grep -q 'PASSWD-STATUS-B2: retrogamer P ' "$LOG" || fail "boot 2: retrogamer has no password"
grep -q 'upper/shadow' "$LOG" || fail "boot 2: /etc/shadow is not in the device-wide upper"

# Cycle 2: the same after the other slot has been re-imaged.
grep -q 'HOSTNAME-FILE-B3: emunix-cycle1' "$LOG" || fail "boot 3: the hostname was lost by the second update"
grep -q 'HOSTNAME-RUNNING-B3: emunix-cycle1' "$LOG" || fail "boot 3: the hostname did not come back at boot"
grep -q 'NM-PROFILES-B3: .*emunix-cycle1' "$LOG" || fail "boot 3: the Wi-Fi profile was lost by the second update"
grep -q 'MARKER-B3: new image in cycle 2' "$LOG" || fail "boot 3: the second image's /etc file is not visible"
grep -q 'PASSWD-STATUS-B3: retrogamer P ' "$LOG" || fail "boot 3: retrogamer has no password"

# The password never changes itself: the shipped one was rejected on both updates (boot.exp exits
# non-zero otherwise) and the user's one logged in.
[ "$(grep -c 'Login incorrect' "$LOG")" -ge 2 ] || fail "the shipped password was not rejected on both updates"

echo "/etc overlay: one upper for the device; hostname, Wi-Fi profile and password survive two A/B updates, new-image files still follow the image"
echo "transcript: $LOG"
