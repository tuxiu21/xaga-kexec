#!/usr/bin/env bash
# Boot/capture loop for the adb-over-USB lean system.
#
# Boot/capture loop for the lean ADB system. The success signal is the LEAN adbd
# enumerating over USB -- the host adb server sees serial 0123456789abcdef.
# Every round also pulls /data/kexec/kxsh.log and adbd.log: those live on the
# shared /data f2fs, so stock Android can read what the lean boot wrote.
#
# Outcomes:
#   - lean adb up                 -> success (exit 0)
#   - reached kxsh, no ep1/ep2     -> the enumeration bug; dump diagnosis, stop
#   - early death before kxsh      -> retry (kxsh.log stays empty; pstore tail)
set -u

ADB=adb.exe
INITRD="${1:-output/combined_ramdisk_kexec_system.lz4}"
INITRD_DEV="$(basename "$INITRD")"
# Patched DTB with regulator-always-on (avoids the ~31.7s regulator-cleanup
# death). Set DTB_DEV= (empty) to reuse the device's live FDT instead.
DTB_DEV="${DTB_DEV:-patched.dtb}"
MAX="${2:-8}"
LEAN_SERIAL="${LEAN_SERIAL:-0123456789abcdef}"
PANIC_AFTER="${PANIC_AFTER:-60}"
NOEXEC_MAX="${NOEXEC_MAX:-3}"
OUT="/home/in/work/kernels/logs/kexec_adb_until_new_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

STOCK_SERIAL=""

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/log.txt"; }

serial_state() { $ADB devices 2>/dev/null | tr -d '\r' | awk -v s="$1" '$1==s{print $2}'; }
lean_up()  { [ "$(serial_state "$LEAN_SERIAL")" = "device" ]; }
stock_up() { [ -n "$STOCK_SERIAL" ] && [ "$(serial_state "$STOCK_SERIAL")" = "device" ]; }

wait_stock_ready() {
    $ADB wait-for-device >/dev/null 2>&1
    local i
    for i in $(seq 1 60); do
        [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && { sleep 3; return 0; }
        sleep 2
    done
    return 1
}

# Phase 1: confirm the jump happened (stock drops). Phase 2: lean adb comes up
# (success) or stock returns (failure -> inspect). rc: 0 lean, 2 stock, 3 no-jump,
# 1 neither-in-time (lean likely hung without panic).
wait_after_kexec() {
    local rebooting=0 i
    for i in $(seq 1 30); do
        lean_up && return 0
        stock_up || { rebooting=1; break; }
        sleep 1
    done
    [ "$rebooting" = 0 ] && return 3
    for i in $(seq 1 100); do
        lean_up && return 0
        stock_up && { sleep 2; return 2; }
        sleep 1
    done
    return 1
}

pull_lean_logs() {  # /data is shared with stock, so these survive the fall-back
    local r="$1"
    $ADB shell "su -c 'cat /data/kexec/kxsh.log 2>/dev/null'" > "$OUT/round_${r}_kxsh.log" 2>/dev/null
    $ADB shell "su -c 'cat /data/kexec/adbd.log 2>/dev/null'" > "$OUT/round_${r}_adbd.log" 2>/dev/null
}

STOCK_SERIAL="$($ADB devices | tr -d '\r' | awk 'NR>1 && $2=="device"{print $1; exit}')"
say "initrd=$INITRD dtb=${DTB_DEV:-<live>} max=$MAX lean=$LEAN_SERIAL stock=$STOCK_SERIAL panic=${PANIC_AFTER}s out=$OUT"

noexec=0
for r in $(seq 1 "$MAX"); do
    say "round $r: waiting for stock Android"
    wait_stock_ready || say "round $r: boot_completed not seen, continuing"

    say "round $r: clearing pstore + lean logs, panic_after=${PANIC_AFTER}s"
    $ADB shell "su -c 'rm -f /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/dmesg-ramoops-*; : > /data/kexec/kxsh.log; : > /data/kexec/adbd.log; echo $PANIC_AFTER > /data/kexec/panic_after'" >/dev/null 2>&1

    base_cmdline="$($ADB shell "su -c 'cat /proc/cmdline'" 2>/dev/null | tr -d '\r\n')"
    initrd_local="$INITRD"; case "$initrd_local" in /*) ;; *) initrd_local="/home/in/work/kernels/$INITRD";; esac
    if [ -f "$initrd_local" ]; then
        initrd_kib="$(( ($(wc -c < "$initrd_local") + 1023) / 1024 ))"
        base_cmdline="$(printf '%s\n' "$base_cmdline" | sed -E "s/(^| )debug_ext\\.initrd_size=[^ ]*/ /g")"
        base_cmdline="$base_cmdline debug_ext.initrd_size=$initrd_kib"
    fi
    bootconfig_args="$($ADB shell "su -c 'cat /proc/bootconfig 2>/dev/null'" | tr -d '\r' | awk '
      /^androidboot[.]/ { key=$1; sub(/^[^=]*=[[:space:]]*/, ""); gsub(/["[:space:]]/, ""); print key "=" $0 }' | tr '\n' ' ')"
    normal_args="$bootconfig_args androidboot.force_normal_boot=1 androidboot.mode=normal androidboot.bootmode=normal androidboot.slot_suffix=_a androidboot.hardware=mt6895 androidboot.init_fatal_panic=true androidboot.init_fatal_reboot_target=bootloader loglevel=7 ignore_loglevel printk.devkmsg=on"
    cmdline="$base_cmdline $normal_args"
    printf '%s\n' "$cmdline" > "$OUT/round_${r}_cmdline.txt"

    nonce="ADBTEST-r${r}-$(date +%s)-${RANDOM}"
    say "round $r: kexec into lean adb (nonce=$nonce)"
    # Kick the AP watchdog to a full budget right before the jump (MTK HW WDT
    # keeps counting across kexec; without this the new kernel often resets
    # before reaching kxsh's own feeder). Stamp the nonce into kmsg for pstore.
    $ADB shell "su -c 'cd /data/local/tmp && echo 0 > /proc/sys/kernel/kptr_restrict && ./kexec -c -l kernel --initrd=$INITRD_DEV ${DTB_DEV:+--dtb=$DTB_DEV} --append=\"$cmdline\" && sync && echo $nonce > /dev/kmsg && echo 1 > /dev/watchdog 2>/dev/null && echo 1 > /dev/watchdog0 2>/dev/null; ./kexec -f -e'" >/dev/null 2>&1

    wait_after_kexec; rc=$?

    if [ "$rc" = 0 ]; then
        say "round $r: *** LEAN ADB IS UP (serial $LEAN_SERIAL) ***"
        probe="$($ADB -s "$LEAN_SERIAL" shell 'echo lean-adb-ok; id; uname -a' 2>&1 | tr -d '\r' | tr '\n' ' ')"
        say "round $r: lean shell probe: $probe"
        pull_lean_logs "$r"
        echo; echo "logs: $OUT"; exit 0
    fi

    if [ "$rc" = 3 ]; then
        noexec=$((noexec+1))
        say "round $r: kexec did not take; never left stock [$noexec/$NOEXEC_MAX]"
        [ "$noexec" -ge "$NOEXEC_MAX" ] && { say "giving up: kexec -l/-e not rebooting the device"; exit 4; }
        continue
    fi

    if [ "$rc" = 1 ]; then
        say "round $r: neither lean adb nor stock in time (lean may be hung w/o panic); waiting for stock"
        $ADB wait-for-device >/dev/null 2>&1
    fi

    # Back on stock (rc==2 or after wait). Pull what the lean boot wrote.
    pull_lean_logs "$r"
    for _ in $(seq 1 12); do
        $ADB shell "su -c 'cat /sys/fs/pstore/console-ramoops-0 2>/dev/null'" > "$OUT/round_${r}_console.txt" 2>/dev/null
        [ -s "$OUT/round_${r}_console.txt" ] && break
        sleep 1
    done

    if [ -s "$OUT/round_${r}_kxsh.log" ] && grep -qa 'kexec-system-init' "$OUT/round_${r}_kxsh.log"; then
        say "round $r: reached kxsh -- adbd enumeration verdict:"
        if grep -qa 'adbd published FunctionFS endpoints' "$OUT/round_${r}_kxsh.log"; then
            say "round $r: adbd PUBLISHED ep1/ep2, but host never saw $LEAN_SERIAL -> UDC bind / host transport issue"
        elif grep -qa 'did not publish FunctionFS endpoints' "$OUT/round_${r}_kxsh.log"; then
            say "round $r: adbd did NOT publish ep1/ep2 -> the enumeration bug"
        else
            say "round $r: reached kxsh but USB phase incomplete (see logs)"
        fi
        echo "===== kxsh.log: USB/adbd section ====="
        grep -aE 'setup_usb_adb|UDC|FunctionFS|ep[0-9]|adbd|gadget|SELinux|usb|published' "$OUT/round_${r}_kxsh.log"
        echo "===== adbd.log ====="
        cat "$OUT/round_${r}_adbd.log" 2>/dev/null
        echo "======================================"
        say "round $r: reached-kxsh diagnosis captured -> $OUT (stopping)"
        exit 0
    fi

    say "round $r: early death before kxsh (kxsh.log empty); retrying. pstore tail:"
    grep -aoE '\[[ ]*[0-9]+\.[0-9]+\].*' "$OUT/round_${r}_console.txt" 2>/dev/null | tail -3 | sed 's/^/    /'
done

say "exhausted $MAX rounds without lean adb or a kxsh diagnosis"
exit 1
