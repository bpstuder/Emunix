# Emunix

**Emunix** — an immutable, Arch-based Linux distribution for x86_64 handhelds (then desktops),
booting straight into EmulationStation-DE. Rolling Arch base, A/B rootfs slots, persistent
`/storage` for ROMs/bios/saves/states. See `INSTALL.md` for flashing and build instructions.


## Layout

- `build/` — image assembly scripts (sgdisk + pacstrap + arch-chroot), boot test
- `profiles/` — base, handheld-common and per-device package lists (`DEVICE=rog-ally`)
- `configs/` — partition layout and udev rules
- `evidence/` — boot transcripts from the image test
- `.github/workflows/` — CI build pipeline

## Quick start (dev)

Requires an Arch host (or container) with `gptfdisk`, `dosfstools`, `btrfs-progs`, `e2fsprogs`
and `arch-install-scripts`.

```sh
sudo DEVICE=rog-ally ./build/build-image.sh       # out/emunix-<date>-x86_64.img + .sha256
sudo ./build/verify-image.sh out/emunix-*-x86_64.img
sudo ./build/boot-test.sh out/emunix-*-x86_64.img  # QEMU + OVMF, login on ttyS0
```

Output lands in `out/` (a 24 GiB GPT disk image, sparse on disk; override with `TOTAL_SIZE`).
