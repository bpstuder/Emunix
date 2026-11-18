# Partition layout (GPT)

Minimum media: **16 GB**. The image is 13.5 GiB; a 16 GB stick has 15.02 GiB usable after the
vendor's own overhead (BP's: 31,490,048 sectors). `build/verify-image.sh` fails a build whose image
exceeds 14 GiB or whose partition sizes differ from this table.

1. esp        vfat  512MiB  /boot
2. rootfs_a   ext4  5GiB    / (ro, active slot)
3. rootfs_b   ext4  5GiB    (inactive slot)
4. var        btrfs 2GiB    /var — do not shrink: the updater needs room for the compressed artifact
5. home       btrfs rest    /home (+ /storage subvol), grown to the device end on first boot

The rootfs slots may stay the same size or shrink between releases, never grow: the updater streams
a release's `rootfs_a` into the inactive slot (see `update/README.md`).
