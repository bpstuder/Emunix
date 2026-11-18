#!/usr/bin/env bash
# The one lint + unit-test gate, shared by build.yml (every push) and release.yml (every
# tag): a release cannot pass a weaker gate than a push to main, and a new file or test
# is added in exactly one place. Runs as root inside archlinux:latest, which is where the
# lint and signing tools come from. build/pads-test.sh boots the image against a host
# evdev and stays a manual test.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
cd "$(dirname "$SCRIPT_DIR")"

pacman -Sy --noconfirm shellcheck minisign gnupg zstd >/dev/null

shellcheck -x build/*.sh tests/*.sh configs/rootfs/usr/local/bin/emunix-session \
  configs/rootfs/usr/local/bin/emunix-firstboot configs/rootfs/usr/local/bin/emunix-etc-overlay \
  configs/rootfs/usr/local/bin/emunix-slot configs/rootfs/usr/local/bin/emunix-health \
  configs/rootfs/usr/local/bin/emunix-pad-order configs/rootfs/usr/local/bin/emunix-tdp \
  configs/rootfs/usr/local/bin/emunix-install \
  configs/rootfs/usr/share/emunix/power-profiles/quiet.sh \
  configs/rootfs/usr/share/emunix/power-profiles/balanced.sh \
  configs/rootfs/usr/share/emunix/power-profiles/performance.sh \
  configs/rootfs/usr/share/emunix/install/*.sh \
  configs/rootfs/etc/skel/.bash_profile
bash -n build/*.sh tests/*.sh configs/rootfs/usr/local/bin/emunix-session \
  configs/rootfs/usr/local/bin/emunix-firstboot configs/rootfs/usr/local/bin/emunix-etc-overlay \
  configs/rootfs/usr/local/bin/emunix-slot configs/rootfs/usr/local/bin/emunix-health \
  configs/rootfs/usr/local/bin/emunix-pad-order configs/rootfs/usr/local/bin/emunix-tdp \
  configs/rootfs/usr/local/bin/emunix-install \
  configs/rootfs/usr/share/emunix/power-profiles/*.sh \
  configs/rootfs/usr/share/emunix/install/*.sh \
  configs/rootfs/etc/skel/.bash_profile

bash tests/test-os-updater.sh
bash tests/test-firstboot.sh
bash tests/test-emunix-install.sh
bash tests/test-etc-overlay.sh
bash tests/test-emunix-slot.sh
bash tests/test-emunix-health.sh
bash tests/test-emunix-update.sh
bash tests/test-session.sh
bash tests/test-emunix-tdp.sh
bash tests/test-emunix-pads.sh
bash tests/test-emunix-repo.sh

echo "ci-test: lint and unit tests passed"
