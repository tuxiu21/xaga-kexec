#!/bin/bash
set -uo pipefail

LOG=/data/kexec/ubuntu_phase_a.log
WATCHDOG_PID=/data/kexec/run/watchdog_feeder.ubuntu.pid
PANIC_TIMER_PID=/data/kexec/run/panic_timer.ubuntu.pid
ADBD_LOG=/data/kexec/adbd_ubuntu.log
WIFI_PID=/data/kexec/run/wifi_bringup.ubuntu.pid
WIFI_FLAG=/data/kexec/ubuntu_wifi

log()
{
    printf 'ubuntu-phase-a: %s\n' "$*" | tee -a "$LOG" >/dev/null
}

start_watchdog()
{
    mkdir -p /data/kexec/run
    if [ -x /data/kexec/watchdog_feeder ]; then
        /data/kexec/watchdog_feeder 5 &
        echo "$!" > "$WATCHDOG_PID"
        log "watchdog feeder started pid=$!"
        return 0
    fi

    log "missing /data/kexec/watchdog_feeder"
    return 1
}

start_panic_timer()
{
    after=300
    if [ -s /data/kexec/panic_after ]; then
        after="$(cat /data/kexec/panic_after 2>/dev/null || echo 300)"
    fi

    case "$after" in
        ''|*[!0-9]*|0)
            log "panic timer disabled"
            return 0
            ;;
    esac

    (
        log "panic timer armed: ${after}s"
        if [ -x /data/kexec/busybox ]; then
            /data/kexec/busybox sleep "$after"
        else
            sleep "$after"
        fi
        log "panic timer firing"
        sync
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
        echo c > /proc/sysrq-trigger 2>/dev/null || true
        echo panic > /proc/sysrq-trigger 2>/dev/null || true
    ) &
    echo "$!" > "$PANIC_TIMER_PID"
}

log_ls()
{
    label="$1"
    path="$2"

    {
        echo "ubuntu-phase-a: $label:"
        ls -la "$path" 2>&1
    } >> "$LOG" 2>&1
}

mount_if_needed()
{
    mp="$1"
    type="$2"
    src="$3"
    opts="${4:-}"

    mkdir -p "$mp"
    grep -q " $mp " /proc/mounts 2>/dev/null && return 0
    if [ -n "$opts" ]; then
        mount -t "$type" -o "$opts" "$src" "$mp" 2>/dev/null
    else
        mount -t "$type" "$src" "$mp" 2>/dev/null
    fi
}

start_adbd()
{
    log "setup adbd: begin"

    mount_if_needed /proc proc proc ""
    mount_if_needed /sys sysfs sysfs ""
    mount_if_needed /dev devtmpfs devtmpfs "mode=0755"
    mount_if_needed /dev/pts devpts devpts "mode=0620,ptmxmode=0666"
    mount_if_needed /config configfs configfs ""

    mkdir -p /system/bin /dev/usb-ffs/adb /data/kexec/run
    ln -sf /bin/sh /system/bin/sh 2>/dev/null || true
    ln -sf /data/kexec/linker64 /system/bin/linker64 2>/dev/null || true

    if [ ! -x /data/kexec/adbd ]; then
        log "setup adbd: missing /data/kexec/adbd"
        return 1
    fi
    if [ ! -x /data/kexec/linker64 ]; then
        log "setup adbd: missing /data/kexec/linker64"
    fi

    if [ -e /sys/fs/selinux/enforce ]; then
        echo 0 > /sys/fs/selinux/enforce 2>/dev/null || true
    fi

    udc="$(ls /sys/class/udc 2>/dev/null | head -n 1)"
    if [ -z "$udc" ]; then
        log "setup adbd: no UDC available"
        return 1
    fi
    log "setup adbd: selected UDC $udc"

    g=/config/usb_gadget/g1
    mkdir -p "$g/strings/0x409" "$g/configs/c.1/strings/0x409" "$g/functions/ffs.adb" 2>/dev/null || {
        log "setup adbd: failed to create gadget directories"
        return 1
    }

    cur="$(cat "$g/UDC" 2>/dev/null || true)"
    if [ -n "$cur" ]; then
        echo "" > "$g/UDC" 2>/dev/null || true
        log "setup adbd: unbound existing UDC $cur"
    fi

    echo 0x2717 > "$g/idVendor" 2>/dev/null || true
    echo 0xff08 > "$g/idProduct" 2>/dev/null || true
    echo 0x0200 > "$g/bcdUSB" 2>/dev/null || true
    echo 0x0100 > "$g/bcdDevice" 2>/dev/null || true
    echo kexec-adbd > "$g/strings/0x409/manufacturer" 2>/dev/null || true
    echo ubuntu-adb > "$g/strings/0x409/product" 2>/dev/null || true
    echo "${UBUNTU_ADB_SERIAL:-ubuntu012345678}" > "$g/strings/0x409/serialnumber" 2>/dev/null || true
    echo adb > "$g/configs/c.1/strings/0x409/configuration" 2>/dev/null || true
    echo 500 > "$g/configs/c.1/MaxPower" 2>/dev/null || true

    mount_if_needed /dev/usb-ffs/adb functionfs adb ""
    log_ls "adb FunctionFS before adbd" /dev/usb-ffs/adb

    : > "$ADBD_LOG"
    LD_LIBRARY_PATH=/data/kexec/adblib /data/kexec/adbd >> "$ADBD_LOG" 2>&1 &
    adbd_pid=$!
    echo "$adbd_pid" > /data/kexec/run/adbd.ubuntu.pid
    log "setup adbd: started pid=$adbd_pid"

    ready=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        if [ -e /dev/usb-ffs/adb/ep1 ]; then
            ready=1
            break
        fi
        sleep 1
    done
    log_ls "adb FunctionFS after adbd" /dev/usb-ffs/adb
    if [ "$ready" != 1 ]; then
        log "setup adbd: endpoints not published"
        cat "$ADBD_LOG" >> "$LOG" 2>/dev/null || true
        return 1
    fi
    log "setup adbd: endpoints published"

    [ -e "$g/configs/c.1/ffs.adb" ] || ln -s "$g/functions/ffs.adb" "$g/configs/c.1/ffs.adb" 2>/dev/null || true
    echo "$udc" > "$g/UDC" 2>/dev/null || true
    log "setup adbd: bound UDC $(cat "$g/UDC" 2>/dev/null || echo unknown)"

    state_node="/sys/class/udc/$udc/state"
    for attempt in 1 2 3 4 5; do
        sleep 2
        st="$(cat "$state_node" 2>/dev/null || echo unknown)"
        if [ "$st" = "configured" ]; then
            log "setup adbd: host enumerated attempt=$attempt"
            return 0
        fi
        log "setup adbd: not enumerated state=$st attempt=$attempt; replug"
        echo "" > "$g/UDC" 2>/dev/null || true
        sleep 1
        echo "$udc" > "$g/UDC" 2>/dev/null || true
    done

    log "setup adbd: host not enumerated after retries"
    return 1
}

start_wifi()
{
    wifi="${UBUNTU_WIFI:-1}"
    if [ -s "$WIFI_FLAG" ]; then
        wifi="$(cat "$WIFI_FLAG" 2>/dev/null || echo "$wifi")"
    fi

    case "$wifi" in
        0|false|FALSE|off|OFF|no|NO)
            log "wifi disabled"
            return 0
            ;;
    esac

    if [ ! -x /data/kexec/wifi_bringup.sh ]; then
        log "wifi requested but /data/kexec/wifi_bringup.sh is missing"
        return 1
    fi

    log "wifi bringup starting"
    /data/kexec/wifi_bringup.sh &
    echo "$!" > "$WIFI_PID"
    log "wifi bringup started pid=$!"
}

start_watchdog
start_panic_timer
start_adbd
start_wifi

{
    echo "===== ubuntu phase A begin $(date -u 2>/dev/null || true) ====="
    echo "pid1=$$ comm=$(cat /proc/1/comm 2>/dev/null || true)"
    uname -a
    id
    echo "--- rootfs ---"
    findmnt / 2>/dev/null || mount | grep ' on / ' || true
    echo "--- mounts ---"
    mount | sed -n '1,120p'
    echo "--- cgroup ---"
    findmnt /sys/fs/cgroup 2>/dev/null || true
    stat -f -c 'cgroup fs type: %T' /sys/fs/cgroup 2>/dev/null || true
    echo "--- data ---"
    ls -lh /data/kexec/ubuntu.ext4 /data/kexec/boot_ubuntu_ext4 2>/dev/null || true
    df -h / /data 2>/dev/null || true
    echo "--- watchdog ---"
    cat "$WATCHDOG_PID" 2>/dev/null || true
    ps -ef 2>/dev/null | grep '[w]atchdog_feeder' || true
    echo "--- panic timer ---"
    cat "$PANIC_TIMER_PID" 2>/dev/null || true
    echo "--- adbd ---"
    cat /data/kexec/run/adbd.ubuntu.pid 2>/dev/null || true
    ps -ef 2>/dev/null | grep '[a]dbd' || true
    tail -80 "$ADBD_LOG" 2>/dev/null || true
    echo "--- wifi ---"
    cat "$WIFI_PID" 2>/dev/null || true
    ps -ef 2>/dev/null | grep '[w]ifi_bringup' || true
    ls -l /data/kexec/modules 2>/dev/null | sed -n '1,80p' || true
    tail -120 /data/kexec/wifi_bringup.log 2>/dev/null || true
    echo "--- docker dir ---"
    ls -ld /var/lib/docker 2>/dev/null || true
    echo "===== ubuntu phase A end $(date -u 2>/dev/null || true) ====="
} >> "$LOG" 2>&1

sync
log "ready; waiting for adb shell or panic timer"
while true; do
    if [ -x /data/kexec/busybox ]; then
        /data/kexec/busybox sleep 60
    else
        sleep 60
    fi
done
