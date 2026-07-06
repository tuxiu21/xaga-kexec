#!/bin/sh

PANIC_TIMER_PID="${PANIC_TIMER_PID:-/lean/run/panic_timer.ubuntu.pid}"

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
