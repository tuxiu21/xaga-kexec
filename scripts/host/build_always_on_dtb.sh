#!/usr/bin/env bash
# Generate and push the patched DTB used by the kexec flow.
#
# Why: a minimal (non-Android) userspace leaves some PMIC rails with no driver
# consumer, so the kernel's "disable unused regulators" cleanup (~30s after boot,
# regulator_late_cleanup) turns them off and the SoC browns out. Marking those
# rails regulator-always-on in the live DTB makes cleanup skip them.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

LIBFDT="$XIAOMI/scripts/dtc/libfdt"
TOOL="$TMP_ROOT/dtb_always_on"

REGS="mt6363_vbuck3 mt6363_vbuck7 mt6363_vcn13 mt6363_vrfio18 \
      mt6368_vbuck1 mt6368_vbuck3 mt6368_vbuck4 mt6368_vibr mt6368_vaud18"

echo "== build libfdt patcher (gcc + kernel libfdt, no flex/bison) =="
gcc -O2 -I"$LIBFDT" -o "$TOOL" "$ROOT/src/dtb_always_on.c" "$LIBFDT"/*.c

echo "== pull the device's live DTB (exec-out avoids CRLF corruption) =="
"$ADB" exec-out su -c 'cat /sys/firmware/fdt' > "$TMP_ROOT/live.dtb"
echo "live.dtb = $(wc -c < "$TMP_ROOT/live.dtb") bytes (expect ~408449)"

echo "== add regulator-always-on in place =="
"$TOOL" "$TMP_ROOT/live.dtb" "$TMP_ROOT/patched.dtb" $REGS

echo "== push patched.dtb -> /data/local/tmp/ =="
"$ADB" push "$TMP_ROOT/patched.dtb" /data/local/tmp/patched.dtb
echo "done. kexec_adb_until_new.sh passes --dtb=patched.dtb by default (DTB_DEV)."
