#!/bin/sh
set -u

LOG=/lean/no_adbd_dwell.log
WATCHDOG_PID=/lean/run/watchdog_feeder.ubuntu.pid
DWELL_SECS="${NO_ADBD_DWELL_SECS:-420}"

log()
{
    printf 'no-adbd-dwell: %s\n' "$*" >> "$LOG"
}

mkdir -p /lean/run
: > "$LOG"
log "start $(date -u 2>/dev/null || true) dwell=${DWELL_SECS}s pid=$$"

if [ -x /lean/watchdog_feeder ]; then
    /lean/watchdog_feeder 5 &
    echo "$!" > "$WATCHDOG_PID"
    log "watchdog started pid=$!"
else
    log "watchdog missing"
fi

log "sleep begin"
sleep "$DWELL_SECS"
log "planned reboot $(date -u 2>/dev/null || true)"
sync
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
echo b > /proc/sysrq-trigger 2>/dev/null || true

while true; do
    sleep 60
done
