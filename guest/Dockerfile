# Builds the Alpine rootfs for the Dockz guest VM. The resulting container
# filesystem is exported with `docker export` and packed into a bootable
# GPT disk image by builder-make-image.sh.
FROM alpine:3.22

# Overridden by build-guest-image.sh with the host's $HOME; this is only a
# neutral fallback so the image builds without leaking a specific username.
ARG SHARE_PATH=/root

RUN apk add --no-cache \
    alpine-base linux-virt grub grub-efi mkinitfs \
    docker docker-cli-compose \
    socat iproute2 \
    e2fsprogs e2fsprogs-extra sfdisk util-linux-misc

# The vsock agents depend on socat's VSOCK address support.
RUN socat -V | grep -qi vsock

COPY rootfs/ /

RUN chmod +x /etc/init.d/dockz-agent /etc/init.d/dockz-resize /etc/init.d/rosetta-binfmt \
      /usr/local/bin/dockz-print-ip /usr/local/bin/dockz-poweroff \
 && sed -i "s|@SHARE_PATH@|${SHARE_PATH}|g" /etc/fstab \
 && mkdir -p "${SHARE_PATH}" /media/rosetta /boot/efi \
 && echo dockz > /etc/hostname \
 && passwd -d root \
 && echo 'rc_cgroup_mode="unified"' >> /etc/rc.conf \
 && echo 'rc_sys=""' >> /etc/rc.conf \
 && printf 'virtio_vsock\nvirtiofs\n' >> /etc/modules \
 && echo 'hvc0::respawn:/sbin/getty -L hvc0 115200 vt100' >> /etc/inittab \
 && for s in devfs dmesg mdev hwdrivers; do rc-update add "$s" sysinit; done \
 && for s in modules sysctl hostname fsck root localmount hwclock seedrng bootmisc syslog networking dockz-resize; do rc-update add "$s" boot; done \
 && for s in docker dockz-agent rosetta-binfmt; do rc-update add "$s" default; done \
 && for s in mount-ro killprocs savecache; do rc-update add "$s" shutdown; done

# Regenerate the initramfs with virtio support (mkinitfs.conf came from rootfs/).
RUN mkinitfs -c /etc/mkinitfs/mkinitfs.conf -b / "$(ls /lib/modules)"
