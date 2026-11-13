# Installing Emunix

No release image is published yet. Emunix is built from source and flashed to the target device:

```sh
sudo DEVICE=rog-ally ./build/build-image.sh         # out/emunix-<version>-x86_64.img + .sha256
sudo ./build/verify-image.sh out/emunix-*-x86_64.img
sudo dd if=out/emunix-*-x86_64.img of=/dev/sdX bs=4M status=progress conv=fsync
```

The build requires an Arch host (the `archlinux:latest` container CI uses works too; see
`README.md`). Boot the flashed device from the image (UEFI).

## Once a release exists

Release images will be published on the [Releases](https://github.com/bpstuder/Emunix/releases)
page; until then, build from source as above. When a release exists:

1. Download the latest image from the Releases page.
2. Decompress: `zstd -d emunix-*.img.zst`
3. Flash to a USB drive or target disk:
   ```sh
   sudo dd if=emunix-*.img of=/dev/sdX bs=4M status=progress conv=fsync
   ```
4. Boot from the target device (UEFI).

## Notes

- Default user: `retrogamer`. The image ships `retrogamer`/`retrogamer`, and the first boot
  replaces that password: it asks for a new one on the console (tty1) and, if nobody answers
  within 30 seconds, generates one, which it prints on the console and logs
  (`journalctl -u firstboot`). The shipped password stops working either way, so a freshly
  flashed device is safe to put on a network.
- The same first boot grows the last partition into the rest of the card/SSD, creates
  `/storage/roms/<system>`, `bios`, `saves` and `states` (all owned by `retrogamer`), and only
  then writes `/var/lib/emunix/initialized`. Remove that file to re-run the unit on the next
  boot.
- Missed the generated password? Boot with `init=/bin/bash`, `mount -o remount,rw /` and
  `passwd retrogamer`. On a headless device the first-boot log, generated password included, is
  on the serial console (`console=ttyS0`) and in the journal.
- Boots into EmulationStation-DE on tty1; quitting it drops to a login shell on tty1 (with a
  journal hint when the session exited non-zero).
- Games are launched from `/storage/roms/<system>/`; `/etc/emulationstation` holds the read-only
  defaults, copied to `~/ES-DE` on first login so your edits survive image updates.
- The root filesystem is read-only, but `/etc` is an overlay: hostname changes, Wi-Fi profiles and
  anything else that writes config at runtime land on `/var/lib/emunix/overlay/etc/<slot>` and
  survive a reboot. Booting the other root slot — what an image update does — starts from that
  image's `/etc` again, so `/etc` edits do not carry across an update.
- The root filesystem is A/B: two ext4 slots (`rootfs_a`, `rootfs_b`), each with a systemd-boot
  entry. `sudo emunix-slot status` prints the running root slot, the loader's default entry and a
  pending one-shot. `sudo emunix-slot next b` makes slot b the default from then on;
  `sudo emunix-slot once b` boots it once only, so the boot after a failed attempt falls back to
  the default again. Both refuse a slot whose filesystem `e2fsck -fn` rejects.
- The signed-update machinery is implemented and tested: the manifest format (`emunix.json`),
  minisign signing and verification against the public key baked into the image at
  `/etc/emunix/update.pub` (`update/README.md`, `build/lib-update.sh`). No manifest is published
  yet, so there is nothing to update to, and the on-device updater is still a skeleton
  (`build/os-updater.sh`).
- ROMs/bios/saves/states live under `/storage`.
- No copyrighted assets are included; supply your own.

## Project status

- No release image is published yet; build from source.
- Emunix publishes no package repository: the image is built from the official Arch repositories,
  and updates are whole signed images, not packages.
- Testing so far runs under QEMU only (`.github/workflows/build.yml`, `evidence/`); no real
  handheld hardware has been tested.
