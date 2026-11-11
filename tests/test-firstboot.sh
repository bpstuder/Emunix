#!/usr/bin/env bash
# firstboot's decision logic, without a disk or a systemd: the shipped password must be replaced
# (from the prompt, or generated when nobody answers), the ROM tree must follow es_systems.xml,
# the root must be left read-only, and the marker must only appear when every step succeeded.
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
printf '#!/bin/sh\ncase "$*" in *pkname*) echo vda ;; *partn*) echo 5 ;; esac\n' >"$TMP/lsblk"
chmod +x "$TMP/lsblk"
stub growpart 0
stub btrfs 0
stub mount 0
stub chown 0
# chpasswd reads the "user:password" line from stdin; keep it for the assertions.
printf '#!/bin/sh\ncat >>"%s/passwords"\n' "$TMP" >"$TMP/chpasswd"; chmod +x "$TMP/chpasswd"

sandbox() { # <growpart status> -> fresh sandbox root, prints its path
  local root
  root=$(mktemp -d "$TMP/root.XXXXXX")
  mkdir -p "$root/etc/emulationstation" "$root/storage"
  printf '<systemList>\n  <system><name>nes</name><path>%%ROMPATH%%/nes</path></system>\n  <system><name>psx</name><path>%%ROMPATH%%/psx</path></system>\n</systemList>\n' \
    >"$root/etc/emulationstation/es_systems.xml"
  printf '#!/bin/sh\necho "growpart $*" >>"%s/calls"\nexit %s\n' "$TMP" "$1" >"$TMP/growpart"
  chmod +x "$TMP/growpart"
  echo "$root"
}

run() { # <root> [stdin file] -> runs firstboot against the sandbox
  EMUNIX_FIRSTBOOT_PREFIX=$1 EMUNIX_FIRSTBOOT_TTY="$TMP/tty" EMUNIX_FIRSTBOOT_TIMEOUT=1 \
    PATH="$TMP:$PATH" "$FIRSTBOOT" <"${2:-/dev/null}" >>"$TMP/out" 2>&1
}

# 1. Someone at the console types a password: it is the one that gets set.
ROOT=$(sandbox 0); : >"$TMP/passwords"; : >"$TMP/calls"; : >"$TMP/out"
printf 'chosenpw\n' >"$TMP/stdin"
run "$ROOT" "$TMP/stdin" || fail "a full first boot should succeed"
grep -qx 'retrogamer:chosenpw' "$TMP/passwords" || fail "the typed password was not set"
[ -f "$ROOT/var/lib/emunix/initialized" ] || fail "the marker was not written"
for d in roms roms/nes roms/psx bios saves states; do
  [ -d "$ROOT/storage/$d" ] || fail "/storage/$d was not created"
done
grep -q "chown -R retrogamer:retrogamer $ROOT/storage" "$TMP/calls" || fail "/storage was not handed to retrogamer"
grep -q 'mount -o remount,rw /' "$TMP/calls" || fail "the root was never remounted read-write"
grep -q 'mount -o remount,ro /' "$TMP/calls" || fail "the root was left writable"
grep -q "btrfs filesystem resize max $ROOT/storage" "$TMP/calls" || fail "btrfs was never grown"
grep -qx 'growpart /dev/vda 5' "$TMP/calls" ||
  fail "growpart was not called with the disk and the partition number"
if grep -q chosenpw "$TMP/out"; then fail "a typed password was written to the log"; fi

# 2. Nobody answers the prompt (headless, no keyboard): a generated password is set instead, and
#    the shipped one is gone.
ROOT=$(sandbox 0); : >"$TMP/passwords"; : >"$TMP/out"
run "$ROOT" /dev/null || fail "a first boot with no console answer should succeed"
pw=$(cut -d: -f2 "$TMP/passwords")
[ -n "$pw" ] || fail "no password was set"
[ "$pw" != retrogamer ] || fail "the shipped password survived an unanswered prompt"
[ "${#pw}" -eq 12 ] || fail "the generated password is not 12 characters: $pw"
grep -q "generated password for retrogamer: $pw" "$TMP/out" || fail "the generated password was not logged"
[ -f "$ROOT/var/lib/emunix/initialized" ] || fail "the marker was not written"

# 3. Already full device: growpart's NOCHANGE is not a failure.
ROOT=$(sandbox 1); : >"$TMP/passwords"
run "$ROOT" /dev/null || fail "NOCHANGE from growpart must not fail the unit"
[ -f "$ROOT/var/lib/emunix/initialized" ] || fail "the marker was not written after NOCHANGE"

# 4. A real growpart failure stops the run before the marker: the next boot retries.
ROOT=$(sandbox 2); : >"$TMP/passwords"
if run "$ROOT" /dev/null; then fail "a failed growpart should exit non-zero"; fi
[ ! -f "$ROOT/var/lib/emunix/initialized" ] || fail "the marker was written after a failure"

# 5. A failed password change must not mark the system initialized either.
ROOT=$(sandbox 0); : >"$TMP/passwords"
printf '#!/bin/sh\ncat >/dev/null\nexit 1\n' >"$TMP/chpasswd"; chmod +x "$TMP/chpasswd"
if run "$ROOT" /dev/null; then fail "a failed chpasswd should exit non-zero"; fi
[ ! -f "$ROOT/var/lib/emunix/initialized" ] || fail "the marker was written without a new password"
grep -q 'mount -o remount,ro /' "$TMP/calls" || fail "the root was left writable after a failed chpasswd"

echo "firstboot: prompt, generated password, ROM tree, read-only root and marker-last OK"
