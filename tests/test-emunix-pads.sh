#!/usr/bin/env bash
# Controller artifacts: udev access rules, the shared gamecontrollerdb, the
# session environment, the player-order helper and the Bluetooth bond path.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$HERE")
fail() { echo "FAIL: $*" >&2; exit 1; }

# 1. udev rules: present, valid, uaccess only (never a world-writable input node).
for f in 70-emunix-gamepads.rules 80-emunix-ally-buttons.rules; do
  [ -f "$REPO/configs/udev/$f" ] || fail "missing configs/udev/$f"
  grep -q 'TAG+="uaccess"' "$REPO/configs/udev/$f" || fail "$f has no uaccess tag"
  ! grep -v '^[[:space:]]*#' "$REPO/configs/udev/$f" | grep -q 'MODE="0666"' ||
    fail "$f world-writes a device"
done
if command -v udevadm >/dev/null; then
  udevadm verify "$REPO"/configs/udev/*.rules >/dev/null || fail "udevadm verify rejected the rules"
fi
RULES=$REPO/configs/udev/70-emunix-gamepads.rules
grep -q 'KERNEL=="hidraw\*"' "$RULES" || fail "no hidraw rule (SDL HIDAPI needs it)"
grep -q 'KERNEL=="js\*"' "$RULES" || fail "no js rule"
grep -q 'ID_INPUT_JOYSTICK' "$RULES" || fail "no ID_INPUT_JOYSTICK (no stable by-id joystick name)"
# The three families the image supports are all matched.
for vendor in 045e 054c 057e; do
  grep -q "id/vendor}==\"$vendor\"" "$RULES" || fail "no rule for vendor $vendor"
done

# 2. gamecontrollerdb: non-empty, has Linux entries, and every entry is parseable.
DB=$REPO/configs/rootfs/usr/share/emunix/gamecontrollerdb.txt
[ -s "$DB" ] || fail "gamecontrollerdb is empty"
[ "$(grep -c 'platform:Linux' "$DB")" -gt 0 ] || fail "gamecontrollerdb has no Linux entries"
while IFS= read -r line; do
  case "$line" in '' | '#'*) continue;; esac
  echo "$line" | grep -qE '^([0-9a-f]{32}|xinput),' || fail "malformed mapping line: $line"
done <"$DB"
# The pads the exit criterion names are in the set.
for guid in 030000004c050000cc09 030000005e040000ea02 030000007e0500000920; do
  grep -q "^$guid" "$DB" || fail "gamecontrollerdb has no mapping for $guid"
done

# 3. The session points SDL at that file and orders the pads.
UNIT=$REPO/configs/rootfs/etc/systemd/user/emunix-session.service
grep -q 'SDL_GAMECONTROLLERCONFIG_FILE=/usr/share/emunix/gamecontrollerdb.txt' "$UNIT" ||
  fail "the session unit does not point SDL at the shipped gamecontrollerdb"
grep -q 'SDL_JOYSTICK_HIDAPI=1' "$UNIT" || fail "the session unit does not keep SDL HIDAPI on"
grep -q 'emunix-pad-order' "$REPO/configs/rootfs/usr/local/bin/emunix-session" ||
  fail "emunix-session does not order the pads"

# 4. Player 1 is the pad used last: the helper lists the most recently connected
#    joystick event device first and skips non-joystick event devices.
ORDER=$REPO/configs/rootfs/usr/local/bin/emunix-pad-order
[ -x "$ORDER" ] || fail "emunix-pad-order is not executable"
fx=$(mktemp -d)
mkdir -p "$fx/dev/input" "$fx/sys/class/input/event2/device" \
  "$fx/sys/class/input/event10/device" "$fx/sys/class/input/event11/device"
touch "$fx/dev/input/event2" "$fx/dev/input/event10" "$fx/dev/input/event11" \
  "$fx/sys/class/input/event2/device/js0" "$fx/sys/class/input/event10/device/js0"
got=$("$ORDER" "$fx/dev/input" "$fx/sys/class/input")
[ "$got" = "$fx/dev/input/event10:$fx/dev/input/event2" ] ||
  fail "pad order is '$got', expected event10:event2 (most recent first)"
got=$("$ORDER" "$fx/empty" "$fx/sys/class/input")
[ -z "$got" ] || fail "an empty input dir should print nothing, got '$got'"

# 5. Bluetooth bonds live on the persistent /var partition (bluez's compiled-in
#    default is /var/lib/bluetooth), so a pairing survives a reboot.
grep -q 'PARTLABEL=var' "$REPO/build/build-image.sh" || fail "the image has no persistent /var"
grep -q '/var/lib/bluetooth' "$REPO/README.md" || fail "README does not document the bond path"

echo "pads: udev uaccess rules, gamecontrollerdb, session env, player order and bond path OK"
