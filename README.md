# Emunix

**Emunix** — an immutable, Arch-based Linux distribution for x86_64 handhelds (then desktops),
booting straight into EmulationStation-DE. Rolling Arch base, A/B rootfs slots, persistent
`/storage` for ROMs/bios/saves/states. See `INSTALL.md` for flashing and build instructions.


## Layout

- `build/` — image assembly scripts (pacstrap + arch-chroot)
- `profiles/` — base and per-device package lists
- `configs/` — fstab template, partition layout, systemd-boot entries
- `.github/workflows/` — CI build pipeline

## Quick start (dev)

Requires an Arch host (or container) with `arch-install-scripts` and `e2fsprogs`.

```sh
./build/build-image.sh
```

Output lands in `out/`.
