#!/usr/bin/env bash
# Turn a built image into the signed update manifest devices fetch: emunix.json + emunix.json.minisig.
#
# The private key comes from $MINISIGN_KEY (default ~/.minisign/minisign.key) and is never
# printed; minisign asks for its passphrase. Nothing is left behind unless the trust anchor baked
# at configs/rootfs/etc/emunix/update.pub verifies the result, so a mismatched key cannot ship.
#
# Env: IMAGE (or the first argument), CHANNEL (default stable), BASE_URL (required: the public
# directory that will hold the image), MIN_FROM (default: the image's own version).
set -euo pipefail

IMAGE=${1:?usage: sign-manifest.sh <emunix-<version>-x86_64.img[.zst]>}
CHANNEL=${CHANNEL:-stable}
BASE_URL=${BASE_URL:?set BASE_URL to the public directory holding the image, e.g. https://github.com/bpstuder/Emunix/releases/download/<tag>}
MIN_FROM=${MIN_FROM:-}
KEY=${MINISIGN_KEY:-$HOME/.minisign/minisign.key}
SCRIPT_DIR=$(cd "$(dirname "$0")" && pwd)
PUBKEY=$SCRIPT_DIR/../configs/rootfs/etc/emunix/update.pub

base=$(basename "$IMAGE")
[[ $base =~ ^emunix-(.+)-x86_64\.img(\.zst)?$ ]] || {
  echo "sign-manifest.sh: $base is not emunix-<version>-x86_64.img[.zst]" >&2
  exit 1
}
VERSION=${BASH_REMATCH[1]}
[ -f "$IMAGE" ] || { echo "sign-manifest.sh: $IMAGE does not exist" >&2; exit 1; }
[ -f "$KEY" ] || { echo "sign-manifest.sh: no private key at $KEY (set MINISIGN_KEY)" >&2; exit 1; }
[ -f "$PUBKEY" ] || {
  echo "sign-manifest.sh: no trust anchor at $PUBKEY; BP's public half must be placed there first" >&2
  exit 1
}

SHA=$(sha256sum "$IMAGE" | awk '{print $1}')
SIZE=$(stat -c %s "$IMAGE")
RELEASED=$(date -u +%Y-%m-%dT%H:%M:%SZ)
MIN_FROM=${MIN_FROM:-$VERSION}
OUT=$(dirname "$IMAGE")/emunix.json

printf '{"channel":"%s","version":"%s","released":"%s","image":{"url":"%s/%s","sha256":"%s","size":%s},"min_from":"%s"}\n' \
  "$CHANNEL" "$VERSION" "$RELEASED" "${BASE_URL%/}" "$base" "$SHA" "$SIZE" "$MIN_FROM" >"$OUT"

if ! minisign -S -s "$KEY" -m "$OUT" -x "$OUT.minisig"; then
  echo "sign-manifest.sh: signing failed" >&2
  exit 1
fi
if ! minisign -V -p "$PUBKEY" -m "$OUT" -x "$OUT.minisig" >/dev/null 2>&1; then
  rm -f "$OUT" "$OUT.minisig"
  echo "sign-manifest.sh: refused: $KEY does not match the trust anchor at $PUBKEY; nothing published" >&2
  exit 1
fi

echo "signed $OUT"
echo "  version $VERSION, channel $CHANNEL, min_from $MIN_FROM"
echo "  image sha256 $SHA ($SIZE bytes)"
echo "  url ${BASE_URL%/}/$base"
echo "publish $OUT, $OUT.minisig and $IMAGE together; see update/README.md"
