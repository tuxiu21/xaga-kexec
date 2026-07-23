#!/bin/sh

RUNTIME="${KEXEC_RUNTIME:-/usr/local/libexec/kexec}"
ADBD_LOG="${ADBD_LOG:-/var/log/kexec-runtime/adbd.log}"
ADBD_READY="${ADBD_READY:-/run/kexec-runtime/adbd.ready}"
USB_ADBD_SAMPLER_LOG="${USB_ADBD_SAMPLER_LOG:-/var/log/kexec-runtime/usb-adbd-sampler.log}"
USB_ADBD_SAMPLER_PID="${USB_ADBD_SAMPLER_PID:-/run/kexec-runtime/usb-adbd-sampler.pid}"

start_adbd()
{
    log "setup adbd: begin"
    rm -f "$ADBD_READY"

    mount_if_needed /proc proc proc ""
    mount_if_needed /sys sysfs sysfs ""
    mount_if_needed /dev devtmpfs devtmpfs "mode=0755"
    mount_if_needed /dev/pts devpts devpts "mode=0620,ptmxmode=0666"
    mount_if_needed /config configfs configfs ""

    mkdir -p /system/bin /dev/usb-ffs/adb /run/kexec-runtime /var/log/kexec-runtime
    ln -sf /bin/sh /system/bin/sh 2>/dev/null || true
    ln -sf "$RUNTIME/linker64" /system/bin/linker64 2>/dev/null || true

    if [ ! -x "$RUNTIME/adbd" ]; then
        log "setup adbd: missing $RUNTIME/adbd"
        return 1
    fi
    if [ ! -x "$RUNTIME/linker64" ]; then
        log "setup adbd: missing $RUNTIME/linker64"
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
    LD_LIBRARY_PATH="$RUNTIME/adblib" "$RUNTIME/adbd" >> "$ADBD_LOG" 2>&1 &
    adbd_pid=$!
    echo "$adbd_pid" > /run/kexec-runtime/adbd.pid
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
            : > "$ADBD_READY"
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
    case "${USB_ADBD_SAMPLER:-0}" in
        1|true|TRUE|yes|YES|on|ON)
            ;;
        *)
            log "usb/adbd sampler skipped"
            return 0
            ;;
    esac

    interval="${USB_ADBD_SAMPLE_INTERVAL:-1}"
    case "$interval" in ''|*[!0-9]*|0) interval=1 ;; esac

    (
        : > "$USB_ADBD_SAMPLER_LOG"
        while true; do
            {
                echo "===== usb/adbd sample $(date -u 2>/dev/null || true) ====="
                echo "--- processes ---"
                ps -ef 2>/dev/null | grep -E 'adbd|kexec-' | grep -v grep || true
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
