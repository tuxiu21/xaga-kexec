#!/bin/bash
set -uo pipefail

LOG=/lean/ubuntu_phase_a.log
WATCHDOG_PID=/lean/run/watchdog_feeder.ubuntu.pid
PANIC_TIMER_PID=/lean/run/panic_timer.ubuntu.pid
ADBD_LOG=/lean/adbd_ubuntu.log
USB_ADBD_SAMPLER_LOG=/lean/usb_adbd_sampler.log
USB_ADBD_SAMPLER_PID=/lean/run/usb_adbd_sampler.pid
WIFI_PID=/lean/run/wifi_bringup.ubuntu.pid
WIFI_FLAG=/lean/ubuntu_wifi

log()
{
    printf 'ubuntu-phase-a: %s\n' "$*" | tee -a "$LOG" >/dev/null
}

start_watchdog()
{
    mkdir -p /lean/run
    if [ -x /lean/watchdog_feeder ]; then
        /lean/watchdog_feeder 5 &
        echo "$!" > "$WATCHDOG_PID"
        log "watchdog feeder started pid=$!"
        return 0
    fi

    log "missing /lean/watchdog_feeder"
    return 1
}

start_panic_timer()
{
    after=300
    if [ -s /lean/panic_after ]; then
        after="$(cat /lean/panic_after 2>/dev/null || echo 300)"
    fi

    case "$after" in
        ''|*[!0-9]*|0)
            log "panic timer disabled"
            return 0
            ;;
    esac

    (
        log "panic timer armed: ${after}s"
        if [ -x /lean/busybox ]; then
            /lean/busybox sleep "$after"
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

resolve_dm_by_name()
{
    name="$1"

    for n in /sys/block/dm-*; do
        [ -e "$n/dm/name" ] || continue
        if [ "$(cat "$n/dm/name" 2>/dev/null)" = "$name" ]; then
            echo "/dev/block/${n##*/}"
            return 0
        fi
    done
    return 1
}

ensure_dm_node()
{
    node="$1"
    base="${node##*/}"
    devno="$(cat "/sys/block/$base/dev" 2>/dev/null || true)"
    [ -n "$devno" ] || return 1
    maj="${devno%:*}"
    min="${devno#*:}"
    mkdir -p /dev/block /dev/mapper
    [ -b "$node" ] || mknod "$node" b "$maj" "$min" 2>/dev/null || true
}

mount_one_vendor_path()
{
    part="$1"
    mp="$2"
    dev="$(resolve_dm_by_name "$part" 2>/dev/null || true)"
    [ -n "$dev" ] || return 1
    ensure_dm_node "$dev" || true
    mkdir -p "$mp"
    grep -q " $mp " /proc/mounts 2>/dev/null && return 0
    mount -t erofs -o ro "$dev" "$mp" 2>/dev/null ||
        mount -o ro "$dev" "$mp" 2>/dev/null
}

ensure_vendor_mounts()
{
    mount_if_needed /proc proc proc ""
    mount_if_needed /sys sysfs sysfs ""
    mount_if_needed /dev devtmpfs devtmpfs "mode=0755"

    slot="_a"
    if [ -r /proc/cmdline ]; then
        slot="$(sed -n 's/.*androidboot.slot_suffix=\([^ ]*\).*/\1/p' /proc/cmdline | head -n 1)"
        [ -n "$slot" ] || slot="_a"
    fi

    log "vendor mount: begin slot=$slot"
    if [ -x /lean/map_super_partitions.py ]; then
        if ! resolve_dm_by_name "vendor${slot}" >/dev/null 2>&1 ||
           ! resolve_dm_by_name "vendor_dlkm${slot}" >/dev/null 2>&1; then
            /lean/map_super_partitions.py --slot "$slot" \
                --partition "vendor${slot}" \
                --partition "vendor_dlkm${slot}" >> "$LOG" 2>&1 || \
                log "vendor mount: map_super_partitions.py failed"
        fi
    else
        log "vendor mount: missing /lean/map_super_partitions.py"
    fi

    mount_one_vendor_path "vendor${slot}" /vendor || true
    mount_one_vendor_path "vendor_dlkm${slot}" /vendor_dlkm || true

    {
        echo "--- vendor mounts ---"
        grep -E ' /(vendor|vendor_dlkm) ' /proc/mounts 2>/dev/null || true
        echo "--- vendor paths ---"
        ls -la /vendor/firmware /vendor/etc/firmware /vendor/lib/modules /vendor_dlkm/lib/modules 2>&1 | sed -n '1,160p'
    } >> "$LOG" 2>&1
}

start_adbd()
{
    log "setup adbd: begin"

    mount_if_needed /proc proc proc ""
    mount_if_needed /sys sysfs sysfs ""
    mount_if_needed /dev devtmpfs devtmpfs "mode=0755"
    mount_if_needed /dev/pts devpts devpts "mode=0620,ptmxmode=0666"
    mount_if_needed /config configfs configfs ""

    mkdir -p /system/bin /dev/usb-ffs/adb /lean/run
    ln -sf /bin/sh /system/bin/sh 2>/dev/null || true
    ln -sf /lean/linker64 /system/bin/linker64 2>/dev/null || true

    if [ ! -x /lean/adbd ]; then
        log "setup adbd: missing /lean/adbd"
        return 1
    fi
    if [ ! -x /lean/linker64 ]; then
        log "setup adbd: missing /lean/linker64"
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
    LD_LIBRARY_PATH=/lean/adblib /lean/adbd >> "$ADBD_LOG" 2>&1 &
    adbd_pid=$!
    echo "$adbd_pid" > /lean/run/adbd.ubuntu.pid
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

start_usb_adbd_sampler()
{
    interval="${USB_ADBD_SAMPLE_INTERVAL:-1}"
    case "$interval" in ''|*[!0-9]*|0) interval=1 ;; esac

    (
        : > "$USB_ADBD_SAMPLER_LOG"
        while true; do
            {
                echo "===== usb/adbd sample $(date -u 2>/dev/null || true) ====="
                echo "--- processes ---"
                ps -ef 2>/dev/null | grep -E 'adbd|phase_a' | grep -v grep || true
                echo "--- udc ---"
                for u in /sys/class/udc/*; do
                    [ -e "$u" ] || continue
                    echo "udc=${u##*/} state=$(cat "$u/state" 2>/dev/null || true)"
                done
                echo "--- gadget ---"
                g=/config/usb_gadget/g1
                [ -e "$g/UDC" ] && echo "g1 UDC=$(cat "$g/UDC" 2>/dev/null || true)"
                ls -la /dev/usb-ffs/adb 2>&1 || true
                echo "--- adbd log tail ---"
                tail -30 "$ADBD_LOG" 2>/dev/null || true
            } >> "$USB_ADBD_SAMPLER_LOG" 2>&1
            sleep "$interval"
        done
    ) &
    echo "$!" > "$USB_ADBD_SAMPLER_PID"
    log "usb/adbd sampler started pid=$! interval=${interval}s"
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

    if [ ! -x /lean/wifi_bringup.sh ]; then
        log "wifi requested but /lean/wifi_bringup.sh is missing"
        return 1
    fi

    log "wifi bringup starting"
    KEXEC_BASE=/lean /lean/busybox sh /lean/wifi_bringup.sh &
    echo "$!" > "$WIFI_PID"
    log "wifi bringup started pid=$!"
}

start_watchdog
start_panic_timer
ensure_vendor_mounts
start_adbd
start_usb_adbd_sampler
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
    df -h / /data 2>/dev/null || true
    echo "--- watchdog ---"
    cat "$WATCHDOG_PID" 2>/dev/null || true
    ps -ef 2>/dev/null | grep '[w]atchdog_feeder' || true
    echo "--- panic timer ---"
    cat "$PANIC_TIMER_PID" 2>/dev/null || true
    echo "--- adbd ---"
    cat /lean/run/adbd.ubuntu.pid 2>/dev/null || true
    ps -ef 2>/dev/null | grep '[a]dbd' || true
    tail -80 "$ADBD_LOG" 2>/dev/null || true
    echo "--- usb/adbd sampler ---"
    cat "$USB_ADBD_SAMPLER_PID" 2>/dev/null || true
    tail -80 "$USB_ADBD_SAMPLER_LOG" 2>/dev/null || true
    echo "--- wifi ---"
    cat "$WIFI_PID" 2>/dev/null || true
    ps -ef 2>/dev/null | grep '[w]ifi_bringup' || true
    ls -l /lean/modules 2>/dev/null | sed -n '1,80p' || true
    tail -120 /lean/wifi_bringup.log 2>/dev/null || true
    echo "--- docker dir ---"
    ls -ld /var/lib/docker 2>/dev/null || true
    echo "===== ubuntu phase A end $(date -u 2>/dev/null || true) ====="
} >> "$LOG" 2>&1

sync
log "ready; waiting for adb shell or panic timer"
while true; do
    if [ -x /lean/busybox ]; then
        /lean/busybox sleep 60
    else
        sleep 60
    fi
done
