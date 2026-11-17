# Installing Emunix

Emunix is an immutable Arch-based system for x86_64 handhelds: a read-only root with two slots
(A/B), persistent `/var`, `/home` and `/storage`, booting straight into EmulationStation-DE.

## Installing a release image

The release pipeline attaches each image to the
[GitHub Releases](https://github.com/bpstuder/Emunix/releases) page when a tag named
`<year>.<month>.<patch>` (for example `2026.11.1`) is pushed; the tag is the version.

Each release carries four files:

| File | What it is |
| --- | --- |
| `emunix-<version>-x86_64.img.zst` | the disk image, compressed |
| `emunix-<version>-x86_64.img.zst.sha256` | its SHA-256 |
| `emunix.json` | the signed update manifest (what the on-device updater consumes) |
| `emunix.json.minisig` | the minisign signature over the manifest |

You need `zstd`, `sha256sum` and (to check the signature) `minisign`.

1. Download the four files from the release page.
2. **Verify the checksum before you write anything.** In the directory with the downloaded files:
   ```sh
   sha256sum -c emunix-<version>-x86_64.img.zst.sha256
   ```
   It must print `emunix-<version>-x86_64.img.zst: OK`. If it does not, delete the file and
   download it again — do not flash it.
3. Verify the signature too. The public key is committed in the repository
   (`configs/rootfs/etc/emunix/update.pub`) and baked into every image at `/etc/emunix/update.pub`:
   ```sh
   git clone --depth 1 https://github.com/bpstuder/Emunix.git
   minisign -Vm emunix.json -x emunix.json.minisig -p Emunix/configs/rootfs/etc/emunix/update.pub
   ```
   It must print `Signature and comment signature verified`. The manifest's `sha256` and `size`
   pin the image bytes; the signature pins the manifest.
4. Decompress:
   ```sh
   zstd -d emunix-<version>-x86_64.img.zst
   ```
5. **Identify the target device.** `lsblk` shows size, type and model, so you can tell the card
   or SSD apart from the drive you are booted from:
   ```sh
   lsblk -o NAME,SIZE,TYPE,MOUNTPOINT,MODEL
   ```
   Unmount anything mounted on it (`sudo umount /dev/sdX*`), and use the whole disk —
   `/dev/sdX` for a USB/SD disk, `/dev/nvme0n1` for an internal NVMe — never a partition.
6. Flash it, and let `dd` flush before it returns:
   ```sh
   sudo dd if=emunix-<version>-x86_64.img of=/dev/sdX bs=4M status=progress conv=fsync
   ```
   `conv=fsync` waits for the write to reach the device; without it a fast `dd` can return while
   the last blocks are still in cache, and the device then fails to boot.
7. Boot the device from the disk (UEFI). The bootloader defaults to slot `a`.

## First boot

The first boot does three things before the frontend starts, and it is normal for it to take a
minute:

- **The password changes.** The image ships `retrogamer`/`retrogamer`. On tty1 you are asked for
  a new password; press Enter to have one generated. If nobody answers within 30 seconds, a
  generated password is printed on the console and written to the journal. Either way the shipped
  password stops working, so a fresh device is safe to put on a network. Read the generated one
  with `journalctl -u firstboot` if you missed it.
- The last partition grows into the rest of the card/SSD, and `/storage/roms/<system>`, `bios`,
  `saves` and `states` are created (owned by `retrogamer`).
- Only then is `/var/lib/emunix/initialized` written. Delete that file to make the next boot run
  the first-boot steps again.

Missed the generated password? Boot with `init=/bin/bash`, `mount -o remount,rw /` and
`passwd retrogamer`. On a headless device the first-boot log, generated password included, is on
the serial console (`console=ttyS0`) and in the journal.

## If the device does not boot

The root filesystem is A/B: two slots (`rootfs_a`, `rootfs_b`), each with a systemd-boot entry.
An image update writes the inactive slot and flips the loader to it, so the slot you booted
before is still there.

- **At the bootloader:** systemd-boot shows a menu for 3 seconds. Pick **Emunix (slot b)** (or
  slot `a` if the failed update went the other way). This is the quickest way back.
- **From a system that boots:** `sudo emunix-slot status` prints the running slot, the default
  entry and any pending one-shot. Then either
  ```sh
  sudo emunix-slot next b    # slot b becomes the default from now on
  sudo emunix-slot once b    # boot slot b once, leaving the default alone
  ```
  Both refuse a slot whose filesystem `e2fsck -fn` rejects.
- **Automatic rollback:** every boot that never reaches `multi-user.target` is counted; two in a
  row flip the loader back to the other slot, mark the failed one bad (`emunix-slot status` shows
  `bad: <slot>`) and reboot into the working slot. The journal and
  `/var/log/emunix-update.log` record the switch.
- If neither slot boots, reflash from the release image.

## Building from source

Requires an Arch host (or container) with `gptfdisk`, `dosfstools`, `btrfs-progs`, `e2fsprogs`
and `arch-install-scripts`:

```sh
sudo DEVICE=rog-ally ./build/build-image.sh         # out/emunix-<version>-x86_64.img + .sha256
sudo ./build/verify-image.sh out/emunix-*-x86_64.img
```

`VERSION` defaults to `<year>.<month>.0`; set it to choose another version. The release pipeline
sets it from the tag.

## Notes

- Default user: `retrogamer`. ROMs/bios/saves/states live under `/storage`.
- Boots into EmulationStation-DE on tty1; quitting it drops to a login shell on tty1 (with a
  journal hint when the session exited non-zero).
- Games are launched from `/storage/roms/<system>/`; `/etc/emulationstation` holds the read-only
  defaults, copied to `~/ES-DE` on first login so your edits survive image updates.
- The root filesystem is read-only, but `/etc` is an overlay: hostname changes, Wi-Fi profiles and
  anything else that writes config at runtime land on `/var/lib/emunix/overlay/etc/<slot>` and
  survive a reboot. Booting the other root slot starts from that image's `/etc` again, so `/etc`
  edits do not carry across an update.
- Updates are whole signed images, not packages. `emunix-os-updater` (daily timer, AC power)
  fetches `emunix.json` and `emunix.json.minisig` from `EMUNIX_REPO_URL`, verifies the signature
  against `/etc/emunix/update.pub`, downloads the `.img.zst`, verifies the sha256/size, streams the
  image's `rootfs_a` partition into the inactive slot, replaces `vmlinuz-linux` and
  `initramfs-linux.img` on the ESP from the image's `esp` partition and flips the loader. The
  ESP is shared by both slots, so the kernel follows an update: after one, booting the other slot
  gives you the *new* kernel with the old rootfs, not the kernel that slot shipped with. Nothing
  else on the ESP is touched. The default `EMUNIX_REPO_URL` is GitHub's latest-release asset URL,
  so a device finds new releases with no configuration; override it for a mirror. See
  `update/README.md`.
- The `[emunix]` pacman repository (`https://bpstuder.github.io/Emunix/`) carries packages the
  official repositories do not, and is used while building the image. The read-only root cannot
  install packages at runtime, so a running device gets them from a new image.
- No copyrighted assets are included; supply your own.

## Project status

- `release.yml` builds, verifies, signs and attaches the four files above to a GitHub Release when a
  `<year>.<month>.<patch>` tag is pushed; the tag is the version. **No image has been published
  yet** — the Releases page is empty until the first tag is pushed.
- Testing so far runs under QEMU only (`.github/workflows/build.yml`, `evidence/`); no real
  handheld hardware has been tested.
