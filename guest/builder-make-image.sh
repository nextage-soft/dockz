#!/bin/sh
# Runs INSIDE an unprivileged alpine container (see build-guest-image.sh).
# Packs /work/rootfs.tar into a bootable GPT disk image without loop devices:
#   - ESP (FAT32, grub-mkimage standalone arm64-efi binary) populated via mtools
#   - root (ext4) populated offline via mke2fs -d
#   - both dd'ed into a GPT-partitioned raw image at fixed MiB offsets
set -eux

apk add --no-cache e2fsprogs mtools dosfstools sfdisk grub grub-efi tar coreutils

ESP_MB=64
ROOT_MB=2960
DISK_MB=3072

mkdir -p /tmp/rootfs
tar -xf /work/rootfs.tar -C /tmp/rootfs
# docker export leaves these behind; openrc would detect "docker" and skip
# fsck/root/localmount, leaving / read-only in the VM.
rm -f /tmp/rootfs/.dockerenv /tmp/rootfs/.dockerinit

# --- ESP with a standalone grub image (no grub-install, no NVRAM needed) ---
grub-mkimage -O arm64-efi -o /tmp/BOOTAA64.EFI -p '(hd0,gpt2)/boot/grub' \
    part_gpt ext2 normal linux configfile search search_label echo ls sleep
mkdir -p /tmp/esp/EFI/BOOT
cp /tmp/BOOTAA64.EFI /tmp/esp/EFI/BOOT/BOOTAA64.EFI

truncate -s "${ESP_MB}M" /tmp/esp.img
mkfs.vfat -F32 -n DOCKZ-ESP /tmp/esp.img
mcopy -i /tmp/esp.img -s /tmp/esp/EFI ::/

# --- Root filesystem populated straight from the extracted rootfs ---
truncate -s "${ROOT_MB}M" /tmp/root.img
mkfs.ext4 -q -L dockz-root -d /tmp/rootfs /tmp/root.img

# --- Assemble the GPT disk (1MiB alignment; sector = 512 bytes) ---
truncate -s "${DISK_MB}M" /tmp/disk.img
sfdisk /tmp/disk.img <<EOF
label: gpt
unit: sectors
start=2048, size=$((ESP_MB * 2048)), type=uefi, name=esp
start=$(( (1 + ESP_MB) * 2048 )), size=$((ROOT_MB * 2048)), type=linux, name=root
EOF

dd if=/tmp/esp.img of=/tmp/disk.img bs=1M seek=1 conv=notrunc
dd if=/tmp/root.img of=/tmp/disk.img bs=1M seek=$((1 + ESP_MB)) conv=notrunc

gzip -1 -c /tmp/disk.img > /work/disk.img.gz
echo "builder: disk image packed to /work/disk.img.gz"
