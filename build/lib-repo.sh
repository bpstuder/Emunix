#!/usr/bin/env bash
# Shared helpers for the [emunix] pacman repository. Sourced by build/repo-build.sh
# and by tests/test-emunix-repo.sh.

# Refuse to publish a repository holding an unsigned package or database.
repo_refuse_unsigned() { # <repo-dir>
	local out=$1 pkg
	shopt -s nullglob
	for pkg in "$out"/*.pkg.tar.zst; do
		if [ ! -f "$pkg.sig" ]; then
			printf 'refusing to publish %s: it has no signature\n' "$pkg" >&2
			return 1
		fi
	done
	if [ ! -f "$out/emunix.db.tar.gz.sig" ]; then
		printf 'refusing to publish %s: the database has no signature\n' "$out" >&2
		return 1
	fi
}

# Verify every signature in <repo-dir> against <pubkey>, in a keyring that holds nothing
# else: a package or database signed by any other key is refused.
repo_verify() { # <repo-dir> <pubkey>
	local out=$1 pubkey=$2 pkg verify
	verify=$(mktemp -d)
	chmod 0700 "$verify"
	gpg --homedir "$verify" --quiet --import "$pubkey" >/dev/null 2>&1
	if ! gpg --homedir "$verify" --verify "$out/emunix.db.tar.gz.sig" "$out/emunix.db.tar.gz" >/dev/null 2>&1; then
		printf 'the database signature does not verify against %s\n' "$pubkey" >&2
		rm -rf "$verify"
		return 1
	fi
	for pkg in "$out"/*.pkg.tar.zst; do
		if ! gpg --homedir "$verify" --verify "$pkg.sig" "$pkg" >/dev/null 2>&1; then
			printf 'the signature on %s does not verify against %s\n' "$pkg" "$pubkey" >&2
			rm -rf "$verify"
			return 1
		fi
	done
	rm -rf "$verify"
}
