#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

OUT="${OUT:-$OUTPUT_DIR/mtk-mbox-ext}"
KOUT="${KOUT:-$AK/out/android12-5.10/common}"
CLANG_BIN="${CLANG_BIN:-$AK/prebuilts-master/clang/host/linux-x86/clang-r416183b/bin}"
VENDOR_CPIO="${VENDOR_CPIO:-$VENDOR_DIR/ramdisk_patched.cpio}"
GKI_RAMDISK="${GKI_RAMDISK:-$UNPACK_GKI_DIR/ramdisk}"
INITRD_OUT="${INITRD_OUT:-$OUTPUT_DIR/combined_ramdisk_kexec_system_mbox.lz4}"
VENDOR_CPIO_OUT="${VENDOR_CPIO_OUT:-$VENDOR_DIR/ramdisk_patched_mbox.cpio}"
BLOCKTAG_KO="${BLOCKTAG_KO:-$BLOCKTAG_BUILD_DIR/blocktag.ko}"
RAMDISK_KXSH="${RAMDISK_KXSH:-$OUTPUT_DIR/ramdisk_kxshbin}"
INIT_KXSH="${INIT_KXSH:-$ROOT/prebuilt/init_first_stage_kxsh}"
WIFI_FIRMWARE_DIR="${WIFI_FIRMWARE_DIR:-}"
WIFI_RAMDISK_FIRMWARE="${WIFI_RAMDISK_FIRMWARE:-conninfra.cfg soc7_0_ram_wmmcu_1b_t_1_hdr.bin wifi.cfg WIFI_RAM_CODE_soc7_0_1b_t_1.bin}"

if [ -n "$WIFI_FIRMWARE_DIR" ]; then
  WIFI_FIRMWARE_DIR="$(realpath -m "$WIFI_FIRMWARE_DIR")"
fi

[ -s "$INIT_KXSH" ] || { echo "missing rebuilt first-stage init: $INIT_KXSH" >&2; exit 1; }

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

aarch64-linux-gnu-gcc -static -Os -s \
  -o "$RAMDISK_KXSH" \
  "$ROOT/src/system_kxsh.c"

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
  if [ -s "$BLOCKTAG_KO" ]; then
    cp "$BLOCKTAG_KO" lib/modules/blocktag.ko
  fi
  find . | cpio -o -H newc > "$work/vendor_mbox.cpio" 2>/dev/null
)

magiskboot compress=lz4_legacy "$work/vendor_mbox.cpio" "$work/vendor_ramdisk_mbox.lz4" >/dev/null

(
  cd "$work"
  magiskboot decompress "$GKI_RAMDISK" gki.cpio >/dev/null
  cp "$INIT_KXSH" init.kxsh
  cp "$RAMDISK_KXSH" ramdisk_kxshbin
  magiskboot cpio gki.cpio 'add 0750 init init.kxsh' >/dev/null
  magiskboot cpio gki.cpio 'add 0750 kxshbin ramdisk_kxshbin' >/dev/null
  magiskboot cpio gki.cpio 'add 0750 first_stage_ramdisk/kxshbin ramdisk_kxshbin' >/dev/null
  if [ -d "$WIFI_FIRMWARE_DIR" ]; then
    for name in $WIFI_RAMDISK_FIRMWARE; do
      fw="$WIFI_FIRMWARE_DIR/$name"
      [ -f "$fw" ] || continue
      cp "$fw" "fw_$name"
      magiskboot cpio gki.cpio "add 0644 vendor/firmware/$name fw_$name" >/dev/null
      magiskboot cpio gki.cpio "add 0644 first_stage_ramdisk/vendor/firmware/$name fw_$name" >/dev/null
    done
  fi
  magiskboot compress=lz4_legacy gki.cpio gki_patched.lz4 >/dev/null
  cat gki_patched.lz4 "$work/vendor_ramdisk_mbox.lz4" > "$INITRD_OUT"
)

cp "$work/vendor_mbox.cpio" "$VENDOR_CPIO_OUT"
modinfo "$OUT/mtk-mbox.stripped.ko" | sed -n '1,20p'
if [ -s "$BLOCKTAG_KO" ]; then
  echo "included blocktag: $BLOCKTAG_KO"
  modinfo "$BLOCKTAG_KO" | sed -n '1,20p'
fi
if [ -d "$WIFI_FIRMWARE_DIR" ]; then
  echo "included wifi firmware: $WIFI_FIRMWARE_DIR"
  for name in $WIFI_RAMDISK_FIRMWARE; do
    [ -f "$WIFI_FIRMWARE_DIR/$name" ] && echo "$name"
  done
fi
ls -lh "$INIT_KXSH" "$RAMDISK_KXSH" "$OUT/mtk-mbox.stripped.ko" "$VENDOR_CPIO_OUT" "$INITRD_OUT"
