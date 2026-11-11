#!/usr/bin/env bash
# emunix-etc-overlay's decision logic, without a disk or systemd: the overlay's upper directory
# must be keyed by the running root slot, a root that is not a slot must get no overlay at all,
# and a second run must not mount twice. Every privileged command is a stub on PATH.
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
    SOURCE) echo "${ROOT_SOURCE:-/dev/vda2}"; exit 0 ;;
  esac
done
exit 1
EOF
cat >"$TMP/lsblk" <<'EOF'
#!/bin/sh
echo "${ROOT_LABEL-rootfs_a}"
EOF
printf '#!/bin/sh\necho "mount $*" >>"%s/calls"\n' "$TMP" >"$TMP/mount"
printf '#!/bin/sh\necho "mkdir $*" >>"%s/calls"\n' "$TMP" >"$TMP/mkdir"
chmod +x "$TMP"/findmnt "$TMP"/lsblk "$TMP"/mount "$TMP"/mkdir

run() { # [VAR=value ...]
  env "$@" PATH="$TMP:$PATH" "$OVERLAY" >>"$TMP/out" 2>&1
}

# 1. Booting slot b puts the writes in b's own directories on /var.
: >"$TMP/calls"
run ROOT_LABEL=rootfs_b || fail "a rootfs_b root should get an overlay"
grep -qx 'mkdir -p /var/lib/emunix/overlay/etc/b/upper /var/lib/emunix/overlay/etc/b/work' "$TMP/calls" ||
  fail "the slot-b upper and work directories were not created"
grep -qx 'mount -t overlay overlay -o lowerdir=/etc,upperdir=/var/lib/emunix/overlay/etc/b/upper,workdir=/var/lib/emunix/overlay/etc/b/work /etc' "$TMP/calls" ||
  fail "the overlay was not mounted over /etc for slot b"

# 2. A root that is not a slot gets no writable /etc: better read-only than the wrong slot's config.
for label in emunix "" rootfs_ "/dev/mapper/cryptroot"; do
  : >"$TMP/calls"
  if run ROOT_LABEL="$label"; then fail "a root labelled '$label' should be refused"; fi
  if grep -q '^mount ' "$TMP/calls"; then fail "an overlay was mounted for the non-slot root '$label'"; fi
done

# 3. Already mounted (a restart of the unit): nothing to do, and no second mount.
: >"$TMP/calls"
run ETC_FSTYPE=overlay || fail "an existing overlay should be a no-op success"
if grep -q '^mount ' "$TMP/calls"; then fail "the overlay was mounted twice"; fi

# 4. The root device comes from the running mount, not a guess.
: >"$TMP/calls"
run ROOT_SOURCE=/dev/nvme0n1p3 ROOT_LABEL=rootfs_a || fail "an nvme root should get an overlay"
grep -q 'etc/a/upper' "$TMP/calls" || fail "slot a was not derived from the root label"

echo "etc-overlay: slot-keyed upper, non-slot root refused, idempotent on restart OK"
