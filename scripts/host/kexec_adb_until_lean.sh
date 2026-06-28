#!/usr/bin/env bash
# Boot/capture loop for the lean ADB system. Success means the lean adbd
# enumerates over USB and the host sees LEAN_SERIAL.
set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

INITRD="${1:-$OUTPUT_DIR/combined_ramdisk_kexec_system_mbox.lz4}"
INITRD_DEV="$(basename "$INITRD")"
DTB_DEV="${DTB_DEV:-patched.dtb}"
MAX="${2:-8}"
LEAN_SERIAL="${LEAN_SERIAL:-0123456789abcdef}"
PANIC_AFTER="${PANIC_AFTER:-60}"
NOEXEC_MAX="${NOEXEC_MAX:-3}"
LINUX_DEV="${LINUX_DEV:-/dev/block/by-name/linux}"
LINUX_MOUNT="${LINUX_MOUNT:-/mnt/linux_kexec}"
LINUX_RUNTIME="${LINUX_RUNTIME:-$LINUX_MOUNT}"
OUT="$LOG_ROOT/kexec_adb_until_lean_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

STOCK_SERIAL="${STOCK_SERIAL:-}"

say() { printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/log.txt"; }

adb_root_shell()
{
    local script="$1"
    if [ "$($ADB shell 'id -u 2>/dev/null' | tr -d '\r')" = "0" ]; then
        $ADB shell "$script"
    else
        $ADB shell "su -c '$script'"
    fi
}

serial_state() { $ADB devices 2>/dev/null | tr -d '\r' | awk -v s="$1" '$1==s{print $2}'; }
lean_up() { [ "$(serial_state "$LEAN_SERIAL")" = "device" ]; }
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

# rc: 0 lean, 2 stock returned, 3 no jump, 1 neither in time.
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

pull_lean_logs() {
    local r="$1"
    adb_root_shell "mkdir -p $LINUX_MOUNT; mount | grep -q \" $LINUX_MOUNT \" || mount -t ext4 -o rw,noatime $LINUX_DEV $LINUX_MOUNT 2>/dev/null || mount -t ext4 -o rw,noatime /dev/block/sdc88 $LINUX_MOUNT 2>/dev/null; cat $LINUX_RUNTIME/kxsh.log 2>/dev/null" > "$OUT/round_${r}_linux_kxsh.log" 2>/dev/null
    adb_root_shell "cat $LINUX_RUNTIME/adbd.log 2>/dev/null" > "$OUT/round_${r}_linux_adbd.log" 2>/dev/null
}

pull_pstore() {
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

build_cmdline() {
    local base_cmdline initrd_local initrd_kib bootconfig_args normal_args
    base_cmdline=""
    for _ in $(seq 1 5); do
        base_cmdline="$($ADB shell "su -c 'cat /proc/cmdline'" 2>/dev/null | tr -d '\r\n')"
        [ -n "$base_cmdline" ] && break
        sleep 1
    done
    if [ -z "$base_cmdline" ]; then
        say "failed to read non-empty /proc/cmdline"
        return 1
    fi
    initrd_local="$INITRD"
    case "$initrd_local" in /*) ;; *) initrd_local="$ROOT/$INITRD";; esac
    if [ -f "$initrd_local" ]; then
        initrd_kib="$(( ($(wc -c < "$initrd_local") + 1023) / 1024 ))"
        base_cmdline="$(printf '%s\n' "$base_cmdline" | sed -E "s/(^| )debug_ext\\.initrd_size=[^ ]*/ /g")"
        base_cmdline="$(printf '%s\n' "$base_cmdline" | sed -E "s/(^| )firmware_class\\.path=[^ ]*/ /g")"
        base_cmdline="$base_cmdline debug_ext.initrd_size=$initrd_kib"
    fi
    bootconfig_args="$($ADB shell "su -c 'cat /proc/bootconfig 2>/dev/null'" | tr -d '\r' | awk '
      /^androidboot[.]/ { key=$1; sub(/^[^=]*=[[:space:]]*/, ""); gsub(/["[:space:]]/, ""); print key "=" $0 }' | tr '\n' ' ')"
    normal_args="$bootconfig_args androidboot.force_normal_boot=1 androidboot.mode=normal androidboot.bootmode=normal androidboot.slot_suffix=_a androidboot.hardware=mt6895 androidboot.init_fatal_panic=true androidboot.init_fatal_reboot_target=bootloader firmware_class.path=/kexec/firmware loglevel=7 ignore_loglevel printk.devkmsg=on"
    printf '%s\n' "$base_cmdline $normal_args"
}

if [ -z "$STOCK_SERIAL" ]; then
    for _ in $(seq 1 10); do
        STOCK_SERIAL="$($ADB devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && $2=="device"{print $1; exit}')"
        [ -n "$STOCK_SERIAL" ] && break
        sleep 1
    done
fi
[ -n "$STOCK_SERIAL" ] || { say "failed to detect stock adb serial"; exit 5; }
say "initrd=$INITRD dtb=${DTB_DEV:-<live>} max=$MAX lean=$LEAN_SERIAL stock=$STOCK_SERIAL panic=${PANIC_AFTER}s out=$OUT"

noexec=0
for r in $(seq 1 "$MAX"); do
    say "round $r: waiting for stock Android"
    wait_stock_ready || say "round $r: boot_completed not seen, continuing"

    say "round $r: clearing pstore + lean logs, panic_after=${PANIC_AFTER}s"
    adb_root_shell "mkdir -p $LINUX_MOUNT; mount | grep -q \" $LINUX_MOUNT \" || mount -t ext4 -o rw,noatime $LINUX_DEV $LINUX_MOUNT 2>/dev/null || mount -t ext4 -o rw,noatime /dev/block/sdc88 $LINUX_MOUNT 2>/dev/null; rm -f /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/dmesg-ramoops-*; : > $LINUX_RUNTIME/kxsh.log; : > $LINUX_RUNTIME/adbd.log; rm -f $LINUX_RUNTIME/boot_ubuntu_ext4.once; echo $PANIC_AFTER > $LINUX_RUNTIME/panic_after" >/dev/null 2>&1

    cmdline="$(build_cmdline)" || exit 5
    printf '%s\n' "$cmdline" > "$OUT/round_${r}_cmdline.txt"

    nonce="ADBTEST-r${r}-$(date +%s)-${RANDOM}"
    say "round $r: kexec into lean adb (nonce=$nonce)"
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
        say "round $r: neither lean adb nor stock in time; waiting for stock"
        $ADB wait-for-device >/dev/null 2>&1
        wait_stock_ready || say "round $r: stock returned but boot_completed not seen before log pull"
    fi

    pull_lean_logs "$r"
    pull_pstore "$r"

    if [ -s "$OUT/round_${r}_linux_kxsh.log" ] && grep -qa 'kexec-system-init' "$OUT/round_${r}_linux_kxsh.log"; then
        say "round $r: reached linux runtime kxsh -- adbd enumeration verdict:"
        if grep -qa 'adbd published FunctionFS endpoints' "$OUT/round_${r}_linux_kxsh.log"; then
            say "round $r: adbd PUBLISHED ep1/ep2, but host never saw $LEAN_SERIAL -> UDC bind / host transport issue"
        elif grep -qa 'did not publish FunctionFS endpoints' "$OUT/round_${r}_linux_kxsh.log"; then
            say "round $r: adbd did NOT publish ep1/ep2 -> the enumeration bug"
        else
            say "round $r: reached linux kxsh but USB phase incomplete"
        fi
        echo "===== linux kxsh.log: USB/adbd section ====="
        grep -aE 'entered|setup_usb_adb|UDC|FunctionFS|ep[0-9]|adbd|gadget|SELinux|usb|published' "$OUT/round_${r}_linux_kxsh.log"
        echo "===== linux adbd.log ====="
        cat "$OUT/round_${r}_linux_adbd.log" 2>/dev/null
        echo "============================================"
        say "round $r: reached-linux-kxsh diagnosis captured -> $OUT (stopping)"
        exit 0
    fi

    last_pstore="$(pstore_last_line "$OUT/round_${r}_console.txt")"
    if printf '%s\n' "$last_pstore" | grep -qa 'mtk_scpsys_mt6895'; then
        say "round $r: early mtk_scpsys_mt6895 death before kxsh; retrying. last=${last_pstore:-<empty>}"
    else
        say "round $r: non-scpsys failure before kxsh -> $OUT (stopping). last=${last_pstore:-<empty>}"
        echo "===== pstore tail ====="
        grep -aoE '\[[ ]*[0-9]+\.[0-9]+\].*' "$OUT/round_${r}_console.txt" 2>/dev/null | tail -120
        echo "======================="
        exit 0
    fi
    grep -aoE '\[[ ]*[0-9]+\.[0-9]+\].*' "$OUT/round_${r}_console.txt" 2>/dev/null | tail -3 | sed 's/^/    /'
done

say "exhausted $MAX rounds without lean adb or a kxsh diagnosis"
exit 1
