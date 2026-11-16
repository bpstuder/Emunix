#!/usr/bin/env bash
# Build every packages/*/PKGBUILD in the Arch container, sign the packages and the
# database with BP's key, and verify the result against the committed public half.
# Runs as root inside the container; the private key is mounted read-only at $1 and
# never written into the repository or the image.
set -euo pipefail
KEYFILE=${1:?usage: repo-build.sh <private-key-file>}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SCRIPT_DIR")
# shellcheck source-path=SCRIPTDIR
# shellcheck source=lib-repo.sh
. "$SCRIPT_DIR/lib-repo.sh"
PKGDIR="$REPO/packages"
KEYRING="$PKGDIR/emunix-keyring"
PUBKEY="$KEYRING/emunix.gpg"
TRUSTED="$KEYRING/emunix-trusted"
OUT=${EMUNIX_REPO_OUT:-$REPO/out/repo}
BUILDUSER=${EMUNIX_REPO_USER:-pkgbuilder}
BUILDROOT=$(mktemp -d /var/cache/emunix-build.XXXXXX)
chmod 0755 "$BUILDROOT"

fail() { printf 'repo-build.sh: %s\n' "$*" >&2; exit 1; }
cleanup() { rm -rf "$BUILDROOT"; }
trap cleanup EXIT

[ -f "$PUBKEY" ] || fail "no public key at $PUBKEY (BP's public half is missing)"
[ -f "$TRUSTED" ] || fail "no trusted fingerprint at $TRUSTED"
[ -f "$KEYFILE" ] || fail "no private key at $KEYFILE (set EMUNIX_GPG_KEY)"
FPR=$(awk -F: '/^[^#]/ {print $1; exit}' "$TRUSTED")
[ -n "$FPR" ] || fail "$TRUSTED carries no fingerprint"

pacman -Sy --noconfirm --needed base-devel gnupg >/dev/null

# The private key is imported into root's keyring for repo-add and into the build
# user's keyring for makepkg --sign; it is copied out of the read-only mount so the
# unprivileged builder can read it.
gpg --quiet --import "$KEYFILE"
gpg --quiet --list-keys "$FPR" >/dev/null ||
  fail "the private key at $KEYFILE is not the key $FPR that $TRUSTED trusts"
id "$BUILDUSER" >/dev/null 2>&1 || useradd -m -s /bin/bash "$BUILDUSER"
printf '%s ALL=(ALL) NOPASSWD: ALL\n' "$BUILDUSER" >/etc/sudoers.d/20-repo-build
chmod 0440 /etc/sudoers.d/20-repo-build
install -m 0644 -o "$BUILDUSER" -g "$BUILDUSER" "$KEYFILE" "$BUILDROOT/repo.key"
su - "$BUILDUSER" -c "gpg --quiet --import '$BUILDROOT/repo.key'"

# Build order: packages/order, not the alphabetical directory order. A dependent's
# makedepends must already be installed in this container, so each package is installed
# as soon as it is built.
ORDER="$PKGDIR/order"
[ -f "$ORDER" ] || fail "no build order at $ORDER"
mapfile -t ORDERED < <(sed 's/#.*//; s/[[:space:]]*$//' "$ORDER" | grep -v '^[[:space:]]*$')
[ ${#ORDERED[@]} -gt 0 ] || fail "$ORDER is empty"

# The list and the directory must agree exactly: every packages/*/ with a PKGBUILD once,
# and no entry without a PKGBUILD. Otherwise a new package builds in an arbitrary order.
shopt -s nullglob
declare -A listed=()
for name in "${ORDERED[@]}"; do
  [ -f "$PKGDIR/$name/PKGBUILD" ] || fail "$ORDER lists $name, which has no PKGBUILD"
  [ -z "${listed[$name]:-}" ] || fail "$ORDER lists $name more than once"
  listed[$name]=1
done
for dir in "$PKGDIR"/*/; do
  name=$(basename "$dir")
  [ -f "$dir/PKGBUILD" ] || continue
  [ -n "${listed[$name]:-}" ] || fail "$PKGDIR/$name has a PKGBUILD but is absent from $ORDER"
done

# Trust the committed public half in pacman's keyring so pacman -U accepts the signed
# packages below; a dependent's makepkg --syncdeps resolves against this container, not
# against [emunix], which is not configured here.
pacman-key --init >/dev/null
pacman-key --add "$PUBKEY" >/dev/null
pacman-key --lsign-key "$FPR" >/dev/null

rm -rf "$OUT"
mkdir -p "$OUT"
for name in "${ORDERED[@]}"; do
  echo "building $name"
  build="$BUILDROOT/$name"
  mkdir -p "$build"
  cp -a "$PKGDIR/$name/." "$build/"
  chown -R "$BUILDUSER":"$BUILDUSER" "$build"
  su - "$BUILDUSER" -c "cd '$build' && makepkg --syncdeps --sign --noconfirm" >/dev/null
  cp "$build"/*.pkg.tar.zst "$build"/*.pkg.tar.zst.sig "$OUT"/
  pkgs=("$OUT/$name-"*.pkg.tar.zst)
  [ ${#pkgs[@]} -gt 0 ] || fail "building $name produced no package"
  # Install it into the build container so the next package's makepkg --syncdeps resolves
  # against this container, not against [emunix]. emunix-keyring is the one exception: it is
  # not a build dependency of anything, and its .install adds the [emunix] stanza, whose
  # database this container deliberately does not serve — a stanza with no database makes
  # every later pacman call fail.
  if [ "$name" != emunix-keyring ]; then
    pacman -U --noconfirm "${pkgs[@]}" >/dev/null
  fi
done
rm -f /etc/sudoers.d/20-repo-build

shopt -s nullglob
pkgs=("$OUT"/*.pkg.tar.zst)
[ ${#pkgs[@]} -gt 0 ] || fail "no packages were built"
repo-add --sign --key "$FPR" --include-sigs "$OUT/emunix.db.tar.gz" "${pkgs[@]}" >/dev/null
repo_refuse_unsigned "$OUT" || exit 1

# repo-add leaves .db/.files as symlinks; publish real files so any static host serves them.
for link in "$OUT"/emunix.db "$OUT"/emunix.db.sig "$OUT"/emunix.files "$OUT"/emunix.files.sig; do
  [ -L "$link" ] || continue
  real=$(mktemp)
  cp -L "$link" "$real"
  rm -f "$link"
  mv "$real" "$link"
  chmod 0644 "$link"
done
chmod -R a+rX "$OUT"

# Verify every signature against the committed public half, in a keyring that holds
# nothing else: a package or database signed by any other key is refused here.
repo_verify "$OUT" "$PUBKEY" || fail "signature verification failed"

echo "repo-build: ${#pkgs[@]} package(s) signed and verified against $PUBKEY"
echo "repo-build: $OUT"
