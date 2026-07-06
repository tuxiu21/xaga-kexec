#!/bin/sh

WATCHDOG_PID="${WATCHDOG_PID:-/lean/run/watchdog.ubuntu.pid}"
WATCHDOG_STATUS="${WATCHDOG_STATUS:-/lean/run/watchdog_health.status}"
WATCHDOG_CONFIG="${WATCHDOG_CONFIG:-/etc/xaga-watchdog.conf}"

start_watchdog_dev()
{
    mkdir -p /lean/run
    WATCHDOG_DEV=""
    if ! watchdog_open_device 2>/dev/null; then
        log "watchdog dev: no watchdog device available"
        return 1
    fi

    echo "$$" > "$WATCHDOG_PID"
    log "watchdog shell feeder started pid=$$ dev=$WATCHDOG_DEV mode=dev feed=${WATCHDOG_FEED_INTERVAL}s"
    while true; do
        printf V >&9 2>/dev/null || log "watchdog dev: kick failed dev=$WATCHDOG_DEV"
        sleep "$WATCHDOG_FEED_INTERVAL"
    done
}

load_watchdog_config()
{
    WATCHDOG_MODE="${WATCHDOG_MODE:-dev}"
    WATCHDOG_DRY_RUN="${WATCHDOG_DRY_RUN:-1}"
    WATCHDOG_FEED_INTERVAL="${WATCHDOG_FEED_INTERVAL:-5}"
    WATCHDOG_CHECK_INTERVAL="${WATCHDOG_CHECK_INTERVAL:-60}"
    WATCHDOG_BOOT_GRACE="${WATCHDOG_BOOT_GRACE:-600}"
    WATCHDOG_FAIL_THRESHOLD="${WATCHDOG_FAIL_THRESHOLD:-10}"
    WATCHDOG_SELF_HEAL_AFTER="${WATCHDOG_SELF_HEAL_AFTER:-3}"
    WATCHDOG_DNS_NAME="${WATCHDOG_DNS_NAME:-archive.ubuntu.com}"
    WATCHDOG_HEALTH_URLS="${WATCHDOG_HEALTH_URLS:-}"
    WATCHDOG_CURL_TIMEOUT="${WATCHDOG_CURL_TIMEOUT:-10}"

    if [ -r "$WATCHDOG_CONFIG" ]; then
        # shellcheck disable=SC1090
        . "$WATCHDOG_CONFIG"
    fi

    case "$WATCHDOG_FEED_INTERVAL" in ''|*[!0-9]*|0) WATCHDOG_FEED_INTERVAL=5 ;; esac
    case "$WATCHDOG_CHECK_INTERVAL" in ''|*[!0-9]*|0) WATCHDOG_CHECK_INTERVAL=60 ;; esac
    case "$WATCHDOG_BOOT_GRACE" in ''|*[!0-9]*) WATCHDOG_BOOT_GRACE=600 ;; esac
    case "$WATCHDOG_FAIL_THRESHOLD" in ''|*[!0-9]*|0) WATCHDOG_FAIL_THRESHOLD=10 ;; esac
    case "$WATCHDOG_SELF_HEAL_AFTER" in ''|*[!0-9]*|0) WATCHDOG_SELF_HEAL_AFTER=3 ;; esac
    case "$WATCHDOG_CURL_TIMEOUT" in ''|*[!0-9]*|0) WATCHDOG_CURL_TIMEOUT=10 ;; esac
}

watchdog_open_device()
{
    for dev in /dev/watchdog0 /dev/watchdog; do
        [ -e "$dev" ] || continue
        if exec 9>"$dev"; then
            WATCHDOG_DEV="$dev"
            return 0
        fi
    done
    return 1
}

watchdog_health_check()
{
    reason=""

    if ! ip route show default 2>/dev/null | grep -q .; then
        reason="${reason} no_default_route;"
    fi

    if ! ip -4 addr show wlan0 2>/dev/null | grep -q ' inet '; then
        reason="${reason} no_wlan0_ipv4;"
    fi

    if ! getent hosts "$WATCHDOG_DNS_NAME" >/dev/null 2>&1; then
        reason="${reason} dns_${WATCHDOG_DNS_NAME}_failed;"
    fi

    if ! systemctl is-active --quiet ssh.service 2>/dev/null &&
       ! systemctl is-active --quiet sshd.service 2>/dev/null; then
        reason="${reason} ssh_inactive;"
    fi

    state="$(systemctl is-system-running 2>/dev/null || true)"
    case "$state" in
        running|degraded) ;;
        *) reason="${reason} systemd_${state:-unknown};" ;;
    esac

    if [ -n "$WATCHDOG_HEALTH_URLS" ]; then
        url_ok=0
        for url in $WATCHDOG_HEALTH_URLS; do
            if command -v curl >/dev/null 2>&1 &&
               curl -fsS --max-time "$WATCHDOG_CURL_TIMEOUT" "$url" >/dev/null 2>&1; then
                url_ok=1
                break
            fi
        done
        [ "$url_ok" = 1 ] || reason="${reason} external_url_failed;"
    fi

    if [ -n "$reason" ]; then
        printf 'FAIL %s\n' "$reason" > "$WATCHDOG_STATUS"
        return 1
    fi

    printf 'OK %s\n' "$(date -Is 2>/dev/null || true)" > "$WATCHDOG_STATUS"
    return 0
}

watchdog_self_heal()
{
    fail_count="$1"

    if [ "$WATCHDOG_DRY_RUN" = 1 ]; then
        log "watchdog gated dry-run: would self-heal fail_count=$fail_count"
        return 0
    fi

    log "watchdog gated: self-heal begin fail_count=$fail_count"
    systemctl restart systemd-resolved.service 2>/dev/null || true
    systemctl restart ssh.service 2>/dev/null || systemctl restart sshd.service 2>/dev/null || true

    if [ "$fail_count" -ge $((WATCHDOG_SELF_HEAL_AFTER + 1)) ]; then
        systemctl restart wpa_supplicant@wlan0.service 2>/dev/null || true
    fi
    if [ "$fail_count" -ge $((WATCHDOG_SELF_HEAL_AFTER + 2)) ]; then
        systemctl restart systemd-networkd.service 2>/dev/null || true
    fi
    if systemctl list-unit-files tailscaled.service >/dev/null 2>&1; then
        systemctl restart tailscaled.service 2>/dev/null || true
    fi
    log "watchdog gated: self-heal end fail_count=$fail_count"
}

start_watchdog_gated()
{
    load_watchdog_config

    if [ "$WATCHDOG_MODE" != "unattended" ]; then
        start_watchdog_dev
        return $?
    fi

    mkdir -p /lean/run
    WATCHDOG_DEV=""
    if ! watchdog_open_device 2>/dev/null; then
        log "watchdog gated: no watchdog device available"
        return 1
    fi

    echo "$$" > "$WATCHDOG_PID"
    boot_epoch="$(date +%s 2>/dev/null || echo 0)"
    next_check=0
    fail_count=0
    log "watchdog gated started pid=$$ dev=$WATCHDOG_DEV dry_run=$WATCHDOG_DRY_RUN feed=${WATCHDOG_FEED_INTERVAL}s check=${WATCHDOG_CHECK_INTERVAL}s grace=${WATCHDOG_BOOT_GRACE}s threshold=$WATCHDOG_FAIL_THRESHOLD"

    while true; do
        now="$(date +%s 2>/dev/null || echo 0)"
        case "$now" in ''|*[!0-9]*) now=0 ;; esac

        if [ "$now" -ge "$next_check" ]; then
            next_check=$((now + WATCHDOG_CHECK_INTERVAL))
            if [ $((now - boot_epoch)) -lt "$WATCHDOG_BOOT_GRACE" ]; then
                printf 'GRACE %s\n' "$(date -Is 2>/dev/null || true)" > "$WATCHDOG_STATUS"
                fail_count=0
            elif watchdog_health_check; then
                [ "$fail_count" = 0 ] || log "watchdog gated: health recovered after fail_count=$fail_count"
                fail_count=0
            else
                fail_count=$((fail_count + 1))
                reason="$(cat "$WATCHDOG_STATUS" 2>/dev/null || true)"
                log "watchdog gated: health failed count=$fail_count/$WATCHDOG_FAIL_THRESHOLD $reason"

                if [ "$fail_count" -ge "$WATCHDOG_SELF_HEAL_AFTER" ] &&
                   [ "$fail_count" -lt "$WATCHDOG_FAIL_THRESHOLD" ]; then
                    watchdog_self_heal "$fail_count"
                fi

                if [ "$fail_count" -ge "$WATCHDOG_FAIL_THRESHOLD" ]; then
                    if [ "$WATCHDOG_DRY_RUN" = 1 ]; then
                        log "watchdog gated dry-run: would stop feeding watchdog; continuing feed"
                        fail_count=0
                    else
                        log "watchdog gated: stopping watchdog feed; holding fd open for hardware reset"
                        while true; do
                            sleep 3600
                        done
                    fi
                fi
            fi
        fi

        printf V >&9 2>/dev/null || log "watchdog gated: kick failed dev=$WATCHDOG_DEV"
        sleep "$WATCHDOG_FEED_INTERVAL"
    done
}
