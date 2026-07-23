#!/system/bin/sh
set -eu

# The single stock-side launcher for both rescue use and host-driven tests.
# Override payload paths through the environment; policy/retry stays outside.
ADB_DIR="${ADB_DIR:-/data/local/tmp}"
INITRD="${INITRD:-$ADB_DIR/combined_ramdisk_kexec_system_mbox.lz4}"
KERNEL="${KERNEL:-$ADB_DIR/kernel}"
KEXEC="${KEXEC:-$ADB_DIR/kexec}"
DTB="${DTB:-$ADB_DIR/patched.dtb}"
LINUX_DEV="${LINUX_DEV:-/dev/block/by-name/linux}"
LINUX_DEV_FALLBACK="${LINUX_DEV_FALLBACK:-/dev/block/sdc88}"
LINUX_MOUNT="${LINUX_MOUNT:-/mnt/linux_kexec}"
PREPARE="${PREPARE:-$LINUX_MOUNT/usr/local/libexec/kexec/prepare_ubuntu_kexec_boot.sh}"
CMDLINE="${CMDLINE:-}"
KEXEC_EXTRA_CMDLINE="${KEXEC_EXTRA_CMDLINE:-}"

die()
{
    echo "reboot-to-ubuntu: $*" >&2
    exit 1
}

mount_linux_root()
{
    mkdir -p "$LINUX_MOUNT"
    grep -q " $LINUX_MOUNT " /proc/mounts 2>/dev/null && return 0
    mount -t ext4 -o rw,noatime "$LINUX_DEV" "$LINUX_MOUNT" 2>/dev/null ||
        mount -t ext4 -o rw,noatime "$LINUX_DEV_FALLBACK" "$LINUX_MOUNT"
}

prepare_ubuntu()
{
    mount_linux_root || die "cannot mount linux root"
    [ -x "$PREPARE" ] || die "missing prepare helper: $PREPARE"
    PANIC_AFTER="${PANIC_AFTER:-0}" \
    UBUNTU_WIFI="${UBUNTU_WIFI:-1}" \
    UBUNTU_WIFI_SKIP_MODULES="${UBUNTU_WIFI_SKIP_MODULES:-}" \
    LINUX_MOUNT="$LINUX_MOUNT" \
        "$PREPARE"
}

pin_mminfra()
{
    mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true
    pd=/sys/devices/platform/disable_unused/disable_unused:disable-unused-pd-mm_infra
    clk=/sys/devices/platform/disable_unused/disable_unused:disable-unused-clk-mminfra_config
    [ -e "$pd/power/control" ] || die "missing $pd/power/control"
    echo on > "$pd/power/control"
    [ ! -e "$clk/power/control" ] || echo on > "$clk/power/control" 2>/dev/null || true
    sleep 1
    state="$(cat /sys/kernel/debug/pm_genpd/mm_infra/current_state 2>/dev/null || true)"
    runtime="$(cat "$pd/power/runtime_status" 2>/dev/null || true)"
    [ "$state" = on ] || die "mm_infra state is not on: ${state:-unknown}"
    [ "$runtime" = active ] || die "mm_infra runtime is not active: ${runtime:-unknown}"
}

build_cmdline()
{
    filtered=""
    for arg in $(cat /proc/cmdline); do
        case "$arg" in
            debug_ext.initrd_size=*|firmware_class.path=*|arm64.nomte|slub_debug=*|init_on_free=*)
                ;;
            *)
                filtered="$filtered $arg"
                ;;
        esac
    done

    bytes="$(stat -c %s "$INITRD" 2>/dev/null || wc -c < "$INITRD")"
    initrd_kib=$(( (bytes + 1023) / 1024 ))
    slot_suffix="$(getprop ro.boot.slot_suffix 2>/dev/null || true)"
    [ -n "$slot_suffix" ] || slot_suffix=_a
    bootconfig_args="$(awk '
        /^androidboot[.]/ {
            key=$1
            sub(/^[^=]*=[[:space:]]*/, "")
            gsub(/["[:space:]]/, "")
            printf "%s=%s ", key, $0
        }' /proc/bootconfig 2>/dev/null || true)"

    printf '%s\n' "$filtered debug_ext.initrd_size=$initrd_kib $bootconfig_args\
 androidboot.force_normal_boot=1 androidboot.mode=normal androidboot.bootmode=normal\
 androidboot.slot_suffix=$slot_suffix androidboot.hardware=mt6895\
 androidboot.init_fatal_panic=true androidboot.init_fatal_reboot_target=bootloader\
 firmware_class.path=/vendor/firmware loglevel=7 ignore_loglevel printk.devkmsg=on\
 $KEXEC_EXTRA_CMDLINE"
}

[ -x "$KEXEC" ] || die "missing kexec: $KEXEC"
[ -s "$KERNEL" ] || die "missing kernel: $KERNEL"
[ -s "$INITRD" ] || die "missing initrd: $INITRD"

prepare_ubuntu
pin_mminfra
[ -n "$CMDLINE" ] || CMDLINE="$(build_cmdline)"

dtb_arg=""
[ -s "$DTB" ] && dtb_arg="--dtb=$DTB"

cd "$ADB_DIR"
echo 0 > /proc/sys/kernel/kptr_restrict 2>/dev/null || true
# shellcheck disable=SC2086
"$KEXEC" -c -l "$KERNEL" --initrd="$INITRD" $dtb_arg --append="$CMDLINE"
sync
echo "stock-rescue reboot-to-ubuntu $(date -Is 2>/dev/null || date)" > /dev/kmsg 2>/dev/null || true
printf '\0' > /dev/watchdog 2>/dev/null || true
printf '\0' > /dev/watchdog0 2>/dev/null || true
exec "$KEXEC" -f -e
