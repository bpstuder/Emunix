#!/usr/bin/env bash
# Unit tests for the update decision. Plain bash on purpose: no test framework in the image build.
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

if [ "$fails" -ne 0 ]; then
  printf '%d test(s) failed\n' "$fails" >&2
  exit 1
fi
printf 'all tests passed\n'
