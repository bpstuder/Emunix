#!/usr/bin/env bash
# Version decision for os-updater, kept separate so it can be tested without a system.
# Usage: needs_update <local> <remote>   -> exit 0 when remote is newer than local.

needs_update() {
  local local_ver="$1" remote_ver="$2" newest
  if [ -z "$remote_ver" ]; then return 1; fi
  if [ -z "$local_ver" ]; then return 0; fi
  if [ "$local_ver" = "$remote_ver" ]; then return 1; fi
  newest=$(printf '%s\n%s\n' "$local_ver" "$remote_ver" | sort -V | tail -n1)
  [ "$newest" = "$remote_ver" ]
}
