#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/home/in/work/kernels}"
AK="${AK:-$ROOT/sources/android-kernel}"
KOUT="${KOUT:-$AK/out/android12-5.10/common}"
CLANG_BIN="${CLANG_BIN:-$AK/prebuilts-master/clang/host/linux-x86/clang-r416183b/bin}"
ADB="${ADB:-adb.exe}"
PROBE_DIR="$ROOT/probes/shutdown_probe"
OUT="${OUT:-$ROOT/output/shutdown_probe}"
MARKER="KEXEC_SHUTDOWN_PROBE_MARKER"

mkdir -p "$OUT"

PATH="$CLANG_BIN:$PATH" make -C "$AK/common" \
  O="$KOUT" \
  ARCH=arm64 \
  LLVM=1 \
  LLVM_IAS=1 \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CC=clang \
  LD=ld.lld \
  M="$PROBE_DIR" \
  modules

cp "$PROBE_DIR/shutdown_probe.ko" "$OUT/shutdown_probe.ko"
"$CLANG_BIN/llvm-strip" --strip-debug "$OUT/shutdown_probe.ko"

echo "built $OUT/shutdown_probe.ko"
modinfo "$OUT/shutdown_probe.ko" | sed -n '1,20p'

"$ADB" wait-for-device
"$ADB" push "$OUT/shutdown_probe.ko" /data/local/tmp/shutdown_probe.ko >/dev/null
"$ADB" shell "su -c 'rm -f /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/dmesg-ramoops-*; dmesg -C 2>/dev/null || true; insmod /data/local/tmp/shutdown_probe.ko panic_on_shutdown=1 || insmod -f /data/local/tmp/shutdown_probe.ko panic_on_shutdown=1; dmesg | grep $MARKER || true; sync'"

cat <<EOF

Probe is loaded in the stock kernel.

Now trigger kexec with the usual script. If device_shutdown() reaches this
driver .shutdown callback, the stock kernel will intentionally panic before
jumping to the new kernel. After the device returns to stock, check:

  adb.exe shell "su -c 'grep -a $MARKER /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/dmesg-ramoops-* 2>/dev/null || true'"

Expected if kernel device_shutdown() reached driver .shutdown:

  $MARKER shutdown called dev=kexec-shutdown-probe.-1

EOF
