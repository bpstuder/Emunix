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

- Default user: `retrogamer` (password same as username — change it).
- ROMs/bios/saves/states live under `/storage`.
- No copyrighted assets are included; supply your own.
