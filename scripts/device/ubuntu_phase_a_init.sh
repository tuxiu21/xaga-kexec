#!/bin/bash
set -uo pipefail

LOG=/data/kexec/ubuntu_phase_a.log
WATCHDOG_PID=/data/kexec/run/watchdog_feeder.ubuntu.pid

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

start_watchdog

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
    echo "--- docker dir ---"
    ls -ld /var/lib/docker 2>/dev/null || true
    echo "===== ubuntu phase A end $(date -u 2>/dev/null || true) ====="
} >> "$LOG" 2>&1

sync
log "triggering panic for stock fallback"
echo 1 > /proc/sys/kernel/sysrq 2>/dev/null || true
echo c > /proc/sysrq-trigger 2>/dev/null || true

while true; do
    sleep 60
done
