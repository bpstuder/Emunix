#!/usr/bin/env bash
# Update decision and signed-manifest verification for Emunix, kept separate so it can be tested
# without a system or a device.
#
#   needs_update <local> <remote>                   -> exit 0 when remote is newer than local
#   version_ge <a> <b>                              -> exit 0 when a sorts at or above b
#   manifest_string <manifest> <key>                -> print a string field, nothing if absent
#   manifest_number <manifest> <key>                -> print an integer field, nothing if absent
#   verify_manifest <manifest> <signature> <pubkey> -> exit 0 only when minisign accepts it
#   verify_image <image> <sha256> <size>            -> exit 0 when both match the file
#   check_update <manifest> <signature> <pubkey> [<image>]
#                                                   -> the whole gate; prints the verdict, exit 0/1
#
# check_update refuses, in order: unreadable inputs, a bad signature, a missing field, a sha256
# that is not 64 hex characters, a non-https image URL, another channel, a target below min_from,
# a target not newer than the installed version, and an image whose bytes do not match.

needs_update() {
  local local_ver="$1" remote_ver="$2" newest
  if [ -z "$remote_ver" ]; then return 1; fi
  if [ -z "$local_ver" ]; then return 0; fi
  if [ "$local_ver" = "$remote_ver" ]; then return 1; fi
  newest=$(printf '%s\n%s\n' "$local_ver" "$remote_ver" | sort -V | tail -n1)
  [ "$newest" = "$remote_ver" ]
}

version_ge() { # <a> <b>: exit 0 when a sorts at or above b
  local a="$1" b="$2" newest
  [ -n "$a" ] && [ -n "$b" ] || return 1
  [ "$a" = "$b" ] && return 0
  newest=$(printf '%s\n%s\n' "$a" "$b" | sort -V | tail -n1)
  [ "$newest" = "$a" ]
}

manifest_string() { # <manifest> <key>: print the value, nothing when absent
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\"\([^\"]*\)\".*/\1/p" "$1" 2>/dev/null | head -n1 || true
}

manifest_number() { # <manifest> <key>: print the integer, nothing when absent
  sed -n "s/.*\"$2\"[[:space:]]*:[[:space:]]*\([0-9]\+\).*/\1/p" "$1" 2>/dev/null | head -n1 || true
}

verify_manifest() { # <manifest> <signature> <pubkey>: exit 0 only on a valid signature
  command -v minisign >/dev/null 2>&1 ||
    { printf 'refused: minisign is not installed\n' >&2; return 1; }
  local out
  if ! out=$(minisign -V -p "$3" -x "$2" -m "$1" 2>&1); then
    printf 'refused: the manifest signature does not verify against %s\n%s\n' "$(basename "$3")" "$out" >&2
    return 1
  fi
}

verify_image() { # <image> <sha256> <size>: exit 0 only when the bytes match both
  local got
  got=$(sha256sum "$1" | awk '{print $1}')
  [ "$got" = "$2" ] ||
    { printf 'refused: image sha256 mismatch (manifest %s, file %s)\n' "$2" "$got" >&2; return 1; }
  got=$(stat -c %s "$1")
  [ "$got" = "$3" ] ||
    { printf 'refused: image size mismatch (manifest %s bytes, file %s bytes)\n' "$3" "$got" >&2; return 1; }
}

check_update() { # <manifest> <signature> <pubkey> [<image>]: the whole gate, exit 0/1
  local manifest=${1:?usage: check_update <manifest> <signature> <pubkey> [<image>]}
  local signature=${2:?} pubkey=${3:?} image=${4:-}
  local field value channel version released url sha256 size min_from installed

  for field in "$manifest" "$signature" "$pubkey"; do
    [ -r "$field" ] || { printf 'refused: %s is not readable\n' "$field" >&2; return 1; }
  done

  # The signature first: nothing parsed below is trusted until minisign accepts these exact bytes.
  verify_manifest "$manifest" "$signature" "$pubkey" || return 1

  for field in channel version released url sha256 size min_from; do
    if [ "$field" = size ]; then
      value=$(manifest_number "$manifest" "$field")
    else
      value=$(manifest_string "$manifest" "$field")
    fi
    [ -n "$value" ] || { printf 'refused: manifest has no usable "%s"\n' "$field" >&2; return 1; }
    printf -v "$field" '%s' "$value"
  done

  [[ $sha256 =~ ^[0-9a-f]{64}$ ]] ||
    { printf 'refused: "image.sha256" is not a sha256 hex digest\n' >&2; return 1; }
  case $released in
    ????-??-??T*) ;;
    *) printf 'refused: "released" is not a timestamp: %s\n' "$released" >&2; return 1 ;;
  esac
  case $url in
    https://*) ;;
    *) printf 'refused: "image.url" is not an https URL: %s\n' "$url" >&2; return 1 ;;
  esac
  case $channel in
    "${EMUNIX_CHANNEL:-stable}") ;;
    *) printf 'refused: channel "%s" is not "%s"\n' "$channel" "${EMUNIX_CHANNEL:-stable}" >&2; return 1 ;;
  esac

  version_ge "$version" "$min_from" || {
    printf 'refused: version %s is older than min_from %s (known-flawed range)\n' "$version" "$min_from" >&2
    return 1
  }
  installed=$(cat "${EMUNIX_VERSION_FILE:-/etc/emunix-version}" 2>/dev/null || true)
  if [ -n "$installed" ] && ! needs_update "$installed" "$version"; then
    printf 'refused: version %s is not newer than the installed %s\n' "$version" "$installed" >&2
    return 1
  fi

  if [ -n "$image" ]; then
    [ -r "$image" ] || { printf 'refused: %s is not readable\n' "$image" >&2; return 1; }
    verify_image "$image" "$sha256" "$size" || return 1
  fi

  printf 'accepted: version %s (%s channel, %s bytes, sha256 %s)\n' "$version" "$channel" "$size" "$sha256"
  return 0
}
