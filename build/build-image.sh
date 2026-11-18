#!/usr/bin/env bash
# M0: build a flashable x86_64 disk image — GPT (esp + rootfs_a/b + var + home),
# systemd-boot, one user. Run as root on an Arch host or the archlinux CI container.
# Requires: gptfdisk, dosfstools, e2fsprogs, btrfs-progs, arch-install-scripts.
set -euo pipefail
[ "$(id -u)" -eq 0 ] || { echo "build-image.sh must run as root (loop devices, mounts)" >&2; exit 1; }

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SCRIPT_DIR")
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-loop.sh
. "$SCRIPT_DIR/lib-loop.sh"

ARCH_SNAPSHOT="${ARCH_SNAPSHOT:-latest}"   # YYYY/MM/DD to pin archive.archlinux.org
DEVICE="${DEVICE:-}"                       # e.g. rog-ally -> profiles/handhelds/rog-ally.txt
VERSION="${VERSION:-$(date -u +%Y.%m.0)}" # <year>.<month>.<patch>; a release tag overrides it
SOURCE_DATE_EPOCH="${SOURCE_DATE_EPOCH:-$(date -u -d "$ARCH_SNAPSHOT" +%s 2>/dev/null || date -u +%s)}"
WORK="${WORK:-$REPO/work}"
OUT="${OUT:-$REPO/out}"
TOTAL_SIZE="${TOTAL_SIZE:-24G}"
export SOURCE_DATE_EPOCH

mkdir -p "$WORK" "$OUT"
IMG="$OUT/emunix-$VERSION-x86_64.img"
rm -f "$IMG" "$IMG.sha256"

# 1. GPT per configs/partition-layout.md.
truncate -s "$TOTAL_SIZE" "$IMG"
sgdisk --clear \
  --new=1:0:+1G --typecode=1:EF00 --change-name=1:esp \
  --new=2:0:+8G --typecode=2:8300 --change-name=2:rootfs_a \
  --new=3:0:+8G --typecode=3:8300 --change-name=3:rootfs_b \
  --new=4:0:+2G --typecode=4:8300 --change-name=4:var \
  --new=5:0:0   --typecode=5:8300 --change-name=5:home \
  "$IMG" >/dev/null

LOOP=$(attach_image "$IMG")
MNT="$WORK/mnt"
mkdir -p "$MNT"
cleanup() {
  set +e
  umount -R "$MNT" 2>/dev/null
  losetup -d "$LOOP" 2>/dev/null
}
trap cleanup EXIT

mkfs.vfat -F32 -n ESP "${LOOP}p1" >/dev/null
mkfs.ext4 -q -L rootfs_a "${LOOP}p2"
mkfs.ext4 -q -L rootfs_b "${LOOP}p3"
mkfs.btrfs -q -L var "${LOOP}p4"
mkfs.btrfs -q -L home "${LOOP}p5"

mount "${LOOP}p2" "$MNT"
mkdir -p "$MNT/boot" "$MNT/var" "$MNT/home" "$MNT/storage"
mount -o umask=0077 "${LOOP}p1" "$MNT/boot"
mount "${LOOP}p4" "$MNT/var"
mount "${LOOP}p5" "$MNT/home"
btrfs subvolume create "$MNT/home/storage" >/dev/null
mount -o subvol=storage "${LOOP}p5" "$MNT/storage"

# 2. Packages: base + handheld-common + the device profile, if one is named.
PROFILES=("$REPO/profiles/base.txt" "$REPO/profiles/handheld-common.txt")
if [ -n "$DEVICE" ]; then
  DEVICE_PROFILE="$REPO/profiles/handhelds/$DEVICE.txt"
  [ -f "$DEVICE_PROFILE" ] || { echo "unknown DEVICE=$DEVICE (no $DEVICE_PROFILE)" >&2; exit 1; }
  PROFILES+=("$DEVICE_PROFILE")
fi
mapfile -t PKGS < <(sed 's/#.*//; s/[[:space:]]*$//' "${PROFILES[@]}" | grep -v '^[[:space:]]*$')

# ARCH_SNAPSHOT pins every repo to one archive day ($repo/$arch are mirrorlist variables).
PACARGS=()
if [ "$ARCH_SNAPSHOT" != "latest" ]; then
  # pacman expands $repo/$arch from the mirrorlist, the shell must not.
  # shellcheck disable=SC2016
  printf 'Server = https://archive.archlinux.org/repos/%s/$repo/os/$arch\n' "$ARCH_SNAPSHOT" >"$WORK/mirrorlist"
  sed "s|^Include *= */etc/pacman.d/mirrorlist$|Include = $WORK/mirrorlist|" /etc/pacman.conf >"$WORK/pacman.conf"
  grep -qF "$WORK/mirrorlist" "$WORK/pacman.conf" ||
    { echo "ARCH_SNAPSHOT: no mirrorlist Include line in /etc/pacman.conf" >&2; exit 1; }
  PACARGS=(-C "$WORK/pacman.conf")
fi
pacstrap "${PACARGS[@]}" -c "$MNT" "${PKGS[@]}"

# 2b. Repo-owned files: the session, its units, the ES-DE seed. The tree mirrors the image root;
# --no-preserve=ownership because the build host's uid must not leak into the image.
cp -a --no-preserve=ownership "$REPO/configs/rootfs/." "$MNT/"

# udev rules live in their own tree (configs/udev) and are installed as drop-ins.
install -d "$MNT/etc/udev/rules.d"
install -m 0644 "$REPO"/configs/udev/*.rules "$MNT/etc/udev/rules.d/"

# The updater and its verification library live in build/ (they are developed and lint-tested
# next to the other build scripts) and are installed into the image like any repo-owned file.
install -D -m 0755 "$REPO/build/os-updater.sh" "$MNT/usr/local/bin/emunix-os-updater"
install -D -m 0644 "$REPO/build/lib-update.sh" "$MNT/usr/local/lib/emunix/lib-update.sh"

# The image's own pacman.conf is written from the template below, never copied from the build
# host: whatever a host has configured (CI container, a developer's box) would otherwise ship
# inside every published release image, and a private host repository can carry a credential in
# its Server URL. pacstrap above still uses the host configuration; only this file differs.
cat >"$MNT/etc/pacman.conf" <<'EOF'
# Written by build/build-image.sh, not taken from the build host. The official repositories the
# image installs from; [emunix] is appended during the build.
[options]
HoldPkg     = pacman glibc
Architecture = auto
CacheDir    = /var/cache/pacman/pkg/
SigLevel    = Required DatabaseOptional
LocalFileSigLevel = Optional

[core]
Include = /etc/pacman.d/mirrorlist

[extra]
Include = /etc/pacman.d/mirrorlist
EOF

# [emunix] repo: the image build installs the keyring, ryzenadj, freeimage and
# emulationstation-de from it with signature checking on. The public half is committed; the
# private half never enters the image.
# EMUNIX_REPO_URL is the published Pages URL; a file:// URL is bind-mounted so a local
# repository can be used (tests, mirrors).
REPO_URL=${EMUNIX_REPO_URL:-https://bpstuder.github.io/Emunix/}
case "$REPO_URL" in
  file:///*)
    REPO_LOCAL=${REPO_URL#file://}
    [ -d "$REPO_LOCAL" ] || { echo "EMUNIX_REPO_URL: $REPO_LOCAL is not a directory" >&2; exit 1; }
    install -d -m 0755 "$MNT/var/cache/emunix-repo"
    mount --bind "$REPO_LOCAL" "$MNT/var/cache/emunix-repo"
    REPO_URL=file:///var/cache/emunix-repo
    ;;
esac
export REPO_URL
install -d -m 0755 "$MNT/root/emunix-keyring"
install -m 0644 "$REPO/packages/emunix-keyring/emunix.gpg" "$MNT/root/emunix-keyring/emunix.gpg"
install -m 0644 "$REPO/packages/emunix-keyring/emunix-trusted" "$MNT/root/emunix-keyring/emunix-trusted"

# 2c. AUR list for the chroot step: comment-stripped, so the chroot only parses "<name> <commit>".
# Only the packages not yet in packages/ are built here; freeimage and emulationstation-de moved
# to [emunix], so the list can be empty and the image then carries no AUR residue at all.
sed 's/#.*//' "$REPO/profiles/aur.txt" | { grep -v '^[[:space:]]*$' || true; } >"$WORK/aur.txt"
if [ -s "$WORK/aur.txt" ]; then
  # staging dir: arch-chroot mounts a tmpfs over /tmp, which would hide a file put there.
  cp "$WORK/aur.txt" "$MNT/root/aur.txt"
fi

# 3. fstab comes from the partition labels, not from a template.
tee "$MNT/etc/fstab" >/dev/null <<'EOF'
# Generated by build/build-image.sh; labels match configs/partition-layout.md.
PARTLABEL=rootfs_a /        ext4  ro,noatime                         0 1
PARTLABEL=esp      /boot    vfat  defaults,noatime,umask=0077           0 2
PARTLABEL=var      /var     btrfs defaults,noatime                   0 2
PARTLABEL=home     /home    btrfs defaults,noatime                   0 2
PARTLABEL=home     /storage btrfs defaults,noatime,subvol=storage    0 2
tmpfs              /tmp     tmpfs defaults,nosuid,nodev             0 0
EOF
echo "$VERSION" >"$MNT/etc/emunix-version"

arch-chroot "$MNT" /bin/bash -euo pipefail -s <<'CHROOT'
echo emunix >/etc/hostname
printf '127.0.0.1 localhost\n::1       localhost\n127.0.1.1 emunix.localdomain emunix\n' >/etc/hosts
ln -sf /usr/share/zoneinfo/UTC /etc/localtime
printf 'LANG=en_US.UTF-8\n' >/etc/locale.conf
printf 'KEYMAP=us\n' >/etc/vconsole.conf
sed -i 's/^#en_US.UTF-8 UTF-8/en_US.UTF-8 UTF-8/' /etc/locale.gen
locale-gen >/dev/null

systemd-id128 new >/etc/machine-id
# input: ES-DE reads controllers and the keyboard straight from /dev/input when it runs on KMSDRM
# without a compositor, and logind only hands those devices to a session manager, not to a plain
# user session. Single-user kiosk with autologin, so the tradeoff is intentional.
useradd -m -G wheel,input -s /bin/bash retrogamer
printf 'retrogamer:retrogamer\n' | chpasswd
printf '%%wheel ALL=(ALL:ALL) ALL\n' >/etc/sudoers.d/10-wheel
chmod 0440 /etc/sudoers.d/10-wheel
systemctl enable NetworkManager >/dev/null
systemctl enable getty@tty1.service >/dev/null
# First boot owns the disk resize, the /storage tree and the shipped password (card 05).
systemctl enable firstboot.service >/dev/null
# /etc gets an overlay early in every boot: the root stays read-only and config written at runtime
# (NetworkManager profiles, hostname) lands on /var instead.
systemctl enable emunix-etc-overlay.service >/dev/null
# Boot health: an attempt is counted before anything can fail, cleared after a boot that stays up,
# and two unfinished attempts in a row flip the loader back to the other slot (emunix-slot bad).
systemctl enable emunix-boot-attempt.service >/dev/null
systemctl enable emunix-boot-health.service >/dev/null
systemctl enable emunix-boot-clear.service >/dev/null
# Power: emunix-tdp applies the remembered profile at boot, clamping the package ceiling
# with ryzenadj. asusd needs no enabling: it is D-Bus activated by asusctl on first use.
systemctl enable emunix-tdp.service >/dev/null
# The signed-update check runs daily on AC power.
systemctl enable emunix-os-updater.timer >/dev/null

# [emunix] repo: trust the committed public half, add the stanza, then install the keyring,
# ryzenadj, freeimage and emulationstation-de from it. SigLevel is Required
# DatabaseRequired, so an unsigned or foreign-signed repository fails the build instead of
# shipping.
pacman-key --init >/dev/null
pacman-key --add /root/emunix-keyring/emunix.gpg >/dev/null
EMUNIX_FPR=$(awk -F: '/^[^#]/ {print $1; exit}' /root/emunix-keyring/emunix-trusted)
pacman-key --lsign-key "$EMUNIX_FPR" >/dev/null
rm -rf /root/emunix-keyring
grep -q '^\[emunix\]' /etc/pacman.conf ||
  printf '\n[emunix]\nServer = %s\nSigLevel = Required DatabaseRequired\n' "$REPO_URL" >>/etc/pacman.conf
# A single stalled download from the [emunix] host failed the whole 25-minute release build once
# (release run 44168273644: "Operation too slow" on emulationstation-de). Retry each of these two
# transactions once, so a flaky CDN costs 10 seconds instead of the build. pacman's own download
# timeout stays on: a dead mirror still fails the build rather than hanging for hours.
retry() { "$@" || { echo "retry: $* failed, retrying once" >&2; sleep 10; "$@"; }; }
retry pacman -Sy --noconfirm >/dev/null
retry pacman -S --noconfirm emunix-keyring ryzenadj freeimage emulationstation-de >/dev/null
pacman-key --list-keys "$EMUNIX_FPR" >/dev/null ||
  { echo "pacman-key does not list the emunix key" >&2; exit 1; }
# Prove the install came from [emunix], not from a leftover AUR build or the host: pacman
# resolves each of these to the emunix repository (freeimage and emulationstation-de are in
# no official repo, and there is no AUR step for them).
for p in emunix-keyring ryzenadj freeimage emulationstation-de; do
  [ "$(pacman -S --print-format '%r' "$p" 2>/dev/null)" = emunix ] ||
    { echo "$p does not resolve to [emunix]" >&2; exit 1; }
done

# AUR packages (profiles/aur.txt): built here as an unprivileged user, then the toolchain that
# built them is purged so the image ships no compiler.
if [ -s /root/aur.txt ]; then
  pacman -S --needed --noconfirm base-devel git >/dev/null
  useradd -m -d /build -s /bin/bash aurbuilder
  printf 'aurbuilder ALL=(ALL) NOPASSWD: ALL\n' >/etc/sudoers.d/20-aurbuilder
  chmod 0440 /etc/sudoers.d/20-aurbuilder
  while read -r name commit; do
    [ -n "$name" ] || continue
    [ -n "$commit" ] || { echo "profiles/aur.txt: $name has no pinned commit" >&2; exit 1; }
    echo "AUR: building $name at $commit"
    su - aurbuilder -c "
      set -e
      git clone --quiet https://aur.archlinux.org/$name.git /build/$name
      cd /build/$name && git checkout --quiet $commit
      makepkg --syncdeps --install --noconfirm
    " || { echo "AUR: $name failed to build" >&2; exit 1; }
  done </root/aur.txt
  rm -f /etc/sudoers.d/20-aurbuilder /root/aur.txt
  userdel -r aurbuilder
  # No compiler in the shipped image: base-devel is the meta package that holds the toolchain, so
  # drop it (and git), then everything nothing needs any more, i.e. the PKGBUILDs' makedepends.
  pacman -Rns --noconfirm --nosave base-devel git >/dev/null
  orphans=$(pacman -Qdtq || true)
  [ -z "$orphans" ] || pacman -Rns --noconfirm $orphans >/dev/null
fi
[ -x /usr/bin/es-de ] ||
  { echo "no /usr/bin/es-de: emulationstation-de was not installed from [emunix]" >&2; exit 1; }

# virtio_blk so the image boots under QEMU; no autodetect, the image is not the build host.
# amdgpu keeps early KMS on the handhelds without the kms hook, which drags every GPU driver's
# firmware (190 MB, mostly NVIDIA GSP blobs) into the ESP. This conf is hand-written, not Arch's
# default, so it pins COMPRESSION rather than leaning on mkinitcpio's own zstd default.
printf 'MODULES=(virtio_blk virtio_pci amdgpu)\nBINARIES=()\nFILES=()\nHOOKS=(base udev modconf keyboard keymap consolefont block filesystems fsck)\nCOMPRESSION="zstd"\nCOMPRESSION_OPTIONS=(-T0 -19)\n' >/etc/mkinitcpio.conf
mkinitcpio -P >/dev/null

bootctl --esp-path=/boot install >/dev/null
systemctl set-default multi-user.target >/dev/null
mkdir -p /boot/loader/entries
# systemd 262 entry ids carry the .conf suffix; an unprefixed default silently picks another entry.
printf 'default emunix-a.conf\ntimeout 3\n' >/boot/loader/loader.conf
for slot in a b; do
  printf 'title   Emunix (slot %s)\nlinux   /vmlinuz-linux\ninitrd  /initramfs-linux.img\noptions root=PARTLABEL=rootfs_%s ro rootfstype=ext4 quiet console=tty0 console=ttyS0,115200\n' \
    "$slot" "$slot" >"/boot/loader/entries/emunix-$slot.conf"
done
CHROOT

# Deterministic content timestamps; the fs superblocks still carry the build date.
for m in "$MNT" "$MNT/boot" "$MNT/var" "$MNT/home" "$MNT/storage"; do
  find "$m" -xdev -exec touch -h -d "@$SOURCE_DATE_EPOCH" {} +
done

cleanup
trap - EXIT
chmod 0644 "$IMG"
(cd "$OUT" && sha256sum "$(basename "$IMG")") >"$IMG.sha256"

echo "Built $IMG ($(du -h --apparent-size "$IMG" | cut -f1) apparent, $(du -h "$IMG" | cut -f1) on disk)"
echo "Version $VERSION, snapshot $ARCH_SNAPSHOT, device ${DEVICE:-none}"
