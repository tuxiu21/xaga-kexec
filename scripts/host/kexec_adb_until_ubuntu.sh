#!/usr/bin/env bash
# Boot/capture loop for the direct-root Ubuntu handoff.
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

INITRD="${1:-$OUTPUT_DIR/combined_ramdisk_kexec_system_mbox.lz4}"
INITRD_DEV="$(basename "$INITRD")"
DTB_DEV="${DTB_DEV:-patched.dtb}"
MAX="${2:-8}"
UBUNTU_SERIAL="${UBUNTU_SERIAL:-ubuntu012345678}"
PANIC_AFTER="${PANIC_AFTER:-900}"
KEXEC_EXTRA_CMDLINE="${KEXEC_EXTRA_CMDLINE:-}"
UBUNTU_WIFI="${UBUNTU_WIFI:-1}"
UBUNTU_WIFI_SKIP_MODULES="${UBUNTU_WIFI_SKIP_MODULES:-}"
UBUNTU_WIFI_WAIT_READY="${UBUNTU_WIFI_WAIT_READY:-1}"
UBUNTU_WIFI_WAIT="${UBUNTU_WIFI_WAIT:-260}"
NOEXEC_MAX="${NOEXEC_MAX:-3}"
ADB_TIMEOUT="${ADB_TIMEOUT:-8s}"
KEXEC_TRIGGER_TIMEOUT="${KEXEC_TRIGGER_TIMEOUT:-20s}"
STOCK_GRACE="${STOCK_GRACE:-10}"
LINUX_DEV="${LINUX_DEV:-/dev/block/by-name/linux}"
LINUX_DEV_FALLBACK="${LINUX_DEV_FALLBACK:-/dev/block/sdc88}"
LINUX_MOUNT="${LINUX_MOUNT:-/mnt/linux_kexec}"
RUNTIME_DIR="${RUNTIME_DIR:-$LINUX_MOUNT/usr/local/libexec/kexec}"
REMOTE_LOG_DIR="${REMOTE_LOG_DIR:-$LINUX_MOUNT/var/log/kexec-runtime}"
REMOTE_STATE_DIR="${REMOTE_STATE_DIR:-$LINUX_MOUNT/var/lib/kexec-runtime}"
OUT="$LOG_ROOT/kexec_adb_until_ubuntu_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

STOCK_SERIAL="${STOCK_SERIAL:-}"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/log.txt"; }

adb_devices() { timeout "$ADB_TIMEOUT" "$ADB" devices 2>/dev/null | tr -d '\r'; }
serial_state() { adb_devices | awk -v s="$1" '$1==s{print $2}'; }
ubuntu_up() { [ "$(serial_state "$UBUNTU_SERIAL")" = "device" ]; }
stock_up() { [ -n "$STOCK_SERIAL" ] && [ "$(serial_state "$STOCK_SERIAL")" = "device" ]; }
detect_stock_serial() { adb_devices | awk -v u="$UBUNTU_SERIAL" 'NR>1 && $2=="device" && $1!=u {print $1; exit}'; }

adb_root_shell()
{
    local script="$1"
    if [ "$($ADB shell 'id -u 2>/dev/null' | tr -d '\r')" = "0" ]; then
        $ADB shell "$script"
    else
        $ADB shell "su -c '$script'"
    fi
}

probe_ubuntu_root() {
    local out="$1"
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" wait-for-device >/dev/null 2>&1 || return 1
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'echo adb-probe; cat /proc/1/comm 2>/dev/null; findmnt / 2>/dev/null || mount | grep " on / "; cat /etc/os-release 2>/dev/null || true; ps -ef | grep -E "adbd|watchdog|kexec-" | grep -v grep || true' > "$out.tmp" 2>&1 || return 1
    tr -d '\r' < "$out.tmp" > "$out"
    rm -f "$out.tmp"
    grep -qa 'ID=ubuntu' "$out"
}

pull_from_stock() {
    local r="$1"
    adb_root_shell "mkdir -p $LINUX_MOUNT; grep -q \" $LINUX_MOUNT \" /proc/mounts || mount -t ext4 -o rw,noatime $LINUX_DEV $LINUX_MOUNT 2>/dev/null || mount -t ext4 -o rw,noatime $LINUX_DEV_FALLBACK $LINUX_MOUNT; cat $REMOTE_LOG_DIR/bootstrap.log 2>/dev/null" > "$OUT/round_${r}_kxsh.log" 2>/dev/null
    adb_root_shell "cat $REMOTE_LOG_DIR/boot-rootfs.log 2>/dev/null" > "$OUT/round_${r}_boot_ubuntu_rootfs.log" 2>/dev/null
    adb_root_shell "cat $REMOTE_LOG_DIR/ubuntu-runtime.log 2>/dev/null" > "$OUT/round_${r}_ubuntu_phase_a.log" 2>/dev/null
    adb_root_shell "cat $REMOTE_LOG_DIR/adbd.log 2>/dev/null" > "$OUT/round_${r}_adbd_ubuntu.log" 2>/dev/null
    adb_root_shell "cat $REMOTE_LOG_DIR/usb-adbd-sampler.log 2>/dev/null" > "$OUT/round_${r}_usb_adbd_sampler.log" 2>/dev/null
    adb_root_shell "cat $REMOTE_LOG_DIR/wifi-bringup.log 2>/dev/null" > "$OUT/round_${r}_wifi_bringup.log" 2>/dev/null
    adb_root_shell "cat $REMOTE_STATE_DIR/wifi-status 2>/dev/null" > "$OUT/round_${r}_wifi_load_progress.txt" 2>/dev/null
    adb_root_shell "cat $REMOTE_LOG_DIR/dmesg-wifi-before.log 2>/dev/null" > "$OUT/round_${r}_dmesg_wifi_before.log" 2>/dev/null
    adb_root_shell "cat $REMOTE_LOG_DIR/dmesg-wifi-after.log 2>/dev/null" > "$OUT/round_${r}_dmesg_wifi_after.log" 2>/dev/null
}

pull_from_ubuntu() {
    local r="$1"
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /var/log/kexec-runtime/bootstrap.log 2>/dev/null' > "$OUT/round_${r}_kxsh.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /var/log/kexec-runtime/boot-rootfs.log 2>/dev/null' > "$OUT/round_${r}_boot_ubuntu_rootfs.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /var/log/kexec-runtime/ubuntu-runtime.log 2>/dev/null' > "$OUT/round_${r}_ubuntu_phase_a.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /var/log/kexec-runtime/adbd.log 2>/dev/null' > "$OUT/round_${r}_adbd_ubuntu.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /var/log/kexec-runtime/usb-adbd-sampler.log 2>/dev/null' > "$OUT/round_${r}_usb_adbd_sampler.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /var/log/kexec-runtime/wifi-bringup.log 2>/dev/null' > "$OUT/round_${r}_wifi_bringup.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /var/lib/kexec-runtime/wifi-status 2>/dev/null' > "$OUT/round_${r}_wifi_load_progress.txt" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /var/log/kexec-runtime/dmesg-wifi-before.log 2>/dev/null' > "$OUT/round_${r}_dmesg_wifi_before.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /var/log/kexec-runtime/dmesg-wifi-after.log 2>/dev/null' > "$OUT/round_${r}_dmesg_wifi_after.log" 2>/dev/null
}

pull_pstore_from_stock() {
    local r="$1"
    for _ in $(seq 1 12); do
        $ADB shell "su -c 'cat /sys/fs/pstore/console-ramoops-0 2>/dev/null'" > "$OUT/round_${r}_console.txt" 2>/dev/null
        [ -s "$OUT/round_${r}_console.txt" ] && break
        sleep 1
    done
}

pstore_last_line() {
    local path="$1"
    grep -aoE '\[[ ]*[0-9]+\.[0-9]+\].*' "$path" 2>/dev/null | tail -1
}

wait_stock_ready() {
    $ADB wait-for-device >/dev/null 2>&1
    local i
    for i in $(seq 1 60); do
        [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && { sleep 3; return 0; }
        sleep 2
    done
    return 1
}

# rc: 0 ubuntu adb, 2 stock returned, 3 no jump, 1 neither in time.
wait_after_kexec() {
    local rebooting=0 stock_seen=0 i
    for i in $(seq 1 30); do
        ubuntu_up && return 0
        stock_up || { rebooting=1; break; }
        sleep 1
    done
    [ "$rebooting" = 0 ] && return 3
    for i in $(seq 1 140); do
        ubuntu_up && return 0
        if stock_up; then
            stock_seen=$((stock_seen+1))
            [ "$stock_seen" -ge "$STOCK_GRACE" ] && return 2
        else
            stock_seen=0
        fi
        sleep 1
    done
    return 1
}

wait_ubuntu_wifi_done() {
    local r="$1" status i
    [ "$UBUNTU_WIFI" = "1" ] || return 0
    [ "$UBUNTU_WIFI_WAIT_READY" = "1" ] || {
        say "round $r: not waiting for Ubuntu Wi-Fi bringup result (UBUNTU_WIFI_WAIT_READY=$UBUNTU_WIFI_WAIT_READY)"
        return 0
    }
    say "round $r: waiting for Ubuntu Wi-Fi bringup result (${UBUNTU_WIFI_WAIT}s max)"
    for i in $(seq 1 "$UBUNTU_WIFI_WAIT"); do
        if ! ubuntu_up; then
            if stock_up; then
                say "round $r: stock returned while waiting for Ubuntu Wi-Fi"
                return 2
            fi
            sleep 1
            continue
        fi
        status="$(timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /var/lib/kexec-runtime/wifi-status 2>/dev/null' 2>/dev/null | tr -d '\r\n')"
        case "$status" in
            READY|NO_WLAN_IFACE|WMTWIFI_MISSING)
                say "round $r: Wi-Fi bringup result: $status"
                return 0
                ;;
        esac
        sleep 1
    done
    if ! ubuntu_up && stock_up; then
        say "round $r: stock returned after Ubuntu Wi-Fi wait timeout"
        return 2
    fi
    status="$(timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /var/lib/kexec-runtime/wifi-status 2>/dev/null' 2>/dev/null | tr -d '\r\n')"
    say "round $r: Wi-Fi bringup did not finish before timeout; last status=${status:-<empty>}"
    return 1
}

print_ubuntu_logs() {
    local r="$1"
    echo "===== adb probe ====="
    cat "$OUT/round_${r}_adb_probe.txt" 2>/dev/null
    echo "===== kxsh.log ====="
    cat "$OUT/round_${r}_kxsh.log" 2>/dev/null
    echo "===== boot_ubuntu_rootfs.log ====="
    cat "$OUT/round_${r}_boot_ubuntu_rootfs.log" 2>/dev/null
    echo "===== ubuntu_phase_a.log ====="
    cat "$OUT/round_${r}_ubuntu_phase_a.log" 2>/dev/null
    echo "===== adbd_ubuntu.log ====="
    cat "$OUT/round_${r}_adbd_ubuntu.log" 2>/dev/null
    echo "===== usb_adbd_sampler.log ====="
    cat "$OUT/round_${r}_usb_adbd_sampler.log" 2>/dev/null
    echo "===== wifi_bringup.log ====="
    cat "$OUT/round_${r}_wifi_bringup.log" 2>/dev/null
    echo "===== wifi_load_progress.txt ====="
    cat "$OUT/round_${r}_wifi_load_progress.txt" 2>/dev/null
    echo "===== dmesg_wifi_after tail ====="
    grep -aEi 'conn_pwr|conninfra_pwr|connsys|conn_infra|pre_cal|WIFI_RAM|download|firmware|gen4m|wmt turn|func_ctrl|chip_ver|wlan0|p2p|wlanProbe|probe success|netif|patch.*dl|MBOX Error|drop unmatched|Unknown symbol' "$OUT/round_${r}_dmesg_wifi_after.log" 2>/dev/null | tail -120
    echo "===== pstore tail ====="
    grep -aoE '\[[ ]*[0-9]+\.[0-9]+\].*' "$OUT/round_${r}_console.txt" 2>/dev/null | tail -80
    echo "====================="
}

if [ -z "$STOCK_SERIAL" ]; then
    STOCK_SERIAL="$(detect_stock_serial)"
fi
say "initrd=$INITRD dtb=${DTB_DEV:-<live>} max=$MAX ubuntu=$UBUNTU_SERIAL stock=$STOCK_SERIAL panic=${PANIC_AFTER}s kexec_extra_cmdline=${KEXEC_EXTRA_CMDLINE:-<none>} wifi=${UBUNTU_WIFI} wifi_skip=${UBUNTU_WIFI_SKIP_MODULES:-<none>} wait_wifi_ready=${UBUNTU_WIFI_WAIT_READY} wifi_wait=${UBUNTU_WIFI_WAIT}s out=$OUT"

if ubuntu_up; then
    say "already on Ubuntu ADB; probing current root"
    if probe_ubuntu_root "$OUT/round_0_adb_probe.txt"; then
        say "*** UBUNTU ADB SHELL IS UP (serial $UBUNTU_SERIAL) ***"
        say "adb probe: $(tr '\n' ' ' < "$OUT/round_0_adb_probe.txt")"
        echo; echo "logs: $OUT"; exit 0
    fi
    say "Ubuntu serial is present, but Ubuntu rootfs was not validated"
fi

noexec=0
for r in $(seq 1 "$MAX"); do
    say "round $r: waiting for stock Android"
    wait_stock_ready || say "round $r: boot_completed not seen, continuing"
    if [ -z "$STOCK_SERIAL" ]; then
        STOCK_SERIAL="$(detect_stock_serial)"
        say "round $r: detected stock serial=${STOCK_SERIAL:-<empty>}"
    fi

    nonce="UBUNTU-r${r}-$(date +%s)-${RANDOM}"
    say "round $r: install and invoke the stock direct-root launcher (nonce=$nonce)"
    "$ADB" push "$ROOT/scripts/stock/reboot-to-ubuntu.sh" \
        /data/local/tmp/reboot-to-ubuntu.sh >/dev/null
    timeout "$KEXEC_TRIGGER_TIMEOUT" "$ADB" shell "su -c 'chmod 0755 /data/local/tmp/reboot-to-ubuntu.sh; echo $nonce > /dev/kmsg; INITRD=/data/local/tmp/$INITRD_DEV DTB=/data/local/tmp/$DTB_DEV PANIC_AFTER=$PANIC_AFTER UBUNTU_WIFI=$UBUNTU_WIFI UBUNTU_WIFI_SKIP_MODULES=\"$UBUNTU_WIFI_SKIP_MODULES\" KEXEC_EXTRA_CMDLINE=\"$KEXEC_EXTRA_CMDLINE\" /data/local/tmp/reboot-to-ubuntu.sh'" > "$OUT/round_${r}_kexec_trigger.log" 2>&1
    kexec_trigger_rc=$?
    say "round $r: kexec trigger adb command returned rc=$kexec_trigger_rc"

    wait_after_kexec; rc=$?

    if [ "$rc" = 0 ]; then
        say "round $r: Ubuntu ADB appeared; probing root"
        if probe_ubuntu_root "$OUT/round_${r}_adb_probe.txt"; then
            say "round $r: *** UBUNTU ADB SHELL IS UP (serial $UBUNTU_SERIAL) ***"
            say "round $r: adb probe: $(tr '\n' ' ' < "$OUT/round_${r}_adb_probe.txt")"
            wait_ubuntu_wifi_done "$r"; wifi_rc=$?
            if [ "$wifi_rc" = 2 ]; then
                pull_from_stock "$r"
                pull_pstore_from_stock "$r"
                print_ubuntu_logs "$r"
                say "round $r: stock returned while waiting for Wi-Fi -> $OUT (stopping)"
                echo; echo "logs: $OUT"; exit 0
            fi
            if ubuntu_up; then
                pull_from_ubuntu "$r"
            else
                pull_from_stock "$r"
                pull_pstore_from_stock "$r"
            fi
            echo; echo "logs: $OUT"; exit 0
        fi
        pull_from_ubuntu "$r"
        print_ubuntu_logs "$r"
        say "round $r: Ubuntu serial appeared but root probe failed -> $OUT (stopping)"
        exit 0
    fi

    if [ "$rc" = 3 ]; then
        noexec=$((noexec+1))
        say "round $r: kexec did not take; never left stock [$noexec/$NOEXEC_MAX]"
        [ "$noexec" -ge "$NOEXEC_MAX" ] && { say "giving up: kexec -l/-e not rebooting the device"; exit 4; }
        continue
    fi

    if [ "$rc" = 1 ]; then
        say "round $r: neither Ubuntu ADB nor stock in time; waiting for stock"
        $ADB wait-for-device >/dev/null 2>&1
        wait_stock_ready || say "round $r: stock returned but boot_completed not seen before log pull"
    fi

    say "round $r: collecting stock-readable Ubuntu logs"
    pull_from_stock "$r"
    pull_pstore_from_stock "$r"
    print_ubuntu_logs "$r"

    if [ -s "$OUT/round_${r}_boot_ubuntu_rootfs.log" ] &&
       grep -qa 'begin direct rootfs' "$OUT/round_${r}_boot_ubuntu_rootfs.log"; then
        say "round $r: reached direct-root handoff, but Ubuntu ADB did not validate -> $OUT (stopping)"
        exit 0
    fi

    last_pstore="$(pstore_last_line "$OUT/round_${r}_console.txt")"
    if printf '%s\n' "$last_pstore" | grep -qa 'mtk_scpsys_mt6895'; then
        say "round $r: early mtk_scpsys_mt6895 death before direct-root handoff; retrying. last=${last_pstore:-<empty>}"
    else
        say "round $r: non-scpsys failure before direct-root handoff or Ubuntu did not validate -> $OUT (stopping). last=${last_pstore:-<empty>}"
        echo "===== pstore tail ====="
        grep -aoE '\[[ ]*[0-9]+\.[0-9]+\].*' "$OUT/round_${r}_console.txt" 2>/dev/null | tail -120
        echo "======================="
        exit 0
    fi
    grep -aoE '\[[ ]*[0-9]+\.[0-9]+\].*' "$OUT/round_${r}_console.txt" 2>/dev/null | tail -3 | sed 's/^/    /'
done

say "exhausted $MAX rounds without Ubuntu ADB"
exit 1
