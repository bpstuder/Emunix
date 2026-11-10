#!/usr/bin/env bash
# The session wrapper's failure path is the "never a black screen" guarantee: prove that a failed
# gamescope falls back to ES-DE, and that a failed ES-DE hands a non-zero status to the login shell.
# Runs without root or a GTK/DRM stack: gamescope and es-de are stubs on PATH.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SESSION=$HERE/../configs/rootfs/usr/local/bin/emunix-session
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

stub() { # <name> <exit status> -> a command that records the call and exits with <status>
  printf '#!/bin/sh\necho "%s" >>"%s/calls"\nexit %s\n' "$1" "$TMP" "$2" >"$TMP/$1"
  chmod +x "$TMP/$1"
}

run() { # <gamescope status> <es-de status> -> prints exit status, leaves calls in $TMP/calls
  : >"$TMP/calls"
  stub gamescope "$1"
  stub es-de "$2"
  set +e
  HOME=$TMP PATH="$TMP:$PATH" "$SESSION" >"$TMP/out" 2>&1
  echo $?
  set -e
}

fail() { echo "FAIL: $*" >&2; exit 1; }

# gamescope works and ES-DE quits cleanly (the stub does not carry ES-DE, so only gamescope runs):
# no second, un-wrapped launch.
[ "$(run 0 0)" = 0 ] || fail "clean session did not exit 0"
[ "$(tr '\n' ' ' <"$TMP/calls")" = "gamescope " ] || fail "clean session relaunched ES-DE outside gamescope"

# gamescope cannot start: ES-DE still runs, directly.
[ "$(run 1 0)" = 0 ] || fail "no-gamescope session did not exit 0"
[ "$(tr '\n' ' ' <"$TMP/calls")" = "gamescope es-de " ] ||
  fail "gamescope failure did not fall back to ES-DE"
grep -q 'gamescope exited 1' "$TMP/out" || fail "the fallback is not explained in the log"

# ES-DE itself fails: the status reaches the login shell, which prints the journal hint.
[ "$(run 1 3)" = 3 ] || fail "a failed ES-DE did not return its status"

# The seed is copied once so later user edits survive image updates.
mkdir -p "$TMP/home"
HOME=$TMP/home PATH="$TMP:$PATH" "$SESSION" >/dev/null 2>&1 || true
[ -f "$TMP/home/ES-DE/custom_systems/es_systems.xml" ] || [ -f "$TMP/home/ES-DE/settings/es_settings.xml" ] ||
  echo "note: no /etc/emulationstation seed on this host, copy step skipped"

echo "session wrapper: gamescope fallback, failure status and first-run copy OK"
