#!/usr/bin/env bash
# emunix-health's decisions without a disk: begin increments the counter, check fails only at the
# threshold, clear forgets the attempts, and rollback clears the counter before touching the loader
# so a failed rollback cannot cascade into another one. Every privileged command is a stub.
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

count() { cat "$STATE/boot-attempts" 2>/dev/null || echo 0; }
calls() { cat "$TMP/calls" 2>/dev/null || true; }

# 1. begin counts boots: the first boot after a cleared count is 1, the next is 2.
[ "$(count)" = 0 ] || fail "a fresh state already has a counter"
run -- begin | grep -qx 'boot attempt 1 of 2' || fail "begin did not report attempt 1"
[ "$(count)" = 1 ] || fail "begin did not write 1"
run -- begin >/dev/null
[ "$(count)" = 2 ] || fail "the second begin did not write 2"
grep -q 'boot attempt 1 of 2' "$LOG" || fail "begin did not log"

# 2. A missing, unreadable or unparsable counter reads as zero, never as a failure.
printf 'garbage\n' >"$STATE/boot-attempts"
[ "$(run -- begin)" = "boot attempt 1 of 2" ] || fail "an unparsable counter was not treated as zero"
rm -f "$STATE/boot-attempts"
run -- begin >/dev/null
[ "$(count)" = 1 ] || fail "a missing counter was not treated as zero"

# 3. check passes below the threshold and fails at it; the failure is the OnFailure trigger.
run -- check || fail "check failed at attempt 1"
run -- begin >/dev/null
if run -- check >/dev/null 2>"$TMP/err"; then fail "check passed at attempt 2"; fi
grep -q 'did not complete; rolling back' "$TMP/err" || fail "check did not explain the rollback: $(cat "$TMP/err")"
grep -q 'attempt 2 did not complete' "$LOG" || fail "check did not log the rollback"

# 4. clear forgets the attempts after a completed boot.
run -- clear | grep -qx 'boot completed; attempt counter clear' || fail "clear did not report"
[ "$(count)" = 0 ] || fail "clear did not reset the counter"
run -- check || fail "check failed after a clear"

# 5. rollback clears the count, points the loader at the other slot, marks this one bad, reboots.
: >"$TMP/calls"
run -- begin >/dev/null; run -- begin >/dev/null   # two unfinished attempts
run STUB_ACTIVE=b -- rollback || fail "rollback failed"
[ "$(count)" = 0 ] || fail "rollback left the counter at $(count)"
grep -qx 'slot active' "$TMP/calls" || fail "rollback did not ask which slot is running"
grep -qx 'slot next a' "$TMP/calls" || fail "rollback did not point the loader at slot a"
grep -qx 'slot bad b' "$TMP/calls" || fail "rollback did not mark slot b bad"
grep -qx 'reboot --no-block reboot' "$TMP/calls" || fail "rollback did not reboot"
grep -q 'slot b did not boot; default is emunix-a.conf' "$LOG" ||
  fail "rollback did not log the switch"

# 6. A slot that is neither a nor b stops the rollback instead of guessing; the counter is already
#    clear, so the next boot cannot roll back again by itself.
: >"$TMP/calls"
if run STUB_ACTIVE=c -- rollback >/dev/null 2>"$TMP/err"; then fail "rollback accepted an unknown slot"; fi
grep -q "not a or b" "$TMP/err" || fail "the refusal was not explained: $(cat "$TMP/err")"
[ "$(count)" = 0 ] || fail "a refused rollback still changed the counter"
grep -q '^reboot' "$TMP/calls" && fail "a refused rollback rebooted"

# 7. A loader flip that fails stops the rollback before the reboot (no loop, no half-switched slot).
: >"$TMP/calls"
if run STUB_ACTIVE=b STUB_NEXT_FAIL=1 -- rollback >/dev/null 2>"$TMP/err"; then
  fail "rollback ignored a failed loader flip"
fi
grep -q 'could not point the loader' "$TMP/err" || fail "the loader failure was not explained: $(cat "$TMP/err")"
grep -qx 'slot next a' "$TMP/calls" || fail "the failed flip was not attempted"
grep -q '^slot bad' "$TMP/calls" && fail "a failed flip still marked the slot bad"
grep -q '^reboot' "$TMP/calls" && fail "a failed flip still rebooted"

echo "emunix-health: attempts counted, check trips at the threshold, rollback flips and reboots safely"
