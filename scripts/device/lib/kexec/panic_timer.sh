#!/bin/sh

PANIC_TIMER_PID="${PANIC_TIMER_PID:-/run/kexec-runtime/panic-timer.pid}"

start_panic_timer()
{
    after=0
    if [ -s /etc/kexec-runtime/panic_after ]; then
        after="$(cat /etc/kexec-runtime/panic_after 2>/dev/null || echo 0)"
    fi

    case "$after" in
        ''|*[!0-9]*|0)
            log "panic timer disabled"
            return 0
            ;;
    esac

    (
        log "panic timer armed: ${after}s"
        sleep "$after"
        log "panic timer firing"
        sync
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
        echo c > /proc/sysrq-trigger 2>/dev/null || true
        echo panic > /proc/sysrq-trigger 2>/dev/null || true
    ) &
    mkdir -p "$(dirname "$PANIC_TIMER_PID")"
    echo "$!" > "$PANIC_TIMER_PID"
}
