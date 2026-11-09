# Emunix

**Emunix** — an immutable, Arch-based Linux distribution for x86_64 handhelds (then desktops),
booting straight into EmulationStation-DE. Rolling Arch base, A/B rootfs slots, persistent
`/storage` for ROMs/bios/saves/states. See `INSTALL.md` for flashing and build instructions.


## Layout

- `build/` — image assembly scripts (pacstrap + arch-chroot)
- `packages/` — PKGBUILDs for handheld tools, updater, ES-DE config
- `profiles/` — base package lists, partition layout
- `configs/` — systemd units, udev rules, pacman.conf, fstab template
- `docs/` — design doc and milestones
- `.github/workflows/` — CI build pipeline

## Quick start (dev)

Requires an Arch host (or container) with `arch-install-scripts`, `squashfs-tools`, `qemu-img`.

```sh
./build/build-image.sh
```

Output lands in `out/`.
