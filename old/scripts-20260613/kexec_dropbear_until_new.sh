#!/usr/bin/env bash
# Boot/capture loop: kexec into the lean-Linux system, retrying until a full boot.
# Stop when SSH becomes reachable, or when a non-stale pstore log is captured.
set -u

ADB=adb.exe
INITRD="${1:-combined_ramdisk_kexec_dropbear.lz4}"
# On the device, kexec runs from /data/local/tmp where push_initrd.sh drops the
# initrd under its basename. INITRD may be passed as a host-relative path
# (e.g. output/foo.lz4) for the host-side size calc, so the device must use the
# basename only -- otherwise "kexec -l" fails to open it, never reboots, and
# every round just re-reads the previous boot's stale pstore ("Bye!").
INITRD_DEV="$(basename "$INITRD")"
# Patched DTB carrying regulator-always-on on the rails the kernel's ~30s
# "disable unused regulators" cleanup would otherwise cut (that killed full
# boots at ~31.7s). Generate+push it with scripts/build_always_on_dtb.sh.
# Set DTB_DEV= (empty) to fall back to reusing the device's live FDT.
DTB_DEV="${DTB_DEV:-patched.dtb}"
MAX="${2:-20}"
SSH_HOST="${3:-192.168.66.2}"
SSH_PORT="${4:-22}"
# Stop early instead of burning every round on the same failure (env-overridable).
STALE_MAX="${STALE_MAX:-3}"
BYE_MAX="${BYE_MAX:-3}"
NOEXEC_MAX="${NOEXEC_MAX:-3}"
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
    # Phase 1: confirm the jump actually happened. A real "kexec -e" drops adb
    # within a couple of seconds; if the device never leaves Android then the
    # load or exec failed and there is nothing new to inspect (return 3).
    rebooting=0
    for _ in $(seq 1 30); do
        if ssh_port_open; then
            return 0
        fi
        if ! adb_online; then
            rebooting=1
            break
        fi
        sleep 1
    done
    if [ "$rebooting" = 0 ]; then
        return 3
    fi

    # Phase 2: the device is rebooting. Success = rescue SSH comes up and Android
    # never returns. Failure = it boots back into Android (then inspect pstore).
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

stale=0
byeonly=0
noexec=0
partial=0
best_bytes=0

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

    nonce="KEXECTRY-r${r}-$(date +%s)-${RANDOM}"
    printf '%s\n' "$nonce" > "$OUT/round_${r}_nonce.txt"

    say "round $r: kexec into dropbear rescue (nonce=$nonce)"
    # Two things happen right before the jump:
    #  1. Stamp the nonce into the kernel log. ramoops captures every printk, so it
    #     lands in the persistent console buffer just ahead of the old kernel's
    #     "Bye!" and lets us tell this round's capture from a stale one.
    #  2. Kick the AP watchdog to a full budget. The MTK HW watchdog (~15s period)
    #     keeps counting across the kexec jump; if the rescue kernel does not reach
    #     its own feeder (kxsh, ~3.8s) before the budget runs out, it resets with
    #     poffreason=AP_WDT -- often before printing anything, so pstore shows only
    #     the old kernel's tail. Kicking here hands the rescue the maximum window;
    #     in testing it took pre-print AP_WDT deaths from ~50% of rounds to 0.
    $ADB shell "su -c 'cd /data/local/tmp && echo 0 > /proc/sys/kernel/kptr_restrict && ./kexec -c -l kernel --initrd=$INITRD_DEV ${DTB_DEV:+--dtb=$DTB_DEV} --append=\"$cmdline\" && sync && echo $nonce > /dev/kmsg && echo 1 > /dev/watchdog 2>/dev/null && echo 1 > /dev/watchdog0 2>/dev/null; ./kexec -f -e'" >/dev/null 2>&1

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

    if [ "$rc" = "3" ]; then
        noexec=$((noexec + 1))
        say "round $r: kexec did not take; device never left Android [$noexec/$NOEXEC_MAX]"
        if [ "$noexec" -ge "$NOEXEC_MAX" ]; then
            say "giving up: 'kexec -l/-e' is not rebooting the device"
            say "check that './kexec -l ...' succeeds and that 'kernel' is valid for this device"
            exit 4
        fi
        continue
    fi

    # rc == 2: the device rebooted back into Android. Capture this round's boot.
    # pstore records repopulate a moment after Android comes up, so poll for them.
    f="$OUT/round_${r}_console.txt"
    : > "$f"
    for _ in $(seq 1 15); do
        $ADB shell "su -c 'cat /sys/fs/pstore/console-ramoops-0 2>/dev/null'" > "$f" 2>/dev/null
        [ -s "$f" ] && break
        sleep 1
    done

    # Decide freshness from THIS round's nonce, not from "Bye!". The old kernel
    # always prints "Bye!" just before the kexec jump (arch/arm64 machine_kexec.c),
    # so it is in every capture and tells us nothing about staleness.
    fresh=0;         grep -qaF "$nonce" "$f" && fresh=1
    has_bye=0;       grep -qa  'Bye!'   "$f" && has_bye=1
    console_empty=1; [ -s "$f" ] && console_empty=0
    # New-kernel output = whatever was logged after the last "Bye!".
    post_bye="$(awk '/Bye!/{buf=""; seen=1; next} {if (seen) buf=buf $0 "\n"} END{printf "%s", buf}' "$f" | tr -d '\000[:space:]')"

    # Panic/oops dumps land in a separate record; fold them into the report.
    fd="$OUT/round_${r}_dmesg.txt"
    $ADB shell "su -c 'cat /sys/fs/pstore/dmesg-ramoops-* 2>/dev/null'" > "$fd" 2>/dev/null
    had_dmesg=0; [ -s "$fd" ] && had_dmesg=1
    [ "$had_dmesg" = 1 ] && cat "$fd" >> "$f"

    if [ -n "$post_bye" ] || [ "$had_dmesg" = 1 ] || { [ "$has_bye" = 0 ] && [ "$console_empty" = 0 ]; }; then
        if grep -qa 'kexec-system-init' "$f"; then
            # Full rescue log: the new kernel reached our static init (kxsh). This
            # is the goal -- report it and stop.
            stale=0; byeonly=0
            say "round $r: FULL rescue log (reached kxsh) -> $f"
            [ "$had_dmesg" = 1 ] && say "round $r: panic/oops dump captured -> $fd"
            echo
            echo "================= key lines ================="
            grep -a -nE 'Booting Linux|Linux version|Freeing unused kernel memory|Run /init|execv|kexec-stage2|kexec-system-init|mounted /data|dropbear|rndis|usb_gadget|USB_STATE|first stage|Unable to handle|Internal error|DEVAPC|SPI3|PMIF|VIO_INFO|mt6315|kernel BUG|Call trace|panic|Reason:' "$f" | head -120
            echo "============================================="
            echo "full log: $f"
            exit 0
        fi
        # Fresh capture, but the rescue died before reaching kxsh -- an intermittent
        # early reset (SSPM/Cold_reset) that lands at a random point and is not tied
        # to one driver. Keep the most complete capture and retry for a full log;
        # ~3/4 of rounds reach kxsh, so a full log normally lands within a few tries.
        b=$(wc -c < "$f")
        if [ "$b" -gt "$best_bytes" ]; then best_bytes="$b"; cp "$f" "$OUT/best_partial_console.txt" 2>/dev/null; fi
        partial=$((partial + 1))
        say "round $r: fresh but PARTIAL rescue log (died before kxsh at $(grep -aoE '\[[ ]*[0-9]+\.[0-9]+\]' "$f" | tail -1)); retrying for a full one [partial=$partial]"
        continue
    fi

    if [ "$fresh" = 1 ]; then
        byeonly=$((byeonly + 1))
        say "round $r: fresh capture, but the new kernel wrote nothing to pstore [$byeonly/$BYE_MAX]"
        say "round $r: kexec jumped (old kernel reached 'Bye!') yet the rescue kernel logged nothing to ramoops"
        if [ "$byeonly" -ge "$BYE_MAX" ]; then
            say "giving up: the kexec'd kernel is not writing to the ramoops console"
            say "pstore cannot show rescue progress on this device; likely causes:"
            say "  - the new kernel has no ramoops/pstore console in its DT view, or"
            say "  - it resets before console init"
            say "debug the rescue boot over the USB/RNDIS console, or boot a kernel with ramoops"
            say "kept: $f"
            exit 5
        fi
        continue
    fi

    stale=$((stale + 1))
    say "round $r: no round nonce and no new-kernel output (stale / pstore not refreshed) [$stale/$STALE_MAX]"
    if [ "$stale" -ge "$STALE_MAX" ]; then
        say "giving up: pstore is not capturing this round's boot after $STALE_MAX tries"
        say "the device may not be rebooting through ramoops, or pstore is not repopulating"
        exit 6
    fi
    continue
done

say "exhausted $MAX rounds without SSH or a full rescue log"
if [ "$best_bytes" -gt 0 ]; then
    say "most complete capture this run: $OUT/best_partial_console.txt ($best_bytes bytes)"
fi
exit 1
