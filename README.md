# Emunix

**Emunix** — an immutable, Arch-based Linux distribution for x86_64 handhelds (then desktops),
booting straight into EmulationStation-DE. Rolling Arch base, A/B rootfs slots, and persistent
state: `/storage` for ROMs/bios/saves/states, and `/etc` for Wi-Fi profiles, the hostname, users
and the timezone, so an image update keeps your settings. See `INSTALL.md` for flashing and build
instructions.

The image ships the public password `retrogamer`/`retrogamer` and nothing forces a change: run
`passwd` before you take the device anywhere you do not control. There is no `sshd`, so it guards
the console and `sudo`, not a network service.


## Layout

- `build/` — image assembly (sgdisk + pacstrap + arch-chroot), the AUR build for what is not yet
  in `[emunix]`, image and session boot tests
- `profiles/` — base, handheld-common and per-device package lists (`DEVICE=rog-ally`);
  `aur.txt` holds the AUR packages still built in the chroot, pinned by commit
- `packages/` — PKGBUILDs for the `[emunix]` pacman repository (the keyring, `ryzenadj`,
  `freeimage`, `emulationstation-de`, …), built in `packages/order` by `build/repo.sh` and
  served from GitHub Pages
- `repo/` — the `[emunix]` repository: signing-key custody, publishing, and why it is for
  image builds only
- `configs/rootfs/` — files copied into the image root (ES-DE session, its units, the ES-DE seed)
- `configs/` — partition layout
- `evidence/` — boot transcripts and screenshots from the image tests
- `tests/` — shell tests for the scripts in `build/` and `configs/rootfs/` (plain
  `bash tests/test-*.sh`, no framework); CI runs them before the image build
- `update/` — the signed update manifest format, signing and signing-key custody
- `.github/workflows/` — CI build pipeline, and the tag-driven release pipeline (`release.yml`)

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
`F16` is the natural menu trigger. ES-DE cannot bind a button to a shell command, so
`F17`/`F18` are not wired by default; map them in `~/ES-DE/es_input.cfg` to ES-DE actions
if you want them to do something. Power profiles are switched from the **Power Profiles**
menu entry instead (below).

## Power profiles

Three TDP profiles are defined over `asusctl` (platform profile, with separate AC and
battery settings so `asusd` follows the power source) and `ryzenadj` (the package-power
ceiling, which `asusctl` does not expose):

| Profile | asusctl on AC | asusctl on battery | Ceiling on AC | Ceiling on battery |
| --- | --- | --- | --- | --- |
| `quiet` | Quiet | Quiet | 9 W | 8 W |
| `balanced` | Balanced | Quiet | 15 W | 10 W |
| `performance` | Performance | Balanced | 25 W | 15 W |

Ceilings are kept below the ~30 W sustained package limit ROG Ally firmware is known to
enforce on the Z1 Extreme, so a running profile should not be rolled back mid-game. The
5-minute acceptance measurement is where any remaining rollback would show up. Only
package power limits are set; no thermal limit (Tctl, skin temperature) is touched.

Switch from the **Power Profiles** entry in ES-DE (three script entries seeded into
`/storage/roms/power`), or run `sudo emunix-tdp quiet|balanced|performance`. The choice is
remembered in `/var/lib/emunix/tdp-profile` on the persistent `/var` partition and reapplied
at boot; with nothing stored, the boot default is `balanced` on AC and `quiet` on battery. The
boot unit has `ConditionPathExists=/sys/module/asus_wmi`, so it is skipped (not failed) on hardware
without the ASUS WMI driver, such as QEMU.
The ES-DE entries escalate through a sudoers rule that allows exactly those three commands
and nothing else.

Measure a profile on the device with `sudo ryzenadj --dump-table` (the SMU PM table,
including package power) while sampling over a 5-minute load, or `sudo sensors` for
thermals. If `asusd` re-applies its own PPT tuning and rolls the ceiling back after a few
minutes, raise it in a card rather than editing the script by hand.

`power-profiles-daemon` is deliberately not installed: the ArchWiki warns that it races
`asusd` for the kernel's `platform_profile` interface, so the profiles are owned by
`asusctl`.

## Quick start (dev)

Requires an Arch host (or container) with `gptfdisk`, `dosfstools`, `btrfs-progs`, `e2fsprogs`
and `arch-install-scripts`. On a non-Arch host, run the commands below inside an `archlinux`
container — that is how CI and this workstation do it.

```sh
sudo DEVICE=rog-ally ./build/build-image.sh       # out/emunix-<version>-x86_64.img + .sha256
sudo ./build/verify-image.sh out/emunix-*-x86_64.img
sudo ./build/boot-test.sh out/emunix-*-x86_64.img  # QEMU + OVMF, login on ttyS0
sudo ./build/session-test.sh out/emunix-*-x86_64.img  # QEMU + virtio-vga: ES-DE session, screenshots
sudo ./build/firstboot-test.sh out/emunix-*-x86_64.img  # two boots on a bigger disk: growth, /storage, shipped password kept until passwd
sudo ./build/etc-overlay-test.sh out/emunix-*-x86_64.img  # two A/B cycles: /etc settings survive the update
sudo ./build/slot-test.sh out/emunix-*-x86_64.img  # four boots: next/once and the kernel cmdline follow the slot
sudo ./build/updater-test.sh out/emunix-*-x86_64.img  # signed v1->v2, corrupt aborts
sudo ./build/health-test.sh out/emunix-*-x86_64.img  # two failed boots roll back
# build/pads-test.sh is manual only: it needs a joystick evdev node on the host
# (a real pad, or a uinput one as tests/test-emunix-pads.sh makes)
#   sudo ./build/pads-test.sh out/emunix-*-x86_64.img /dev/input/event12
```

The image tests need a privileged container (loop mounts, QEMU). Output lands in `out/` (a 24 GiB
GPT disk image, sparse on disk; override with `TOTAL_SIZE`).

## The `[emunix]` repository

Packages that the official repositories do not carry are built from `packages/` into a signed
pacman repository on GitHub Pages (`https://bpstuder.github.io/Emunix/`) by
`build/repo.sh`; the image build installs `emunix-keyring`, `ryzenadj`, `freeimage` and
`emulationstation-de` from it with signature checking on. The private signing key is BP's and
never enters the repository or the image. The repository is for **image builds**: the read-only
root cannot install packages at runtime, so a running device gets them from a new image. See
`repo/README.md`.
