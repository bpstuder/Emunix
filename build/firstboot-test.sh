#!/usr/bin/env bash
# Prove the first boot of a flashed Emunix image: the last partition grows into the rest of the
# device, /storage gets its ROM tree owned by retrogamer, the shipped password stops
# authenticating, and a second boot does not run the unit again.
#
# The image copy is enlarged by GROW_SIZE before the first boot: that is what flashing a 24 GiB
# image onto a bigger device looks like. Requires root (loop mount), qemu-system-x86, edk2-ovmf,
# expect, socat, gptfdisk. Usage: firstboot-test.sh <emunix.img> [evidence-dir]
set -euo pipefail
IMG=${1:?usage: firstboot-test.sh <emunix.img> [evidence-dir]}
OUT=${2:-$(dirname "$0")/../evidence}
GROW_SIZE=${GROW_SIZE:-8G}
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "firstboot-test.sh must run as root (loop mount)" >&2; exit 1; }
OVMF=/usr/share/edk2/x64
[ -f "$OVMF/OVMF_CODE.4m.fd" ] || { echo "edk2-ovmf is not installed ($OVMF)" >&2; exit 1; }
command -v expect socat sgdisk sfdisk >/dev/null || { echo "expect, socat, gptfdisk and util-linux are required" >&2; exit 1; }

mkdir -p "$OUT"
LOG=$OUT/m0-firstboot.log
WORK=$(mktemp -d)
DISK=$WORK/disk.img
trap 'pkill -f "[q]emu-system-x86_64" 2>/dev/null || true; rm -rf "$WORK"' EXIT
: >"$LOG"

# The disk the "device" turns out to be: bigger than the image, with a relocated backup GPT.
cp --sparse=always "$IMG" "$DISK"
truncate -s "+$GROW_SIZE" "$DISK"
sgdisk --move-second-header "$DISK" >/dev/null
part_size() { sfdisk -d "$1" | sed -n 's|^.*: start= *[0-9]*, size= *\([0-9]*\).*|\1|p' | tail -1; }
SIZE_BEFORE=$(part_size "$DISK")
echo "image $IMG, grown by $GROW_SIZE: last partition is $SIZE_BEFORE sectors before the first boot" | tee -a "$LOG"

VARS=$WORK/OVMF_VARS.fd
cp "$OVMF/OVMF_VARS.4m.fd" "$VARS"
ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
SOCK=$WORK/qmp.sock

# --- Boot 1: no console input at all, the way a headless or keyboard-less device starts up.
set +e
expect -f - "$DISK" "$LOG" "$OVMF/OVMF_CODE.4m.fd" "$VARS" "$ACCEL" "$SOCK" <<'EXPECT'
set img   [lindex $argv 0]
set log   [lindex $argv 1]
set code  [lindex $argv 2]
set vars  [lindex $argv 3]
set accel [lindex $argv 4]
set sock  [lindex $argv 5]
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
# No key is sent anywhere: the unit must finish on its own, with the prompt unanswered.
expect {
  -re {emunix-firstboot: first boot complete} {}
  -re {Bailing out|Kernel panic|No bootable device} { puts stderr "boot failed before userspace"; exit 1 }
  timeout { puts stderr "the first boot never completed"; exit 1 }
}
after 4000
qmp "{\"execute\":\"system_powerdown\"}"
expect {
  eof {}
  timeout { puts stderr "the VM did not power off after boot 1"; exit 1 }
}
exit 0
EXPECT
RC=$?
set -e
[ "$RC" -eq 0 ] || { echo "FAIL: first boot did not finish on its own (expect rc=$RC)" >&2; exit 1; }

PW=$(sed -n 's/.*generated password for retrogamer: \([A-Za-z0-9-]*\).*/\1/p' "$LOG" | tail -1)
[ -n "$PW" ] || { echo "FAIL: no generated password in the transcript" >&2; exit 1; }

SIZE_AFTER=$(part_size "$DISK")
echo "last partition after the first boot: $SIZE_AFTER sectors" | tee -a "$LOG"
rm -f "$SOCK"

# --- Boot 2: the same disk, one password change later.
set +e
expect -f - "$DISK" "$LOG" "$OVMF/OVMF_CODE.4m.fd" "$VARS" "$ACCEL" "$SOCK" "$PW" <<'EXPECT'
set img   [lindex $argv 0]
set log   [lindex $argv 1]
set code  [lindex $argv 2]
set vars  [lindex $argv 3]
set accel [lindex $argv 4]
set sock  [lindex $argv 5]
set pw    [lindex $argv 6]
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

# The shipped password is tried first: this is the exposure the unit exists for.
expect {
  -re {login: } { send "retrogamer\r" }
  timeout { puts stderr "no login prompt on the second boot"; exit 1 }
}
expect -re {[Pp]assword: }
send "retrogamer\r"
expect {
  -re {Login incorrect} { puts "\nshipped password rejected at the console login" }
  -re {\[retrogamer@emunix[^]]*\]\$ } { puts stderr "the shipped password still logs in"; exit 1 }
  timeout { puts stderr "no verdict on the shipped password"; exit 1 }
}
# The generated one is the password that works.
expect -re {login: }
send "retrogamer\r"
expect -re {[Pp]assword: }
send "$pw\r"
expect {
  -re {\[retrogamer@emunix[^]]*\]\$ } {}
  -re {login: } { puts stderr "the generated password does not log in"; exit 1 }
  timeout { puts stderr "no shell on the second boot"; exit 1 }
}

send "echo EMUNIX-FIRSTBOOT-EVIDENCE\r"
expect -re {EMUNIX-FIRSTBOOT-EVIDENCE}
send "echo \"PASSWD-STATUS: \$(passwd -S retrogamer)\"; echo '--- firstboot unit on this boot:'; systemctl show -p ActiveState -p ConditionResult -p Result firstboot; journalctl -b -u firstboot --no-pager | tail -3; echo '--- disk:'; findmnt -no SOURCE,SIZE,TARGET /storage; df -h /storage | tail -1; echo '--- storage tree:'; ls -d /storage/*; ls /storage/roms | tr '\\n' ' '; echo; stat -c '%U:%G %a %n' /storage /storage/roms/nes; touch /storage/roms/nes/.write-test && echo STORAGE-WRITABLE-AS-RETROGAMER && rm /storage/roms/nes/.write-test; echo '--- root fs:'; findmnt -no OPTIONS /; echo '--- the shipped password against pam_unix again (sudo):'; echo retrogamer | sudo -S -k id 2>&1; echo \"SHIPPED-SUDO-RC=\$?\"; echo EMUNIX-FIRSTBOOT-EVIDENCE-A-END\r"
expect {
  -re {EMUNIX-FIRSTBOOT-EVIDENCE-A-END} {}
  timeout { puts stderr "no evidence from the second boot"; exit 1 }
}
expect -re {\[retrogamer@emunix[^]]*\]\$ }
send "echo EMUNIX-FIRSTBOOT-EVIDENCE-END\r"
expect -re {EMUNIX-FIRSTBOOT-EVIDENCE-END}
after 2000
qmp "{\"execute\":\"system_powerdown\"}"
expect {
  eof {}
  timeout { puts stderr "the VM did not power off after boot 2"; exit 1 }
}
exit 0
EXPECT
RC=$?
set -e
[ "$RC" -eq 0 ] || { echo "FAIL: the second boot did not verify (expect rc=$RC)" >&2; exit 1; }

# --- The four claims, read back out of the transcript.
fail() { echo "FAIL: $*" >&2; echo "transcript: $LOG" >&2; exit 1; }
grep -q 'CHANGED: partition=5' "$LOG" || fail "growpart did not grow the last partition"
[ "$SIZE_AFTER" -gt "$SIZE_BEFORE" ] ||
  fail "the last partition did not grow ($SIZE_BEFORE -> $SIZE_AFTER sectors)"
grep -q 'emunix-firstboot: grew .* into the free space' "$LOG" || fail "firstboot did not report the resize"
grep -q 'emunix-firstboot: password for retrogamer replaced' "$LOG" || fail "firstboot did not report the password change"
# The transcript carries the shell's escape sequences in front of the output lines, hence the
# unanchored markers.
grep -q 'PASSWD-STATUS: retrogamer P ' "$LOG" || fail "passwd -S retrogamer is not P"
grep -q 'Login incorrect' "$LOG" || fail "the shipped password was not rejected at the console"
grep -q 'SHIPPED-SUDO-RC=1' "$LOG" || fail "sudo accepted the shipped password"
grep -q 'STORAGE-WRITABLE-AS-RETROGAMER' "$LOG" || fail "retrogamer cannot write the /storage tree"
grep -q 'ConditionResult=no' "$LOG" || fail "the unit's condition did not hold on the second boot"
grep -q 'skipped, unmet condition check' "$LOG" || fail "the second boot did not skip firstboot"

echo "first boot: partition $SIZE_BEFORE -> $SIZE_AFTER sectors, /storage seeded, shipped password rejected, second boot skipped the unit"
echo "transcript: $LOG"
