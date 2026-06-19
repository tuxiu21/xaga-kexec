#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

"$ADB" shell getprop ro.boot.slot_suffix

"$ADB" shell "su -c 'dd if=/dev/block/by-name/vendor_boot_a of=/data/local/tmp/vendor_boot_a.img bs=4M'"
"$ADB" pull /data/local/tmp/vendor_boot_a.img "$VENDOR_DIR/vendor_boot_a.img"

cd "$VENDOR_DIR"
magiskboot unpack vendor_boot_a.img || true
if [ ! -s "$VENDOR_DIR/ramdisk.cpio" ]; then
  echo "magiskboot did not produce $VENDOR_DIR/ramdisk.cpio" >&2
  exit 1
fi

work="$(mktemp -d "$TMP_ROOT/vendor_base.XXXXXX")"
cleanup()
{
  rm -rf "$work"
}
trap cleanup EXIT

cd "$work"
cp "$VENDOR_DIR/ramdisk.cpio" ramdisk.cpio

magiskboot cpio ramdisk.cpio \
  'extract lib/modules/mt6315-regulator.ko mt6315-regulator.ko'

perl -0pi -e 's/mediatek,mt6315_7-regulator/mediatek,mt6315_x-regulator/g' mt6315-regulator.ko

magiskboot cpio ramdisk.cpio \
  'add 0644 lib/modules/mt6315-regulator.ko mt6315-regulator.ko'

magiskboot cpio ramdisk.cpio \
  'extract lib/modules/modules.load modules.load' \
  'extract lib/modules/modules.load.recovery modules.load.recovery' \
  'extract lib/modules/modules.dep modules.dep'

sed -i '/^device-apc-mt6895\.ko$/d' modules.load
sed -i '/^device-apc-mt6895\.ko$/d' modules.load.recovery
sed -i '\#^/lib/modules/device-apc-mt6895\.ko:#d' modules.dep

magiskboot cpio ramdisk.cpio \
  'rm lib/modules/device-apc-mt6895.ko' \
  'add 0644 lib/modules/modules.load modules.load' \
  'add 0644 lib/modules/modules.load.recovery modules.load.recovery' \
  'add 0644 lib/modules/modules.dep modules.dep'

cp ramdisk.cpio "$VENDOR_DIR/ramdisk_patched.cpio"

cd "$VENDOR_DIR"
magiskboot compress=lz4_legacy ramdisk_patched.cpio vendor_ramdisk_patched.lz4

cat "$UNPACK_GKI_DIR/ramdisk" \
  "$VENDOR_DIR/vendor_ramdisk_patched.lz4" \
  > "$OUTPUT_DIR/combined_ramdisk_known_good_base.lz4"

ls -lh "$VENDOR_DIR/ramdisk_patched.cpio" \
  "$VENDOR_DIR/vendor_ramdisk_patched.lz4" \
  "$OUTPUT_DIR/combined_ramdisk_known_good_base.lz4"
