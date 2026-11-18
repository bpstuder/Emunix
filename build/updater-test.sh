#!/usr/bin/env bash
# Prove emunix-os-updater on a real boot: v1 on slot a fetches a signed v2 manifest over HTTPS,
# verifies it, downloads the release artifact, writes the inactive slot and flips the loader; a
# reboot lands on v2 with /etc/emunix-version matching. The negative case serves a corrupted
# artifact and shows the abort with the active slot still on v1.
#
# The v2 artifact is the real release artifact: the full GPT disk image with only the version
# bumped, compressed to .img.zst. The updater streams its rootfs_a partition into the slot, so the
# 13.5 GiB raw image never touches the 2 GiB /var cache.
#
# Requires root (loop mount), qemu-system-x86, edk2-ovmf, expect, socat, gptfdisk, e2fsprogs,
# openssl, python3, minisign, zstd. Usage: updater-test.sh <emunix.img> [evidence-dir]
set -euo pipefail
IMG=${1:?usage: updater-test.sh <emunix.img> [evidence-dir]}
OUT=${2:-$(dirname "$0")/../evidence}
[ -f "$IMG" ] || { echo "no image $IMG" >&2; exit 1; }
[ "$(id -u)" -eq 0 ] || { echo "updater-test.sh must run as root (loop mount)" >&2; exit 1; }
OVMF=/usr/share/edk2/x64
[ -f "$OVMF/OVMF_CODE.4m.fd" ] || { echo "edk2-ovmf is not installed ($OVMF)" >&2; exit 1; }
for c in expect socat python3 openssl minisign zstd sha256sum curl arch-chroot partx mkfs.vfat fstrim; do
  command -v "$c" >/dev/null || { echo "$c is required" >&2; exit 1; }
done

SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-loop.sh
. "$SCRIPT_DIR/lib-loop.sh"

mkdir -p "$OUT"
LOG=$OUT/m2-updater.log
WORK=$(mktemp -d)
POS=$WORK/pos.img
NEG=$WORK/neg.img
ACCEL=tcg; [ -w /dev/kvm ] && ACCEL=kvm
SOCK=$WORK/qmp.sock
PORT=8443
SERVER_PID=
cleanup() {
  pkill -f "[q]emu-system-x86_64" 2>/dev/null || true
  [ -n "$SERVER_PID" ] && kill "$SERVER_PID" 2>/dev/null || true
  umount -R -l "$WORK" 2>/dev/null || true
  for m in "$WORK/a" "$WORK/mnt"; do rmdir "$m" 2>/dev/null || true; done
  # Never let rm -rf recurse into a mounted partition: it would delete the filesystem inside.
  if ! mountpoint -q "$WORK/a" 2>/dev/null && ! mountpoint -q "$WORK/mnt" 2>/dev/null; then
    rm -rf "$WORK"
  else
    printf 'warning: %s is still mounted; leaving it in place\n' "$WORK" >&2
  fi
}
trap cleanup EXIT
: >"$LOG"
echo "image $IMG, accel $ACCEL" | tee -a "$LOG"

# --- the v2 release artifact: the real disk image, version and kernel changed --------------
# Work on a copy: the built image is never mounted, so a test run cannot modify it. This is the
# full GPT disk image a release publishes, so the updater must stream rootfs_a out of it.
#
# The kernel changes too: the previous pkgrel of the same kernel from the Arch archive supplies
# vmlinuz and the modules, and the image's own mkinitcpio builds the matching initramfs. The
# artifact's ESP and rootfs then carry a kernel the installed one does not have.
KOLD_VER=7.3.4-arch1-1
KOLD_PKG=linux-7.3.4.arch1-1-x86_64.pkg.tar.zst
curl -fsSL -o "$WORK/$KOLD_PKG" "https://archive.archlinux.org/packages/l/linux/$KOLD_PKG"
mkdir -p "$WORK/kold"
tar -xf "$WORK/$KOLD_PKG" -C "$WORK/kold"
cp --sparse=always "$IMG" "$WORK/v2.img"
LOOP=$(attach_image "$WORK/v2.img")
mkdir -p "$WORK/a" "$WORK/e" "$WORK/esp-old" "$WORK/esp-new"
mount "${LOOP}p2" "$WORK/a"
V1=$(cat "$WORK/a/etc/emunix-version")
V1KERN=$(find "$WORK/a/usr/lib/modules" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | head -n1)
# The version is <year>.<month>.<patch>; bump the patch, not the day.
V2=$(awk -F. '{printf "%s.%s.%d", $1, $2, $3 + 1}' <<<"$V1")
cp -a "$WORK/kold/usr/lib/modules/$KOLD_VER" "$WORK/a/usr/lib/modules/"
# The new rootfs carries the new kernel's modules, not the old one's: a real release has one.
rm -rf "$WORK/a/usr/lib/modules/$V1KERN"
arch-chroot "$WORK/a" depmod "$KOLD_VER"
arch-chroot "$WORK/a" mkinitcpio -k "$KOLD_VER" -g /boot/initramfs-linux.img
printf '%s\n' "$V2" >"$WORK/a/etc/emunix-version"
# Rebuild the ESP from scratch: the bootloader and loader entries are copied, the kernel and
# initramfs are the new ones. Punching the partition first keeps the old files' blocks out of the
# artifact, so the test image stays the size a real release is.
mount -o ro "${LOOP}p1" "$WORK/esp-old"
cp -a "$WORK/esp-old/EFI" "$WORK/esp-old/loader" "$WORK/esp-new/"
umount "$WORK/esp-old"
read -r esp_start esp_sectors _ < <(partx --show --output START,SECTORS,NAME --noheadings "$WORK/v2.img" |
  awk '$3=="esp" {print $1, $2}')
fallocate -p -o $((esp_start * 512)) -l $((esp_sectors * 512)) "$WORK/v2.img" 2>/dev/null || true
mkfs.vfat -F32 -n ESP "${LOOP}p1" >/dev/null
mount "${LOOP}p1" "$WORK/e"
cp -a "$WORK/esp-new/." "$WORK/e/"
cp "$WORK/kold/usr/lib/modules/$KOLD_VER/vmlinuz" "$WORK/e/vmlinuz-linux"
cp "$WORK/a/boot/initramfs-linux.img" "$WORK/e/initramfs-linux.img"
rm -f "$WORK/a/boot/initramfs-linux.img"
fstrim "$WORK/a" >/dev/null 2>&1 || true
umount "$WORK/e"
umount "$WORK/a"
losetup -d "$LOOP"
zstd -q -T0 -19 -f "$WORK/v2.img" -o "$WORK/v2.img.zst"
rm -f "$WORK/v2.img"
echo "v1 $V1 (kernel $V1KERN) -> v2 $V2 (kernel $KOLD_VER), artifact $(stat -c %s "$WORK/v2.img.zst") bytes compressed" | tee -a "$LOG"

# The corrupt copy: one byte flipped, so the sha256 no longer matches the manifest.
cp --sparse=always "$WORK/v2.img.zst" "$WORK/v2-corrupt.img.zst"
printf 'x' | dd of="$WORK/v2-corrupt.img.zst" bs=1 seek=1000 conv=notrunc status=none

# --- the HTTPS endpoint: a throwaway CA, a server cert for 10.0.2.2, and a test keypair ----
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$WORK/ca.key" -out "$WORK/ca.pem" \
  -days 2 -subj "/CN=Emunix updater test CA" 2>/dev/null
openssl req -newkey rsa:2048 -nodes -keyout "$WORK/server.key" -out "$WORK/server.csr" \
  -subj "/CN=10.0.2.2" 2>/dev/null
printf 'subjectAltName=IP:10.0.2.2,IP:127.0.0.1\n' >"$WORK/san.cnf"
openssl x509 -req -in "$WORK/server.csr" -CA "$WORK/ca.pem" -CAkey "$WORK/ca.key" \
  -CAcreateserial -out "$WORK/server.pem" -days 2 -extfile "$WORK/san.cnf" 2>/dev/null
minisign -G -W -p "$WORK/pub" -s "$WORK/key" >/dev/null

SHA=$(sha256sum "$WORK/v2.img.zst" | awk '{print $1}')
SIZE=$(stat -c %s "$WORK/v2.img.zst")
mkdir -p "$WORK/serve"
printf '{"channel":"stable","version":"%s","released":"2026-11-13T00:00:00Z","image":{"url":"https://10.0.2.2:%s/emunix-%s-x86_64.img.zst","sha256":"%s","size":%s},"min_from":"%s"}\n' \
  "$V2" "$PORT" "$V2" "$SHA" "$SIZE" "$V1" >"$WORK/serve/emunix.json"
minisign -S -W -s "$WORK/key" -m "$WORK/serve/emunix.json" -x "$WORK/serve/emunix.json.minisig"
cp "$WORK/v2.img.zst" "$WORK/serve/emunix-$V2-x86_64.img.zst"

cat >"$WORK/serve.py" <<'PY'
import http.server, ssl, sys, os
os.chdir(sys.argv[1])
httpd = http.server.ThreadingHTTPServer(("0.0.0.0", int(sys.argv[2])), http.server.SimpleHTTPRequestHandler)
ctx = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
ctx.load_cert_chain(sys.argv[3], sys.argv[4])
httpd.socket = ctx.wrap_socket(httpd.socket, server_side=True)
httpd.serve_forever()
PY
python3 "$WORK/serve.py" "$WORK/serve" "$PORT" "$WORK/server.pem" "$WORK/server.key" \
  >"$WORK/serve.log" 2>&1 &
SERVER_PID=$!
for _ in $(seq 1 10); do
  curl -fsS --cacert "$WORK/ca.pem" "https://127.0.0.1:$PORT/emunix.json" >/dev/null 2>&1 && break
  sleep 1
done
curl -fsS --cacert "$WORK/ca.pem" "https://127.0.0.1:$PORT/emunix.json" >/dev/null ||
  { echo "FAIL: the test endpoint does not serve the manifest" >&2; cat "$WORK/serve.log" >&2; exit 1; }

# --- two disk copies: one for the positive run, one for the negative one -----------------
cp --sparse=always "$IMG" "$POS"
cp --sparse=always "$IMG" "$NEG"
for d in "$POS" "$NEG"; do
  loop=$(attach_image "$d")
  mkdir -p "$WORK/mnt"
  mount "${loop}p4" "$WORK/mnt"
  mkdir -p "$WORK/mnt/lib/emunix"
  : >"$WORK/mnt/lib/emunix/initialized"
  umount "$WORK/mnt"
  losetup -d "$loop"
done
cp "$OVMF/OVMF_VARS.4m.fd" "$WORK/OVMF_VARS.fd"

# --- one QEMU boot: log in, validate sudo, run the command line, power down --------------
cat >"$WORK/boot.exp" <<'EXPECT'
set img   [lindex $argv 0]
set log   [lindex $argv 1]
set code  [lindex $argv 2]
set vars  [lindex $argv 3]
set accel [lindex $argv 4]
set sock  [lindex $argv 5]
set cmds  [lindex $argv 6]
set tag   [lindex $argv 7]
set timeout 900
log_file -a $log
proc qmp {json} {
  global sock
  catch {exec socat -t 2 - UNIX-CONNECT:$sock << "{\"execute\":\"qmp_capabilities\"}\n$json\n"}
}
spawn qemu-system-x86_64 -machine q35 -accel $accel -m 3072 -smp 4 -vga none \
  -device bochs-display -display none \
  -netdev user,id=n0 -device virtio-net-pci,netdev=n0 \
  -qmp unix:$sock,server,nowait \
  -drive if=pflash,format=raw,readonly=on,file=$code \
  -drive if=pflash,format=raw,file=$vars \
  -drive file=$img,format=raw,if=virtio -no-reboot \
  -serial stdio
expect {
  -re {login: } { send "retrogamer\r" }
  -re {Bailing out|Kernel panic|No bootable device} { puts stderr "boot failed before userspace"; exit 1 }
  timeout { puts stderr "no login prompt"; exit 1 }
}
expect -re {[Pp]assword: }
send "retrogamer\r"
expect {
  -re {\[retrogamer@[^]]*\]\$ } {}
  -re {Login incorrect} { puts stderr "the shipped password was rejected"; exit 1 }
  timeout { puts stderr "no shell after login"; exit 1 }
}
send "sudo -v\r"
expect -re {[Pp]assword for [^:\r\n]*: |[Pp]assword: }
send "retrogamer\r"
expect -re {\[retrogamer@[^]]*\]\$ }
set f [open $cmds]
set line [read $f]
close $f
send "$line\r"
expect {
  -re {[Pp]assword for [^:\r\n]*: } { send "retrogamer\r"; exp_continue }
  -re $tag {}
  timeout { puts stderr "the commands did not finish"; exit 1 }
}
after 2000
qmp "{\"execute\":\"system_powerdown\"}"
expect {
  eof {}
  timeout { puts stderr "the VM did not power off"; exit 1 }
}
exit 0
EXPECT

boot() { # <disk> <cmds file> <end marker>
  set +e
  expect "$WORK/boot.exp" "$1" "$LOG" "$OVMF/OVMF_CODE.4m.fd" "$WORK/OVMF_VARS.fd" \
    "$ACCEL" "$SOCK" "$2" "$3"
  local rc=$?
  set -e
  rm -f "$SOCK"
  [ "$rc" -eq 0 ] || { echo "FAIL: $1 did not finish (expect rc=$rc)" >&2; echo "transcript: $LOG" >&2; exit 1; }
}

# The guest brings up the QEMU user network, installs the test CA and the test public key,
# then runs the updater. expect reads the first line of the command file.
CA_B64=$(base64 -w0 "$WORK/ca.pem")
PUB_B64=$(base64 -w0 "$WORK/pub")
one_line() { tr '\n' ';' | sed 's/;$//'; }

cat >"$WORK/t1" <<'EOF'
for i in $(seq 1 30); do dev=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}'); [ -n "$dev" ] && break; sleep 1; done
sudo ip link set "$dev" up
sudo ip addr add 10.0.2.15/24 dev "$dev" 2>/dev/null || true
sudo ip route add default via 10.0.2.2 2>/dev/null || true
echo '@CA@' | base64 -d >/tmp/ca.pem
echo '@PUB@' | base64 -d >/tmp/test.pub
sudo env CURL_CA_BUNDLE=/tmp/ca.pem EMUNIX_UPDATE_PUBKEY=/tmp/test.pub EMUNIX_REPO_URL=https://10.0.2.2:8443 /usr/local/bin/emunix-os-updater
echo "UPDATER-RC=$?"
echo "VERSION-B1: $(cat /etc/emunix-version)"
echo "KERNEL-B1: $(uname -r)"
echo "SLOT-B1: $(sudo emunix-slot status | tr '\n' ' ')"
echo "UPDATE-BOOT1-E""ND"
EOF
sed -e "s|@CA@|$CA_B64|" -e "s|@PUB@|$PUB_B64|" "$WORK/t1" | one_line >"$WORK/cmds1"

cat >"$WORK/t2" <<'EOF'
echo "ROOT-B2: $(grep -o 'root=[^ ]*' /proc/cmdline)"
echo "VERSION-B2: $(cat /etc/emunix-version)"
echo "KERNEL-B2: $(uname -r)"
echo "ACTIVE-B2: $(sudo emunix-slot status | sed -n 's/^active: //p')"
echo "DEFAULT-B2: $(sudo emunix-slot status | sed -n 's/^default: //p')"
echo "UPDATE-BOOT2-E""ND"
EOF
one_line <"$WORK/t2" >"$WORK/cmds2"

cat >"$WORK/t3" <<'EOF'
for i in $(seq 1 30); do dev=$(ip -o link show | awk -F': ' '$2!="lo"{print $2; exit}'); [ -n "$dev" ] && break; sleep 1; done
sudo ip link set "$dev" up
sudo ip addr add 10.0.2.15/24 dev "$dev" 2>/dev/null || true
sudo ip route add default via 10.0.2.2 2>/dev/null || true
echo '@CA@' | base64 -d >/tmp/ca.pem
echo '@PUB@' | base64 -d >/tmp/test.pub
sudo env CURL_CA_BUNDLE=/tmp/ca.pem EMUNIX_UPDATE_PUBKEY=/tmp/test.pub EMUNIX_REPO_URL=https://10.0.2.2:8443 /usr/local/bin/emunix-os-updater
echo "UPDATER-RC=$?"
echo "VERSION-B3: $(cat /etc/emunix-version)"
echo "KERNEL-B3: $(uname -r)"
echo "SLOT-B3: $(sudo emunix-slot status | tr '\n' ' ')"
echo "UPDATE-BOOT3-E""ND"
EOF
sed -e "s|@CA@|$CA_B64|" -e "s|@PUB@|$PUB_B64|" "$WORK/t3" | one_line >"$WORK/cmds3"

# --- the positive run: v1 -> v2, then a reboot lands on v2 -------------------------------
echo "=== boot 1: run the updater on slot a" | tee -a "$LOG"
boot "$POS" "$WORK/cmds1" "UPDATE-BOOT1-END"
echo "=== boot 2: reboot after the update" | tee -a "$LOG"
boot "$POS" "$WORK/cmds2" "UPDATE-BOOT2-END"

# --- the negative run: a corrupted image aborts, slot a is untouched ---------------------
cp "$WORK/v2-corrupt.img.zst" "$WORK/serve/emunix-$V2-x86_64.img.zst"
echo "=== boot 3: the corrupt image" | tee -a "$LOG"
boot "$NEG" "$WORK/cmds3" "UPDATE-BOOT3-END"

# --- the claims, read back out of the transcript -----------------------------------------
fail() { echo "FAIL: $*" >&2; echo "transcript: $LOG" >&2; exit 1; }
grep -aq 'UPDATER-RC=0' "$LOG" || fail "boot 1: the updater did not succeed"
grep -aq 'accepted: version' "$LOG" || fail "boot 1: the manifest was not accepted"
grep -aq "staged $V2 on slot b" "$LOG" || fail "boot 1: the update was not staged on slot b"
grep -aq "VERSION-B1: $V1" "$LOG" || fail "boot 1: the running version changed before the reboot"
grep -aq "KERNEL-B1: $V1KERN" "$LOG" || fail "boot 1: the running kernel is not $V1KERN"
grep -aq 'SLOT-B1: active: a' "$LOG" || fail "boot 1: the active slot changed"
grep -aq 'SLOT-B1: active: a default: emunix-b.conf' "$LOG" || fail "boot 1: the loader was not flipped"

grep -aq 'ROOT-B2: root=PARTLABEL=rootfs_b' "$LOG" || fail "boot 2: the reboot did not land on slot b"
grep -aq "VERSION-B2: $V2" "$LOG" || fail "boot 2: the version is not $V2"
grep -aq "KERNEL-B2: $KOLD_VER" "$LOG" || fail "boot 2: the new kernel $KOLD_VER did not boot"
grep -aq 'ACTIVE-B2: b' "$LOG" || fail "boot 2: the active slot is not b"
grep -aq 'DEFAULT-B2: emunix-b.conf' "$LOG" || fail "boot 2: the default is not slot b"

grep -aq 'UPDATER-RC=1' "$LOG" || fail "boot 3: the corrupt image did not abort"
grep -aq 'does not match the manifest' "$LOG" || fail "boot 3: the image refusal was not shown"
grep -aq "VERSION-B3: $V1" "$LOG" || fail "boot 3: the active slot version changed"
grep -aq "KERNEL-B3: $V1KERN" "$LOG" || fail "boot 3: the corrupt update changed the kernel"
grep -aq 'SLOT-B3: active: a' "$LOG" || fail "boot 3: the active slot changed"
grep -aq 'SLOT-B3: active: a default: emunix-a.conf' "$LOG" || fail "boot 3: the loader default changed"

echo "emunix-os-updater: v1 -> v2 staged and booted (kernel $V1KERN -> $KOLD_VER), a corrupt image aborts with slot a untouched"
echo "transcript: $LOG"
