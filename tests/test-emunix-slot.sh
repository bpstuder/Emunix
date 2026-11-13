#!/usr/bin/env bash
# emunix-slot's decisions without a disk: the running slot comes from the root's partition label,
# status writes that slot out for os-updater and reports the pending state, next rewrites the
# loader default, once sets the loader's one-shot entry, and neither will point at a slot without
# a boot entry or with a filesystem e2fsck rejects. Every privileged command is a stub on PATH.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
SLOT=$HERE/../configs/rootfs/usr/local/bin/emunix-slot
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }
export TMPLOG=$TMP   # the stub scripts log their calls here

ESP=$TMP/esp
mkdir -p "$ESP/loader/entries"
printf 'title   Emunix (slot a)\noptions root=PARTLABEL=rootfs_a ro\n' >"$ESP/loader/entries/emunix-a.conf"
printf 'title   Emunix (slot b)\noptions root=PARTLABEL=rootfs_b ro\n' >"$ESP/loader/entries/emunix-b.conf"
printf 'default emunix-a.conf\ntimeout 3\n' >"$ESP/loader/loader.conf"

cat >"$TMP/findmnt" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case $a in
    SOURCE) echo "${ROOT_SOURCE:-/dev/vda2}"; exit 0 ;;
    FSTYPE) echo "${FS_TYPE:-}"; exit 0 ;;
  esac
done
exit 1
EOF
cat >"$TMP/lsblk" <<'EOF'
#!/bin/sh
echo "${ROOT_LABEL-rootfs_a}"
EOF
cat >"$TMP/e2fsck" <<'EOF'
#!/bin/sh
echo "$*" >>"$TMPLOG/e2fsck.calls"
[ -z "${FSCK_OUT:-}" ] || echo "$FSCK_OUT"
exit "${FSCK_RC:-0}"
EOF
cat >"$TMP/bootctl" <<'EOF'
#!/bin/sh
echo "$*" >>"$TMPLOG/bootctl.calls"
if [ "$1" = status ]; then
  printf 'System:\n    Firmware: UEFI 2.8\n\nBoot Loader Interface:\n  Current Entry: emunix-a.conf\n  Default Entry: emunix-a.conf\n'
  [ -z "${ONESHOT:-}" ] || printf '  OneShot Entry: %s\n' "$ONESHOT"
fi
exit 0
EOF
chmod +x "$TMP"/findmnt "$TMP"/lsblk "$TMP"/e2fsck "$TMP"/bootctl

run() { # [VAR=value ...] -- <emunix-slot args>
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env "${envs[@]}" PATH="$TMP:$PATH" EMUNIX_ESP="$ESP" EMUNIX_RUN_DIR="$TMP/run" \
    EMUNIX_STATE_DIR="$TMP/state" "$SLOT" "$@"
}

# 1. The running slot comes from the root's partition label, and a root that is not a slot is
#    refused rather than guessed.
[ "$(run ROOT_LABEL=rootfs_b -- active)" = b ] || fail "the running slot was not read from the root label"
[ "$(run ROOT_SOURCE=/dev/nvme0n1p3 ROOT_LABEL=rootfs_a -- active)" = a ] ||
  fail "an nvme root was not handled"
for label in emunix "" rootfs_ /dev/mapper/cryptroot; do
  if run ROOT_LABEL="$label" -- active 2>/dev/null; then fail "a root labelled '$label' should be refused"; fi
done

# 2. status writes the running slot for os-updater and reports default + one-shot + bad.
out=$(run ROOT_LABEL=rootfs_a -- status) || fail "status failed"
[ "$out" = "$(printf 'active: a\ndefault: emunix-a.conf\noneshot: none\nbad: none')" ] ||
  fail "status printed '$out'"
[ "$(cat "$TMP/run/active_slot")" = a ] || fail "status did not write the running slot to active_slot"
out=$(run ROOT_LABEL=rootfs_b ONESHOT=emunix-a.conf -- status) || fail "status with a one-shot failed"
echo "$out" | grep -qx 'oneshot: emunix-a.conf' || fail "status lost the pending one-shot: $out"
echo "$out" | grep -qx 'active: b' || fail "status did not report slot b: $out"
[ "$(cat "$TMP/run/active_slot")" = b ] || fail "active_slot was not updated to b"

# 3. bad records the slot whose boots did not complete, and status reports it.
run -- bad b >/dev/null || fail "bad b failed"
[ "$(cat "$TMP/state/bad")" = b ] || fail "bad b did not write the marker"
out=$(run ROOT_LABEL=rootfs_a -- status) || fail "status after bad failed"
echo "$out" | grep -qx 'bad: b' || fail "status did not report the bad slot: $out"
run -- bad c >/dev/null 2>&1 && fail "bad c should be refused"
run -- bad >/dev/null 2>&1 && fail "bad without a slot should be refused"

# 4. next rewrites only the default line, keeps the rest of loader.conf, and checks the target
#    partition with e2fsck -fn.
: >"$TMP/e2fsck.calls"
run -- next b >/dev/null || fail "next b failed"
[ "$(cat "$ESP/loader/loader.conf")" = "$(printf 'default emunix-b.conf\ntimeout 3')" ] ||
  fail "next b left loader.conf as: $(cat "$ESP/loader/loader.conf")"
grep -qx -- '-fn /dev/disk/by-partlabel/rootfs_b' "$TMP/e2fsck.calls" ||
  fail "next b did not validate rootfs_b (e2fsck calls: $(cat "$TMP/e2fsck.calls"))"

# A loader.conf that has no default line yet gets one.
printf 'timeout 3\n' >"$ESP/loader/loader.conf"
run -- next a >/dev/null || fail "next a failed on a loader.conf without a default line"
grep -qx 'default emunix-a.conf' "$ESP/loader/loader.conf" || fail "next a did not add a default line"

# 5. A slot whose filesystem e2fsck rejects is refused, and loader.conf is left alone.
printf 'default emunix-a.conf\ntimeout 3\n' >"$ESP/loader/loader.conf"
if run ROOT_LABEL=rootfs_a FSCK_RC=4 FSCK_OUT='rootfs_b: Superblock invalid' -- next b >/dev/null 2>"$TMP/err"; then
  fail "next b accepted a slot that fails e2fsck"
fi
grep -q 'Superblock invalid' "$TMP/err" || fail "the e2fsck complaint was not shown"
grep -qx 'default emunix-a.conf' "$ESP/loader/loader.conf" || fail "a refused next still changed the default"

# 6. Nonsense arguments are refused: no slot at all, a slot that is not a|b, a slot with no entry.
run -- next >/dev/null 2>&1 && fail "next with no slot should fail"
run -- next c >/dev/null 2>&1 && fail "next c should fail"
run -- once "a b" >/dev/null 2>&1 && fail "a multi-word slot should fail"
mv "$ESP/loader/entries/emunix-b.conf" "$TMP/"
run -- next b >/dev/null 2>&1 && fail "a slot with no boot entry should fail"
mv "$TMP/emunix-b.conf" "$ESP/loader/entries/emunix-b.conf"

# 7. once hands the entry to the loader's one-shot variable and does not touch the default.
: >"$TMP/bootctl.calls"
run -- once b >/dev/null || fail "once b failed"
grep -qx 'set-oneshot emunix-b.conf' "$TMP/bootctl.calls" ||
  fail "once b did not call 'bootctl set-oneshot emunix-b.conf' (calls: $(cat "$TMP/bootctl.calls"))"
grep -qx 'default emunix-a.conf' "$ESP/loader/loader.conf" || fail "once b changed the default"

echo "emunix-slot: root label -> slot, status writes active_slot + pending, next/once validated, refusals OK"
