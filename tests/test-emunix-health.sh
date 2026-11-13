#!/usr/bin/env bash
# emunix-health's decisions without a disk: begin opens an attempt, a boot that reaches
# multi-user is remembered as having booted, two boots in a row that never get there trip the
# rollback, and a boot that got there forgives the previous one. Every privileged command is a
# stub. The rollback must clear the count before touching the loader so it cannot cascade.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
HEALTH=$HERE/../configs/rootfs/usr/local/bin/emunix-health
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fail() { echo "FAIL: $*" >&2; exit 1; }

STATE=$TMP/state
LOG=$TMP/log
cat >"$TMP/slot" <<'STUB'
#!/bin/sh
echo "slot $*" >>"$STUB_LOG"
case ${1:-} in
  active) printf '%s\n' "${STUB_ACTIVE:-a}" ;;
  next) [ -n "${STUB_NEXT_FAIL:-}" ] && exit 1
        printf 'default: emunix-%s.conf (slot %s)\n' "${2:-}" "${2:-}" ;;
  bad) [ -n "${STUB_BAD_FAIL:-}" ] && exit 1
       printf 'bad: slot %s\n' "${2:-}" ;;
  *) exit 1 ;;
esac
STUB
cat >"$TMP/reboot" <<'STUB'
#!/bin/sh
echo "reboot $*" >>"$STUB_LOG"
[ -n "${STUB_REBOOT_FAIL:-}" ] && exit 1
exit 0
STUB
chmod +x "$TMP/slot" "$TMP/reboot"

run() { # [VAR=value ...] -- <emunix-health args>
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env "${envs[@]}" PATH="$TMP:$PATH" EMUNIX_STATE_DIR="$STATE" EMUNIX_UPDATE_LOG="$LOG" \
    EMUNIX_SLOT_BIN="$TMP/slot" EMUNIX_REBOOT="$TMP/reboot" STUB_LOG="$TMP/calls" "$HEALTH" "$@"
}

attempts() { cat "$STATE/boot-attempts" 2>/dev/null || echo 0; }
reached() { cat "$STATE/reached" 2>/dev/null || echo 0; }
calls() { cat "$TMP/calls" 2>/dev/null || true; }

# 1. The first boot of a device opens attempt 1 and is not yet a rollback.
mkdir -p "$STATE"
run -- begin | grep -qx 'boot attempt 1 of 2' || fail "begin did not report attempt 1"
[ "$(attempts)" = 1 ] || fail "begin did not write 1"
[ "$(reached)" = 0 ] || fail "begin marked the boot as reaching multi-user"
run -- check || fail "check failed at attempt 1"

# 2. Two boots in a row that never reach multi-user trip the rollback.
run -- begin >/dev/null
[ "$(attempts)" = 2 ] || fail "the second begin did not write 2"
if run -- check >/dev/null 2>"$TMP/err"; then fail "check passed at attempt 2"; fi
grep -q 'did not reach multi-user; rolling back' "$TMP/err" ||
  fail "check did not explain the rollback: $(cat "$TMP/err")"
grep -q 'attempt 2 did not reach multi-user' "$LOG" || fail "check did not log the rollback"

# 3. A boot that reaches multi-user marks itself; clear forgets everything after the settle window.
run -- reached | grep -qx 'multi-user.target reached' || fail "reached did not report"
[ "$(reached)" = 1 ] || fail "reached did not write the marker"
[ "$(attempts)" = 2 ] || fail "reached changed the attempt count"
run -- clear | grep -qx 'boot completed; attempt counter clear' || fail "clear did not report"
[ "$(attempts)" = 0 ] || fail "clear did not reset the attempts"
[ "$(reached)" = 0 ] || fail "clear did not reset the marker"
run -- check || fail "check failed after a clear"

# 4. A boot that reached multi-user forgives the boots before it: this is what keeps a device that
#    was switched off during boot (or right after the first-boot password prompt) from putting a
#    healthy next boot at risk of a rollback.
printf '2\n' >"$STATE/boot-attempts"
printf '1\n' >"$STATE/reached"
run -- begin | grep -qx 'boot attempt 1 of 2' || fail "a reached boot did not restart the count"
[ "$(attempts)" = 1 ] || fail "the forgiven boot left attempts at $(attempts)"
[ "$(reached)" = 0 ] || fail "the forgiven boot kept the old marker"
run -- check || fail "check failed after a forgiven boot"

# 5. A missing or unparsable counter reads as zero, never as a failure.
printf 'garbage\n' >"$STATE/boot-attempts"
[ "$(run -- begin)" = "boot attempt 1 of 2" ] || fail "an unparsable counter was not treated as zero"
rm -f "$STATE/boot-attempts" "$STATE/reached"
run -- begin >/dev/null
[ "$(attempts)" = 1 ] || fail "a missing counter was not treated as zero"

# 6. rollback clears both files, points the loader at the other slot, marks this one bad, reboots.
: >"$TMP/calls"
run -- begin >/dev/null; run -- begin >/dev/null   # two boots that never reached multi-user
run STUB_ACTIVE=b -- rollback || fail "rollback failed"
[ "$(attempts)" = 0 ] || fail "rollback left the attempts at $(attempts)"
[ "$(reached)" = 0 ] || fail "rollback left the reached marker"
grep -qx 'slot active' "$TMP/calls" || fail "rollback did not ask which slot is running"
grep -qx 'slot next a' "$TMP/calls" || fail "rollback did not point the loader at slot a"
grep -qx 'slot bad b' "$TMP/calls" || fail "rollback did not mark slot b bad"
grep -qx 'reboot --no-block reboot' "$TMP/calls" || fail "rollback did not reboot"
grep -q 'slot b did not boot; default is emunix-a.conf' "$LOG" ||
  fail "rollback did not log the switch"

# 7. A slot that is neither a nor b stops the rollback instead of guessing; the counter is already
#    clear, so the next boot cannot roll back again by itself.
: >"$TMP/calls"
if run STUB_ACTIVE=c -- rollback >/dev/null 2>"$TMP/err"; then fail "rollback accepted an unknown slot"; fi
grep -q "not a or b" "$TMP/err" || fail "the refusal was not explained: $(cat "$TMP/err")"
[ "$(attempts)" = 0 ] || fail "a refused rollback still changed the attempts"
grep -q '^reboot' "$TMP/calls" && fail "a refused rollback rebooted"

# 8. A loader flip that fails stops the rollback before the reboot (no loop, no half-switched slot).
: >"$TMP/calls"
if run STUB_ACTIVE=b STUB_NEXT_FAIL=1 -- rollback >/dev/null 2>"$TMP/err"; then
  fail "rollback ignored a failed loader flip"
fi
grep -q 'could not point the loader' "$TMP/err" || fail "the loader failure was not explained: $(cat "$TMP/err")"
grep -qx 'slot next a' "$TMP/calls" || fail "the failed flip was not attempted"
grep -q '^slot bad' "$TMP/calls" && fail "a failed flip still marked the slot bad"
grep -q '^reboot' "$TMP/calls" && fail "a failed flip still rebooted"

echo "emunix-health: attempts counted, a reached boot forgives, rollback flips and reboots safely"
