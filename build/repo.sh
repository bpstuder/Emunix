#!/usr/bin/env bash
# Build the [emunix] pacman repository in the Arch container and, with --publish, push
# the database and packages to the gh-pages branch (GitHub Pages).
#
# The private key is BP's and never enters this repository: point EMUNIX_GPG_KEY at it
# (default ~/.emunix/repo.key) and it is mounted read-only into the container. The
# public half is committed at packages/emunix-keyring/emunix.gpg; repo-build.sh refuses
# to publish any package or database whose signature does not verify against it.
set -euo pipefail
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
REPO=$(dirname "$SCRIPT_DIR")
PRIVKEY=${EMUNIX_GPG_KEY:-$HOME/.emunix/repo.key}
IMAGE=${EMUNIX_REPO_IMAGE:-archlinux:latest}
OUT=${EMUNIX_REPO_OUT:-$REPO/out/repo}
PUBLISH=0
if [ "${1:-}" = "--publish" ]; then PUBLISH=1; shift; fi
[ $# -eq 0 ] || { echo "usage: repo.sh [--publish]" >&2; exit 1; }

fail() { printf 'repo.sh: %s\n' "$*" >&2; exit 1; }
[ -f "$REPO/packages/emunix-keyring/emunix.gpg" ] ||
  fail "no public key at packages/emunix-keyring/emunix.gpg (BP's public half is missing)"
[ -f "$PRIVKEY" ] || fail "no private key at $PRIVKEY (set EMUNIX_GPG_KEY)"
command -v docker >/dev/null 2>&1 || fail "docker is required to build in the Arch container"

publish() {
  local tmp remote
  remote=$(git -C "$REPO" remote get-url origin) ||
    { printf 'repo.sh: %s has no origin remote to publish to\n' "$REPO" >&2; exit 1; }
  tmp=$(mktemp -d)
  if git ls-remote --exit-code --heads "$remote" gh-pages >/dev/null 2>&1; then
    git clone --quiet --branch gh-pages --single-branch "$remote" "$tmp"
  else
    git clone --quiet --depth 1 "$remote" "$tmp"
    git -C "$tmp" checkout --quiet --orphan gh-pages
    git -C "$tmp" rm -rf --quiet . >/dev/null 2>&1 || true
  fi
  cp "$OUT"/emunix.db "$OUT"/emunix.db.sig "$OUT"/emunix.files "$OUT"/emunix.files.sig \
    "$OUT"/*.pkg.tar.zst "$OUT"/*.pkg.tar.zst.sig "$tmp"/
  git -C "$tmp" add -A
  git -C "$tmp" -c user.name=emunix-repo -c user.email=emunix-repo@users.noreply.github.com \
    commit --quiet -m "emunix repo: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  git -C "$tmp" push --quiet origin gh-pages
  rm -rf "$tmp"
}

docker run --rm \
  -v "$REPO:/work" \
  -v "$PRIVKEY:/run/secrets/emunix-repo.key:ro" \
  -w /work "$IMAGE" \
  bash build/repo-build.sh /run/secrets/emunix-repo.key

[ "$PUBLISH" -eq 0 ] || publish

echo "repo.sh: repository is at $OUT"
[ "$PUBLISH" -eq 0 ] || echo "repo.sh: published to the gh-pages branch (https://bpstuder.github.io/Emunix/)"
