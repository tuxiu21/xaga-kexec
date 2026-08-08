#!/usr/bin/env bash
# Recover an already-installed Ubuntu payload through the stock rescue tunnel.
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

SSH="${SSH:-ssh}"
GATEWAY="${XAGA_RECOVER_GATEWAY:-usjgw}"
REMOTE_BIND="${XAGA_RECOVER_BIND:-127.0.0.1}"
STOCK_PORT="${XAGA_STOCK_SSH_PORT:-22023}"
UBUNTU_PORT="${XAGA_UBUNTU_SSH_PORT:-22024}"
STOCK_USER="${XAGA_STOCK_SSH_USER:-root}"
UBUNTU_USER="${XAGA_UBUNTU_SSH_USER:-root}"
IDENTITY_ALIAS="${XAGA_RECOVER_IDENTITY_ALIAS:-xaga}"
DEFAULT_IDENTITY="$("$SSH" -G "$IDENTITY_ALIAS" 2>/dev/null |
    awk '$1 == "identityfile" { print $2; exit }')"
STOCK_IDENTITY="${XAGA_STOCK_SSH_IDENTITY:-$DEFAULT_IDENTITY}"
UBUNTU_IDENTITY="${XAGA_UBUNTU_SSH_IDENTITY:-$DEFAULT_IDENTITY}"
STOCK_HOST_KEY_ALIAS="${XAGA_STOCK_HOST_KEY_ALIAS:-xaga-stock-via-usjgw}"
UBUNTU_HOST_KEY_ALIAS="${XAGA_UBUNTU_HOST_KEY_ALIAS:-xaga-ubuntu-via-usjgw}"
CONNECT_TIMEOUT="${RECOVER_CONNECT_TIMEOUT:-8}"
POLL_INTERVAL="${RECOVER_POLL_INTERVAL:-5}"
WAIT_TIMEOUT="${RECOVER_WAIT_TIMEOUT:-600}"
STOCK_READY_TIMEOUT="${RECOVER_STOCK_READY_TIMEOUT:-120}"
PROFILE="${RECOVER_PROFILE:-dev}"
PANIC_AFTER="${RECOVER_PANIC_AFTER:-0}"
LAUNCHER="${XAGA_STOCK_LAUNCHER:-/data/local/tmp/xaga/reboot-to-ubuntu.sh}"
NOEXEC_GRACE="${RECOVER_NOEXEC_GRACE:-60}"

OUT="${RECOVER_LOG_DIR:-$LOG_ROOT/recover_stock_ssh_$(date +%Y%m%d_%H%M%S)}"
mkdir -p "$OUT"
LOG="$OUT/recover.log"

say()
{
    printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$LOG"
}

die()
{
    say "ERROR: $*"
    exit 2
}

valid_uint()
{
    case "$1" in
        ''|*[!0-9]*) return 1 ;;
    esac
}

valid_port()
{
    valid_uint "$1" && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

valid_remote_name()
{
    case "$1" in
        ''|*[!A-Za-z0-9_.:-]*) return 1 ;;
    esac
}

valid_remote_path()
{
    case "$1" in
        /*) ;;
        *) return 1 ;;
    esac
    case "$1" in
        *[!A-Za-z0-9_./+-]*) return 1 ;;
    esac
}

tunnel_run()
{
    local port="$1" user="$2" identity="$3" host_key_alias="$4" command="$5"
    local -a args=(
        -J "$GATEWAY"
        -o BatchMode=yes
        -o "ConnectTimeout=$CONNECT_TIMEOUT"
        -o ServerAliveInterval=5
        -o ServerAliveCountMax=3
        -o StrictHostKeyChecking=accept-new
        -o "HostKeyAlias=$host_key_alias"
    )
    [ -z "$identity" ] || args+=(-i "$identity" -o IdentitiesOnly=yes)
    args+=(-p "$port" "$user@$REMOTE_BIND" "$command")
    "$SSH" "${args[@]}"
}

stock_run()
{
    tunnel_run "$STOCK_PORT" "$STOCK_USER" "$STOCK_IDENTITY" \
        "$STOCK_HOST_KEY_ALIAS" "$1"
}

ubuntu_run()
{
    tunnel_run "$UBUNTU_PORT" "$UBUNTU_USER" "$UBUNTU_IDENTITY" \
        "$UBUNTU_HOST_KEY_ALIAS" "$1"
}

stock_probe()
{
    stock_run 'test "$(id -u)" = 0 && echo RECOVER_STOCK_PROBE_OK' 2>/dev/null |
        grep -qx RECOVER_STOCK_PROBE_OK
}

ubuntu_probe()
{
    ubuntu_run 'test "$(id -u)" = 0 && grep -q "^ID=ubuntu$" /etc/os-release && echo RECOVER_UBUNTU_PROBE_OK' 2>/dev/null |
        grep -qx RECOVER_UBUNTU_PROBE_OK
}

collect_stock_logs()
{
    local destination="$OUT/stock-failure.log"
    say "collecting stock-readable recovery logs -> $destination"
    stock_run '
        echo "===== identity ====="
        id
        getprop ro.product.device 2>/dev/null || true
        getprop sys.boot_completed 2>/dev/null || true
        uptime 2>/dev/null || true
        echo "===== stock rescue ====="
        cat /data/local/tmp/stock-rescue.log 2>/dev/null || true
        echo "===== pstore ====="
        for f in /sys/fs/pstore/*; do
            [ -f "$f" ] || continue
            echo "--- $f"
            cat "$f"
        done
        echo "===== Ubuntu runtime logs ====="
        mounted_here=0
        if ! grep -q " /mnt/linux_kexec " /proc/mounts 2>/dev/null; then
            mkdir -p /mnt/linux_kexec
            linux_dev=/dev/block/by-name/linux
            [ -b "$linux_dev" ] || linux_dev=/dev/block/sdc88
            mount -t ext4 -o ro,noload "$linux_dev" /mnt/linux_kexec 2>/dev/null ||
                mount -t ext4 -o ro "$linux_dev" /mnt/linux_kexec 2>/dev/null ||
                true
            grep -q " /mnt/linux_kexec " /proc/mounts 2>/dev/null &&
                mounted_here=1
        fi
        for f in \
            /mnt/linux_kexec/var/log/kexec-runtime/flight-recorder.log.8 \
            /mnt/linux_kexec/var/log/kexec-runtime/flight-recorder.log.7 \
            /mnt/linux_kexec/var/log/kexec-runtime/flight-recorder.log.6 \
            /mnt/linux_kexec/var/log/kexec-runtime/flight-recorder.log.5 \
            /mnt/linux_kexec/var/log/kexec-runtime/flight-recorder.log.4 \
            /mnt/linux_kexec/var/log/kexec-runtime/flight-recorder.log.3 \
            /mnt/linux_kexec/var/log/kexec-runtime/flight-recorder.log.2 \
            /mnt/linux_kexec/var/log/kexec-runtime/flight-recorder.log.1 \
            /mnt/linux_kexec/var/log/kexec-runtime/flight-recorder.log \
            /mnt/linux_kexec/var/log/kexec-runtime/bootstrap.log \
            /mnt/linux_kexec/var/log/kexec-runtime/boot-rootfs.log \
            /mnt/linux_kexec/var/log/kexec-runtime/ubuntu-runtime.log \
            /mnt/linux_kexec/var/log/kexec-runtime/adbd.log \
            /mnt/linux_kexec/var/log/kexec-runtime/wifi-bringup.log; do
            [ -f "$f" ] || continue
            echo "--- $f"
            cat "$f"
        done
        [ "$mounted_here" = 0 ] || umount /mnt/linux_kexec 2>/dev/null || true
    ' > "$destination" 2>&1 || say "stock log collection failed"
    "$ROOT/scripts/host/decode_flight_recorder.sh" "$destination" \
        > "$OUT/flight-recorder-pmsg.txt" 2>/dev/null || true
}

case "$PROFILE" in
    dev|prod) ;;
    *) die "invalid recovery profile: $PROFILE" ;;
esac
valid_uint "$PANIC_AFTER" || die "invalid panic timeout: $PANIC_AFTER"
valid_uint "$WAIT_TIMEOUT" && [ "$WAIT_TIMEOUT" -gt 0 ] ||
    die "invalid wait timeout: $WAIT_TIMEOUT"
valid_uint "$POLL_INTERVAL" || die "invalid poll interval: $POLL_INTERVAL"
valid_uint "$NOEXEC_GRACE" || die "invalid no-exec grace: $NOEXEC_GRACE"
valid_uint "$STOCK_READY_TIMEOUT" && [ "$STOCK_READY_TIMEOUT" -gt 0 ] ||
    die "invalid stock-ready timeout: $STOCK_READY_TIMEOUT"
valid_uint "$CONNECT_TIMEOUT" && [ "$CONNECT_TIMEOUT" -gt 0 ] ||
    die "invalid connect timeout: $CONNECT_TIMEOUT"
valid_port "$STOCK_PORT" || die "invalid stock SSH port: $STOCK_PORT"
valid_port "$UBUNTU_PORT" || die "invalid Ubuntu SSH port: $UBUNTU_PORT"
valid_remote_name "$REMOTE_BIND" || die "invalid tunnel bind address: $REMOTE_BIND"
valid_remote_name "$STOCK_USER" || die "invalid stock SSH user: $STOCK_USER"
valid_remote_name "$UBUNTU_USER" || die "invalid Ubuntu SSH user: $UBUNTU_USER"
valid_remote_name "$STOCK_HOST_KEY_ALIAS" || die "invalid stock host-key alias"
valid_remote_name "$UBUNTU_HOST_KEY_ALIAS" || die "invalid Ubuntu host-key alias"
valid_remote_path "$LAUNCHER" || die "invalid stock launcher path: $LAUNCHER"
[ -z "$STOCK_IDENTITY" ] || valid_remote_path "$STOCK_IDENTITY" ||
    die "stock identity must be an absolute local path"
[ -z "$UBUNTU_IDENTITY" ] || valid_remote_path "$UBUNTU_IDENTITY" ||
    die "Ubuntu identity must be an absolute local path"
command -v "$SSH" >/dev/null 2>&1 || die "missing SSH command: $SSH"

say "proxy_jump=$GATEWAY stock=$REMOTE_BIND:$STOCK_PORT ubuntu=$REMOTE_BIND:$UBUNTU_PORT profile=$PROFILE panic=${PANIC_AFTER}s timeout=${WAIT_TIMEOUT}s"
say "waiting up to ${STOCK_READY_TIMEOUT}s for stock rescue and payload preflight"
preflight='
    set -eu
    test "$(id -u)" = 0
    test "$(getprop ro.product.device 2>/dev/null || true)" = xaga
    test -x '"$LAUNCHER"'
    for f in \
        /data/local/tmp/kernel \
        /data/local/tmp/kexec \
        /data/local/tmp/combined_ramdisk_kexec_system_mbox.lz4; do
        test -s "$f"
    done
    test -b /dev/block/by-name/linux || test -b /dev/block/sdc88
    echo "battery_status=$(cat /sys/class/power_supply/battery/status 2>/dev/null || echo unknown)"
    echo "battery_capacity=$(cat /sys/class/power_supply/battery/capacity 2>/dev/null || echo unknown)"
    sha256sum \
        /data/local/tmp/kernel \
        /data/local/tmp/combined_ramdisk_kexec_system_mbox.lz4
    echo RECOVER_STOCK_PRECHECK_OK
'
preflight_deadline=$(( $(date +%s) + STOCK_READY_TIMEOUT ))
preflight_passed=0
: > "$OUT/preflight.log"
while [ "$(date +%s)" -lt "$preflight_deadline" ]; do
    if stock_run "$preflight" >> "$OUT/preflight.log" 2>&1; then
        preflight_passed=1
        break
    fi
    sleep 10
done
cat "$OUT/preflight.log"
if [ "$preflight_passed" != 1 ]; then
    die "stock SSH preflight failed; see $OUT/preflight.log"
fi

say "preflight passed; invoking the existing stock launcher exactly once"
trigger="WATCHDOG_PROFILE=$PROFILE PANIC_AFTER=$PANIC_AFTER $LAUNCHER"
stock_run "$trigger" > "$OUT/trigger.log" 2>&1
trigger_rc=$?
case "$trigger_rc" in
    0|255)
        say "stock trigger returned rc=$trigger_rc; waiting for Ubuntu"
        ;;
    *)
        say "stock trigger failed rc=$trigger_rc; not retrying automatically"
        collect_stock_logs
        exit 3
        ;;
esac

start="$(date +%s)"
deadline=$((start + WAIT_TIMEOUT))
stock_went_away=0
while [ "$(date +%s)" -lt "$deadline" ]; do
    if ubuntu_probe; then
        if ubuntu_run '
            echo "RECOVER_UBUNTU_OK"
            hostname
            systemctl is-system-running 2>/dev/null || true
            uptime
        ' > "$OUT/ubuntu-validation.log" 2>&1; then
            cat "$OUT/ubuntu-validation.log"
            say "SUCCESS: Ubuntu is reachable through port $UBUNTU_PORT"
            say "logs: $OUT"
            exit 0
        fi
        say "Ubuntu probe succeeded but validation disconnected; continuing to wait"
    fi

    if stock_probe; then
        if [ "$stock_went_away" = 1 ]; then
            say "stock returned before Ubuntu SSH became reachable"
            collect_stock_logs
            say "logs: $OUT"
            exit 4
        fi
        if [ $(( $(date +%s) - start )) -ge "$NOEXEC_GRACE" ]; then
            say "stock never went away within ${NOEXEC_GRACE}s; refusing to trigger again"
            collect_stock_logs
            say "logs: $OUT"
            exit 5
        fi
    else
        if [ "$stock_went_away" = 0 ]; then
            stock_went_away=1
            say "stock SSH disappeared; kexec handoff is in progress"
        fi
    fi
    sleep "$POLL_INTERVAL"
done

say "timed out waiting for Ubuntu SSH after ${WAIT_TIMEOUT}s"
stock_probe && collect_stock_logs
say "logs: $OUT"
exit 6
