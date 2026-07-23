#!/bin/sh

WIFI_PID="${WIFI_PID:-/run/kexec-runtime/wifi-bringup.pid}"
WIFI_FLAG="${WIFI_FLAG:-/etc/kexec-runtime/wifi_enabled}"

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

    runtime=/usr/local/libexec/kexec
    if [ ! -x "$runtime/wifi_bringup.sh" ]; then
        log "wifi requested but $runtime/wifi_bringup.sh is missing"
        return 1
    fi

    log "wifi bringup starting"
    mkdir -p "$(dirname "$WIFI_PID")"
    KEXEC_RUNTIME="$runtime" /bin/sh "$runtime/wifi_bringup.sh" &
    echo "$!" > "$WIFI_PID"
    log "wifi bringup started pid=$!"
}
