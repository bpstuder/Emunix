# Installing Emunix

Emunix is in early development (M0). These instructions will be expanded as releases land.

## Flashing a release image

1. Download the latest image from the [Releases](https://github.com/bpstuder/Emunix/releases) page.
2. Decompress: `zstd -d emunix-*.img.zst`
3. Flash to a USB drive or target disk:
   ```sh
   sudo dd if=emunix-*.img of=/dev/sdX bs=4M status=progress conv=fsync
   ```
4. Boot from the target device (UEFI).

## Building from source

See `build/build-image.sh` and `.github/workflows/build.yml`. Requires an Arch host.

## Notes

- Default user: `retrogamer`. The image ships `retrogamer`/`retrogamer` and the **first boot replaces
  that password**: it asks for a new one on the console (a handheld needs a USB keyboard for this)
  and, if nobody answers within 30 seconds, generates one, which it prints on the console and logs
  (`journalctl -u firstboot`). The shipped password stops working either way, so a freshly flashed
  device is safe to put on a network.
- The same first boot grows the last partition into the rest of the card/SSD, creates
  `/storage/roms/<system>`, `bios`, `saves` and `states` (all owned by `retrogamer`), and only then
  writes `/var/lib/emunix/initialized`. Remove that file to re-run the unit on the next boot.
- Missed the generated password? Boot with `init=/bin/bash`, `mount -o remount,rw /` and
  `passwd retrogamer`. On a headless device the first-boot log, generated password included, is on
  the serial console (`console=ttyS0`) and in the journal.
- Boots into EmulationStation-DE on tty1; quitting it drops to a shell with the journal hint.
- Games are launched from `/storage/roms/<system>/`; `/etc/emulationstation` holds the read-only
  defaults, copied to `~/ES-DE` on first login so your edits survive image updates.
- ROMs/bios/saves/states live under `/storage`.
- No copyrighted assets are included; supply your own.
