#!/usr/bin/env bash
# Prove emunix-install end to end, without an Ally: the image boots as the "USB stick" (/dev/vda)
# next to an empty 20 GiB disk (/dev/vdb), emunix-install copies it, moves the backup GPT, resets the
# GUIDs and points the target's loader at them -- and the target then boots on its own with slot a,
# the /etc overlay up and home grown to the whole disk.
#
# No loop mount on the host: everything happens inside the guests. Boot 1 also runs firstboot on the
# stick, the way a stick that was booted before installing really behaves, so the target only grows
# because emunix-install dropped its first-boot marker.
#
# Requires qemu-system-x86, edk2-ovmf, expect, gptfdisk and util-linux.
# Usage: install-test.sh <emunix.img> [evidence-dir]
set -euo pipefail
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-qemu.sh
. "$SCRIPT_DIR/lib-qemu.sh"
require_qemu_allowed

IMG=${1:?usage: install-test.sh <emunix.img> [evidence-dir]}
OUT=${2:-$(dirname "$0")/../evidence}
TARGET_SIZE=${TARGET_SIZE:-20G}
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }
OVMF=/usr/share/edk2/x64
[ -f "$OVMF/OVMF_CODE.4m.fd" ] || { echo "edk2-ovmf is not installed ($OVMF)" >&2; exit 1; }
command -v expect sgdisk sfdisk truncate >/dev/null ||
  { echo "expect, gptfdisk and util-linux are required" >&2; exit 1; }

mkdir -p "$OUT"
LOG=$OUT/m4-install.log
WORK=$(mktemp -d)
STICK=$WORK/stick.img
TARGET=$WORK/target.img
trap 'pkill -f "[q]emu-system-x86_64" 2>/dev/null || true; rm -rf "$WORK"' EXIT
: >"$LOG"

# A copy, so the artifact under test is never written; boot 1 runs firstboot on it.
cp --sparse=always "$IMG" "$STICK"
# The target: an empty disk, larger than the image, as an internal SSD would be. The copy allocates
# ~13.5 GB here (the host's free space is printed to the transcript), which is why the test cleans up
# after itself.
truncate -s "$TARGET_SIZE" "$TARGET"
ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
# Two copies of the NVRAM template: one per boot, and never the system's own file (it is written to).
VARS1=$WORK/OVMF_VARS.1.fd
VARS2=$WORK/OVMF_VARS.2.fd
cp "$OVMF/OVMF_VARS.4m.fd" "$VARS1"
cp "$OVMF/OVMF_VARS.4m.fd" "$VARS2"
echo "stick $IMG (copy), target $TARGET ($TARGET_SIZE empty), accel $ACCEL" | tee -a "$LOG"
echo "work dir $WORK: $(df -h --output=avail "$WORK" | tail -1) available" | tee -a "$LOG"

uuid_of() { # <file> <partlabel> -> that partition's PARTUUID, read out of the GPT
  sfdisk -d "$1" | grep "name=\"$2\"" | sed -n 's/.*uuid=\([^,]*\).*/\1/p'
}
STICK_A=$(uuid_of "$IMG" rootfs_a)
[ -n "$STICK_A" ] || { echo "cannot read rootfs_a's PARTUUID from $IMG" >&2; exit 1; }
echo "stick rootfs_a PARTUUID before the install: $STICK_A" | tee -a "$LOG"

# --- Boot 1: two disks. Install, and record what the guest sees afterwards.
set +e
expect -f - "$STICK" "$TARGET" "$LOG" "$OVMF/OVMF_CODE.4m.fd" "$VARS1" "$ACCEL" <<'EXPECT'
set stick [lindex $argv 0]
set tgt   [lindex $argv 1]
set log   [lindex $argv 2]
set code  [lindex $argv 3]
set vars0 [lindex $argv 4]
set accel [lindex $argv 5]
set timeout 2400
log_file -a $log

spawn qemu-system-x86_64 -machine q35 -accel $accel -m 4096 -smp 4 -vga none \
  -device bochs-display -display none \
  -drive if=pflash,format=raw,readonly=on,file=$code \
  -drive if=pflash,format=raw,file=$vars0 \
  -drive file=$stick,format=raw,if=virtio \
  -drive file=$tgt,format=raw,if=virtio \
  -no-reboot -serial stdio
expect {
  -re {login: } { send "retrogamer\r" }
  -re {Bailing out|Kernel panic|No bootable device} { puts stderr "boot 1 failed before userspace"; exit 1 }
  timeout { puts stderr "no login prompt on boot 1"; exit 1 }
}
expect -re {[Pp]assword: }
send "retrogamer\r"
expect {
  -re {\[retrogamer@emunix[^]]*\]\$ } {}
  timeout { puts stderr "no shell on boot 1"; exit 1 }
}

# The stick's own first boot must be over before its partition table is copied.
send "for i in \$(seq 60); do case \$(systemctl is-active firstboot) in inactive) break;; esac; sleep 2; done; echo STICK-FIRSTBOOT: \$(systemctl is-active firstboot); echo FIRSTBOOT-DONE\r"
expect -re {FIRSTBOOT-DONE}
expect -re {\[retrogamer@emunix[^]]*\]\$ }

# The ES-DE entry, run the way ES-DE runs it: the seeded script, no terminal, no arguments. It must
# print the plan and refuse - this is also what proves the narrow sudoers entry is accepted.
send "ls -l /storage/roms/install/; bash /storage/roms/install/install-to-disk.sh; echo LAUNCHER-RC=\$?\r"
expect {
  -re {LAUNCHER-RC=[0-9]+} {}
  timeout { puts stderr "the ES-DE launcher never returned"; exit 1 }
}
expect -re {\[retrogamer@emunix[^]]*\]\$ }

# The supported path: the CLI, on the console, with the target named.
send "echo retrogamer | sudo -S /usr/local/bin/emunix-install --target /dev/vdb --yes; echo INSTALL-RC=\$?\r"
expect {
  -re {INSTALL-RC=[0-9]+} {}
  timeout { puts stderr "the install never finished"; exit 1 }
}
expect -re {\[retrogamer@emunix[^]]*\]\$ }

# What the guest sees on the target now: new GUIDs, the stick's still the old ones.
send "echo INSTALLED-GUIDS:; sudo -n blkid /dev/vdb1 /dev/vdb2 /dev/vdb3 /dev/vdb4 /dev/vdb5; echo STICK-GUID: \$(lsblk -no PARTUUID /dev/vda2); echo GUIDS-END\r"
expect -re {GUIDS-END}
expect -re {\[retrogamer@emunix[^]]*\]\$ }

after 2000
send "echo retrogamer | sudo -S poweroff\r"
expect {
  eof {}
  timeout { puts stderr "the VM did not power off after the install"; exit 1 }
}
exit 0
EXPECT
RC=$?
set -e
[ "$RC" -eq 0 ] || { echo "FAIL: boot 1 / install did not complete (expect rc=$RC)" >&2; echo "transcript: $LOG" >&2; exit 1; }

# --- Between the boots: what install did to the target, read from the host.
fail() { echo "FAIL: $*" >&2; echo "transcript: $LOG" >&2; exit 1; }
TARGET_A=$(uuid_of "$TARGET" rootfs_a)
[ -n "$TARGET_A" ] || fail "the target has no rootfs_a partition"
[ "$TARGET_A" != "$STICK_A" ] || fail "the target kept the stick's PARTUUIDs ($TARGET_A)"
echo "target rootfs_a PARTUUID after the install: $TARGET_A" | tee -a "$LOG"
# The target is 20 GiB apparent; its allocated size shows whether the zero-hole punching above worked.
echo "target file: apparent $(du -h --apparent-size "$TARGET" | cut -f1), on disk $(du -h "$TARGET" | cut -f1)" |
  tee -a "$LOG"
sgdisk -v "$TARGET" >"$WORK/verify" 2>&1 || true
cat "$WORK/verify" >>"$LOG"
grep -q 'No problems found' "$WORK/verify" ||
  fail "the target's GPT does not verify: $(grep -i 'problem' "$WORK/verify" | head -1)"

# --- Boot 2: the target alone, with a fresh NVRAM: nothing points at it, the ESP has to be found.
set +e
expect -f - "$TARGET" "$LOG" "$OVMF/OVMF_CODE.4m.fd" "$VARS2" "$ACCEL" <<'EXPECT'
set tgt   [lindex $argv 0]
set log   [lindex $argv 1]
set code  [lindex $argv 2]
set vars0 [lindex $argv 3]
set accel [lindex $argv 4]
set timeout 2400
log_file -a $log

spawn qemu-system-x86_64 -machine q35 -accel $accel -m 4096 -smp 4 -vga none \
  -device bochs-display -display none \
  -drive if=pflash,format=raw,readonly=on,file=$code \
  -drive if=pflash,format=raw,file=$vars0 \
  -drive file=$tgt,format=raw,if=virtio \
  -no-reboot -serial stdio
expect {
  -re {login: } { send "retrogamer\r" }
  -re {Bailing out|Kernel panic|No bootable device} { puts stderr "the installed disk did not boot"; exit 1 }
  timeout { puts stderr "no login prompt on the installed disk"; exit 1 }
}
expect -re {[Pp]assword: }
send "retrogamer\r"
expect {
  -re {\[retrogamer@emunix[^]]*\]\$ } {}
  timeout { puts stderr "no shell on the installed disk"; exit 1 }
}
send "for i in \$(seq 60); do case \$(systemctl is-active firstboot) in inactive) break;; esac; sleep 2; done; echo TARGET-FIRSTBOOT: \$(systemctl is-active firstboot); echo TARGET-BOOT-READY\r"
expect -re {TARGET-BOOT-READY}
expect -re {\[retrogamer@emunix[^]]*\]\$ }

send "echo retrogamer | sudo -S -v 2>/dev/null; echo BOOT2-ROOT: \$(findmnt -no SOURCE,TARGET /); echo BOOT2-CMDLINE: \$(cat /proc/cmdline); echo BOOT2-SLOT: \$(sudo -n emunix-slot status | tr '\\n' ' '); echo BOOT2-ETC: \$(findmnt -no TARGET,FSTYPE,OPTIONS /etc); echo BOOT2-STORAGE-BYTES: \$(findmnt -bno SIZE /storage); echo BOOT2-DF: \$(df -h /storage | tail -1); echo BOOT2-ENTRY-A: \$(sudo -n cat /boot/loader/entries/emunix-a.conf | tr '\\n' ' '); echo BOOT2-FIRSTBOOT: \$(sudo -n journalctl -b -u firstboot --no-pager | grep -E 'grew|CHANGED' | tr '\\n' ' '); echo BOOT2-DISK: \$(sudo -n lsblk -no NAME,SIZE,PARTLABEL /dev/vda | tr '\\n' ' '); echo BOOT2-END\r"
expect -re {BOOT2-END}
expect -re {\[retrogamer@emunix[^]]*\]\$ }

after 2000
send "echo retrogamer | sudo -S poweroff\r"
expect {
  eof {}
  timeout { puts stderr "the VM did not power off after boot 2"; exit 1 }
}
exit 0
EXPECT
RC=$?
set -e
[ "$RC" -eq 0 ] || { echo "FAIL: the installed disk did not verify (expect rc=$RC)" >&2; echo "transcript: $LOG" >&2; exit 1; }

# --- The claims, read back out of the transcript.
grep -q 'INSTALL-RC=0' "$LOG" || fail "emunix-install did not exit 0"
grep -q 'LAUNCHER-RC=1' "$LOG" || fail "the ES-DE launcher did not refuse to install"
grep -q 'emunix-install: no console to confirm on' "$LOG" ||
  fail "the ES-DE launcher did not say why it stopped (is the sudoers entry accepted?)"
grep -q 'install-to-disk.sh' "$LOG" || fail "the install entry was not seeded into /storage/roms/install"
grep -q 'emunix-install: target  /dev/vdb' "$LOG" || fail "the plan the launcher printed did not name the target"
grep -q 'emunix-install: done on /dev/vdb' "$LOG" || fail "the installer did not report the target done"
grep -q 'emunix-install: power off, remove the USB stick' "$LOG" || fail "the closing instruction is missing"
grep -q 'STICK-FIRSTBOOT: inactive' "$LOG" || fail "the stick's first boot did not finish before the install"
grep -q "BOOT2-ROOT: /dev/vda2 /" "$LOG" || fail "the installed disk did not boot from its own root"
grep -qi "BOOT2-CMDLINE: .*root=PARTUUID=$TARGET_A" "$LOG" ||
  fail "the installed system did not boot the loader entry with the target's PARTUUID"
grep -q 'BOOT2-SLOT: active: a ' "$LOG" || fail "the installed system is not on slot a"
grep -q 'BOOT2-ETC: /etc .* overlay .*upperdir=/var/lib/emunix/etc/upper' "$LOG" ||
  fail "/etc is not the writable overlay on the installed disk"
# 20 GiB target minus esp (512 MiB), two 5 GiB slots and var (2 GiB) is ~7.5 GiB of /storage.
BYTES=$(sed -n 's/.*BOOT2-STORAGE-BYTES: \([0-9][0-9]*\).*/\1/p' "$LOG" | tail -1)
[ -n "$BYTES" ] || fail "no /storage size in the transcript"
[ "$BYTES" -gt 7500000000 ] && [ "$BYTES" -lt 8300000000 ] ||
  fail "/storage is $BYTES bytes, not grown to the target's ~7.5 GiB"
grep -q 'BOOT2-FIRSTBOOT: .*CHANGED: partition=5' "$LOG" ||
  fail "the target's first boot did not grow the last partition"

echo "install test: stick -> /dev/vdb copied, GUIDs reset ($STICK_A -> $TARGET_A), installed disk boots slot a, /etc overlay up, /storage $BYTES bytes"
echo "transcript: $LOG"
