#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

GKI_RAMDISK="$UNPACK_GKI_DIR/ramdisk"
VENDOR_CPIO="$VENDOR_DIR/ramdisk_patched.cpio"
VENDOR_LZ4="$VENDOR_DIR/vendor_ramdisk_system.lz4"
OUT="$OUTPUT_DIR/combined_ramdisk_kexec_system.lz4"
RAMDISK_KXSH="$OUTPUT_DIR/ramdisk_kxshbin"
INIT_KXSH="${INIT_KXSH:-$ROOT/prebuilt/init_first_stage_kxsh}"
WORK="$(mktemp -d "$TMP_ROOT/kexec_system_initrd.XXXXXX")"

cleanup()
{
  rm -rf "$WORK"
}
trap cleanup EXIT

[ -s "$INIT_KXSH" ] || { echo "missing rebuilt first-stage init: $INIT_KXSH" >&2; exit 1; }

aarch64-linux-gnu-gcc -static -Os -s \
  -o "$RAMDISK_KXSH" \
  "$ROOT/src/system_kxsh.c"

cd "$WORK"

cp "$VENDOR_CPIO" vendor.cpio
magiskboot cpio vendor.cpio 'rm init'
mkdir -p vendor_root
(
  cd vendor_root
  cpio -idm < ../vendor.cpio >/dev/null 2>&1
  mkdir -p linux
  for fstab in first_stage_ramdisk/fstab.mt6895 first_stage_ramdisk/fstab.emmc; do
    [ -f "$fstab" ] || continue
    grep -q ' /mnt ' "$fstab" || \
      printf '/dev/block/by-name/linux /mnt ext4 noatime,nosuid,nodev wait,nofail,first_stage_mount\n' >> "$fstab"
  done
  find . | cpio -o -H newc > ../vendor.cpio 2>/dev/null
)
magiskboot compress=lz4_legacy vendor.cpio "$VENDOR_LZ4"

magiskboot decompress "$GKI_RAMDISK" gki.cpio
cp "$INIT_KXSH" init.kxsh
cp "$RAMDISK_KXSH" ramdisk_kxshbin
magiskboot cpio gki.cpio 'add 0750 init init.kxsh'
magiskboot cpio gki.cpio 'add 0750 kxshbin ramdisk_kxshbin'
magiskboot cpio gki.cpio 'add 0750 first_stage_ramdisk/kxshbin ramdisk_kxshbin'
magiskboot compress=lz4_legacy gki.cpio gki_patched.lz4

cat gki_patched.lz4 "$VENDOR_LZ4" > "$OUT"
ls -lh "$INIT_KXSH" "$RAMDISK_KXSH" "$OUT"
