# Emunix

**Emunix** — an immutable, Arch-based Linux distribution for x86_64 handhelds (then desktops),
booting straight into EmulationStation-DE. Rolling Arch base, A/B rootfs slots, persistent
`/storage` for ROMs/bios/saves/states. See `INSTALL.md` for flashing and build instructions.


## Layout

- `build/` — image assembly (sgdisk + pacstrap + arch-chroot), AUR build, image and session boot tests
- `profiles/` — base, handheld-common and per-device package lists (`DEVICE=rog-ally`);
  `aur.txt` holds the AUR packages built in the chroot, pinned by commit
- `configs/rootfs/` — files copied into the image root (ES-DE session, its units, the ES-DE seed)
- `configs/` — partition layout
- `evidence/` — boot transcripts and screenshots from the image tests
- `update/` — the signed update manifest format, signing and signing-key custody
- `.github/workflows/` — CI build pipeline

## Quick start (dev)

Requires an Arch host (or container) with `gptfdisk`, `dosfstools`, `btrfs-progs`, `e2fsprogs`
and `arch-install-scripts`.

```sh
sudo DEVICE=rog-ally ./build/build-image.sh       # out/emunix-<date>-x86_64.img + .sha256
sudo ./build/verify-image.sh out/emunix-*-x86_64.img
sudo ./build/boot-test.sh out/emunix-*-x86_64.img  # QEMU + OVMF, login on ttyS0
sudo ./build/session-test.sh out/emunix-*-x86_64.img  # QEMU + virtio-vga: ES-DE session, screenshots
sudo ./build/firstboot-test.sh out/emunix-*-x86_64.img  # two boots on a bigger disk: growth, /storage, password
sudo ./build/slot-test.sh out/emunix-*-x86_64.img  # four boots: next/once and the kernel cmdline follow the slot
```

Output lands in `out/` (a 24 GiB GPT disk image, sparse on disk; override with `TOTAL_SIZE`).
