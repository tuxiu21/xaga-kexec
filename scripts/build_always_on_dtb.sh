#!/usr/bin/env bash
# Generate and push the patched DTB used by the kexec flow.
#
# Why: a minimal (non-Android) userspace leaves some PMIC rails with no driver
# consumer, so the kernel's "disable unused regulators" cleanup (~30s after boot,
# regulator_late_cleanup) turns them off and the SoC browns out -- full kexec
# boots died at ~31.7s. Marking those rails regulator-always-on in the DTB makes
# the cleanup skip them (it does `if (c->always_on) return 0;`).
#
# How: we do NOT rebuild the DTB from source and we do NOT decompile. We pull the
# device's *live* DTB (/sys/firmware/fdt = the bootloader's finished product, with
# its runtime fixups: memory, reserved-memory carveouts, /chosen) and add the 9
# properties in place with libfdt, preserving every other byte.
set -euo pipefail
ROOT=/home/in/work/kernels
LIBFDT="$ROOT/sources/Xiaomi_Kernel_OpenSource/scripts/dtc/libfdt"
TOOL=/tmp/dtb_always_on
ADB=adb.exe

# The rails the cleanup disabled right before death. vibr/vaud18 are almost
# certainly harmless to keep on; the fatal ones are among the vbucks. Keeping all
# 9 is the safe superset (can be narrowed later by bisection).
REGS="mt6363_vbuck3 mt6363_vbuck7 mt6363_vcn13 mt6363_vrfio18 \
      mt6368_vbuck1 mt6368_vbuck3 mt6368_vbuck4 mt6368_vibr mt6368_vaud18"

echo "== build libfdt patcher (gcc + kernel libfdt, no flex/bison) =="
gcc -O2 -I"$LIBFDT" -o "$TOOL" "$ROOT/src/dtb_always_on.c" "$LIBFDT"/*.c

echo "== pull the device's live DTB (exec-out avoids CRLF corruption) =="
$ADB exec-out su -c 'cat /sys/firmware/fdt' > /tmp/live.dtb
echo "live.dtb = $(wc -c < /tmp/live.dtb) bytes (expect ~408449)"

echo "== add regulator-always-on in place =="
"$TOOL" /tmp/live.dtb /tmp/patched.dtb $REGS

echo "== push patched.dtb -> /data/local/tmp/ =="
$ADB push /tmp/patched.dtb /data/local/tmp/patched.dtb
echo "done. kexec_dropbear_until_new.sh passes --dtb=patched.dtb by default (DTB_DEV)."
