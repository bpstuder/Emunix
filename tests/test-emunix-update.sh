#!/usr/bin/env bash
# Signed update manifests: the genuine manifest+image is accepted, and each tamper is refused --
# a one-byte-modified manifest, a manifest signed with another key, an image whose sha256 differs.
# Key pairs are generated here with minisign -W and die with the temp dir.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../build/lib-update.sh
. "$HERE/../build/lib-update.sh"

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0

command -v minisign >/dev/null 2>&1 || { echo "FAIL: minisign is required" >&2; exit 1; }

# The tests must not depend on whatever /etc/emunix-version exists on the machine running them.
export EMUNIX_VERSION_FILE=$TMP/absent-version-file

minisign -G -W -p "$TMP/pub" -s "$TMP/key" >/dev/null
minisign -G -W -p "$TMP/other-pub" -s "$TMP/other-key" >/dev/null

head -c 65536 /dev/urandom >"$TMP/image.img"
SHA=$(sha256sum "$TMP/image.img" | awk '{print $1}')
SIZE=$(stat -c %s "$TMP/image.img")

write_manifest() { # <file> <version> <min_from>
  printf '{"channel":"stable","version":"%s","released":"2026-11-13T00:00:00Z","image":{"url":"https://example.com/emunix-x86_64.img","sha256":"%s","size":%s},"min_from":"%s"}\n' \
    "$2" "$SHA" "$SIZE" "$3" >"$1"
}

sign() { # <manifest> <key> <signature>
  minisign -S -W -s "$2" -m "$1" -x "$3" >/dev/null
}

say() { printf '%s\n' "$*"; }

expect_ok() { # <name> <cmd...>
  local name=$1 out rc
  shift
  out=$("$@" 2>&1); rc=$?
  say "$out"
  if [ "$rc" -eq 0 ]; then
    say "ok   $name"
  else
    say "FAIL $name: verifier refused it (exit $rc)"
    fails=$((fails + 1))
  fi
}

expect_refused() { # <name> <needle> <cmd...>
  local name=$1 needle=$2 out rc
  shift 2
  out=$("$@" 2>&1); rc=$?
  say "$out"
  if [ "$rc" -eq 0 ]; then
    say "FAIL $name: verifier accepted it"
    fails=$((fails + 1))
  elif [[ $out != *"$needle"* ]]; then
    say "FAIL $name: refusal did not mention \"$needle\""
    fails=$((fails + 1))
  else
    say "ok   $name"
  fi
}

write_manifest "$TMP/emunix.json" "2026.11.13" "2026.11.01"
sign "$TMP/emunix.json" "$TMP/key" "$TMP/emunix.json.minisig"

# The genuine manifest and image.
expect_ok "genuine manifest accepted" \
  check_update "$TMP/emunix.json" "$TMP/emunix.json.minisig" "$TMP/pub" "$TMP/image.img"

# (a) One byte changed in the signed manifest.
sed 's/stable/stablf/' "$TMP/emunix.json" >"$TMP/mangled.json"
cp "$TMP/emunix.json.minisig" "$TMP/mangled.json.minisig"
expect_refused "(a) one-byte-modified manifest rejected" "does not verify" \
  check_update "$TMP/mangled.json" "$TMP/mangled.json.minisig" "$TMP/pub" "$TMP/image.img"

# (b) The same manifest signed with a different key.
sign "$TMP/emunix.json" "$TMP/other-key" "$TMP/other.minisig"
expect_refused "(b) manifest signed with another key rejected" "does not verify" \
  check_update "$TMP/emunix.json" "$TMP/other.minisig" "$TMP/pub" "$TMP/image.img"

# (c) An image whose sha256 differs from the manifest.
cp "$TMP/image.img" "$TMP/corrupt.img"
printf 'x' >>"$TMP/corrupt.img"
expect_refused "(c) image with a different sha256 rejected" "sha256 mismatch" \
  check_update "$TMP/emunix.json" "$TMP/emunix.json.minisig" "$TMP/pub" "$TMP/corrupt.img"

# min_from is the downgrade floor: a target below it is refused even though it is "newer" than
# nothing (no installed version).
write_manifest "$TMP/flawed.json" "2026.11.09" "2026.11.10"
sign "$TMP/flawed.json" "$TMP/key" "$TMP/flawed.json.minisig"
expect_refused "target below min_from rejected" "older than min_from" \
  check_update "$TMP/flawed.json" "$TMP/flawed.json.minisig" "$TMP/pub"

# Fail closed on a correctly signed manifest that is missing a required field.
sed 's/,"min_from":"[^"]*"//' "$TMP/emunix.json" >"$TMP/nofield.json"
sign "$TMP/nofield.json" "$TMP/key" "$TMP/nofield.json.minisig"
expect_refused "signed manifest without min_from rejected" 'no usable "min_from"' \
  check_update "$TMP/nofield.json" "$TMP/nofield.json.minisig" "$TMP/pub"

# A device that already runs a newer build refuses the older candidate.
echo "2026.11.14" >"$TMP/local-version"
EMUNIX_VERSION_FILE=$TMP/local-version expect_refused "target older than the installed version rejected" "not newer" \
  check_update "$TMP/emunix.json" "$TMP/emunix.json.minisig" "$TMP/pub"

if [ "$fails" -ne 0 ]; then
  printf '%d test(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'all tests passed\n'
