# Partition layout (GPT)

1. esp        vfat  1GiB   /boot
2. rootfs_a   ext4  8GiB   / (ro, active slot)
3. rootfs_b   ext4  8GiB   (inactive slot)
4. var        btrfs 2GiB   /var
5. home       btrfs rest    /home (+ /storage subvol)
