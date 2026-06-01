#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/in/work/kernels"
GKI_RAMDISK="$ROOT/unpack_gki/ramdisk"
VENDOR_CPIO="$ROOT/vendor/ramdisk_patched.cpio"
VENDOR_LZ4="$ROOT/vendor/vendor_ramdisk_system.lz4"
OUT="$ROOT/output/combined_ramdisk_kexec_system.lz4"
WORK="/tmp/kexec_system_initrd"

rm -rf "$WORK"
mkdir -p "$WORK"
cd "$WORK"

cp "$VENDOR_CPIO" vendor.cpio
magiskboot cpio vendor.cpio 'rm init'
magiskboot compress=lz4_legacy vendor.cpio "$VENDOR_LZ4"

magiskboot decompress "$GKI_RAMDISK" gki.cpio
magiskboot cpio gki.cpio 'extract init init.orig'
cp init.orig init.patched
perl -0pi -e 's#/system/bin/init#/system/bin/kxsh#g' init.patched
magiskboot cpio gki.cpio 'add 0750 init init.patched'
magiskboot compress=lz4_legacy gki.cpio gki_patched.lz4

cat gki_patched.lz4 "$VENDOR_LZ4" > "$OUT"
ls -lh "$OUT"
