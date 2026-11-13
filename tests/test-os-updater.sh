#!/usr/bin/env bash
# Unit tests for the update decision and for emunix-os-updater's safety rails. Plain bash on
# purpose: no test framework in the image build.
set -uo pipefail
DIR=$(cd "$(dirname "$0")/.." && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../build/lib-update.sh
. "$DIR/build/lib-update.sh"

fails=0
check() { # <name> <expected: update|stay> <local> <remote>
  local got
  if needs_update "$3" "$4"; then got=update; else got=stay; fi
  if [ "$got" = "$2" ]; then
    printf 'ok   %s\n' "$1"
  else
    printf 'FAIL %s: wanted %s, got %s (local=%s remote=%s)\n' "$1" "$2" "$got" "$3" "$4"
    fails=$((fails + 1))
  fi
}

check "equal versions stay"          stay   "2026.11.09" "2026.11.09"
check "newer day updates"            update "2026.11.09" "2026.11.10"
check "newer year updates"           update "2026.11.09" "2027.01.01"
check "older remote stays"           stay   "2026.11.10" "2026.11.09"
check "empty remote stays"           stay   "2026.11.09" ""
check "missing local version updates" update ""         "2026.11.09"
check "numeric, not lexical"         update "1.9"       "1.10"

# --- emunix-os-updater: every privileged command is a stub on PATH. ---
UPDATER=$DIR/build/os-updater.sh
UT=$(mktemp -d)
trap 'rm -rf "$UT"' EXIT
mkdir -p "$UT/bin" "$UT/cache" "$UT/parts"
command -v minisign >/dev/null 2>&1 || { echo "FAIL: minisign is required" >&2; exit 1; }

fail() { printf 'FAIL: %s\n' "$*" >&2; fails=$((fails + 1)); }

# The test manifest and image. The signature is generated here and dies with the temp dir.
minisign -G -W -p "$UT/pub" -s "$UT/key" >/dev/null
head -c 65536 /dev/urandom >"$UT/image.img"
SHA=$(sha256sum "$UT/image.img" | awk '{print $1}')
SIZE=$(stat -c %s "$UT/image.img")
manifest=$UT/emunix.json
printf '{"channel":"stable","version":"2026.11.13","released":"2026-11-13T00:00:00Z","image":{"url":"https://test.example/emunix-x86_64.img","sha256":"%s","size":%s},"min_from":"2026.11.01"}\n' \
  "$SHA" "$SIZE" >"$manifest"
minisign -S -W -s "$UT/key" -m "$manifest" -x "$UT/emunix.json.minisig" >/dev/null
printf '2026.11.11\n' >"$UT/version"

cat >"$UT/bin/curl" <<'STUB'
#!/bin/bash
out=""; url=""
while [ $# -gt 0 ]; do
  case $1 in
    -o) out=$2; shift 2 ;;
    -C) shift 2 ;;
    -*) shift ;;
    *) url=$1; shift ;;
  esac
done
case $url in
  */emunix.json.minisig) cat "$STUB_SIG" >"$out" ;;
  */emunix.json) cat "$STUB_MANIFEST" >"$out" ;;
  *) cat "$STUB_IMAGE" >"$out" ;;
esac
STUB
cat >"$UT/bin/dd" <<'STUB'
#!/bin/bash
if="" of=""
while [ $# -gt 0 ]; do
  case $1 in
    if=*) if=${1#if=} ;;
    of=*) of=${1#of=} ;;
  esac
  shift
done
echo "dd $if $of" >>"$STUB_LOG"
# A real block-device node cannot be written by cp in a test container; the log is the assertion.
[ -b "$of" ] || cp "$if" "$of"
STUB
cat >"$UT/bin/e2fsck" <<'STUB'
#!/bin/bash
echo "e2fsck $*" >>"$STUB_LOG"
exit "${STUB_FSCK_RC:-0}"
STUB
cat >"$UT/bin/df" <<'STUB'
#!/bin/bash
echo "Avail"
echo "${STUB_AVAIL:-2000000000}"
STUB
cat >"$UT/slot" <<'STUB'
#!/bin/bash
echo "slot $*" >>"$STUB_LOG"
case ${1:-} in
  active) printf '%s\n' "${STUB_ACTIVE:-a}" ;;
  next) printf 'default: emunix-%s.conf (slot %s)\n' "${2:-}" "${2:-}" ;;
  *) exit 1 ;;
esac
STUB
chmod +x "$UT/bin/curl" "$UT/bin/dd" "$UT/bin/e2fsck" "$UT/bin/df" "$UT/slot"

# The write tests need real block-device nodes for the updater's [ -b ] check.
CAN_WRITE=0
if [ "$(id -u)" -eq 0 ]; then
  if mknod "$UT/parts/rootfs_a" b 7 200 && mknod "$UT/parts/rootfs_b" b 7 201; then CAN_WRITE=1; fi
fi

# The active-slot lookup is expected; a write, a check or a loader flip is not.
privileged() { grep -q -e '^dd ' -e '^e2fsck ' -e '^slot next' "$UT/calls"; }

run_updater() { # [VAR=value ...] -- <args...>
  local envs=()
  while [ "$1" != "--" ]; do envs+=("$1"); shift; done
  shift
  env \
    PATH="$UT/bin:$PATH" \
    EMUNIX_LIB="$DIR/build/lib-update.sh" \
    EMUNIX_REPO_URL="https://test.example/emunix" \
    EMUNIX_CACHE_DIR="$UT/cache" \
    EMUNIX_UPDATE_PUBKEY="$UT/pub" \
    EMUNIX_VERSION_FILE="$UT/version" \
    EMUNIX_SLOT_BIN="$UT/slot" \
    EMUNIX_LOCK_FILE="$UT/lock" \
    EMUNIX_UPDATE_LOG="$UT/log" \
    EMUNIX_PARTITION_DIR="$UT/parts" \
    STUB_MANIFEST="$manifest" STUB_SIG="$UT/emunix.json.minisig" \
    STUB_IMAGE="$UT/image.img" STUB_LOG="$UT/calls" \
    "${envs[@]}" \
    "$UPDATER" "$@"
}

# 1. --dry-run prints the plan and calls nothing privileged.
: >"$UT/calls"
out=$(run_updater -- --dry-run) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "--dry-run exited $rc: $out"
printf '%s\n' "$out" | grep -q 'dry run: 2026.11.11 -> 2026.11.13' || fail "--dry-run did not print the versions: $out"
printf '%s\n' "$out" | grep -q 'url:    https://test.example/emunix-x86_64.img' || fail "--dry-run did not print the url: $out"
printf '%s\n' "$out" | grep -q "target: $UT/parts/rootfs_b" || fail "--dry-run did not print the inactive target: $out"
printf '%s\n' "$out" | grep -q 'bytes:  65536' || fail "--dry-run did not print the size: $out"
privileged && fail "--dry-run touched the slot: $(cat "$UT/calls")"

# 2. An active slot that is not a|b aborts before anything is fetched or written.
: >"$UT/calls"
out=$(run_updater STUB_ACTIVE=weird -- 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "an ambiguous active slot should abort"
printf '%s\n' "$out" | grep -q 'not a or b' || fail "the ambiguous-slot refusal was not shown: $out"
privileged && fail "an ambiguous slot still touched the slot: $(cat "$UT/calls")"

# 3. A manifest whose signature does not verify aborts before the download.
sed 's/stable/stablf/' "$manifest" >"$UT/mangled.json"
out=$(run_updater STUB_MANIFEST="$UT/mangled.json" -- 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a bad signature should abort"
printf '%s\n' "$out" | grep -q 'signature does not verify' || fail "the signature refusal was not shown: $out"
privileged && fail "a bad signature still touched the slot: $(cat "$UT/calls")"

# 4. A manifest that is not newer than the installed version is a no-op, not a failure.
printf '2026.11.13\n' >"$UT/version"
out=$(run_updater -- 2>&1) && rc=0 || rc=$?
[ "$rc" -eq 0 ] || fail "an up-to-date device should exit 0: $out"
printf '%s\n' "$out" | grep -q 'No update available' || fail "the up-to-date message was not shown: $out"
printf '2026.11.11\n' >"$UT/version"

# 5. An image whose sha256 differs aborts after the download, before the slot is written.
cp "$UT/image.img" "$UT/corrupt.img"
printf 'x' >>"$UT/corrupt.img"
: >"$UT/calls"
out=$(run_updater STUB_IMAGE="$UT/corrupt.img" -- 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a corrupt image should abort"
printf '%s\n' "$out" | grep -q 'does not match the manifest' || fail "the image refusal was not shown: $out"
privileged && fail "a corrupt image still touched the slot: $(cat "$UT/calls")"

# 6. Too little free space aborts before the download.
: >"$UT/calls"
out=$(run_updater STUB_AVAIL=1000 -- 2>&1) && rc=0 || rc=$?
[ "$rc" -ne 0 ] || fail "a full cache should abort"
printf '%s\n' "$out" | grep -q 'not enough free space' || fail "the free-space refusal was not shown: $out"
privileged && fail "a full cache still touched the slot: $(cat "$UT/calls")"

# 7. A second run while the lock is held is a no-op.
flock "$UT/lock" sleep 2 &
holder=$!
sleep 0.3
out=$(run_updater -- 2>&1) && rc=0 || rc=$?
wait "$holder"
[ "$rc" -eq 0 ] || fail "a concurrent run should be a no-op (rc=$rc): $out"
printf '%s\n' "$out" | grep -q 'is held' || fail "the concurrent-run message was not shown: $out"

# 8. A valid update writes the inactive slot, checks it, and flips the loader -- never the active.
if [ "$CAN_WRITE" -eq 1 ]; then
  : >"$UT/calls"
  out=$(run_updater -- 2>&1) && rc=0 || rc=$?
  [ "$rc" -eq 0 ] || fail "a valid update failed: $out"
  grep -q "dd $UT/cache/emunix-x86_64.img $UT/parts/rootfs_b" "$UT/calls" || fail "the inactive slot was not written: $(cat "$UT/calls")"
  grep -q 'e2fsck -f -y '"$UT/parts/rootfs_b" "$UT/calls" || fail "the written slot was not checked: $(cat "$UT/calls")"
  grep -q 'slot next b' "$UT/calls" || fail "the loader was not flipped: $(cat "$UT/calls")"
  grep -q "of=$UT/parts/rootfs_a" "$UT/calls" && fail "the active slot was written"
  printf '%s\n' "$out" | grep -q 'staged 2026.11.13 on slot b' || fail "the staging message was not shown: $out"
else
  printf 'skip: the write tests need root for block-device nodes\n'
fi

if [ "$fails" -ne 0 ]; then
  printf '%d test(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'all tests passed\n'
