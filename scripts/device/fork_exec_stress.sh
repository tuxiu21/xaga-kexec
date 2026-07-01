#!/bin/sh
set -u

BASE="${KEXEC_BASE:-/lean}"
LOG="${FORK_STRESS_LOG:-$BASE/fork_exec_stress.log}"
STATE="${FORK_STRESS_STATE:-$BASE/fork_exec_stress.state}"
MODE="${FORK_STRESS_MODE:-sampler}"
ROUNDS="${FORK_STRESS_ROUNDS:-0}"
SLEEP_SECS="${FORK_STRESS_SLEEP:-1}"
BURST="${FORK_STRESS_BURST:-8}"
BB="${BASE}/busybox"

[ -x "$BB" ] || BB=busybox

log()
{
    printf 'fork-stress: %s\n' "$*" | "$BB" tee -a "$LOG" >/dev/null
}

mark()
{
    printf '%s\n' "$*" > "$STATE.tmp" 2>/dev/null &&
        "$BB" mv "$STATE.tmp" "$STATE" 2>/dev/null || true
}

one_sampler_round()
{
    {
        echo "===== sample $("${BB}" date -u 2>/dev/null || true) ====="
        echo "--- processes ---"
        ps -ef 2>/dev/null | grep -E 'adbd|phase_a|fork_exec_stress' | grep -v grep || true
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
        tail -30 "$BASE/adbd_ubuntu.log" 2>/dev/null || true
    } >> "$LOG" 2>&1
}

one_fast_round()
{
    date -u >/dev/null 2>&1 || true
    ps -ef >/dev/null 2>&1 || true
    grep -E 'adbd|phase_a' /proc/*/comm >/dev/null 2>&1 || true
    cat /proc/meminfo >/dev/null 2>&1 || true
    ls -la /dev/usb-ffs/adb >/dev/null 2>&1 || true
    tail -30 "$BASE/adbd_ubuntu.log" >/dev/null 2>&1 || true
}

one_burst_round()
{
    i=0
    while [ "$i" -lt "$BURST" ]; do
        ( one_fast_round ) &
        i=$((i + 1))
    done
    wait
}

case "$MODE" in
    sampler|fast|burst)
        ;;
    *)
        echo "usage: FORK_STRESS_MODE=sampler|fast|burst $0" >&2
        exit 2
        ;;
esac

: > "$LOG"
log "begin mode=$MODE rounds=$ROUNDS sleep=$SLEEP_SECS burst=$BURST pid=$$"

round=0
while :; do
    round=$((round + 1))
    mark "mode=$MODE round=$round start=$("$BB" date -u 2>/dev/null || true) pid=$$"
    case "$MODE" in
        sampler) one_sampler_round ;;
        fast) one_fast_round ;;
        burst) one_burst_round ;;
    esac
    mark "mode=$MODE round=$round done=$("$BB" date -u 2>/dev/null || true) pid=$$"

    if [ "$ROUNDS" != 0 ] && [ "$round" -ge "$ROUNDS" ]; then
        break
    fi
    case "$SLEEP_SECS" in
        0) ;;
        *) "$BB" sleep "$SLEEP_SECS" ;;
    esac
done

log "complete rounds=$round"
