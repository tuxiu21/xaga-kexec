#!/system/bin/sh
set -eu

ADB_DIR="${ADB_DIR:-/data/local/tmp}"
INITRD="${INITRD:-$ADB_DIR/combined_ramdisk_kexec_system_mbox.lz4}"
KERNEL="${KERNEL:-$ADB_DIR/kernel}"
KEXEC="${KEXEC:-$ADB_DIR/kexec}"
DTB="${DTB:-$ADB_DIR/patched.dtb}"
CMDLINE="${CMDLINE:-androidboot.hardware=mt6895 firmware_class.path=/vendor/firmware}"

[ -x "$KEXEC" ] || { echo "missing kexec: $KEXEC" >&2; exit 1; }
[ -s "$KERNEL" ] || { echo "missing kernel: $KERNEL" >&2; exit 1; }
[ -s "$INITRD" ] || { echo "missing initrd: $INITRD" >&2; exit 1; }

dtb_arg=""
[ -s "$DTB" ] && dtb_arg="--dtb=$DTB"

cd "$ADB_DIR"
echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null || true
"$KEXEC" -c -l "$KERNEL" --initrd="$INITRD" $dtb_arg --append="$CMDLINE"
sync
echo "stock-rescue reboot-to-ubuntu $(date -Is 2>/dev/null || date)" > /dev/kmsg 2>/dev/null || true
echo 1 > /dev/watchdog 2>/dev/null || true
echo 1 > /dev/watchdog0 2>/dev/null || true
exec "$KEXEC" -f -e
