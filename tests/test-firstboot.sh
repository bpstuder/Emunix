#!/usr/bin/env bash
# firstboot's decision logic, without a disk or a systemd: the ROM tree must follow
# es_systems.xml, /storage must be handed to retrogamer, the shipped password must be left alone,
# and the marker must only appear when every step succeeded.
# Runs as root in CI, but touches nothing outside its own sandbox: every privileged command is a
# stub on PATH and every path comes from EMUNIX_FIRSTBOOT_PREFIX.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
FIRSTBOOT=$HERE/../configs/rootfs/usr/local/bin/emunix-firstboot
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

# Stubs: record the call, and let each test pick the exit status.
stub() { # <name> [exit status]
  printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\nexit %s\n' "$1" "$TMP" "${2:-0}" >"$TMP/$1"
  chmod +x "$TMP/$1"
}
# findmnt names the device of the /storage mount (btrfs reports the subvolume too); the sandbox has
# no mounts, and lsblk derives the disk and partition number growpart needs.
printf '#!/bin/sh\necho "/dev/vda5[/storage]"\n' >"$TMP/findmnt"; chmod +x "$TMP/findmnt"
printf '#!/bin/sh\ncase "$*" in *pkname*) echo vda ;; *partn*) echo 5 ;; *SIZE*) echo 29.8G ;; esac\n' >"$TMP/lsblk"
chmod +x "$TMP/lsblk"
stub growpart 0
stub btrfs 0
stub chown 0
# Both are stubs so the test can assert firstboot never calls them: there is no password step and
# no reason to make the root writable.
stub mount 0
stub chpasswd 0

sandbox() { # <growpart status> -> fresh sandbox root, prints its path
  local root
  root=$(mktemp -d "$TMP/root.XXXXXX")
  mkdir -p "$root/etc/emulationstation" "$root/storage" \
    "$root/usr/share/emunix/power-profiles" "$root/usr/share/emunix/install"
  printf '<systemList>\n  <system><name>nes</name><path>%%ROMPATH%%/nes</path></system>\n  <system><name>psx</name><path>%%ROMPATH%%/psx</path></system>\n  <system><name>power</name><path>%%ROMPATH%%/power</path></system>\n  <system><name>install</name><path>%%ROMPATH%%/install</path></system>\n</systemList>\n' \
    >"$root/etc/emulationstation/es_systems.xml"
  for s in quiet balanced performance; do
    printf '#!/bin/sh\nexit 0\n' >"$root/usr/share/emunix/power-profiles/$s.sh"
  done
  printf '#!/bin/sh\nexit 0\n' >"$root/usr/share/emunix/install/install-to-disk.sh"
  printf '#!/bin/sh\necho "growpart $*" >>"%s/calls"\nexit %s\n' "$TMP" "$1" >"$TMP/growpart"
  chmod +x "$TMP/growpart"
  echo "$root"
}

run() { # <root> [stdin file] -> runs firstboot against the sandbox
  : >"$TMP/tty1"
  EMUNIX_FIRSTBOOT_TTY=$TMP/tty1 EMUNIX_FIRSTBOOT_PREFIX=$1 PATH="$TMP:$PATH" "$FIRSTBOOT" \
    <"${2:-/dev/null}" >>"$TMP/out" 2>&1
}

# 1. A full first boot: the disk grows, /storage is seeded and handed over, the marker is last.
ROOT=$(sandbox 0); : >"$TMP/calls"; : >"$TMP/out"
run "$ROOT" || fail "a full first boot should succeed"
[ -f "$ROOT/var/lib/emunix/initialized" ] || fail "the marker was not written"
for d in roms roms/nes roms/psx bios saves states; do
  [ -d "$ROOT/storage/$d" ] || fail "/storage/$d was not created"
done
for s in quiet balanced performance; do
  [ -f "$ROOT/storage/roms/power/$s.sh" ] || fail "/storage/roms/power/$s.sh was not seeded"
done
[ -f "$ROOT/storage/roms/install/install-to-disk.sh" ] ||
  fail "/storage/roms/install/install-to-disk.sh was not seeded"
grep -q "chown -R retrogamer:retrogamer $ROOT/storage" "$TMP/calls" || fail "/storage was not handed to retrogamer"
grep -q "btrfs filesystem resize max $ROOT/storage" "$TMP/calls" || fail "btrfs was never grown"
grep -qx 'growpart /dev/vda 5' "$TMP/calls" ||
  fail "growpart was not called with the disk and the partition number"
if grep -q '^mount ' "$TMP/calls"; then fail "firstboot touched the mounts"; fi
if grep -q '^chpasswd' "$TMP/calls"; then fail "firstboot changed the shipped password"; fi

# The screen the user stares at: one line per phase, in order, the frontend line last, and the same
# lines on stdout - which firstboot.service sends to the journal and the console.
# Written with a shell comparison, not diff: archlinux:latest ships neither diff nor cmp.
expected=$(printf 'Emunix first boot: growing the disk to 29.8G...\nEmunix first boot: seeding /storage...\nEmunix first boot: done, starting the frontend')
[ "$(cat "$TMP/tty1")" = "$expected" ] || fail "the phase lines on tty1 are missing or out of order"
grep -qxF 'Emunix first boot: seeding /storage...' "$TMP/out" ||
  fail "the phase lines never reached stdout (journal+console)"

# 2. Already full device: growpart's NOCHANGE is not a failure.
ROOT=$(sandbox 1)
run "$ROOT" || fail "NOCHANGE from growpart must not fail the unit"
[ -f "$ROOT/var/lib/emunix/initialized" ] || fail "the marker was not written after NOCHANGE"

# 3. A real growpart failure stops the run before the marker: the next boot retries.
ROOT=$(sandbox 2)
if run "$ROOT"; then fail "a failed growpart should exit non-zero"; fi
[ ! -f "$ROOT/var/lib/emunix/initialized" ] || fail "the marker was written after a failure"

echo "firstboot: disk growth, /storage seeding, shipped password untouched and marker-last OK"
