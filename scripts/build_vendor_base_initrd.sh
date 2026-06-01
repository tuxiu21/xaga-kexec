#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/in/work/kernels"

adb.exe shell getprop ro.boot.slot_suffix

adb.exe shell "su -c 'dd if=/dev/block/by-name/vendor_boot_a of=/data/local/tmp/vendor_boot_a.img bs=4M'"
adb.exe pull /data/local/tmp/vendor_boot_a.img "$ROOT/vendor/vendor_boot_a.img"

cd "$ROOT/vendor"
magiskboot unpack vendor_boot_a.img

cd /tmp
cp "$ROOT/vendor/ramdisk.cpio" ramdisk.cpio

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

cp ramdisk.cpio "$ROOT/vendor/ramdisk_patched.cpio"

cd "$ROOT/vendor"
magiskboot compress=lz4_legacy ramdisk_patched.cpio vendor_ramdisk_patched.lz4

cat "$ROOT/unpack_gki/ramdisk" \
  "$ROOT/vendor/vendor_ramdisk_patched.lz4" \
  > "$ROOT/output/combined_ramdisk_known_good_base.lz4"

ls -lh "$ROOT/vendor/ramdisk_patched.cpio" \
  "$ROOT/vendor/vendor_ramdisk_patched.lz4" \
  "$ROOT/output/combined_ramdisk_known_good_base.lz4"
