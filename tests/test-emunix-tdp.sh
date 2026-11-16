#!/usr/bin/env bash
# TDP profiles: the command applies the right asusctl/ryzenadj pair per profile and power
# source, remembers the choice across a reboot, defaults conservatively on battery, and
# never hands ryzenadj a thermal limit. Runs without root: asusctl and ryzenadj are stubs
# on PATH and every path comes from EMUNIX_TDP_PREFIX.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
TDP=$REPO/configs/rootfs/usr/local/bin/emunix-tdp
UNIT=$REPO/configs/rootfs/etc/systemd/system/emunix-tdp.service
SUDOERS=$REPO/configs/rootfs/etc/sudoers.d/30-emunix-tdp
POWER_DIR=$REPO/configs/rootfs/usr/share/emunix/power-profiles
SYSTEMS=$REPO/configs/rootfs/etc/emulationstation/es_systems.xml
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

stub() { # <name> [exit status]
  printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\nexit %s\n' "$1" "$TMP" "${2:-0}" >"$TMP/$1"
  chmod +x "$TMP/$1"
}
stub asusctl
stub ryzenadj

sandbox() { # <ac: 0|1|none> -> prints a fresh root; none removes the sysfs tree entirely
  local root
  root=$(mktemp -d "$TMP/root.XXXXXX")
  mkdir -p "$root/var/lib/emunix" "$root/sys/class/power_supply/AC"
  [ "$1" = none ] || printf '%s\n' "$1" >"$root/sys/class/power_supply/AC/online"
  printf '%s\n' "$root"
}

run() { # <root> [args...] -> exit status; leaves output in $TMP/out and calls in $TMP/calls
  local root=$1 rc
  shift
  : >"$TMP/calls"
  set +e
  EMUNIX_TDP_PREFIX="$root" PATH="$TMP:$PATH" "$TDP" "$@" >"$TMP/out" 2>&1
  rc=$?
  set -e
  return "$rc"
}

# 1. Artifacts: command, boot unit, ES-DE grant, menu scripts, system entry, package lists.
for f in "$TDP" "$UNIT" "$SUDOERS" "$POWER_DIR/quiet.sh" "$POWER_DIR/balanced.sh" \
  "$POWER_DIR/performance.sh"; do
  [ -f "$f" ] || fail "missing $f"
done
[ -x "$TDP" ] || fail "emunix-tdp is not executable"
grep -qx 'ExecStart=/usr/local/bin/emunix-tdp' "$UNIT" || fail "the boot unit does not run emunix-tdp"
grep -qx 'WantedBy=multi-user.target' "$UNIT" || fail "the boot unit is not enabled for multi-user"
grep -qx 'After=dbus.service' "$UNIT" ||
  fail "the boot unit does not order after dbus (asusd is D-Bus activated)"

# Exactly the three switch commands are granted, no wildcards.
[ "$(grep -c 'NOPASSWD' "$SUDOERS")" -eq 3 ] || fail "the ES-DE grant must allow exactly three commands"
for p in quiet balanced performance; do
  grep -qx "retrogamer ALL=(root) NOPASSWD: /usr/local/bin/emunix-tdp $p" "$SUDOERS" ||
    fail "the ES-DE grant for '$p' is missing"
done
grep -qF '*' "$SUDOERS" && fail "the ES-DE grant uses a wildcard" || true

# The menu entries switch to their own profile.
for p in quiet balanced performance; do
  grep -qx "exec sudo -n /usr/local/bin/emunix-tdp $p" "$POWER_DIR/$p.sh" ||
    fail "$p.sh does not switch to the $p profile"
done

# ES-DE scans the folder the power entries are seeded into.
grep -qx '        <name>power</name>' "$SYSTEMS" || fail "es_systems.xml has no power system"
grep -qx '        <path>%ROMPATH%/power</path>' "$SYSTEMS" || fail "the power system does not scan %ROMPATH%/power"

# Packages: ryzenadj from the pinned AUR list, telemetry for the acceptance measurement, and
# no power-profiles-daemon (it races asusd for the kernel platform_profile interface).
grep -qE '^ryzenadj [0-9a-f]{40}$' "$REPO/profiles/aur.txt" || fail "profiles/aur.txt has no pinned ryzenadj"
grep -q '^lm_sensors' "$REPO/profiles/handheld-common.txt" || fail "lm_sensors is not in the handheld package list"
grep -q '^power-profiles-daemon' "$REPO/profiles/handheld-common.txt" &&
  fail "power-profiles-daemon races asusd for platform_profile and must not ship" || true

# 2. Battery default: quiet, with the battery-side ceiling (the conservative one).
R=$(sandbox 0)
run "$R" || fail "a default apply should succeed"
[ "$(cat "$R/var/lib/emunix/tdp-profile")" = quiet ] || fail "the battery default was not quiet"
grep -qx 'ryzenadj --stapm-limit=8000 --fast-limit=8000 --slow-limit=8000' "$TMP/calls" ||
  fail "quiet-on-battery ceiling missing: $(tr '\n' '|' <"$TMP/calls")"
grep -qx 'asusctl profile set --ac Quiet' "$TMP/calls" || fail "the AC curve was not set"
grep -qx 'asusctl profile set --battery Quiet' "$TMP/calls" || fail "the battery curve was not set"
head -1 "$TMP/calls" | grep -q '^ryzenadj ' ||
  fail "the ceiling must be applied before the platform profile"
grep -q 'power source: battery' "$TMP/out" || fail "the status does not report the power source"
if grep -E '^ryzenadj ' "$TMP/calls" |
   grep -qE -- '--(tctl-temp|apu-skin-temp|dgpu-skin-temp|skin-temp-limit)'; then
  fail "ryzenadj was handed a thermal limit"
fi

# 3. AC default: balanced, with the AC-side ceiling.
R=$(sandbox 1)
run "$R" || fail "an AC default apply should succeed"
[ "$(cat "$R/var/lib/emunix/tdp-profile")" = balanced ] || fail "the AC default was not balanced"
grep -qx 'ryzenadj --stapm-limit=15000 --fast-limit=15000 --slow-limit=15000' "$TMP/calls" ||
  fail "balanced-on-AC ceiling missing: $(tr '\n' '|' <"$TMP/calls")"
grep -qx 'asusctl profile set --ac Balanced' "$TMP/calls" || fail "the AC curve was not set"
grep -qx 'asusctl profile set --battery Quiet' "$TMP/calls" || fail "the battery curve was not set"

# 4. An explicit profile applies both curves and stores the name.
R=$(sandbox 0)
run "$R" performance || fail "an explicit profile apply should succeed"
[ "$(cat "$R/var/lib/emunix/tdp-profile")" = performance ] || fail "the profile was not remembered"
grep -qx 'ryzenadj --stapm-limit=15000 --fast-limit=15000 --slow-limit=15000' "$TMP/calls" ||
  fail "performance-on-battery ceiling missing: $(tr '\n' '|' <"$TMP/calls")"
grep -qx 'asusctl profile set --ac Performance' "$TMP/calls" || fail "the AC curve was not set"
grep -qx 'asusctl profile set --battery Balanced' "$TMP/calls" || fail "the battery curve was not set"

# 5. The remembered profile survives a reboot: a fresh sandbox shares the /var state and a
#    different power source.
SRC=$(sandbox 1)
run "$SRC" performance || fail "seeding the remembered profile failed"
R2=$(sandbox 0)
cp "$SRC/var/lib/emunix/tdp-profile" "$R2/var/lib/emunix/"
run "$R2" || fail "reapplying a remembered profile failed"
[ "$(cat "$R2/var/lib/emunix/tdp-profile")" = performance ] || fail "the profile was forgotten"
grep -qx 'ryzenadj --stapm-limit=15000 --fast-limit=15000 --slow-limit=15000' "$TMP/calls" ||
  fail "after a reboot the battery side of performance was not applied"

# 6. No power_supply at all (a board with no battery): the conservative battery side.
R=$(sandbox none)
run "$R" || fail "a supply-less apply should succeed"
grep -qx 'ryzenadj --stapm-limit=8000 --fast-limit=8000 --slow-limit=8000' "$TMP/calls" ||
  fail "a board without AC reporting did not get the quiet ceiling"
[ "$(cat "$R/var/lib/emunix/tdp-profile")" = quiet ] || fail "the default was not the quiet profile"

# 7. Unknown profile: fails and stores nothing.
R=$(sandbox 0)
if run "$R" turbo; then fail "an unknown profile must fail"; fi
[ ! -e "$R/var/lib/emunix/tdp-profile" ] || fail "a failed apply stored a profile"

# 8. Too many arguments: usage error.
R=$(sandbox 0)
if run "$R" quiet extra; then fail "too many arguments must fail"; fi

# 9. A failing platform profile still leaves the ceiling applied, and is not remembered.
printf '#!/bin/sh\necho "asusctl $*" >>"%s/calls"\nexit 1\n' "$TMP" >"$TMP/asusctl"
chmod +x "$TMP/asusctl"
R=$(sandbox 1)
if run "$R" balanced; then fail "a failing asusctl must fail the command"; fi
grep -qx 'ryzenadj --stapm-limit=15000 --fast-limit=15000 --slow-limit=15000' "$TMP/calls" ||
  fail "the ceiling was not applied before asusctl failed"
[ ! -e "$R/var/lib/emunix/tdp-profile" ] || fail "a partially applied profile was remembered"
stub asusctl

echo "tdp: profiles, power-source curves, reboot persistence, thermal limits and grants OK"
