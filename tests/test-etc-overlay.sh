#!/usr/bin/env bash
# emunix-etc-overlay's decision logic, without a disk or systemd: one upper directory on /var for
# the whole device (no root slot in the path), the mount carries index=off, the copy-up scratch and
# the machine-generated files are cleared before every mount, and a second run must not mount
# twice. Every privileged command is a stub on PATH.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
OVERLAY=$HERE/../configs/rootfs/usr/local/bin/emunix-etc-overlay
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

fail() { echo "FAIL: $*" >&2; exit 1; }

cat >"$TMP/findmnt" <<'EOF'
#!/bin/sh
for a in "$@"; do
  case $a in
    FSTYPE) printf '%s\n' "${ETC_FSTYPE:-}"; exit 0 ;;
  esac
done
exit 1
EOF
# find/rm/mount/mkdir record the call; the script only reads /etc, it never writes it here.
for c in find rm mount mkdir; do
  printf '#!/bin/sh\necho "%s $*" >>"%s/calls"\n' "$c" "$TMP" >"$TMP/$c"
done
chmod +x "$TMP"/findmnt "$TMP"/find "$TMP"/rm "$TMP"/mount "$TMP"/mkdir

run() { # [VAR=value ...]
  env "$@" PATH="$TMP:$PATH" "$OVERLAY" >>"$TMP/out" 2>&1
}

# 1. One upper for the device: the path has no root slot in it, whatever slot is running.
: >"$TMP/calls"
run || fail "a boot should mount the overlay"
grep -qx 'mkdir -p /var/lib/emunix/etc/upper /var/lib/emunix/etc/work' "$TMP/calls" ||
  fail "the device-wide upper and work directories were not created"
grep -qx 'find /var/lib/emunix/etc/work -mindepth 1 -delete' "$TMP/calls" ||
  fail "the copy-up scratch was not cleared"
grep -qx 'rm -f /var/lib/emunix/etc/upper/ld.so.cache /var/lib/emunix/etc/upper/.updated /var/lib/emunix/etc/upper/machine-id' "$TMP/calls" ||
  fail "the machine-generated files were not dropped"
grep -qx 'mount -t overlay overlay -o lowerdir=/etc,upperdir=/var/lib/emunix/etc/upper,workdir=/var/lib/emunix/etc/work,index=off /etc' "$TMP/calls" ||
  fail "the overlay was not mounted over /etc with index=off"

# 2. index=off is what lets the upper outlive the image it was written under: with the index on,
# overlayfs pins the upper to the lower's filesystem and a re-imaged slot fails with ESTALE.
grep '^mount ' "$TMP/calls" | grep -q 'index=off' ||
  fail "the mount does not pass index=off"

# 3. Already mounted (a restart of the unit): nothing to do, and no second mount.
: >"$TMP/calls"
run ETC_FSTYPE=overlay || fail "an existing overlay should be a no-op success"
if grep -q '^mount ' "$TMP/calls"; then fail "the overlay was mounted twice"; fi

# 4. A failed mount is a failure, not a silent success.
printf '#!/bin/sh\nexit 32\n' >"$TMP/mount"; chmod +x "$TMP/mount"
if run; then fail "a failed mount should exit non-zero"; fi

echo "etc-overlay: one upper for the device, index=off, scratch cleared, idempotent on restart OK"
