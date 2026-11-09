---
title: "Emunix — Immutable Arch-based Emulation OS"
date: 2026-11-08
tags: [project, emulation, arch, immutable]
source: dev-bot
type: project
project: Emunix
---

# Emunix — Immutable Arch-based Emulation OS (x86_64)

**Status:** Draft v1 — for review before repo creation
**Author:** dev-bot (with BP)
**Prior art reviewed:** REG Linux (immutable retro-gaming OS, x86_64 + ARM) — https://github.com/REG-Linux
**Date:** 2026-11-08

## 1. Goal

An immutable, Arch-based operating system for x86_64 handhelds (then desktops) that boots
straight into EmulationStation-DE, launching RetroArch cores or standalone emulators.
Reference points: SteamOS 3 (immutable, A/B, systemd-boot), ChimeraOS (Arch-based gaming OS),
Rocknix x86 fork (core pruning for AMD64), Batocera (frontend/UX expectations).

Non-goals for v1: ARM support, online multiplayer infrastructure, cloud sync, custom kernel.

## 2. Architecture

### 2.1 Immutability model (SteamOS 3 style)

- Two root partitions `rootfs_a` / `rootfs_b` (ext4 or btrfs), only one active.
- A separate `esp` (FAT32) holds kernels + initramfs + bootloader entries.
- A persistent `home`/`data` partition (btrfs recommended) mounted at `/home` and `/var/lib/...`,
  survives A/B swaps.
- Updates are image-based: download a new rootfs image, write to inactive slot, flip boot entry,
  reboot. Rollback = boot the other slot.
- Root filesystem is read-only at runtime (`ro` mount + overlay for `/var` and `/tmp`).

### 2.2 Boot chain

- UEFI only (handhelds are UEFI). `systemd-boot` (simple, matches SteamOS).
- Secure Boot: out of scope v1; document signing later.

### 2.3 Base

- Arch Linux (rolling). Pinned snapshot date for reproducible builds (Arch Linux Archive).
- Kernel: `linux` (mainline) for v1; evaluate `linux-zen` later. Include `linux-firmware`.
- Init: `systemd`, `mkinitcpio`.

## 3. Partition layout (GPT)

| # | Name        | FS     | Size      | Mount        | Notes                  |
|---|-------------|--------|-----------|--------------|------------------------|
| 1 | esp         | vfat   | 1 GiB     | /boot        | systemd-boot, kernels  |
| 2 | rootfs_a    | ext4   | 8 GiB     | / (ro)       | active slot            |
| 3 | rootfs_b    | ext4   | 8 GiB     | (inactive)   | update target          |
| 4 | var         | btrfs  | 2 GiB     | /var         | logs, pacman db, cache |
| 5 | home        | btrfs  | rest      | /home        | ROMs, saves, configs   |

ROMs live under `/home/deck/roms` (or `/home/gamer/roms`) on the persistent partition —
never on the rootfs, so updates never wipe them.

## 4. Package sets

### 4.1 Core system
`base`, `linux`, `linux-firmware`, `mkinitcpio`, `systemd`, `systemd-boot`, `btrfs-progs`,
`e2fsprogs`, `dosfstools`, `networkmanager`, `pipewire`, `pipewire-pulse`, `wireplumber`,
`bluez`, `bluez-utils`, `mesa`, `vulkan-radeon`, `vulkan-intel`, `libva`, `vulkan-tools`,
`gamemode`, `mangohud`, `gamescope`, `udev`, `sudo`, `polkit`.

### 4.2 Handheld support
`asusctl` (AUR), `rog-control-center` (AUR), `ryzenadj` (AUR), `power-profiles-daemon`,
udev rules for: Xbox/PS/Switch controllers, ROG Ally buttons, Steam Deck (future), SD cards.

### 4.3 Emulation
- RetroArch + cores: prefer `retroarch` from repos/AUR; cores as individual packages or a
  single `libretro-cores` bundle. Reuse the AMD64 pruning from the Rocknix x86 fork:
  drop ARM-only cores (amiberry, parallel-n64-lr, armsx2-sa, azahar-sa,
  yabasanshiro-pirry-sa, boom3-lr dep).
- Standalone: `dolphin-emu`, `pcsx2`, `rpcs3`, `ppsspp`, `mupen64plus`, `flycast`.
- Frontend: `emulationstation-de` (AUR).
- Tools: `scummvm`, `dosbox-staging`, `mame`.

### 4.4 Custom repo
A pacman repository hosted on GitHub Releases (or a static host) containing:
our PKGBUILDs for handheld tools, ES-DE config, default themes, and the updater daemon.
Clients add it to `/etc/pacman.conf`.

## 5. Image build pipeline

- **Tool:** custom script wrapping `pacstrap` + `arch-chroot`, producing a squashfs rootfs.
  (Alternative: `archiso` profiles, but archiso is live-ISO oriented; we want installed images.)
- **CI:** GitHub Actions on `ubuntu-latest` with `arch-chroot` via loop devices; or run on an
  Arch runner. Cross-compilation not needed (x86_64 builds on x86_64).
- **Artifacts:** `rootfs.img` (raw ext4), `boot.tar.zst` (kernel+initramfs), `image.zst`
  (full disk image for flashing).
- **Reproducibility:** pin Arch snapshot date; sort file lists; set SOURCE_DATE_EPOCH.

## 6. Update mechanism

- A small daemon `os-updater` (systemd service) checks the custom repo for a new
  `os-image` package; when present, downloads `rootfs.img`, writes to inactive slot,
  updates `/boot/loader/entries/*.conf`, sets next-boot flag, notifies ES-DE.
- Rollback: boot entry menu (systemd-boot) lets user pick the other slot; also auto-rollback
  if new slot fails to reach `multi-user.target` within N seconds (health check service).
- User data (`/home`, `/var`) is never touched by updates.

## 7. First-boot experience

- `firstboot.service` (systemd, `ConditionPathExists=!/var/lib/os/initialized`) creates user
  `gamer`, sets locale/timezone interactively, generates ES-DE config, resizes home partition
  to fill disk, marks initialized.
- ES-DE launches as a systemd user service on tty1 auto-login (getty autologin) or as a
  graphical session via `gamescope` compositor.

## 8. Repository layout (proposed)

```
os-image/
├── build/            # pacstrap + image assembly scripts
├── packages/         # PKGBUILDs (handheld tools, updater, es-de config)
├── profiles/         # base package lists, partition layout
├── configs/          # systemd units, udev rules, pacman.conf, fstab template
├── .github/workflows/build.yml
└── docs/
```

## 9. Risks / open questions

- Arch rolling base + immutable rootfs: pacman db lives on `/var` (persistent), but packages
  installed at image build time are baked into the read-only rootfs. Users cannot `pacman -S`
  at runtime unless we add a mutable overlay — decide: allow overlay or forbid. SteamOS forbids.
- AUR dependencies for handheld tools (asusctl) may lag or break; vendor them as PKGBUILDs
  in our repo with pinned sources.
- Gamescope + ES-DE on raw DRM vs. under a compositor: test early on ROG Ally.
- Image size: ~8 GiB rootfs is generous; aim for <4 GiB compressed.

## 10. Suggested v1 milestones

1. M0: bootable Arch image (no immutability) on ROG Ally, ES-DE launches. (1-2 weeks)
2. M1: A/B partition layout + systemd-boot + manual slot switching. (1 week)
3. M2: os-updater daemon + auto-rollback health check. (1-2 weeks)
4. M3: handheld power/TDP profiles + controller udev. (1 week)
5. M4: first real release image + flashing instructions. (1 week)

## 11. What I need from BP before scaffolding

1. Confirm immutable (A/B) vs. mutable-overlay decision (recommend A/B-only, SteamOS style).
2. Confirm user name (`gamer` vs `deck`) and home path for ROMs.
3. Confirm kernel choice (mainline vs linux-zen).
4. Confirm repo name and whether to host the pacman repo on GitHub Releases.

### Decisions (2026-11-08)

1. **Immutability model:** immutable A/B (SteamOS style) confirmed — no mutable overlay.
2. **User account:** username `retrogamer`. Default password equals username (`retrogamer`) — **weak default; must be changed on first boot / before any network exposure.**
3. **Storage layout:** ROMs, BIOS, saves, and states live under `/storage` on the persistent partition.
4. **Kernel:** mainline (`linux`) for v1, with selectability for future kernels (e.g. `linux-zen`) built in.
5. **Repository name:** TBD.

#### Security note — default password

The default account `retrogamer` ships with password `retrogamer`. This is a weak, publicly known default and must not be used in production. `firstboot.service` (or the image build) must force a password change on first login and refuse to proceed with the default; document this in flashing/install instructions. Treat any device still using the default as compromised.

Once these are settled, I'll scaffold the repo with M0 build scripts and a CI workflow.
