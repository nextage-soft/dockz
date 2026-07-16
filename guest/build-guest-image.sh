#!/bin/bash
# Builds the Alpine guest disk image with Docker (any daemon: colima, dockz…)
# and installs it to ~/.dockz/disk.img (sparse-extended to 64G).
#
# Usage: build-guest-image.sh [--force]
set -euo pipefail
cd "$(dirname "$0")"

TARGET="$HOME/.dockz/disk.img"
if [[ -f "$TARGET" && "${1:-}" != "--force" ]]; then
    echo "error: $TARGET already exists (contains your docker data)." >&2
    echo "       Re-run with --force to rebuild and WIPE it." >&2
    exit 1
fi

SHARE_PATH="${SHARE_PATH:-$HOME}"
mkdir -p work

echo "==> Building guest rootfs (share path: $SHARE_PATH)"
docker build --build-arg SHARE_PATH="$SHARE_PATH" -t dockz-guest-rootfs .

echo "==> Exporting rootfs tar"
cid="$(docker create dockz-guest-rootfs)"
trap 'docker rm -f "$cid" >/dev/null 2>&1 || true' EXIT
docker export "$cid" -o work/rootfs.tar
docker rm "$cid" >/dev/null
trap - EXIT

echo "==> Packing bootable disk image"
docker run --rm \
    -v "$PWD/work:/work" \
    -v "$PWD/builder-make-image.sh:/builder.sh:ro" \
    alpine:3.22 sh /builder.sh

echo "==> Installing to $TARGET"
mkdir -p "$HOME/.dockz"
rm -f "$TARGET"
gunzip -c work/disk.img.gz > "$TARGET"
truncate -s 64G "$TARGET"

echo "Done. $TARGET installed (sparse 64G; guest grows its fs on first boot)."
