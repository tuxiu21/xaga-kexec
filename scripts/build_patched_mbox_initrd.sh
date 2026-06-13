#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/home/in/work/kernels}"
AK="${AK:-$ROOT/sources/android-kernel}"
XIAOMI="${XIAOMI:-$ROOT/sources/Xiaomi_Kernel_OpenSource}"
OUT="${OUT:-$ROOT/output/mtk-mbox-ext}"
KOUT="${KOUT:-$AK/out/android12-5.10/common}"
CLANG_BIN="${CLANG_BIN:-$AK/prebuilts-master/clang/host/linux-x86/clang-r416183b/bin}"
VENDOR_CPIO="${VENDOR_CPIO:-$ROOT/vendor/ramdisk_patched.cpio}"
GKI_RAMDISK="${GKI_RAMDISK:-$ROOT/unpack_gki/ramdisk}"
INITRD_OUT="${INITRD_OUT:-$ROOT/output/combined_ramdisk_kexec_system_mbox.lz4}"
VENDOR_CPIO_OUT="${VENDOR_CPIO_OUT:-$ROOT/vendor/ramdisk_patched_mbox.cpio}"

rm -rf "$OUT"
mkdir -p "$OUT/linux/soc/mediatek"
cp "$XIAOMI/drivers/soc/mediatek/mtk-mbox.c" "$OUT/mtk-mbox.c"
cp "$XIAOMI/include/linux/soc/mediatek/mtk-mbox.h" "$OUT/linux/soc/mediatek/mtk-mbox.h"
printf 'obj-m += mtk-mbox.o\nccflags-y += -I$(src)\n' > "$OUT/Makefile"

PATH="$CLANG_BIN:$PATH" make -C "$AK/common" \
  O="$KOUT" \
  ARCH=arm64 \
  LLVM=1 \
  LLVM_IAS=1 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CC=clang \
  LD=ld.lld \
  M="$OUT" \
  modules

cp "$OUT/mtk-mbox.ko" "$OUT/mtk-mbox.stripped.ko"
"$CLANG_BIN/llvm-strip" --strip-debug "$OUT/mtk-mbox.stripped.ko"

work="$(mktemp -d)"
cleanup()
{
  rm -rf "$work"
}
trap cleanup EXIT

mkdir -p "$work/vendor_root"
(
  cd "$work/vendor_root"
  cpio -idm < "$VENDOR_CPIO" >/dev/null 2>&1
  rm -f init
  cp "$OUT/mtk-mbox.stripped.ko" lib/modules/mtk-mbox.ko
  find . | cpio -o -H newc > "$work/vendor_mbox.cpio" 2>/dev/null
)

magiskboot compress=lz4_legacy "$work/vendor_mbox.cpio" "$work/vendor_ramdisk_mbox.lz4" >/dev/null

(
  cd "$work"
  magiskboot decompress "$GKI_RAMDISK" gki.cpio >/dev/null
  magiskboot cpio gki.cpio 'extract init init.orig' >/dev/null
  cp init.orig init.patched
  perl -0pi -e 's#/system/bin/init#/system/bin/kxsh#g' init.patched
  magiskboot cpio gki.cpio 'add 0750 init init.patched' >/dev/null
  magiskboot compress=lz4_legacy gki.cpio gki_patched.lz4 >/dev/null
  cat gki_patched.lz4 "$work/vendor_ramdisk_mbox.lz4" > "$INITRD_OUT"
)

cp "$work/vendor_mbox.cpio" "$VENDOR_CPIO_OUT"
modinfo "$OUT/mtk-mbox.stripped.ko" | sed -n '1,20p'
ls -lh "$OUT/mtk-mbox.stripped.ko" "$VENDOR_CPIO_OUT" "$INITRD_OUT"
