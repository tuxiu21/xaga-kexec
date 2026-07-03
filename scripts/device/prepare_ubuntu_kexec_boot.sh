#!/bin/sh
set -u

LINUX_MOUNT="${LINUX_MOUNT:-/mnt/linux_kexec}"
LEAN_DIR="${LEAN_DIR:-$LINUX_MOUNT/lean}"
PANIC_AFTER="${PANIC_AFTER:-900}"
UBUNTU_WIFI="${UBUNTU_WIFI:-1}"

SYSTEMD_DIR="$LINUX_MOUNT/etc/systemd/system"
MULTI_USER_WANTS="$SYSTEMD_DIR/multi-user.target.wants"
NETWORKD_DIR="$LINUX_MOUNT/etc/systemd/network"
SYSINIT_WANTS="$SYSTEMD_DIR/sysinit.target.wants"

mkdir -p "$LEAN_DIR/run"

rm -f \
    /sys/fs/pstore/console-ramoops-0 \
    /sys/fs/pstore/dmesg-ramoops-*

: > "$LEAN_DIR/kxsh.log"
: > "$LEAN_DIR/adbd.log"
: > "$LEAN_DIR/boot_ubuntu_rootfs.log"
: > "$LEAN_DIR/ubuntu_phase_a.log"
: > "$LEAN_DIR/adbd_ubuntu.log"
: > "$LEAN_DIR/usb_adbd_sampler.log"
: > "$LEAN_DIR/wifi_bringup.log"
: > "$LEAN_DIR/wifi_load_progress.txt"
: > "$LEAN_DIR/dmesg_wifi_before.log"
: > "$LEAN_DIR/dmesg_wifi_after.log"

rm -f \
    "$LEAN_DIR/run/adbd.ubuntu.pid" \
    "$LEAN_DIR/run/adbd.ready" \
    "$LEAN_DIR/run/usb_adbd_sampler.pid" \
    "$LEAN_DIR/run/panic_timer.ubuntu.pid" \
    "$LEAN_DIR/run/wifi_bringup.ubuntu.pid"

mkdir -p "$SYSTEMD_DIR" "$MULTI_USER_WANTS" "$SYSINIT_WANTS" "$NETWORKD_DIR"

ln -sfn /lib/systemd/system/multi-user.target "$SYSTEMD_DIR/default.target"
rm -f \
    "$SYSTEMD_DIR/kexec-phase-a.service" \
    "$MULTI_USER_WANTS/kexec-phase-a.service"
rm -rf "$SYSTEMD_DIR/kexec-phase-a.service.d"

for unit in \
    kexec-time-keeper.service \
    kexec-watchdog.service \
    kexec-panic-timer.service \
    kexec-vendor-mount.service \
    kexec-adbd.service \
    kexec-wifi.service; do
    if [ -f "$SYSTEMD_DIR/$unit" ]; then
        ln -sfn "../$unit" "$MULTI_USER_WANTS/$unit"
    fi
done

if [ -f "$LINUX_MOUNT/lib/systemd/system/systemd-networkd.service" ]; then
    ln -sfn /lib/systemd/system/systemd-networkd.service \
        "$MULTI_USER_WANTS/systemd-networkd.service"
fi

if [ -f "$LINUX_MOUNT/lib/systemd/system/systemd-resolved.service" ]; then
    rm -f "$SYSTEMD_DIR/systemd-resolved.service"
    ln -sfn /lib/systemd/system/systemd-resolved.service \
        "$SYSINIT_WANTS/systemd-resolved.service"
    ln -sfn /lib/systemd/system/systemd-resolved.service \
        "$SYSTEMD_DIR/dbus-org.freedesktop.resolve1.service"
    ln -sfn ../run/systemd/resolve/stub-resolv.conf "$LINUX_MOUNT/etc/resolv.conf"
fi

if [ -f "$LINUX_MOUNT/lib/systemd/system/wpa_supplicant@.service" ]; then
    ln -sfn /lib/systemd/system/wpa_supplicant@.service \
        "$MULTI_USER_WANTS/wpa_supplicant@wlan0.service"
fi

ln -sf /dev/null "$SYSTEMD_DIR/systemd-networkd-wait-online.service"

echo "$PANIC_AFTER" > "$LEAN_DIR/panic_after"
echo "$UBUNTU_WIFI" > "$LEAN_DIR/ubuntu_wifi"
touch "$LEAN_DIR/boot_ubuntu_rootfs.once"

sync
