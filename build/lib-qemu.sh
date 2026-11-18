#!/usr/bin/env bash
# Shared guard for the tests that boot the image under QEMU.
#
# A guest here is 3-4 GiB of RAM with KVM, plus a second (20 GiB) disk image and the host's
# loop mounts. On a small host that is not a test, it is an outage: on porygon (12 GiB total) a
# worker started install-test.sh and drove the machine into swap (9.4 GiB of 11) with a load
# average of 83 until it was killed. Nothing about the test is wrong -- the host is.
#
# So the boot tests do not run unless the caller says the host can take it. CI sets the variable
# in the workflow; an agent on a small host cannot set it by accident, and gets a clear message
# instead of a wedged machine.

require_qemu_allowed() {
  [ "${EMUNIX_ALLOW_QEMU:-0}" = 1 ] && return 0
  cat >&2 <<'EOF'
refusing to boot the image under QEMU: this host has not been declared big enough for a guest.

  EMUNIX_ALLOW_QEMU=1 <script> ...      run it here, having checked `free -h` first
  (GitHub Actions sets it in .github/workflows/build.yml)

The boot tests stay in CI. Do not "try it once" on a host that is already the machine under
test -- 3-4 GiB of guest on 12 GiB of host has taken porygon down before.
EOF
  exit 78   # EX_CONFIG
}
