#!/bin/sh
# Wi-Fi bring-up for the direct-root kexec Ubuntu environment on mt6895/xaga.
#
# Requirements:
# - patched mtk-mbox.ko in the initrd, otherwise SCP mailbox bring-up can BUG
#   or spin on unmatched recv IRQ bits after kexec.
# - /vendor_dlkm and /vendor are mounted before loading Wi-Fi modules.
#
# Output:
# - /var/log/kexec-runtime/wifi-bringup.log
# - /var/lib/kexec-runtime/wifi-status
# - /var/log/kexec-runtime/dmesg-wifi-before.log
# - /var/log/kexec-runtime/dmesg-wifi-after.log

RUNTIME="${KEXEC_RUNTIME:-/usr/local/libexec/kexec}"
export PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
LOG="/var/log/kexec-runtime/wifi-bringup.log"
PROG="/var/lib/kexec-runtime/wifi-status"
DMESG_BEFORE="/var/log/kexec-runtime/dmesg-wifi-before.log"
DMESG_AFTER="/var/log/kexec-runtime/dmesg-wifi-after.log"
FIRMWARE_DIR="${WIFI_FIRMWARE_DIR:-/vendor/firmware}"
POWER_WAIT_SECS="${WIFI_POWER_WAIT_SECS:-240}"
POLL_SECS=5
DIRS="/vendor_dlkm/lib/modules /vendor/lib/modules"
WIFI_SKIP_MODULES="${WIFI_SKIP_MODULES:-}"
mkdir -p /var/log/kexec-runtime /var/lib/kexec-runtime
if [ -s /etc/kexec-runtime/wifi_skip_modules ]; then
    WIFI_SKIP_MODULES="$(cat /etc/kexec-runtime/wifi_skip_modules 2>/dev/null || echo "$WIFI_SKIP_MODULES")"
fi

MODULE_ORDER="mtk-mbox mtk_rpmsg_mbox mtk_tinysys_ipi mtk-ssc
connadp
mcupm gpueb fhctl
mtk-afe-external scp
connscp
mtk_low_battery_throttling mtk_dynamic_loading_throttling mtk_mdpm mtk_pbm
ccci_util_lib ccci_auxadc rps_perf ccmni ccci_md_all
conninfra connfem wmt_chrdev_wifi_connac2 mddp wlan_drv_gen4m_6895"

skip_module()
{
    needle="$1"

    for mod in $WIFI_SKIP_MODULES; do
        [ "$mod" = "$needle" ] && return 0
    done
    return 1
}

log_step()
{
    echo "$1" > "$PROG"
    sync
}

setup_firmware_path()
{
    if [ -d "$FIRMWARE_DIR" ] && [ -w /sys/module/firmware_class/parameters/path ]; then
        printf '%s' "$FIRMWARE_DIR" > /sys/module/firmware_class/parameters/path 2>/dev/null || true
    fi

    if [ -r /sys/module/firmware_class/parameters/path ]; then
        echo "## firmware path: $(cat /sys/module/firmware_class/parameters/path 2>/dev/null)"
    else
        echo "## firmware path: unreadable"
    fi
    if [ -d "$FIRMWARE_DIR" ]; then
        echo "## firmware dir: $FIRMWARE_DIR"
    else
        echo "!! firmware dir missing: $FIRMWARE_DIR"
    fi
    ls -lh "$FIRMWARE_DIR" 2>&1 | sed -n '1,120p'
}

ensure_vendor_mounts()
{
    if [ -d /vendor/firmware ] && [ -d /vendor_dlkm/lib/modules ]; then
        return 0
    fi

    slot="_a"
    if [ -r /proc/cmdline ]; then
        slot="$(sed -n 's/.*androidboot.slot_suffix=\([^ ]*\).*/\1/p' /proc/cmdline | head -n 1)"
        [ -n "$slot" ] || slot="_a"
    fi

    echo "## vendor paths missing; trying map_super_partitions.py --mount slot=$slot"
    if [ -x "$RUNTIME/map_super_partitions.py" ]; then
        "$RUNTIME/map_super_partitions.py" --slot "$slot" \
            --partition "vendor${slot}" \
            --partition "vendor_dlkm${slot}" \
            --mount 2>&1 || true
    else
        echo "!! missing $RUNTIME/map_super_partitions.py"
    fi

    if [ ! -d /vendor/firmware ] || [ ! -d /vendor_dlkm/lib/modules ]; then
        echo "!! /vendor/firmware: $( [ -d /vendor/firmware ] && echo ok || echo missing )"
        echo "!! /vendor_dlkm/lib/modules: $( [ -d /vendor_dlkm/lib/modules ] && echo ok || echo missing )"
    fi
}

load_module()
{
    ko="$1"
    lname="$(echo "$ko" | tr '-' '_')"

    if lsmod | grep -q "^$lname "; then
        echo "  already $ko"
        return 0
    fi

    path=""
    for d in $DIRS; do
        [ -e "$d/$ko.ko" ] && { path="$d/$ko.ko"; break; }
    done
    if [ -z "$path" ]; then
        echo "  MISS  $ko"
        return 0
    fi

    log_step "$ko"
    echo "  insmod $ko from $path"
    out="$(insmod "$path" 2>&1)"
    rc=$?
    if [ "$rc" = 0 ]; then
        echo "  ok    $ko from $path"
    else
        echo "  rc=$rc $ko : $out"
    fi
    sync

    case "$ko" in
        connadp) sleep 2 ;;
        scp) sleep 8 ;;
        connscp) sleep 2 ;;
        ccci_md_all) sleep 2 ;;
        conninfra) sleep 3 ;;
        wmt_chrdev_wifi_connac2) sleep 2 ;;
    esac
}

create_dev_nodes()
{
    for spec in "wmtWifi:mtk_wmt_wifi_chrdev" "conninfra_dev:conninfra_drv" "connfem:connfem"; do
        node="/dev/${spec%%:*}"
        name="${spec##*:}"
        maj="$(awk -v x="$name" '$2==x{print $1}' /proc/devices)"
        [ -n "$maj" ] && { [ -c "$node" ] || mknod "$node" c "$maj" 0; }
    done
    if [ ! -e /dev/rfkill ] && [ -r /sys/class/misc/rfkill/dev ]; then
        dev="$(cat /sys/class/misc/rfkill/dev 2>/dev/null || true)"
        maj="${dev%:*}"
        min="${dev#*:}"
        case "$maj:$min" in
            *[!0-9:]*|:|*:)
                ;;
            *)
                mknod /dev/rfkill c "$maj" "$min" 2>/dev/null || true
                chmod 0664 /dev/rfkill 2>/dev/null || true
                ;;
        esac
    fi
}

dump_state()
{
    echo "## key modules"
    lsmod | grep -iE '^wlan_drv|^mddp|^wmt_chrdev|^conninfra|^connfem|^connscp|^scp |^connadp|^ccci|^ccmni|^rps_perf|^mtk_pbm|^mtk_mdpm|^mtk_dynamic|^mtk_low' || echo "  (NONE)"

    echo "## dev nodes"
    ls -la /dev/wmtWifi /dev/conninfra_dev /dev/connfem /dev/rfkill 2>&1

    echo "## wlan ifaces"
    ls /sys/class/net/ | grep -iE 'wlan|p2p|ap' || echo "  (none)"

    echo "## ieee80211 phys"
    ls /sys/class/ieee80211/ 2>&1
}

dump_wifi_dmesg()
{
    dmesg | grep -iE 'conn_pwr|conninfra_pwr|connsys|conn_infra|pre_cal|WIFI_RAM|download|firmware|gen4m|wmt turn|func_ctrl|chip_ver|wlan0|p2p|wlanProbe|probe success|netif|patch.*dl|MBOX Error|drop unmatched|Unknown symbol' | tail -220
}

has_wlan_iface()
{
    ls /sys/class/net/ | grep -qE '^(wlan|p2p|ap)[0-9]*$'
}

has_probe_success()
{
    dmesg | grep -qiE 'wlanProbe: probe success|wlanProbeSuccessForLowLatency'
}

wait_for_wifi_ready()
{
    waited=0
    while [ "$waited" -lt "$POWER_WAIT_SECS" ]; do
        if has_wlan_iface || has_probe_success; then
            echo "## wifi ready after ${waited}s"
            return 0
        fi
        log_step "POST_POWER_WAIT_${waited}s"
        sleep "$POLL_SECS"
        waited=$((waited + POLL_SECS))
    done
    echo "## wifi wait timed out after ${POWER_WAIT_SECS}s"
    return 1
}

{
    echo "===== WIFI BRINGUP BEGIN $(date) ====="
    : > "$PROG"
    : > "$DMESG_BEFORE"
    : > "$DMESG_AFTER"

    echo "## module search dirs: $DIRS"
    echo "## skipped modules: ${WIFI_SKIP_MODULES:-<none>}"
    ensure_vendor_mounts
    setup_firmware_path

    for ko in $MODULE_ORDER; do
        if skip_module "$ko"; then
            echo "  skip  $ko"
            log_step "SKIP_$ko"
            continue
        fi
        load_module "$ko"
    done
    log_step "MODULES_DONE"

    create_dev_nodes
    dump_state

    if [ -c /dev/wmtWifi ]; then
        echo "===== power on STA via /dev/wmtWifi ====="
        dmesg > "$DMESG_BEFORE" 2>&1
        log_step "POWER_ON"
        ( echo 1 > /dev/wmtWifi ) 2>&1
        echo "  write rc=$?"

        # The vendor driver can return EIO before the asynchronous pre-cal and
        # firmware path completes. Poll for the actual netdev/probe outcome.
        log_step "POST_POWER_WAIT_0s"
        sync
        wait_for_wifi_ready
        wifi_ready=$?
        dmesg > "$DMESG_AFTER" 2>&1

        echo "## connsys/wlan dmesg after power-on wait"
        dump_wifi_dmesg

        if [ "$wifi_ready" = 0 ] || has_wlan_iface || has_probe_success; then
            result="READY"
        else
            result="NO_WLAN_IFACE"
        fi
    else
        echo "!! /dev/wmtWifi missing"
        dmesg > "$DMESG_AFTER" 2>&1
        result="WMTWIFI_MISSING"
    fi

    create_dev_nodes
    dump_state
    log_step "$result"
    if [ -x "$RUNTIME/bin/kexec-flight-recorder" ]; then
        case "$result" in
            READY)
                "$RUNTIME/bin/kexec-flight-recorder" event info wifi "$result" \
                    >/dev/null 2>&1 || true
                ;;
            *)
                "$RUNTIME/bin/kexec-flight-recorder" event warn wifi "$result" \
                    >/dev/null 2>&1 || true
                ;;
        esac
    fi
    echo "## result: $result"
    echo "===== WIFI BRINGUP END $(date) ====="
    sync
} 2>&1 | tee "$LOG"
