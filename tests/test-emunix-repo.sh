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
	if grep -rIl -- "$marker" "$REPO_ROOT" --exclude-dir=.git --exclude-dir=work --exclude-dir=out \
	  --exclude='*.md' --exclude='*.sh' 2>/dev/null | grep -q .; then
		say "FAIL: private key marker \"$marker\" found outside the documentation"
		fails=$((fails + 1))
	else
		say "ok   no \"$marker\" outside the documentation"
	fi
done
[ -f "$REPO_ROOT/packages/emunix-keyring/emunix.gpg" ] &&
	[ -f "$REPO_ROOT/packages/emunix-keyring/emunix-trusted" ] ||
	{ say "FAIL: the committed public key or trusted fingerprint is missing"; fails=$((fails + 1)); }

if [ "$fails" -ne 0 ]; then
	printf '%d test(s) failed\n' "$fails" >&2
	exit 1
fi
printf 'all tests passed\n'
