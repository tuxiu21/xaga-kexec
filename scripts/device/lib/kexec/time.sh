#!/bin/sh

TIME_STATE="${TIME_STATE:-/var/lib/kexec-runtime/time-state}"
TIME_KEEPER_PID="${TIME_KEEPER_PID:-/run/kexec-runtime/time-keeper.pid}"

restore_time()
{
    min_epoch=1781272800
    now="$(date +%s 2>/dev/null || echo 0)"
    case "$now" in ''|*[!0-9]*) now=0 ;; esac

    saved="$(cat "$TIME_STATE" 2>/dev/null || true)"
    case "$saved" in ''|*[!0-9]*) saved=0 ;; esac

    if [ "$saved" -ge "$min_epoch" ] && [ "$saved" -gt "$now" ]; then
        if date -u -s "@$saved" >/dev/null 2>&1; then
            log "time restored from $TIME_STATE: $(date -u 2>/dev/null || true)"
            return 0
        fi
        log "time restore failed from $TIME_STATE epoch=$saved"
    else
        log "time restore skipped now=$now saved=$saved"
    fi
}

start_time_keeper()
{
    restore_time
    mkdir -p "$(dirname "$TIME_STATE")" "$(dirname "$TIME_KEEPER_PID")"
    (
        while true; do
            now="$(date +%s 2>/dev/null || echo 0)"
            case "$now" in
                ''|*[!0-9]*|0)
                    ;;
                *)
                    printf '%s\n' "$now" > "$TIME_STATE.tmp" 2>/dev/null &&
                        mv "$TIME_STATE.tmp" "$TIME_STATE" 2>/dev/null &&
                        sync "$TIME_STATE" 2>/dev/null || true
                    ;;
            esac
            sleep 60
        done
    ) &
    echo "$!" > "$TIME_KEEPER_PID"
    log "time keeper started pid=$!"
}
