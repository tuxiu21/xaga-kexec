#!/bin/sh

WIFI_PID="${WIFI_PID:-/lean/run/wifi_bringup.ubuntu.pid}"
WIFI_FLAG="${WIFI_FLAG:-/lean/ubuntu_wifi}"

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
