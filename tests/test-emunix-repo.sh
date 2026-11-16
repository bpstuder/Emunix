#!/usr/bin/env bash
# [emunix] repo guards: signatures verify against the committed public half, a foreign
# key or a tampered database is refused, an unsigned package or database is refused, and
# no private key material is committed.
set -uo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
# shellcheck source-path=SCRIPTDIR
# shellcheck source=../build/lib-repo.sh
. "$HERE/../build/lib-repo.sh"

command -v gpg >/dev/null 2>&1 || { echo "FAIL: gpg is required" >&2; exit 1; }

TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
fails=0
export GNUPGHOME="$TMP/gnupg"
mkdir -p "$GNUPGHOME" "$TMP/repo"
chmod 0700 "$GNUPGHOME"

say() { printf '%s\n' "$*"; }
expect_ok() {
	local name=$1 out rc
	shift
	out=$("$@" 2>&1); rc=$?
	say "$out"
	if [ "$rc" -eq 0 ]; then say "ok   $name"; else say "FAIL $name"; fails=$((fails + 1)); fi
}
expect_refused() {
	local name=$1 out rc
	shift
	out=$("$@" 2>&1); rc=$?
	say "$out"
	if [ "$rc" -ne 0 ]; then say "ok   $name"; else say "FAIL $name: accepted"; fails=$((fails + 1)); fi
}

gpg --batch --passphrase '' --quick-gen-key "Emunix Repo Test <repo@emunix.local>" ed25519 sign 0 >/dev/null 2>&1
gpg --batch --passphrase '' --quick-gen-key "Emunix Repo Other <other@emunix.local>" ed25519 sign 0 >/dev/null 2>&1
FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
OTHER=$(gpg --list-keys --with-colons | awk -F: '/^fpr:/ {print $10}' | sed -n 2p)
gpg --export "$FPR" >"$TMP/pub.gpg"
gpg --export "$OTHER" >"$TMP/other.gpg"

head -c 4096 /dev/urandom >"$TMP/repo/emunix-probe-1.0-1-x86_64.pkg.tar.zst"
echo db >"$TMP/repo/emunix.db.tar.gz"
gpg --detach-sign -o "$TMP/repo/emunix-probe-1.0-1-x86_64.pkg.tar.zst.sig" "$TMP/repo/emunix-probe-1.0-1-x86_64.pkg.tar.zst"
gpg --detach-sign -o "$TMP/repo/emunix.db.tar.gz.sig" "$TMP/repo/emunix.db.tar.gz"

expect_ok "genuine signatures accepted" repo_verify "$TMP/repo" "$TMP/pub.gpg"
expect_refused "foreign key refused" repo_verify "$TMP/repo" "$TMP/other.gpg"

rm -f "$TMP/repo/emunix.db.tar.gz.sig"
expect_refused "unsigned database refused" repo_refuse_unsigned "$TMP/repo"
gpg --detach-sign -o "$TMP/repo/emunix.db.tar.gz.sig" "$TMP/repo/emunix.db.tar.gz"

rm -f "$TMP/repo/emunix-probe-1.0-1-x86_64.pkg.tar.zst.sig"
expect_refused "unsigned package refused" repo_refuse_unsigned "$TMP/repo"
gpg --detach-sign -o "$TMP/repo/emunix-probe-1.0-1-x86_64.pkg.tar.zst.sig" "$TMP/repo/emunix-probe-1.0-1-x86_64.pkg.tar.zst"

echo tampered >"$TMP/repo/emunix.db.tar.gz"
expect_refused "tampered database refused" repo_verify "$TMP/repo" "$TMP/pub.gpg"

# The committed keyring files are the only key material in the tree, and they are public.
# The grep skips the documentation and test that quote the markers; a real private key file
# would live outside those.
REPO_ROOT=$(dirname "$HERE")
for marker in 'BEGIN PGP PRIVATE KEY BLOCK' 'minisign encrypted secret key'; do
	if grep -rIq --exclude-dir=.git --exclude-dir=work --exclude-dir=out \
	  --exclude='*.md' --exclude='*.sh' -- "$marker" "$REPO_ROOT" 2>/dev/null; then
		say "FAIL: private key marker \"$marker\" found outside the documentation"
		fails=$((fails + 1))
	else
		say "ok   no \"$marker\" outside the documentation"
	fi
done
[ -f "$REPO_ROOT/packages/emunix-keyring/emunix.gpg" ] &&
	[ -f "$REPO_ROOT/packages/emunix-keyring/emunix-trusted" ] ||
	{ say "FAIL: the committed public key or trusted fingerprint is missing"; fails=$((fails + 1)); }

# --- packages/order: the build order is explicit, complete and dependency-correct ---
ORDER="$REPO_ROOT/packages/order"
[ -f "$ORDER" ] || { say "FAIL: no build order at $ORDER"; fails=$((fails + 1)); }
order_names=()
while read -r n _; do
	[ -n "$n" ] || continue
	order_names+=("$n")
done < <(sed 's/#.*//; s/[[:space:]]*$//' "$ORDER" 2>/dev/null | grep -v '^[[:space:]]*$')
[ ${#order_names[@]} -gt 0 ] || { say "FAIL: $ORDER is empty"; fails=$((fails + 1)); }

declare -A seen=()
order_ok=1
for n in "${order_names[@]}"; do
	if [ ! -f "$REPO_ROOT/packages/$n/PKGBUILD" ]; then
		say "FAIL: $ORDER lists $n, which has no PKGBUILD"; order_ok=0
	fi
	if [ -n "${seen[$n]:-}" ]; then
		say "FAIL: $ORDER lists $n more than once"; order_ok=0
	fi
	seen[$n]=1
done
for d in "$REPO_ROOT"/packages/*/; do
	n=$(basename "$d")
	[ -f "$d/PKGBUILD" ] || continue
	if [ -z "${seen[$n]:-}" ]; then
		say "FAIL: packages/$n has a PKGBUILD but is absent from $ORDER"; order_ok=0
	fi
done
[ "$order_ok" -eq 1 ] && say "ok   packages/order covers every package exactly once" || fails=$((fails + 1))

freeimage_at=-1
esde_at=-1
i=0
for n in "${order_names[@]}"; do
	[ "$n" = freeimage ] && freeimage_at=$i
	[ "$n" = emulationstation-de ] && esde_at=$i
	i=$((i + 1))
done
if [ "$freeimage_at" -ge 0 ] && [ "$esde_at" -ge 0 ] && [ "$freeimage_at" -lt "$esde_at" ]; then
	say "ok   freeimage is built before emulationstation-de"
else
	say "FAIL: freeimage must precede emulationstation-de in $ORDER"; fails=$((fails + 1))
fi

# The two packages are pinned by checksum, not SKIP.
for pb in freeimage emulationstation-de; do
	if grep -q 'SKIP' "$REPO_ROOT/packages/$pb/PKGBUILD"; then
		say "FAIL: packages/$pb/PKGBUILD pins nothing (SKIP)"; fails=$((fails + 1))
	else
		say "ok   packages/$pb/PKGBUILD has no SKIP checksum"
	fi
done

# They are installed from [emunix], not built from AUR.
for p in freeimage emulationstation-de; do
	if sed 's/#.*//' "$REPO_ROOT/profiles/aur.txt" | grep -qE "^$p([[:space:]]|$)"; then
		say "FAIL: profiles/aur.txt still builds $p from AUR"; fails=$((fails + 1))
	else
		say "ok   profiles/aur.txt no longer builds $p"
	fi
done
grep -q 'pacman -S --noconfirm emunix-keyring ryzenadj freeimage emulationstation-de' \
	"$REPO_ROOT/build/build-image.sh" ||
	{ say "FAIL: build-image.sh does not install freeimage + emulationstation-de"; fails=$((fails + 1)); }
grep -q "pacman -S --print-format '%r'" "$REPO_ROOT/build/build-image.sh" ||
	{ say "FAIL: build-image.sh does not assert the [emunix] provenance"; fails=$((fails + 1)); }

if [ "$fails" -ne 0 ]; then
	printf '%d test(s) failed\n' "$fails" >&2
	exit 1
fi
printf 'all tests passed\n'
