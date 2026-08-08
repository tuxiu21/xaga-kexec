#!/bin/bash

FLIGHT_CONFIG="${FLIGHT_CONFIG:-/etc/xaga-flight-recorder.conf}"
FLIGHT_LOG="${FLIGHT_LOG:-/var/log/kexec-runtime/flight-recorder.log}"
FLIGHT_STATE_DIR="${FLIGHT_STATE_DIR:-/run/kexec-runtime/flight-recorder}"
FLIGHT_PMSG="${FLIGHT_PMSG:-/dev/pmsg0}"

FLIGHT_HEARTBEAT_SEC="${FLIGHT_HEARTBEAT_SEC:-300}"
FLIGHT_DISK_MAX_BYTES="${FLIGHT_DISK_MAX_BYTES:-2097152}"
FLIGHT_DISK_FILES="${FLIGHT_DISK_FILES:-8}"
FLIGHT_PMSG_BUDGET_BYTES="${FLIGHT_PMSG_BUDGET_BYTES:-49152}"
FLIGHT_EVENT_MAX_BYTES="${FLIGHT_EVENT_MAX_BYTES:-512}"

flight_valid_uint()
{
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
}

flight_load_config()
{
    if [ -r "$FLIGHT_CONFIG" ]; then
        # This is a root-owned deployment configuration, matching the watchdog
        # configuration contract.
        # shellcheck disable=SC1090
        . "$FLIGHT_CONFIG"
    fi

    flight_valid_uint "$FLIGHT_HEARTBEAT_SEC" &&
        [ "$FLIGHT_HEARTBEAT_SEC" -gt 0 ] || FLIGHT_HEARTBEAT_SEC=300
    flight_valid_uint "$FLIGHT_DISK_MAX_BYTES" &&
        [ "$FLIGHT_DISK_MAX_BYTES" -ge 65536 ] || FLIGHT_DISK_MAX_BYTES=2097152
    flight_valid_uint "$FLIGHT_DISK_FILES" &&
        [ "$FLIGHT_DISK_FILES" -gt 0 ] || FLIGHT_DISK_FILES=8
    flight_valid_uint "$FLIGHT_PMSG_BUDGET_BYTES" &&
        [ "$FLIGHT_PMSG_BUDGET_BYTES" -le 49152 ] ||
        FLIGHT_PMSG_BUDGET_BYTES=49152
    flight_valid_uint "$FLIGHT_EVENT_MAX_BYTES" &&
        [ "$FLIGHT_EVENT_MAX_BYTES" -ge 128 ] &&
        [ "$FLIGHT_EVENT_MAX_BYTES" -le 1024 ] || FLIGHT_EVENT_MAX_BYTES=512
}

flight_init()
{
    mkdir -p "$(dirname "$FLIGHT_LOG")" "$FLIGHT_STATE_DIR"
    flight_lock
    [ -e "$FLIGHT_STATE_DIR/seq" ] ||
        printf '0\n' > "$FLIGHT_STATE_DIR/seq"
    [ -e "$FLIGHT_STATE_DIR/pmsg-bytes" ] ||
        printf '0\n' > "$FLIGHT_STATE_DIR/pmsg-bytes"
    [ -e "$FLIGHT_STATE_DIR/kernel-seen" ] ||
        : > "$FLIGHT_STATE_DIR/kernel-seen"
    flight_unlock
    FLIGHT_BOOT_ID="$(cat /proc/sys/kernel/random/boot_id 2>/dev/null ||
        printf unknown)"
    export FLIGHT_BOOT_ID
}

flight_lock()
{
    exec 9>"$FLIGHT_STATE_DIR/write.lock"
    if command -v flock >/dev/null 2>&1; then
        flock -x 9
    fi
}

flight_unlock()
{
    if command -v flock >/dev/null 2>&1; then
        flock -u 9
    fi
    exec 9>&-
}

flight_rotate_disk_log()
{
    local size i

    size="$(stat -c %s "$FLIGHT_LOG" 2>/dev/null || printf 0)"
    flight_valid_uint "$size" || size=0
    [ "$size" -lt "$FLIGHT_DISK_MAX_BYTES" ] && return 0

    i="$FLIGHT_DISK_FILES"
    while [ "$i" -gt 1 ]; do
        [ ! -e "$FLIGHT_LOG.$((i - 1))" ] ||
            mv -f "$FLIGHT_LOG.$((i - 1))" "$FLIGHT_LOG.$i"
        i=$((i - 1))
    done
    [ ! -e "$FLIGHT_LOG" ] || mv -f "$FLIGHT_LOG" "$FLIGHT_LOG.1"
    : > "$FLIGHT_LOG"
}

flight_sanitize()
{
    printf '%s' "$*" |
        tr '\r\n\t' '   ' |
        LC_ALL=C tr -cd '[:print:]' |
        cut -c "1-$FLIGHT_EVENT_MAX_BYTES"
}

flight_record()
{
    local persist="$1" level="$2" event="$3"
    shift 3
    local message seq mono wall line bytes used

    level="$(printf '%s' "$level" | LC_ALL=C tr -cd 'A-Za-z0-9_.-' |
        cut -c 1-16)"
    event="$(printf '%s' "$event" | LC_ALL=C tr -cd 'A-Za-z0-9_.-' |
        cut -c 1-32)"
    [ -n "$level" ] || level=unknown
    [ -n "$event" ] || event=unknown
    message="$(flight_sanitize "$*")"
    mono="$(awk '{print $1; exit}' /proc/uptime 2>/dev/null || printf 0)"
    wall="$(date -u +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || printf unknown)"

    flight_lock
    seq="$(cat "$FLIGHT_STATE_DIR/seq" 2>/dev/null || printf 0)"
    flight_valid_uint "$seq" || seq=0
    seq=$((seq + 1))
    printf '%s\n' "$seq" > "$FLIGHT_STATE_DIR/seq"

    line="XFR1 seq=$seq boot=$FLIGHT_BOOT_ID mono=$mono wall=$wall level=$level event=$event msg=$message"
    flight_rotate_disk_log
    printf '%s\n' "$line" >> "$FLIGHT_LOG"

    if [ "$persist" = 1 ] && [ -w "$FLIGHT_PMSG" ]; then
        used="$(cat "$FLIGHT_STATE_DIR/pmsg-bytes" 2>/dev/null || printf 0)"
        flight_valid_uint "$used" || used=0
        bytes=${#line}
        bytes=$((bytes + 1))
        if [ $((used + bytes)) -le "$FLIGHT_PMSG_BUDGET_BYTES" ]; then
            if printf '%s\n' "$line" > "$FLIGHT_PMSG" 2>/dev/null; then
                printf '%s\n' $((used + bytes)) \
                    > "$FLIGHT_STATE_DIR/pmsg-bytes"
                sync "$FLIGHT_LOG" 2>/dev/null || true
            fi
        fi
    fi
    flight_unlock
}

flight_recorder_event()
{
    local level="$1" event="$2"
    shift 2

    flight_load_config
    flight_init
    flight_record 1 "$level" "$event" "$*"
}

flight_kernel_interesting()
{
    printf '%s\n' "$1" | grep -Eiq \
        'BUG:|WARNING:|Unable to handle|Internal error: Oops|Kernel panic|Bad page|bad page|KASAN:|KFENCE:|use-after-free|double[- ]free|slab.*corrupt|SMMU|IOMMU.*fault|DMA.*(fault|timeout)|soft lockup|hard LOCKUP|hung task|rcu.*stall|firmware.*(assert|crash|timeout)|MBOX Error|drop unmatched|skb_release_data'
}

flight_kernel_monitor()
{
    local line normalized fingerprint

    dmesg --follow --notime --level=emerg,alert,crit,err,warn 2>/dev/null |
        while IFS= read -r line; do
            flight_kernel_interesting "$line" || continue
            normalized="$(flight_sanitize "$line")"
            fingerprint="$(printf '%s' "$normalized" |
                sha256sum 2>/dev/null | awk '{print $1}')"
            [ -n "$fingerprint" ] || continue
            if grep -qx "$fingerprint" "$FLIGHT_STATE_DIR/kernel-seen" \
                2>/dev/null; then
                continue
            fi
            printf '%s\n' "$fingerprint" \
                >> "$FLIGHT_STATE_DIR/kernel-seen"
            flight_record 1 error kernel "$normalized"
        done
}

flight_read_one()
{
    cat "$1" 2>/dev/null | head -1 | tr '\r\n\t ' '____' || printf absent
}

flight_heartbeat()
{
    local system_state failed load memavail blocked
    local operstate rx_bytes tx_bytes rx_errors tx_errors rx_dropped tx_dropped
    local watchdog

    system_state="$(systemctl is-system-running 2>/dev/null || printf unknown)"
    failed="$(systemctl --failed --no-legend --plain 2>/dev/null |
        sed '/^[[:space:]]*$/d' | wc -l)"
    load="$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null | tr ' ' ',')"
    memavail="$(awk '/^MemAvailable:/ {print $2; exit}' /proc/meminfo)"
    blocked="$(ps -eo stat= 2>/dev/null | awk '$1 ~ /^D/ {n++} END {print n+0}')"
    operstate="$(flight_read_one /sys/class/net/wlan0/operstate)"
    rx_bytes="$(flight_read_one /sys/class/net/wlan0/statistics/rx_bytes)"
    tx_bytes="$(flight_read_one /sys/class/net/wlan0/statistics/tx_bytes)"
    rx_errors="$(flight_read_one /sys/class/net/wlan0/statistics/rx_errors)"
    tx_errors="$(flight_read_one /sys/class/net/wlan0/statistics/tx_errors)"
    rx_dropped="$(flight_read_one /sys/class/net/wlan0/statistics/rx_dropped)"
    tx_dropped="$(flight_read_one /sys/class/net/wlan0/statistics/tx_dropped)"
    watchdog="$(flight_read_one /run/kexec-runtime/watchdog-health)"

    flight_record 0 info heartbeat \
        "system=$system_state failed=$failed load=$load memavail_kb=$memavail blocked=$blocked wlan=$operstate rx_bytes=$rx_bytes tx_bytes=$tx_bytes rx_errors=$rx_errors tx_errors=$tx_errors rx_dropped=$rx_dropped tx_dropped=$tx_dropped watchdog=$watchdog"
}

flight_state_transitions()
{
    local failed watchdog previous

    failed="$(systemctl --failed --no-legend --plain 2>/dev/null |
        sed '/^[[:space:]]*$/d' | wc -l)"
    previous="$(cat "$FLIGHT_STATE_DIR/failed-count" 2>/dev/null || printf 0)"
    flight_valid_uint "$failed" || failed=0
    flight_valid_uint "$previous" || previous=0
    if [ "$failed" -gt "$previous" ]; then
        flight_record 1 warn systemd_failed \
            "failed_units=$failed previous=$previous"
    fi
    printf '%s\n' "$failed" > "$FLIGHT_STATE_DIR/failed-count"

    watchdog="$(cat /run/kexec-runtime/watchdog-health 2>/dev/null |
        head -1 || true)"
    previous="$(cat "$FLIGHT_STATE_DIR/watchdog-state" 2>/dev/null || true)"
    if [ -n "$watchdog" ] && [ "$watchdog" != "$previous" ]; then
        case "$watchdog" in
            FAIL*)
                flight_record 1 warn watchdog "$watchdog"
                ;;
        esac
        printf '%s\n' "$watchdog" > "$FLIGHT_STATE_DIR/watchdog-state"
    fi
}

flight_recorder_main()
{
    local cmdline_hash previous_pstore kernel_monitor_pid

    flight_load_config
    flight_init
    cmdline_hash="$(sha256sum /proc/cmdline 2>/dev/null | awk '{print $1}')"
    previous_pstore="$(find /sys/fs/pstore /var/lib/systemd/pstore \
        -maxdepth 1 -type f 2>/dev/null | wc -l)"
    flight_record 1 info boot \
        "kernel=$(uname -r) cmdline_sha256=${cmdline_hash:-unknown} previous_pstore=$previous_pstore pmsg_budget=$FLIGHT_PMSG_BUDGET_BYTES"

    flight_kernel_monitor &
    kernel_monitor_pid=$!
    trap 'kill "$kernel_monitor_pid" 2>/dev/null || true; wait "$kernel_monitor_pid" 2>/dev/null || true' EXIT
    trap 'exit 0' INT TERM

    while true; do
        flight_heartbeat
        flight_state_transitions
        sleep "$FLIGHT_HEARTBEAT_SEC"
    done
}
