#!/bin/sh

LOG="${LOG:-/lean/ubuntu_phase_a.log}"

log()
{
    printf 'kexec-ubuntu: %s\n' "$*" | tee -a "$LOG" >/dev/null
}

log_ls()
{
    label="$1"
    path="$2"

    {
        echo "kexec-ubuntu: $label:"
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

wait_forever()
{
    sync
    log "ready; waiting"
    while true; do
        if [ -x /lean/busybox ]; then
            /lean/busybox sleep 60
        else
            sleep 60
        fi
    done
}
