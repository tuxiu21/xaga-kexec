#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

GKI_RAMDISK="$UNPACK_GKI_DIR/ramdisk"
VENDOR_CPIO="$VENDOR_DIR/ramdisk_patched.cpio"
VENDOR_LZ4="$VENDOR_DIR/vendor_ramdisk_system.lz4"
OUT="$OUTPUT_DIR/combined_ramdisk_kexec_system.lz4"
WORK="$(mktemp -d "$TMP_ROOT/kexec_system_initrd.XXXXXX")"

cleanup()
{
  rm -rf "$WORK"
}
trap cleanup EXIT

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
