#!/bin/sh
# Runs INSIDE the Alpine netboot builder VM, driven over the serial console by
# `Dockz build-image`. Installs Alpine + dockerd onto /dev/vda from scratch —
# no Docker daemon involved anywhere. The dockz config files come from the
# virtiofs share mounted at /w (the repo's guest/ directory).
#
# Env: SHARE_PATH — host home directory to mirror inside the guest.
set -eux

SHARE_PATH="${SHARE_PATH:?SHARE_PATH must be set}"
# PROFILE=docker → the dockerd engine VM; PROFILE=machine → a general-purpose
# multipass-style VM (sshd + curl/bash, no docker). PUBKEY, when set, becomes
# root's authorized_keys (machine profile).
PROFILE="${PROFILE:-docker}"
PUBKEY="${PUBKEY:-}"

# docker & friends live in the community repository (netboot sets up main only)
community_repo="$(sed -n 's|/main$|/community|p' /etc/apk/repositories | head -n1)"
grep -q "$community_repo" /etc/apk/repositories || echo "$community_repo" >> /etc/apk/repositories

apk add sfdisk e2fsprogs dosfstools grub grub-efi

# The netboot environment runs from RAM; filesystem drivers are modules.
modprobe ext4 2>/dev/null || true
modprobe vfat 2>/dev/null || true

# --- Partition the whole disk (ESP + root over the rest) ---
sfdisk /dev/vda <<EOF
label: gpt
start=2048, size=131072, type=uefi, name=esp
type=linux, name=root
EOF
mdev -s 2>/dev/null || true
sleep 1

mkfs.vfat -F32 -n DOCKZ-ESP /dev/vda1
mkfs.ext4 -q -L dockz-root /dev/vda2
mount /dev/vda2 /mnt
mkdir -p /mnt/boot/efi
mount /dev/vda1 /mnt/boot/efi

# --- Base system straight from the apk repository ---
COMMON_PKGS="alpine-base linux-virt socat iproute2 e2fsprogs e2fsprogs-extra sfdisk util-linux-misc grub grub-efi mkinitfs"
if [ "$PROFILE" = "machine" ]; then
    PROFILE_PKGS="openssh sudo bash curl ca-certificates htop nano"
else
    PROFILE_PKGS="docker docker-cli-compose"
fi
apk --root /mnt --initdb --arch aarch64 \
    --keys-dir /etc/apk/keys --repositories-file /etc/apk/repositories \
    add $COMMON_PKGS $PROFILE_PKGS
cp /etc/apk/repositories /mnt/etc/apk/repositories

# --- Dockz configuration (same rootfs/ files as the docker-based build) ---
cp -R /w/rootfs/. /mnt/
chmod +x /mnt/etc/init.d/dockz-agent /mnt/etc/init.d/dockz-resize \
    /mnt/etc/init.d/rosetta-binfmt /mnt/usr/local/bin/dockz-print-ip \
    /mnt/usr/local/bin/dockz-poweroff
sed -i "s|@SHARE_PATH@|${SHARE_PATH}|g" /mnt/etc/fstab
mkdir -p "/mnt${SHARE_PATH}" /mnt/media/rosetta
echo dockz > /mnt/etc/hostname
chroot /mnt passwd -d root
echo 'rc_cgroup_mode="unified"' >> /mnt/etc/rc.conf
echo 'rc_sys=""' >> /mnt/etc/rc.conf
printf 'virtio_vsock\nvirtiofs\n' >> /mnt/etc/modules
echo 'hvc0::respawn:/sbin/getty -L hvc0 115200 vt100' >> /mnt/etc/inittab

for s in devfs dmesg mdev hwdrivers; do chroot /mnt rc-update add "$s" sysinit; done
for s in modules sysctl hostname fsck root localmount hwclock seedrng bootmisc \
         syslog networking dockz-resize; do chroot /mnt rc-update add "$s" boot; done
if [ "$PROFILE" = "machine" ]; then
    for s in sshd dockz-agent; do chroot /mnt rc-update add "$s" default; done
else
    for s in docker dockz-agent rosetta-binfmt; do chroot /mnt rc-update add "$s" default; done
fi
for s in mount-ro killprocs savecache; do chroot /mnt rc-update add "$s" shutdown; done

if [ "$PROFILE" = "machine" ]; then
    # Key-only root SSH for the multipass-style machines.
    mkdir -p /mnt/root/.ssh
    if [ -n "$PUBKEY" ]; then
        echo "$PUBKEY" > /mnt/root/.ssh/authorized_keys
        chmod 700 /mnt/root/.ssh
        chmod 600 /mnt/root/.ssh/authorized_keys
    fi
    echo "PermitRootLogin prohibit-password" >> /mnt/etc/ssh/sshd_config
    # Pre-generate host keys so sshd binds port 22 immediately on first boot
    # (otherwise ssh-keygen -A runs at boot and delays the listener by seconds).
    chroot /mnt ssh-keygen -A
    # cgroups v2 mounted for k3s and friends.
    echo 'rc_cgroup_mode="unified"' >> /mnt/etc/rc.conf || true
fi

# --- initramfs with virtio, standalone grub EFI binary (no NVRAM needed) ---
chroot /mnt mkinitfs -c /etc/mkinitfs/mkinitfs.conf -b / "$(ls /mnt/lib/modules)"
grub-mkimage -O arm64-efi -o /tmp/BOOTAA64.EFI -p '(hd0,gpt2)/boot/grub' \
    part_gpt ext2 normal linux configfile search search_label echo ls sleep
mkdir -p /mnt/boot/efi/EFI/BOOT
cp /tmp/BOOTAA64.EFI /mnt/boot/efi/EFI/BOOT/BOOTAA64.EFI

sync
umount /mnt/boot/efi /mnt
echo DOCKZ-PROVISION-DONE
poweroff
