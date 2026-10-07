#!/bin/sh
# Runs INSIDE the Alpine netboot builder VM, driven over the serial console by
# DiskShrinker (sources/dockz/disk-shrinker.swift). Shrinks an existing DockZ
# disk (GPT: vda1 ESP, vda2 ext4 root — the last partition) so the host can
# truncate the image to TARGET_SECTORS. ext4 can only be shrunk unmounted,
# which is why this runs here and not in the guest itself.
#
# Env: TARGET_SECTORS      — new disk size in 512-byte sectors
#      HEADROOM_BYTES      — free space the shrunk filesystem must still have
#
# Markers for the host (one line each):
#   DOCKZ-SHRINK-STEP:<label>
#   DOCKZ-SHRINK-TOOSMALL:<minimum filesystem bytes>
#   DOCKZ-SHRINK-FAIL:<reason>
#   DOCKZ-SHRINK-DONE
# The host keeps an APFS clone of the image and restores it on anything but
# DONE, so a failure at any point leaves the original disk untouched.
set -u

TARGET_SECTORS="${TARGET_SECTORS:?TARGET_SECTORS must be set}"
HEADROOM_BYTES="${HEADROOM_BYTES:?HEADROOM_BYTES must be set}"

fail() { echo "DOCKZ-SHRINK-FAIL:$1"; sync; poweroff; exit 1; }
step() { echo "DOCKZ-SHRINK-STEP:$1"; }

step "installing filesystem tools"
apk add e2fsprogs e2fsprogs-extra sfdisk >/dev/null || fail "could not install e2fsprogs/sfdisk (no network?)"
modprobe ext4 2>/dev/null || true
mdev -s 2>/dev/null || true

[ -b /dev/vda2 ] || fail "the disk has no root partition (vda2)"
DISK_SECTORS=$(cat /sys/block/vda/size)
P2_START=$(cat /sys/block/vda/vda2/start)
[ "$TARGET_SECTORS" -lt "$DISK_SECTORS" ] || fail "target is not smaller than the disk"

# Root ends 1 MiB-aligned, before the 33 sectors of the GPT backup (header +
# 32 sectors of entries) at the very end of the new disk.
P2_SECTORS=$(( (TARGET_SECTORS - 34 - P2_START) / 2048 * 2048 ))
[ "$P2_SECTORS" -gt 0 ] || fail "target is smaller than the boot partition"

step "checking the filesystem"
e2fsck -f -y /dev/vda2
[ $? -lt 4 ] || fail "e2fsck found errors it could not fix"

BLOCK_SIZE=$(dumpe2fs -h /dev/vda2 2>/dev/null | sed -n 's/^Block size: *//p')
MIN_BLOCKS=$(resize2fs -P /dev/vda2 2>/dev/null | sed -n 's/.*: *//p' | tail -n1)
[ -n "$BLOCK_SIZE" ] && [ -n "$MIN_BLOCKS" ] || fail "could not read the filesystem size"
MIN_BYTES=$(( MIN_BLOCKS * BLOCK_SIZE ))
if [ $(( MIN_BYTES + HEADROOM_BYTES )) -gt $(( P2_SECTORS * 512 )) ]; then
    echo "DOCKZ-SHRINK-TOOSMALL:$MIN_BYTES"
    sync; poweroff; exit 1
fi

step "shrinking the filesystem"
resize2fs /dev/vda2 "${P2_SECTORS}s" || fail "resize2fs could not shrink the filesystem"

# A GPT names its own end (last usable LBA, backup location), so it must be
# rewritten for the smaller disk. Build it with sfdisk on a sparse file of the
# new size (same label id, partitions, UUIDs and names; root shortened), then
# copy its primary (sectors 0-33) and backup (last 33 sectors) onto the disk at
# the places they will occupy once the host truncates the image.
step "rewriting the partition table"
sfdisk --dump /dev/vda > /tmp/table.old || fail "could not read the partition table"
grep -v -e '^device:' -e '^last-lba:' /tmp/table.old \
    | sed 's#^/dev/vda[0-9]* *: *##' \
    | awk -v start="$P2_START" -v size="$P2_SECTORS" '
        /^start=/ && $0 ~ ("^start= *" start ",") { sub(/size= *[0-9]+/, "size=" size) }
        { print }' > /tmp/table.new
grep -q "size=$P2_SECTORS," /tmp/table.new || fail "could not prepare the new partition table"
rm -f /tmp/gpt.img
truncate -s $(( TARGET_SECTORS * 512 )) /tmp/gpt.img
sfdisk --no-reread --no-tell-kernel /tmp/gpt.img < /tmp/table.new >/dev/null \
    || fail "sfdisk rejected the new partition table"
dd if=/tmp/gpt.img of=/dev/vda bs=512 count=34 conv=notrunc 2>/dev/null \
    || fail "could not write the primary partition table"
dd if=/tmp/gpt.img of=/dev/vda bs=512 skip=$(( TARGET_SECTORS - 33 )) \
    seek=$(( TARGET_SECTORS - 33 )) count=33 conv=notrunc 2>/dev/null \
    || fail "could not write the backup partition table"
sync

step "verifying"
e2fsck -f -n /dev/vda2 >/dev/null 2>&1 || fail "the shrunk filesystem did not check clean"
echo "DOCKZ-SHRINK-DONE"
sync
poweroff
