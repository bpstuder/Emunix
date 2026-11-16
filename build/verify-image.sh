#!/usr/bin/env bash
# Assert a built Emunix disk image is what the build claims: GPT labels, systemd-boot on the
# ESP, the generated fstab, the user and machine-id. Needs root (loop device, mounts).
set -euo pipefail
IMG=${1:?usage: verify-image.sh <emunix.img>}
[ -f "$IMG" ] || { echo "FAIL: $IMG does not exist" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "FAIL: verify-image.sh must run as root (loop devices, mounts)" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-loop.sh
. "$SCRIPT_DIR/lib-loop.sh"

fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }
LOOP=$(attach_image "$IMG")
MNT=$(mktemp -d)
cleanup() {
  set +e
  umount -R "$MNT" 2>/dev/null
  losetup -d "$LOOP" 2>/dev/null
  rmdir "$MNT"
}
trap cleanup EXIT

# 1. Partition table.
for spec in 1:esp 2:rootfs_a 3:rootfs_b 4:var 5:home; do
  sgdisk --info="${spec%%:*}" "$IMG" | grep -q "Partition name: '${spec#*:}'" ||
    fail "partition ${spec%%:*} is not labelled ${spec#*:}"
done

# 2. ESP: bootloader, entries, kernel, initramfs.
mount -o ro "${LOOP}p1" "$MNT"
for f in EFI/systemd/systemd-bootx64.efi loader/loader.conf vmlinuz-linux initramfs-linux.img \
  loader/entries/emunix-a.conf loader/entries/emunix-b.conf; do
  [ -f "$MNT/$f" ] || fail "/$f missing from the ESP"
done
grep -q '^default emunix-a\.conf$' "$MNT/loader/loader.conf" || fail "loader.conf does not default to emunix-a.conf"
for slot in a b; do
  grep -q "root=PARTLABEL=rootfs_$slot ro" "$MNT/loader/entries/emunix-$slot.conf" ||
    fail "emunix-$slot.conf does not boot rootfs_$slot read-only"
done
# One template writes both entries: nothing but the slot may differ between them.
[ "$(sed 's/rootfs_a/rootfs_X/; s/ (slot a)/ (slot X)/' "$MNT/loader/entries/emunix-a.conf")" = \
  "$(sed 's/rootfs_b/rootfs_X/; s/ (slot b)/ (slot X)/' "$MNT/loader/entries/emunix-b.conf")" ] ||
  fail "emunix-a.conf and emunix-b.conf differ by more than the slot"
umount "$MNT"

# 3. rootfs_a: the generated fstab, the user, machine-id, the frontend, the session.
mount -o ro "${LOOP}p2" "$MNT"
for f in etc/fstab etc/machine-id etc/emunix-version etc/hostname usr/bin/retroarch \
  etc/pacman.conf etc/sudoers.d/10-wheel \
  etc/systemd/system/multi-user.target.wants/NetworkManager.service \
  usr/bin/es-de usr/lib/libretro/nestopia_libretro.so usr/bin/gamescope \
  usr/lib/libfreeimage.so \
  usr/local/bin/emunix-session etc/systemd/user/emunix-session.service \
  usr/local/bin/emunix-firstboot etc/systemd/system/firstboot.service \
  etc/systemd/system/multi-user.target.wants/firstboot.service usr/bin/growpart \
  usr/local/bin/emunix-slot usr/local/bin/emunix-etc-overlay etc/systemd/system/emunix-etc-overlay.service \
  etc/systemd/system/sysinit.target.wants/emunix-etc-overlay.service \
  usr/bin/minisign etc/emunix/update.pub usr/bin/zstd \
  usr/share/pacman/keyrings/emunix.gpg usr/share/pacman/keyrings/emunix-trusted \
  usr/local/bin/emunix-os-updater usr/local/lib/emunix/lib-update.sh \
  etc/systemd/system/emunix-os-updater.service etc/systemd/system/emunix-os-updater.timer \
  etc/systemd/system/timers.target.wants/emunix-os-updater.timer \
  etc/systemd/system/getty@tty1.service.d/autologin.conf \
  etc/systemd/system/getty.target.wants/getty@tty1.service \
  etc/emulationstation/es_settings.xml etc/emulationstation/es_systems.xml \
  etc/udev/rules.d/70-emunix-gamepads.rules etc/udev/rules.d/80-emunix-ally-buttons.rules \
  usr/share/emunix/gamecontrollerdb.txt usr/local/bin/emunix-pad-order \
  usr/local/bin/emunix-tdp etc/systemd/system/emunix-tdp.service \
  etc/systemd/system/multi-user.target.wants/emunix-tdp.service \
  etc/sudoers.d/30-emunix-tdp \
  usr/share/emunix/power-profiles/quiet.sh usr/share/emunix/power-profiles/balanced.sh \
  usr/share/emunix/power-profiles/performance.sh \
  usr/bin/asusd usr/lib/systemd/system/asusd.service \
  usr/share/dbus-1/system.d/asusd.conf \
  usr/bin/ryzenadj; do
  # -L too: the enabled unit is a symlink to an absolute path in the image, not in this host.
  [ -e "$MNT/$f" ] || [ -L "$MNT/$f" ] || fail "/$f missing from rootfs_a"
done
grep -q -- '--autologin retrogamer' "$MNT/etc/systemd/system/getty@tty1.service.d/autologin.conf" ||
  fail "tty1 autologin is not configured for retrogamer"
grep -q 'ROMDirectory.*"/storage/roms"' "$MNT/etc/emulationstation/es_settings.xml" ||
  fail "es_settings.xml does not point ES-DE at /storage/roms"
grep -q 'SDL_GAMECONTROLLERCONFIG_FILE=/usr/share/emunix/gamecontrollerdb.txt' \
  "$MNT/etc/systemd/user/emunix-session.service" ||
  fail "the session unit does not point SDL at the shipped gamecontrollerdb"
grep -q 'SDL_JOYSTICK_HIDAPI=1' "$MNT/etc/systemd/user/emunix-session.service" ||
  fail "the session unit does not keep SDL HIDAPI on"
grep -q '<name>power</name>' "$MNT/etc/emulationstation/es_systems.xml" ||
  fail "es_systems.xml has no power system for the ES-DE menu"
grep -qx 'retrogamer ALL=(root) NOPASSWD: /usr/local/bin/emunix-tdp quiet' \
  "$MNT/etc/sudoers.d/30-emunix-tdp" || fail "the ES-DE sudoers grant is missing"
# power-profiles-daemon must not ship: it races asusd for the platform_profile interface.
[ ! -e "$MNT/usr/bin/powerprofilesctl" ] ||
  fail "power-profiles-daemon is installed: it races asusd for platform_profile"
[ "$(grep -c 'platform:Linux' "$MNT/usr/share/emunix/gamecontrollerdb.txt")" -gt 0 ] ||
  fail "the shipped gamecontrollerdb has no Linux entries"
if find "$MNT/etc/udev/rules.d" -name '*.rules' -print0 |
   xargs -0 -r grep -h -v '^[[:space:]]*#' | grep -q 'MODE="0666"'; then
  fail "a udev rule world-writes a device (MODE=\"0666\")"
fi
# The AUR build toolchain must not survive into the image.
for f in usr/bin/gcc usr/bin/cmake usr/bin/make build etc/sudoers.d/20-aurbuilder root/aur.txt; do
  [ ! -e "$MNT/$f" ] || fail "/$f is build residue: the image ships a compiler"
done

# Update trust anchor: the image must carry BP's published public half byte for byte, and it must
# parse as a minisign Ed25519 public key. An image without it can never verify an update.
ANCHOR=$SCRIPT_DIR/../configs/rootfs/etc/emunix/update.pub
[ -f "$ANCHOR" ] || fail "no update trust anchor at $ANCHOR (BP's public half is missing)"
[ "$(sha256sum "$ANCHOR" | cut -d' ' -f1)" = "$(sha256sum "$MNT/etc/emunix/update.pub" | cut -d' ' -f1)" ] ||
  fail "/etc/emunix/update.pub is not the repo's trust anchor ($ANCHOR)"
[ "$(wc -l <"$MNT/etc/emunix/update.pub")" -eq 2 ] ||
  fail "/etc/emunix/update.pub is not a two-line minisign public key"
awk 'NR==2' "$MNT/etc/emunix/update.pub" | base64 -d | od -An -tx1 | grep -q '^ *45 64' ||
  fail "/etc/emunix/update.pub is not a minisign Ed25519 public key"

# [emunix] repo: the image trusts BP's committed public half and configures the repository
# with signature checking required, so an unsigned or foreign-signed repo cannot install.
grep -q '^\[emunix\]' "$MNT/etc/pacman.conf" || fail "pacman.conf has no [emunix] stanza"
grep -q '^SigLevel = Required DatabaseRequired$' "$MNT/etc/pacman.conf" ||
  fail "the [emunix] stanza does not require signatures"
awk '/^\[emunix\]/ {inrepo=1; next} /^\[/ {inrepo=0} inrepo && /^Server = / {found=1} END {exit !found}' \
  "$MNT/etc/pacman.conf" || fail "the [emunix] stanza has no Server line"
[ "$(sha256sum "$MNT/usr/share/pacman/keyrings/emunix.gpg" | cut -d' ' -f1)" = \
  "$(sha256sum "$SCRIPT_DIR/../packages/emunix-keyring/emunix.gpg" | cut -d' ' -f1)" ] ||
  fail "/usr/share/pacman/keyrings/emunix.gpg is not the committed public half"
[ "$(grep -c '^\[emunix\]' "$MNT/etc/pacman.conf")" -eq 1 ] ||
  fail "pacman.conf does not have exactly one [emunix] stanza"

grep -q '^PARTLABEL=rootfs_a / *ext4 *ro' "$MNT/etc/fstab" || fail "fstab has no read-only rootfs_a root"
grep -q '^PARTLABEL=var .* /var ' "$MNT/etc/fstab" || fail "fstab has no /var mount for the /etc overlay"
grep -q '^PARTLABEL=home .* /storage ' "$MNT/etc/fstab" || fail "fstab has no /storage subvolume"
grep -q '^retrogamer:' "$MNT/etc/passwd" || fail "user retrogamer missing"
grep -q '^wheel:.*retrogamer' "$MNT/etc/group" || fail "retrogamer is not in wheel"
[ -s "$MNT/etc/machine-id" ] || fail "machine-id is empty"
[ "$(readlink "$MNT/etc/systemd/system/default.target")" = /usr/lib/systemd/system/multi-user.target ] ||
  fail "default target is not multi-user.target"
umount "$MNT"

# 4. var: first boot has not run yet, so its unit must still fire on the flashed device.
mount -o ro "${LOOP}p4" "$MNT"
[ ! -e "$MNT/lib/emunix/initialized" ] ||
  fail "/var/lib/emunix/initialized is in the image: first boot would be skipped"
umount "$MNT"

# 5. home: the user's directory and the /storage subvolume live on their own partition.
mount -o ro "${LOOP}p5" "$MNT"
[ -d "$MNT/retrogamer" ] || fail "/home/retrogamer missing from the home partition"
grep -q 'emunix-session' "$MNT/retrogamer/.bash_profile" || fail "tty1 login does not start the session"
# Asset policy: no ROMs, BIOS or saves are baked into the image.
[ -d "$MNT/storage" ] || fail "/storage btrfs subvolume missing"
[ -z "$(ls -A "$MNT/storage")" ] || fail "/storage is not empty: the image ships content"

echo "verified $IMG: 5 labels, systemd-boot + 2 entries, kernel/initramfs, fstab + mounts, retrogamer, machine-id"
