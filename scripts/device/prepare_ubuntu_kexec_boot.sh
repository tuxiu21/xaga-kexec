#!/system/bin/sh
set -eu

LINUX_MOUNT="${LINUX_MOUNT:-/mnt/linux_kexec}"
CONFIG_DIR="${CONFIG_DIR:-$LINUX_MOUNT/etc/kexec-runtime}"
LOG_DIR="${LOG_DIR:-$LINUX_MOUNT/var/log/kexec-runtime}"
STATE_DIR="${STATE_DIR:-$LINUX_MOUNT/var/lib/kexec-runtime}"

[ -x "$LINUX_MOUNT/usr/local/libexec/kexec/boot_ubuntu_rootfs" ] || {
    echo "missing direct-root boot helper" >&2
    exit 1
}
[ -x "$LINUX_MOUNT/sbin/init" ] || {
    echo "missing Ubuntu /sbin/init" >&2
    exit 1
}

mkdir -p "$CONFIG_DIR" "$LOG_DIR" "$STATE_DIR" \
    "$LINUX_MOUNT/etc/systemd/system"

target="${UBUNTU_TARGET:-multi-user.target}"
ln -sfn "/lib/systemd/system/$target" \
    "$LINUX_MOUNT/etc/systemd/system/default.target"

printf '%s\n' "${PANIC_AFTER:-0}" > "$CONFIG_DIR/panic_after"
printf '%s\n' "${UBUNTU_WIFI:-1}" > "$CONFIG_DIR/wifi_enabled"
printf '%s\n' "${UBUNTU_WIFI_SKIP_MODULES:-}" > "$CONFIG_DIR/wifi_skip_modules"

: > "$LOG_DIR/boot-rootfs.log"
: > "$LOG_DIR/ubuntu-runtime.log"
: > "$LOG_DIR/adbd.log"
: > "$LOG_DIR/wifi-bringup.log"
rm -f "$STATE_DIR/wifi-status" "$STATE_DIR/watchdog-health"

sync
echo "prepared direct Ubuntu boot target=$target panic_after=${PANIC_AFTER:-0} wifi=${UBUNTU_WIFI:-1}"
