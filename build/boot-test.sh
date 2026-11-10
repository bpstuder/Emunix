#!/usr/bin/env bash
# Boot a built image under QEMU + OVMF and prove it reaches multi-user with a serial login.
# Requires: qemu-system-x86, edk2-ovmf, expect. Usage: boot-test.sh <emunix.img> [log]
set -euo pipefail
IMG=${1:?usage: boot-test.sh <emunix.img> [log]}
LOG=${2:-$(dirname "$0")/../evidence/m0-boot.log}
OVMF=/usr/share/edk2/x64
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }
[ -f "$OVMF/OVMF_CODE.4m.fd" ] || { echo "edk2-ovmf is not installed ($OVMF)" >&2; exit 1; }
VARS=$(mktemp)
cp "$OVMF/OVMF_VARS.4m.fd" "$VARS"
trap 'rm -f "$VARS"' EXIT
ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
mkdir -p "$(dirname "$LOG")"
: >"$LOG" # each run is its own transcript

expect -f - "$IMG" "$LOG" "$OVMF/OVMF_CODE.4m.fd" "$VARS" "$ACCEL" <<'EXPECT'
set img [lindex $argv 0]
set log [lindex $argv 1]
set code [lindex $argv 2]
set vars [lindex $argv 3]
set accel [lindex $argv 4]
set timeout 900
log_file $log
spawn qemu-system-x86_64 -machine q35 -accel $accel -m 2048 -smp 2 \
  -drive if=pflash,format=raw,readonly=on,file=$code \
  -drive if=pflash,format=raw,file=$vars \
  -drive file=$img,format=raw,if=virtio -snapshot \
  -display none -serial stdio -no-reboot
expect {
  -re {login: } { send "retrogamer\r" }
  -re {Bailing out|Kernel panic|No bootable device} { puts stderr "boot failed before userspace"; exit 1 }
  eof { puts stderr "qemu exited before the login prompt"; exit 1 }
  timeout { puts stderr "timeout waiting for a login prompt"; exit 1 }
}
expect -re {[Pp]assword: }
send "retrogamer\r"
# login() flushes pending tty input, so wait for the shell prompt before typing the block.
expect {
  -re {\[retrogamer@emunix[^]]*\]\$ } {}
  -re {login: } { puts stderr "retrogamer could not log in"; exit 1 }
  timeout { puts stderr "no shell prompt after login"; exit 1 }
}
# One marked block: these lines are the acceptance evidence.
send "id -un; cat /etc/emunix-version; systemctl is-system-running; systemctl get-default; findmnt -no OPTIONS /; for m in /boot /var /home /storage; do findmnt -no TARGET,FSTYPE \$m; done; systemctl --failed --no-legend; echo EMUNIX-EVIDENCE-END\r"
expect {
  -re {EMUNIX-EVIDENCE-END} {}
  -re {login: } { puts stderr "retrogamer could not log in"; exit 1 }
  timeout { puts stderr "no shell after login"; exit 1 }
}
# The marker echoes before the commands run; the prompt proves the output is in the log.
expect -re {\[retrogamer@emunix[^]]*\]\$ }
send "sudo poweroff\r"
# Also proves the wheel+sudo grant: sudo prompts and then the machine goes down.
expect {
  -re {assword for} { send "retrogamer\r"; exp_continue }
  eof {}
  timeout { puts stderr "system did not power off"; exit 1 }
}
EXPECT
echo "boot test transcript: $LOG"
