#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/env.sh"

if [ ! -s "$GKI_BOOT_IMAGE" ]; then
  echo "missing GKI boot image: $GKI_BOOT_IMAGE" >&2
  echo "put the downloaded boot image at local/boot-5.10.img, or set GKI_BOOT_IMAGE=/path/to/boot.img" >&2
  exit 1
fi

boot_img="$UNPACK_GKI_DIR/$(basename "$GKI_BOOT_IMAGE")"

mkdir -p "$UNPACK_GKI_DIR"
cp "$GKI_BOOT_IMAGE" "$boot_img"

(
  cd "$UNPACK_GKI_DIR"
  rm -f kernel ramdisk boot_signature header
  magiskboot unpack "$boot_img" || true
)

if [ ! -s "$UNPACK_GKI_DIR/ramdisk" ]; then
  echo "magiskboot did not produce $UNPACK_GKI_DIR/ramdisk" >&2
  exit 1
fi

ls -lh "$boot_img" "$UNPACK_GKI_DIR/ramdisk"
