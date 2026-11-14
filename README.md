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

## Controllers

Xbox, PlayStation and Nintendo pads work over USB and Bluetooth. `configs/udev/` tags them
`uaccess` — never `MODE="0666"` — so the logged-in console user gets an ACL on the pad's
`hidraw` and `event`/`js` nodes, and systemd-logind revokes it when the session ends. The
same rules set `ID_INPUT_JOYSTICK`, which gives every pad a stable
`/dev/input/by-id/<bus>-<serial>-joystick` name across reboots and event-number shuffles.

`emunix-session` exports `SDL_JOYSTICK_DEVICE` with the pads ordered **most recently
connected first**, so the pad you turned on last is player 1. SDL2/SDL3 enumerate in that
order; a pad connected after the session started is appended by SDL's own hotplug detection.

One mapping set is shared by ES-DE and the standalone emulators:
`/usr/share/emunix/gamecontrollerdb.txt` (an SDL_GameControllerDB snapshot, zlib licence),
pointed at by `SDL_GAMECONTROLLERCONFIG_FILE` in the `emunix-session` user unit. HIDAPI is
left on (`SDL_JOYSTICK_HIDAPI=1`), which is what the DS4/DS5, Switch and Xbox One S/Series
pads need; if a specific pad misbehaves under HIDAPI, set `SDL_JOYSTICK_HIDAPI=0` for the
session. Refresh the database by re-downloading `gamecontrollerdb.txt` from
<https://github.com/mdqinc/SDL_GameControllerDB>.

RetroArch's default joypad driver is `udev`, which uses RetroArch's own autoconfig profiles
rather than the SDL database. To make RetroArch use the shared set too, add
`input_joypad_driver = "sdl2"` to `~/.config/retroarch/retroarch.cfg`.

Bluetooth bonds live in `/var/lib/bluetooth` on the persistent `/var` partition, so a paired
pad survives a reboot and an A/B slot switch.

### ROG Ally buttons

The Ally's front/back buttons are on a separate HID interface (`0b05:1abe`; Ally X
`0b05:1b4c`). The kernel `hid-asus` driver maps them to unused F-keys:

| Key | Button |
| --- | --- |
| `KEY_F15` | left back button |
| `KEY_F16` | QAM / Armoury Crate button |
| `KEY_F17` | ROG button, long-press |
| `KEY_F18` | ROG button, long-press release |

Firmware-reserved (they never reach Linux): the power button, the short press of the ROG
button, and the volume keys (the N-Key device reports them as volume down/up; on some units
both report volume down). Confirm on the device with `sudo evtest`: pick the N-Key device,
press each button, and the printed keycode is the one in the table.

Wiring: ES-DE opens its menu on the `Start` action (Escape on the keyboard by default), so
`F16` is the natural menu trigger; `F17`/`F18` are for the TDP profile switch
(card `t_88a807c2`). Map them in `~/ES-DE/es_input.cfg` and the TDP command.

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
