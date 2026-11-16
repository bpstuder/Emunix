# The `[emunix]` pacman repository

Packages that are not in the official Arch repositories — the ES-DE frontend, `ryzenadj`,
`rog-control-center`, the updater, default themes — are built from `packages/` and published
as a pacman repository on GitHub Pages:

```text
https://bpstuder.github.io/Emunix/
```

`build/build-image.sh` consumes it: the image build installs `emunix-keyring` and `ryzenadj`
from `[emunix]` with signature checking on. Nothing is installed from it at runtime (see
below).

## Layout

```text
packages/<name>/PKGBUILD   one directory per package; sources are pinned (release tarball +
                           sha256, or a pinned VCS commit for an AUR-shaped package)
packages/emunix-keyring/   the public half of the signing key and the [emunix] stanza
build/repo-build.sh        builds every PKGBUILD in the Arch container, signs, repo-adds
build/repo.sh              runs repo-build.sh in the container and optionally publishes
```

## Signing key

The repository is signed with a **GPG** key: pacman verifies repository and package
signatures with GnuPG, so unlike the minisign update manifest (`update/README.md`) the repo
cannot use a minisign key. The key is an **Ed25519** key — the same algorithm family as the
update-signing key.

- **Private half:** BP's. It never enters this repository, the image or CI. Point
  `EMUNIX_GPG_KEY` at it (default `~/.emunix/repo.key`); `build/repo.sh` mounts it read-only
  into the build container.
- **Public half:** committed at `packages/emunix-keyring/emunix.gpg`, with the trusted
  fingerprint in `packages/emunix-keyring/emunix-trusted`. The image carries it at
  `/usr/share/pacman/keyrings/emunix.gpg`.

Generate the pair and export the public half with:

```sh
gpg --batch --passphrase '' --quick-gen-key 'Emunix Repo <repo@emunix.local>' ed25519 sign 0
FPR=$(gpg --list-keys --with-colons | awk -F: '/^fpr:/ {print $10; exit}')
gpg --export "$FPR" > packages/emunix-keyring/emunix.gpg
echo "$FPR:4:" > packages/emunix-keyring/emunix-trusted
```

`repo-build.sh` refuses to publish any package or database that is unsigned, and refuses to
publish if a signature does not verify against the committed public half. It never prints
the private key.

## Building and publishing

```sh
EMUNIX_GPG_KEY=~/.emunix/repo.key ./build/repo.sh            # build + sign + verify
EMUNIX_GPG_KEY=~/.emunix/repo.key ./build/repo.sh --publish  # ... and push to gh-pages
```

`--publish` replaces the contents of the `gh-pages` branch with the built database and
packages and pushes it. It is never run automatically. GitHub Pages must be enabled for the
repository (Settings → Pages → Deploy from a branch → `gh-pages`).

## Using the repository

The `emunix-keyring` package installs the public key and the stanza:

```sh
sudo pacman -S emunix-keyring
sudo pacman-key --init
sudo pacman-key --populate emunix
sudo pacman -S ryzenadj
```

Or add the stanza by hand and trust the key:

```sh
sudo tee -a /etc/pacman.conf >/dev/null <<'EOF'

[emunix]
Server = https://bpstuder.github.io/Emunix/
SigLevel = Required DatabaseRequired
EOF
sudo pacman-key --init && sudo pacman-key --populate emunix
```

## This repository is for image builds, not runtime installs

The root filesystem is mounted read-only (`fstab`: `PARTLABEL=rootfs_a / ext4 ro`). Pacman
writes a package's files into `/`, so `pacman -S` cannot install anything at runtime, no
matter which repository it comes from. `/var/lib/pacman` lives on the persistent `var`
partition and the `/etc` overlay keeps `/etc/pacman.conf` (and therefore the `[emunix]`
stanza) writable, but that only makes the database and configuration persistent — it does
not make the root writable. The repository exists so an **image build** can install packages
that the official repositories do not carry; a running device gets new packages from a new
image (the signed update manifest, `update/README.md`).

## Proof that no private key ships

`build/repo-build.sh` reads the key from outside the tree and never prints it; the image
carries only `emunix.gpg`. To check any checkout or mounted image (the docs and the test quote
the markers, so they are excluded — a real key file would not be one):

```sh
grep -rIl 'BEGIN PGP PRIVATE KEY BLOCK' . --exclude='*.md' --exclude='*.sh'   # expected no hits
grep -rIl 'minisign encrypted secret key' . --exclude='*.md' --exclude='*.sh' # expected no hits
```
