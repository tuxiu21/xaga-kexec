#!/usr/bin/env bash
# Loop kexec into the dropbear rescue ramdisk.
# Stop when SSH becomes reachable, or when a non-stale pstore log is captured.
set -u

ADB=adb.exe
INITRD="${1:-combined_ramdisk_kexec_dropbear.lz4}"
MAX="${2:-20}"
SSH_HOST="${3:-192.168.66.2}"
SSH_PORT="${4:-22}"
OUT="/home/in/work/kernels/logs/kexec_dropbear_until_new_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

say()
{
    printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/log.txt"
}

adb_online()
{
    [ "$($ADB get-state 2>/dev/null | tr -d '\r')" = "device" ]
}

wait_android_ready()
{
    $ADB wait-for-device >/dev/null 2>&1
    for _ in $(seq 1 60); do
        [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && {
            sleep 3
            return 0
        }
        sleep 2
    done
    return 1
}

ssh_port_open()
{
    # TCP connect alone is not enough on WSL/Windows USB networking; require
    # a real SSH server banner to avoid false positives from the host route.
    if command -v timeout >/dev/null 2>&1; then
        timeout 3 bash -c "exec 3<>/dev/tcp/$SSH_HOST/$SSH_PORT; IFS= read -r -t 2 line <&3; [[ \"\$line\" == SSH-* ]]" >/dev/null 2>&1
        return $?
    fi

    if command -v nc >/dev/null 2>&1; then
        banner="$(printf '' | nc -w 2 "$SSH_HOST" "$SSH_PORT" 2>/dev/null | head -n 1)"
        case "$banner" in
            SSH-*) return 0 ;;
            *) return 1 ;;
        esac
    fi

    return 1
}

wait_after_kexec()
{
    # Success path for rescue mode: Android/adbd will not come back, SSH should.
    # Failure path: device reboots back to Android, then pstore can be inspected.
    for _ in $(seq 1 120); do
        if ssh_port_open; then
            return 0
        fi

        if adb_online; then
            sleep 3
            return 2
        fi

        sleep 1
    done

    return 1
}

say "initrd=$INITRD max=$MAX ssh=$SSH_HOST:$SSH_PORT out=$OUT"

for r in $(seq 1 "$MAX"); do
    say "round $r: waiting for Android"
    wait_android_ready || say "round $r: Android did not report boot_completed, continuing anyway"

    say "round $r: clearing old pstore"
    $ADB shell "su -c 'rm -f /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/dmesg-ramoops-*'" >/dev/null 2>&1

    base_cmdline="$($ADB shell "su -c 'cat /proc/cmdline'" 2>/dev/null | tr -d '\r\n')"
    initrd_local="$INITRD"
    case "$initrd_local" in
        /*) ;;
        *) initrd_local="/home/in/work/kernels/$INITRD" ;;
    esac
    if [ -f "$initrd_local" ]; then
        initrd_kib="$(( ($(wc -c < "$initrd_local") + 1023) / 1024 ))"
        base_cmdline="$(printf '%s\n' "$base_cmdline" | sed -E "s/(^| )debug_ext\\.initrd_size=[^ ]*/ /g")"
        base_cmdline="$base_cmdline debug_ext.initrd_size=$initrd_kib"
    fi
    bootconfig_args="$($ADB shell "su -c 'cat /proc/bootconfig 2>/dev/null'" | tr -d '\r' | awk '
      /^androidboot[.]/ {
        key=$1
        sub(/^[^=]*=[[:space:]]*/, "")
        gsub(/["[:space:]]/, "")
        print key "=" $0
      }' | tr '\n' ' ')"
    normal_args="$bootconfig_args androidboot.force_normal_boot=1 androidboot.mode=normal androidboot.bootmode=normal androidboot.slot_suffix=_a androidboot.hardware=mt6895 androidboot.init_fatal_panic=true androidboot.init_fatal_reboot_target=bootloader loglevel=7 ignore_loglevel printk.devkmsg=on"
    cmdline="$base_cmdline $normal_args"
    printf '%s\n' "$cmdline" > "$OUT/round_${r}_cmdline.txt"

    say "round $r: kexec into dropbear rescue"
    $ADB shell "su -c 'cd /data/local/tmp && echo 0 > /proc/sys/kernel/kptr_restrict && ./kexec -c -l kernel --initrd=$INITRD --append=\"$cmdline\" && sync && ./kexec -f -e'" >/dev/null 2>&1

    wait_after_kexec
    rc=$?

    if [ "$rc" = "0" ]; then
        say "round $r: SSH is reachable at $SSH_HOST:$SSH_PORT"
        echo
        echo "Try:"
        echo "  ssh -o StrictHostKeyChecking=no root@$SSH_HOST"
        echo "logs dir: $OUT"
        exit 0
    fi

    if [ "$rc" = "1" ]; then
        say "round $r: no SSH and Android did not return within timeout"
        say "round $r: this may mean rescue is alive but USB/RNDIS did not enumerate"
        exit 2
    fi

    f="$OUT/round_${r}_console.txt"
    $ADB shell "su -c 'cat /sys/fs/pstore/console-ramoops-0 2>&1'" > "$f" 2>&1

    if grep -q 'Bye!' "$f"; then
        say "round $r: stale Bye log, retrying"
        continue
    fi

    if ! grep -qaE 'Switching root|kexec-|execv|Kernel panic|Internal error|kernel BUG|poffreason=AP_WDT|poffreason=Watchdog' "$f"; then
        say "round $r: short/incomplete pstore, retrying"
        continue
    fi

    say "round $r: non-stale pstore captured -> $f"
    echo
    echo "================= key lines ================="
    grep -a -nE 'Booting Linux|Linux version|Freeing unused kernel memory|Run /init|execv|kexec-stage2|dropbear|rndis|usb_gadget|first stage|Unable to handle|Internal error|DEVAPC|SPI3|PMIF|VIO_INFO|mt6315|kernel BUG|Call trace|panic|Reason:' "$f" | head -120
    echo "============================================="
    echo "full log: $f"
    exit 0
done

say "exhausted $MAX rounds without SSH or non-stale pstore"
exit 1
