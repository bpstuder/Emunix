# Update manifests and the signing key

A device updates by fetching a signed manifest (`emunix.json`) and verifying it with
[minisign](https://jedisct1.github.io/minisign/) against the public key baked into the image at
`/etc/emunix/update.pub`. The private half never enters this repository or CI; BP holds it
(decisions note, "Update-signing key custody").

## Manifest schema

```json
{
  "channel": "stable",
  "version": "2026.11.13",
  "released": "2026-11-13T08:00:00Z",
  "image": {
    "url": "https://github.com/bpstuder/Emunix/releases/download/2026.11.13/emunix-2026.11.13-x86_64.img.zst",
    "sha256": "<64 hex characters>",
    "size": 1234567890
  },
  "min_from": "2026.11.01"
}
```

| field | meaning |
| --- | --- |
| `channel` | Release channel. A device only applies a manifest whose channel equals its own (`EMUNIX_CHANNEL`, default `stable`). |
| `version` | The image's version. Applied only when it is newer than the installed `/etc/emunix-version`. |
| `released` | UTC release timestamp, informational. |
| `image.url` | HTTPS URL of the image. Must be `https:`; the hash check pins the bytes. |
| `image.sha256` | SHA-256 of the image file, checked after download. |
| `image.size` | Exact byte size, checked after the hash. |
| `min_from` | Downgrade floor: a manifest whose `version` sorts below `min_from` is refused, so a known-flawed release cannot be re-published over a device. |

The signature covers the manifest bytes only; the manifest's `sha256`/`size` pin the image. All of
it is enforced by `build/lib-update.sh` (`check_update`), which refuses an unreadable input, a bad
signature, a missing or malformed field, another channel, a non-https URL, a sub-floor version, a
non-newer version and a hash/size mismatch.

## Signing a release

```sh
BASE_URL=https://github.com/bpstuder/Emunix/releases/download/<tag> \
  ./build/sign-manifest.sh out/emunix-<version>-x86_64.img.zst
```

The script computes `sha256`/`size`, writes `emunix.json` and `emunix.json.minisig` next to the
image, then verifies its own output against `configs/rootfs/etc/emunix/update.pub`; if the key
does not match that anchor, both files are removed and nothing is published. The private key
defaults to `~/.minisign/minisign.key` (override with `MINISIGN_KEY`); minisign asks for its
passphrase interactively. Keep it offline and backed up — see below.

## Publishing

Either target works; the device only needs an HTTPS URL for the manifest, its signature and the
image. Publish all three together — an image without its manifest, or a manifest without its
signature, is unusable by design.

- **GitHub Releases** (decisions note §5): attach the image and the two manifest files to a release
  tag matching `version`:
  ```sh
  gh release create <tag> out/emunix-<version>-x86_64.img.zst out/emunix.json out/emunix.json.minisig
  ```
- **GitHub Pages**: copy the three files under a stable path, e.g. `.../emunix/stable/`.

Note: assets of a *private* repository require authentication to download and devices carry no
credentials, so whatever is published must be reachable over HTTPS without a login (public repo,
public Pages site, or another static host).

## Endpoint layout

The device fetches the manifest and its signature from the publish base URL, and the image from
the absolute `image.url` inside the manifest:

```text
<base>/emunix.json          manifest
<base>/emunix.json.minisig  its minisign signature
<base>/<image filename>     the image (also named by image.url)
```

`build/sign-manifest.sh` writes the manifest and signature next to the image, so `<base>` is the
release or Pages directory you publish from.

## Applying an update

The image ships `emunix-os-updater` (installed from `build/os-updater.sh`) and a daily timer,
`emunix-os-updater.timer`, that runs it on AC power. A run:

1. reads the running slot from the root partition label (`emunix-slot active`) and refuses to
   continue if it cannot be determined;
2. fetches `emunix.json` and `emunix.json.minisig` from `EMUNIX_REPO_URL` and verifies the
   signature and every field (`check_update`);
3. downloads the image to `/var/cache/emunix/` with resume, checks free space first, and verifies
   its sha256 and size;
4. writes it to `/dev/disk/by-partlabel/rootfs_<inactive>`, runs `e2fsck -f`, and flips the loader
   with `emunix-slot next <inactive>`.

A failed run leaves the active slot untouched, so the device still boots. `--dry-run` prints the
plan (version, url, target partition, bytes) and changes nothing.

## Rotating the key

The trust anchor lives in the image, so rotation is an image release, not a setting:

1. Generate the replacement pair: `minisign -G -p ~/.minisign/new.pub -s ~/.minisign/new.key`.
2. Put the new public half at `configs/rootfs/etc/emunix/update.pub` and build the image normally.
3. Sign that release's manifest with the **old** private key: devices still trust the old anchor,
   and the image they receive carries the new one.
4. Once every deployed device has adopted an image carrying the new key, retire the old key.
   Devices that never adopted it keep trusting the old anchor forever.

## If the key is lost

A device trusts exactly the public half baked into its image. With the private key gone no new
manifest can be made that existing devices will accept: they can only move forward by flashing a
new image. Back up the private half offline (paper or USB in a safe) and treat its loss as a
fleet-wide reflash event. There is no remote recovery path by design.

## Proof that no private key ships

`build/sign-manifest.sh` reads the key from outside the tree and never prints it; the image
carries only `update.pub`. To check any checkout or mounted image:

```sh
grep -rIl 'minisign encrypted secret key' .   # repo: expected no hits
```
