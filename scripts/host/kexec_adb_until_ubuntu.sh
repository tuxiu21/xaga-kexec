#!/usr/bin/env bash
# Boot/capture loop for Ubuntu ext4. In this mode lean kxsh skips lean adbd,
# switches root, and the only expected ADB enumeration is Ubuntu adbd.
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

INITRD="${1:-$OUTPUT_DIR/combined_ramdisk_kexec_system_mbox.lz4}"
INITRD_DEV="$(basename "$INITRD")"
DTB_DEV="${DTB_DEV:-patched.dtb}"
MAX="${2:-8}"
UBUNTU_SERIAL="${UBUNTU_SERIAL:-ubuntu012345678}"
LEAN_SERIAL="${LEAN_SERIAL:-0123456789abcdef}"
PANIC_AFTER="${PANIC_AFTER:-180}"
UBUNTU_WIFI="${UBUNTU_WIFI:-1}"
UBUNTU_WIFI_WAIT="${UBUNTU_WIFI_WAIT:-260}"
NOEXEC_MAX="${NOEXEC_MAX:-3}"
ADB_TIMEOUT="${ADB_TIMEOUT:-8s}"
STOCK_GRACE="${STOCK_GRACE:-10}"
OUT="$LOG_ROOT/kexec_adb_until_ubuntu_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

STOCK_SERIAL=""

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/log.txt"; }

adb_devices() { timeout "$ADB_TIMEOUT" "$ADB" devices 2>/dev/null | tr -d '\r'; }
serial_state() { adb_devices | awk -v s="$1" '$1==s{print $2}'; }
ubuntu_up() { [ "$(serial_state "$UBUNTU_SERIAL")" = "device" ]; }
stock_up() { [ -n "$STOCK_SERIAL" ] && [ "$(serial_state "$STOCK_SERIAL")" = "device" ]; }

probe_ubuntu_root() {
    local out="$1"
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" wait-for-device >/dev/null 2>&1 || return 1
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'echo adb-probe; cat /proc/1/comm 2>/dev/null; findmnt / 2>/dev/null || mount | grep " on / "; cat /etc/os-release 2>/dev/null || true; ps -ef | grep -E "adbd|watchdog_feeder|phase_a" | grep -v grep || true' > "$out.tmp" 2>&1 || return 1
    tr -d '\r' < "$out.tmp" > "$out"
    rm -f "$out.tmp"
    grep -qa '/dev/loop0.*ext4' "$out"
}

pull_from_stock() {
    local r="$1"
    $ADB shell "su -c 'cat /data/kexec/kxsh.log 2>/dev/null'" > "$OUT/round_${r}_kxsh.log" 2>/dev/null
    $ADB shell "su -c 'cat /data/kexec/boot_ubuntu_ext4.log 2>/dev/null'" > "$OUT/round_${r}_boot_ubuntu_ext4.log" 2>/dev/null
    $ADB shell "su -c 'cat /data/kexec/ubuntu_phase_a.log 2>/dev/null'" > "$OUT/round_${r}_ubuntu_phase_a.log" 2>/dev/null
    $ADB shell "su -c 'cat /data/kexec/adbd_ubuntu.log 2>/dev/null'" > "$OUT/round_${r}_adbd_ubuntu.log" 2>/dev/null
    $ADB shell "su -c 'cat /data/kexec/wifi_bringup.log 2>/dev/null'" > "$OUT/round_${r}_wifi_bringup.log" 2>/dev/null
    $ADB shell "su -c 'cat /data/kexec/wifi_load_progress.txt 2>/dev/null'" > "$OUT/round_${r}_wifi_load_progress.txt" 2>/dev/null
    $ADB shell "su -c 'cat /data/kexec/dmesg_wifi_before.log 2>/dev/null'" > "$OUT/round_${r}_dmesg_wifi_before.log" 2>/dev/null
    $ADB shell "su -c 'cat /data/kexec/dmesg_wifi_after.log 2>/dev/null'" > "$OUT/round_${r}_dmesg_wifi_after.log" 2>/dev/null
}

pull_from_ubuntu() {
    local r="$1"
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /data/kexec/kxsh.log 2>/dev/null' > "$OUT/round_${r}_kxsh.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /data/kexec/boot_ubuntu_ext4.log 2>/dev/null' > "$OUT/round_${r}_boot_ubuntu_ext4.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /data/kexec/ubuntu_phase_a.log 2>/dev/null' > "$OUT/round_${r}_ubuntu_phase_a.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /data/kexec/adbd_ubuntu.log 2>/dev/null' > "$OUT/round_${r}_adbd_ubuntu.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /data/kexec/wifi_bringup.log 2>/dev/null' > "$OUT/round_${r}_wifi_bringup.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /data/kexec/wifi_load_progress.txt 2>/dev/null' > "$OUT/round_${r}_wifi_load_progress.txt" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /data/kexec/dmesg_wifi_before.log 2>/dev/null' > "$OUT/round_${r}_dmesg_wifi_before.log" 2>/dev/null
    timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /data/kexec/dmesg_wifi_after.log 2>/dev/null' > "$OUT/round_${r}_dmesg_wifi_after.log" 2>/dev/null
}

pull_pstore_from_stock() {
    local r="$1"
    for _ in $(seq 1 12); do
        $ADB shell "su -c 'cat /sys/fs/pstore/console-ramoops-0 2>/dev/null'" > "$OUT/round_${r}_console.txt" 2>/dev/null
        [ -s "$OUT/round_${r}_console.txt" ] && break
        sleep 1
    done
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
        status="$(timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /data/kexec/wifi_load_progress.txt 2>/dev/null' 2>/dev/null | tr -d '\r\n')"
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
    status="$(timeout "$ADB_TIMEOUT" "$ADB" -s "$UBUNTU_SERIAL" shell 'cat /data/kexec/wifi_load_progress.txt 2>/dev/null' 2>/dev/null | tr -d '\r\n')"
    say "round $r: Wi-Fi bringup did not finish before timeout; last status=${status:-<empty>}"
    return 1
}

build_cmdline() {
    local base_cmdline initrd_local initrd_kib bootconfig_args normal_args
    base_cmdline="$($ADB shell "su -c 'cat /proc/cmdline'" 2>/dev/null | tr -d '\r\n')"
    initrd_local="$INITRD"
    case "$initrd_local" in /*) ;; *) initrd_local="$ROOT/$INITRD";; esac
    if [ -f "$initrd_local" ]; then
        initrd_kib="$(( ($(wc -c < "$initrd_local") + 1023) / 1024 ))"
        base_cmdline="$(printf '%s\n' "$base_cmdline" | sed -E "s/(^| )debug_ext\\.initrd_size=[^ ]*/ /g")"
        base_cmdline="$base_cmdline debug_ext.initrd_size=$initrd_kib"
    fi
    bootconfig_args="$($ADB shell "su -c 'cat /proc/bootconfig 2>/dev/null'" | tr -d '\r' | awk '
      /^androidboot[.]/ { key=$1; sub(/^[^=]*=[[:space:]]*/, ""); gsub(/["[:space:]]/, ""); print key "=" $0 }' | tr '\n' ' ')"
    normal_args="$bootconfig_args androidboot.force_normal_boot=1 androidboot.mode=normal androidboot.bootmode=normal androidboot.slot_suffix=_a androidboot.hardware=mt6895 androidboot.init_fatal_panic=true androidboot.init_fatal_reboot_target=bootloader loglevel=7 ignore_loglevel printk.devkmsg=on"
    printf '%s\n' "$base_cmdline $normal_args"
}

print_ubuntu_logs() {
    local r="$1"
    echo "===== adb probe ====="
    cat "$OUT/round_${r}_adb_probe.txt" 2>/dev/null
    echo "===== kxsh.log ====="
    cat "$OUT/round_${r}_kxsh.log" 2>/dev/null
    echo "===== boot_ubuntu_ext4.log ====="
    cat "$OUT/round_${r}_boot_ubuntu_ext4.log" 2>/dev/null
    echo "===== ubuntu_phase_a.log ====="
    cat "$OUT/round_${r}_ubuntu_phase_a.log" 2>/dev/null
    echo "===== adbd_ubuntu.log ====="
    cat "$OUT/round_${r}_adbd_ubuntu.log" 2>/dev/null
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

STOCK_SERIAL="$(adb_devices | awk -v u="$UBUNTU_SERIAL" -v l="$LEAN_SERIAL" 'NR>1 && $2=="device" && $1!=u && $1!=l {print $1; exit}')"
say "initrd=$INITRD dtb=${DTB_DEV:-<live>} max=$MAX ubuntu=$UBUNTU_SERIAL stock=$STOCK_SERIAL panic=${PANIC_AFTER}s wifi=${UBUNTU_WIFI} wifi_wait=${UBUNTU_WIFI_WAIT}s out=$OUT"

if ubuntu_up; then
    say "already on Ubuntu ADB; probing current root"
    if probe_ubuntu_root "$OUT/round_0_adb_probe.txt"; then
        say "*** UBUNTU ADB SHELL IS UP (serial $UBUNTU_SERIAL) ***"
        say "adb probe: $(tr '\n' ' ' < "$OUT/round_0_adb_probe.txt")"
        echo; echo "logs: $OUT"; exit 0
    fi
    say "Ubuntu serial is present, but /dev/loop0 ext4 was not validated"
fi

noexec=0
for r in $(seq 1 "$MAX"); do
    say "round $r: waiting for stock Android"
    wait_stock_ready || say "round $r: boot_completed not seen, continuing"

    say "round $r: clearing pstore + Ubuntu logs, panic_after=${PANIC_AFTER}s wifi=${UBUNTU_WIFI}"
    $ADB shell "su -c 'mkdir -p /data/kexec/run; rm -f /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/dmesg-ramoops-*; : > /data/kexec/kxsh.log; : > /data/kexec/adbd.log; : > /data/kexec/boot_ubuntu_ext4.log; : > /data/kexec/ubuntu_phase_a.log; : > /data/kexec/adbd_ubuntu.log; : > /data/kexec/wifi_bringup.log; : > /data/kexec/wifi_load_progress.txt; : > /data/kexec/dmesg_wifi_before.log; : > /data/kexec/dmesg_wifi_after.log; rm -f /data/kexec/run/adbd.ubuntu.pid /data/kexec/run/panic_timer.ubuntu.pid /data/kexec/run/wifi_bringup.ubuntu.pid; echo $PANIC_AFTER > /data/kexec/panic_after; echo $UBUNTU_WIFI > /data/kexec/ubuntu_wifi; touch /data/kexec/boot_ubuntu_ext4.once; sync'" >/dev/null 2>&1

    cmdline="$(build_cmdline)"
    printf '%s\n' "$cmdline" > "$OUT/round_${r}_cmdline.txt"

    nonce="UBUNTU-r${r}-$(date +%s)-${RANDOM}"
    say "round $r: kexec into Ubuntu ext4 path (nonce=$nonce)"
    $ADB shell "su -c 'cd /data/local/tmp && echo 0 > /proc/sys/kernel/kptr_restrict && ./kexec -c -l kernel --initrd=$INITRD_DEV ${DTB_DEV:+--dtb=$DTB_DEV} --append=\"$cmdline\" && sync && echo $nonce > /dev/kmsg && echo 1 > /dev/watchdog 2>/dev/null && echo 1 > /dev/watchdog0 2>/dev/null; ./kexec -f -e'" >/dev/null 2>&1

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
    fi

    say "round $r: collecting stock-readable Ubuntu logs"
    pull_from_stock "$r"
    pull_pstore_from_stock "$r"
    print_ubuntu_logs "$r"

    if [ -s "$OUT/round_${r}_kxsh.log" ] && grep -qa 'boot_ubuntu_ext4 flag present; switching root before lean adb' "$OUT/round_${r}_kxsh.log"; then
        say "round $r: reached kxsh Ubuntu handoff path, but Ubuntu ADB did not validate -> $OUT (stopping)"
        exit 0
    fi

    say "round $r: Ubuntu path did not validate; retrying. pstore tail:"
    grep -aoE '\[[ ]*[0-9]+\.[0-9]+\].*' "$OUT/round_${r}_console.txt" 2>/dev/null | tail -3 | sed 's/^/    /'
done

say "exhausted $MAX rounds without Ubuntu ADB"
exit 1
