#!/usr/bin/env bash
# Boot the image with a graphics device and prove the M0 session: tty1 auto-starts EmulationStation-DE
# with no manual command, and launching a system from its menu reaches RetroArch with the core loaded.
#
# Screenshots are taken through QEMU's QMP screendump; the serial console drives the keyboard for the
# menu and carries the transcript. Requires root (loop mount), qemu-system-x86, edk2-ovmf, expect,
# socat. Usage: session-test.sh <emunix.img> [evidence-dir]
set -euo pipefail
IMG=${1:?usage: session-test.sh <emunix.img> [evidence-dir]}
OUT=${2:-$(dirname "$0")/../evidence}
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "session-test.sh must run as root (loop mount)" >&2; exit 1; }
OVMF=/usr/share/edk2/x64
[ -f "$OVMF/OVMF_CODE.4m.fd" ] || { echo "edk2-ovmf is not installed ($OVMF)" >&2; exit 1; }
command -v expect socat >/dev/null || { echo "expect and socat are required" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-loop.sh
. "$SCRIPT_DIR/lib-loop.sh"
WORK=$(mktemp -d)
mkdir -p "$OUT"
LOG=$OUT/m0-session.log
rm -f "$OUT"/m0-session-*.png
trap 'umount -R "$WORK/mnt" 2>/dev/null || true; losetup -d "${LOOP:-}" 2>/dev/null || true; rm -rf "$WORK" || true' EXIT
: >"$LOG"

# The ROM tree is firstboot's (card 05) and is empty in this image. Seed it on a copy so the frontend
# has one system to show; the placeholder is 16 zero bytes, no ROM content, and never touches the
# image under test.
SPARSE=--sparse=always
cp "$SPARSE" "$IMG" "$WORK/boot.img"
LOOP=$(attach_image "$WORK/boot.img")
mkdir -p "$WORK/mnt"
mount "${LOOP}p5" "$WORK/mnt"
mkdir -p "$WORK/mnt/storage/roms/nes"
head -c 16 /dev/zero >"$WORK/mnt/storage/roms/nes/placeholder.nes"
umount "$WORK/mnt"
losetup -d "$LOOP"
unset LOOP

VARS=$WORK/OVMF_VARS.fd
cp "$OVMF/OVMF_VARS.4m.fd" "$VARS"
ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
SOCK=$WORK/qmp.sock

# Graphics device: bochs-display gives the guest a KMS device (/dev/dri/card0 via bochs-drm) that
# screendump can read. The virtio-gpu devices segfault QEMU 11.1.3 with -display none here, and
# without -vga none QEMU adds a second VGA adapter that screendump then captures instead.

set +e
expect -f - "$WORK/boot.img" "$LOG" "$OVMF/OVMF_CODE.4m.fd" "$VARS" "$ACCEL" "$SOCK" "$OUT" <<'EXPECT'
set img   [lindex $argv 0]
set log   [lindex $argv 1]
set code  [lindex $argv 2]
set vars  [lindex $argv 3]
set accel [lindex $argv 4]
set sock  [lindex $argv 5]
set out   [lindex $argv 6]
set timeout 1800
log_file $log

# One-shot QMP call: the capabilities handshake plus the command, over a fresh connection.
proc qmp {json} {
  global sock
  catch {exec socat -t 2 - UNIX-CONNECT:$sock << "{\"execute\":\"qmp_capabilities\"}\n$json\n"}
}
proc shot {name} {
  global out
  set path "$out/$name"
  # Software rendering under llvmpipe: retry before calling a frame blank.
  foreach wait {0 5000 10000} {
    after $wait
    qmp "{\"execute\":\"screendump\",\"arguments\":{\"filename\":\"$path\",\"format\":\"png\"}}"
    after 1500
    if {[file exists $path] && [file size $path] > 10000} {
      puts "screenshot: $path ([file size $path] bytes)"
      return
    }
  }
  puts stderr "$name looks blank ([file size $path] bytes)"
  exit 1
}
proc key {name} { qmp "{\"execute\":\"human-monitor-command\",\"arguments\":{\"command-line\":\"sendkey $name\"}}" }

spawn qemu-system-x86_64 -machine q35 -accel $accel -m 3072 -smp 4 -vga none \
  -device bochs-display -display none \
  -qmp unix:$sock,server,nowait \
  -drive if=pflash,format=raw,readonly=on,file=$code \
  -drive if=pflash,format=raw,file=$vars \
  -drive file=$img,format=raw,if=virtio -snapshot -no-reboot \
  -serial stdio
expect {
  -re {login: } { send "retrogamer\r" }
  -re {Bailing out|Kernel panic|No bootable device} { puts stderr "boot failed before userspace"; exit 1 }
  timeout { puts stderr "timeout waiting for the serial login prompt"; exit 1 }
}
expect -re {[Pp]assword: }
send "retrogamer\r"
expect {
  -re {\[retrogamer@emunix[^]]*\]\$ } {}
  timeout { puts stderr "no shell after login"; exit 1 }
}

# 1. The session started by itself on tty1: nothing was typed into the VM before this point.
send "export XDG_RUNTIME_DIR=/run/user/1000; for i in \$(seq 90); do pgrep -x es-de >/dev/null && break; sleep 2; done; echo EMUNIX-SESSION-STATE; systemctl --user is-active emunix-session; pgrep -a es-de; journalctl --user -b -u emunix-session --no-pager | tail -30; echo EMUNIX-SESSION-STATE-END\r"
expect {
  -re {EMUNIX-SESSION-STATE-END} {}
  timeout { puts stderr "the ES-DE session never started"; exit 1 }
}
expect -re {\[retrogamer@emunix[^]]*\]\$ }
after 8000
shot m0-session-es-de.png

# 2. Launch the one system from the menu: Enter opens the game list, Enter starts the game.
key ret
after 6000
shot m0-session-gamelist.png
key ret
after 6000

# 3. Prove the launch reached the core. RetroArch's own output is swallowed by the frontend and it
#    quits as soon as the content is rejected (no ROM may ship in the image), so the frontend's log
#    and a second launch with --log-file are what can be quoted.
send "sleep 12; echo EMUNIX-CORE-STATE; echo '--- frontend log:'; tail -8 /home/retrogamer/ES-DE/logs/es_log.txt; echo EMUNIX-CORE-STATE-END\r"
expect {
  -re {EMUNIX-CORE-STATE-END} {}
  timeout { puts stderr "no core state output"; exit 1 }
}
expect -re {\[retrogamer@emunix[^]]*\]\$ }

# 4. Same launch with RetroArch's log turned on: a test-only copy of the system entry adds the two
#    flags, the command and the content path are the shipped ones.
send "systemctl --user stop emunix-session; sleep 3; mkdir -p /home/retrogamer/ES-DE/settings /home/retrogamer/ES-DE/custom_systems; cp /etc/emulationstation/es_settings.xml /home/retrogamer/ES-DE/settings/; printf '%s' '<systemList><system><name>nes</name><fullname>Nintendo Entertainment System</fullname><path>%ROMPATH%/nes</path><extension>.nes .NES</extension><command>/usr/bin/retroarch --verbose --log-file=/tmp/core.log -L /usr/lib/libretro/nestopia_libretro.so %ROM%</command><platform>nes</platform><theme>nes</theme></system></systemList>' > /home/retrogamer/ES-DE/custom_systems/es_systems.xml; echo FIXTURE-READY\r"
expect {
  -re {FIXTURE-READY} {}
  timeout { puts stderr "could not write the logging fixture"; exit 1 }
}
expect -re {\[retrogamer@emunix[^]]*\]\$ }
send "systemctl --user restart emunix-session\r"
after 5000
send "for i in \$(seq 45); do pgrep -x es-de >/dev/null && break; sleep 2; done; sleep 15; echo EMUNIX-FIXTURE-STATE-END\r"
expect {
  -re {EMUNIX-FIXTURE-STATE-END} {}
  timeout { puts stderr "the fixture session did not start"; exit 1 }
}
expect -re {\[retrogamer@emunix[^]]*\]\$ }
key ret
after 8000
key ret
send "for i in \$(seq 45); do grep -q 'Loading dynamic libretro core' /tmp/core.log 2>/dev/null && break; sleep 2; done; sleep 5; echo EMUNIX-CORE-LOAD; grep -E 'Loading dynamic libretro core|Failed to load content|Libretro core requires content' /tmp/core.log; echo EMUNIX-CORE-LOAD-END\r"
expect {
  -re {EMUNIX-CORE-LOAD\r*\n(.*)EMUNIX-CORE-LOAD-END} {
    set block $expect_out(1,string)
    if {![string match "*nestopia_libretro.so*" $block]} {
      puts stderr "the frontend launch never reached the core: $block"; exit 1
    }
  }
  timeout { puts stderr "no core load output"; exit 1 }
}
expect -re {\[retrogamer@emunix[^]]*\]\$ }

# The transcript is complete; the caller stops the VM (expect cannot reap it from here).
exit 0
EXPECT
RC=$?
pkill -f "[q]emu-system-x86_64" || true
set -e
echo "session test transcript: $LOG"
echo "screenshots: $OUT/m0-session-*.png"
echo "expect exit: $RC"
# The expect run drives the VM; the acceptance evidence is what it left in the transcript.
grep -q 'Launching game' "$LOG" || { echo "FAIL: the frontend never launched a game" >&2; exit 1; }
grep -q 'Loading dynamic libretro core from: "/usr/lib/libretro/nestopia_libretro.so"' "$LOG" ||
  { echo "FAIL: the launch never reached the Nestopia core" >&2; exit 1; }
echo "session test: ES-DE autostarted, launched the NES system, RetroArch loaded nestopia_libretro.so"
