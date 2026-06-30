#!/kexec/lean/busybox sh
# Minimal Wi-Fi bring-up for the lean kexec environment on mt6895/xaga.
#
# Requirements:
# - patched mtk-mbox.ko in the initrd, otherwise SCP mailbox bring-up can BUG
#   or spin on unmatched recv IRQ bits after kexec.
# - /vendor_dlkm and /vendor are mounted before loading Wi-Fi modules.
# - $KEXEC_BASE/busybox available.
#
# Output:
# - $KEXEC_BASE/wifi_bringup.log
# - $KEXEC_BASE/wifi_load_progress.txt
# - $KEXEC_BASE/dmesg_wifi_before.log
# - $KEXEC_BASE/dmesg_wifi_after.log

BASE="${KEXEC_BASE:-/kexec/lean}"
BB="$BASE/busybox"
export PATH="$BASE:/system/bin:/vendor/bin"
LOG="$BASE/wifi_bringup.log"
PROG="$BASE/wifi_load_progress.txt"
DMESG_BEFORE="$BASE/dmesg_wifi_before.log"
DMESG_AFTER="$BASE/dmesg_wifi_after.log"
FIRMWARE_DIR="${WIFI_FIRMWARE_DIR:-/vendor/firmware}"
POWER_WAIT_SECS="${WIFI_POWER_WAIT_SECS:-240}"
POLL_SECS=5
DIRS="/vendor_dlkm/lib/modules /vendor/lib/modules"

MODULE_ORDER="mtk-mbox mtk_rpmsg_mbox mtk_tinysys_ipi mtk-ssc
connadp
mcupm gpueb fhctl
mtk-afe-external scp
connscp
mtk_low_battery_throttling mtk_dynamic_loading_throttling mtk_mdpm mtk_pbm
ccci_util_lib ccci_auxadc rps_perf ccmni ccci_md_all
conninfra connfem wmt_chrdev_wifi_connac2 mddp wlan_drv_gen4m_6895"

log_step()
{
    echo "$1" > "$PROG"
    "$BB" sync
}

setup_firmware_path()
{
    if [ -d "$FIRMWARE_DIR" ] && [ -w /sys/module/firmware_class/parameters/path ]; then
        printf '%s' "$FIRMWARE_DIR" > /sys/module/firmware_class/parameters/path 2>/dev/null || true
    fi

    if [ -r /sys/module/firmware_class/parameters/path ]; then
        echo "## firmware path: $("$BB" cat /sys/module/firmware_class/parameters/path 2>/dev/null)"
    else
        echo "## firmware path: unreadable"
    fi
    if [ -d "$FIRMWARE_DIR" ]; then
        echo "## firmware dir: $FIRMWARE_DIR"
    else
        echo "!! firmware dir missing: $FIRMWARE_DIR"
    fi
    "$BB" ls -lh "$FIRMWARE_DIR" 2>&1 | "$BB" sed -n '1,120p'
}

ensure_vendor_mounts()
{
    if [ -d /vendor/firmware ] && [ -d /vendor_dlkm/lib/modules ]; then
        return 0
    fi

    slot="_a"
    if [ -r /proc/cmdline ]; then
        slot="$("$BB" sed -n 's/.*androidboot.slot_suffix=\([^ ]*\).*/\1/p' /proc/cmdline | "$BB" head -n 1)"
        [ -n "$slot" ] || slot="_a"
    fi

    echo "## vendor paths missing; trying map_super_partitions.py --mount slot=$slot"
    if [ -x "$BASE/map_super_partitions.py" ]; then
        "$BASE/map_super_partitions.py" --slot "$slot" \
            --partition "vendor${slot}" \
            --partition "vendor_dlkm${slot}" \
            --mount 2>&1 || true
    else
        echo "!! missing $BASE/map_super_partitions.py"
    fi

    if [ ! -d /vendor/firmware ] || [ ! -d /vendor_dlkm/lib/modules ]; then
        echo "!! /vendor/firmware: $( [ -d /vendor/firmware ] && echo ok || echo missing )"
        echo "!! /vendor_dlkm/lib/modules: $( [ -d /vendor_dlkm/lib/modules ] && echo ok || echo missing )"
    fi
}

load_module()
{
    ko="$1"
    lname="$(echo "$ko" | "$BB" tr '-' '_')"

    if "$BB" lsmod | "$BB" grep -q "^$lname "; then
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
    out="$("$BB" insmod "$path" 2>&1)"
    rc=$?
    if [ "$rc" = 0 ]; then
        echo "  ok    $ko from $path"
    else
        echo "  rc=$rc $ko : $out"
    fi
    "$BB" sync

    case "$ko" in
        connadp) "$BB" sleep 2 ;;
        scp) "$BB" sleep 8 ;;
        connscp) "$BB" sleep 2 ;;
        ccci_md_all) "$BB" sleep 2 ;;
        conninfra) "$BB" sleep 3 ;;
        wmt_chrdev_wifi_connac2) "$BB" sleep 2 ;;
    esac
}

create_dev_nodes()
{
    for spec in "wmtWifi:mtk_wmt_wifi_chrdev" "conninfra_dev:conninfra_drv" "connfem:connfem"; do
        node="/dev/${spec%%:*}"
        name="${spec##*:}"
        maj="$("$BB" awk -v x="$name" '$2==x{print $1}' /proc/devices)"
        [ -n "$maj" ] && { [ -c "$node" ] || "$BB" mknod "$node" c "$maj" 0; }
    done
}

dump_state()
{
    echo "## key modules"
    "$BB" lsmod | "$BB" grep -iE '^wlan_drv|^mddp|^wmt_chrdev|^conninfra|^connfem|^connscp|^scp |^connadp|^ccci|^ccmni|^rps_perf|^mtk_pbm|^mtk_mdpm|^mtk_dynamic|^mtk_low' || echo "  (NONE)"

    echo "## dev nodes"
    "$BB" ls -la /dev/wmtWifi /dev/conninfra_dev /dev/connfem 2>&1

    echo "## wlan ifaces"
    "$BB" ls /sys/class/net/ | "$BB" grep -iE 'wlan|p2p|ap' || echo "  (none)"

    echo "## ieee80211 phys"
    "$BB" ls /sys/class/ieee80211/ 2>&1
}

dump_wifi_dmesg()
{
    "$BB" dmesg | "$BB" grep -iE 'conn_pwr|conninfra_pwr|connsys|conn_infra|pre_cal|WIFI_RAM|download|firmware|gen4m|wmt turn|func_ctrl|chip_ver|wlan0|p2p|wlanProbe|probe success|netif|patch.*dl|MBOX Error|drop unmatched|Unknown symbol' | "$BB" tail -220
}

has_wlan_iface()
{
    "$BB" ls /sys/class/net/ | "$BB" grep -qE '^(wlan|p2p|ap)[0-9]*$'
}

has_probe_success()
{
    "$BB" dmesg | "$BB" grep -qiE 'wlanProbe: probe success|wlanProbeSuccessForLowLatency'
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
        "$BB" sleep "$POLL_SECS"
        waited=$((waited + POLL_SECS))
    done
    echo "## wifi wait timed out after ${POWER_WAIT_SECS}s"
    return 1
}

{
    echo "===== WIFI BRINGUP BEGIN $("$BB" date) ====="
    : > "$PROG"
    : > "$DMESG_BEFORE"
    : > "$DMESG_AFTER"

    echo "## module search dirs: $DIRS"
    ensure_vendor_mounts
    setup_firmware_path

    for ko in $MODULE_ORDER; do
        load_module "$ko"
    done
    log_step "MODULES_DONE"

    create_dev_nodes
    dump_state

    if [ -c /dev/wmtWifi ]; then
        echo "===== power on STA via /dev/wmtWifi ====="
        "$BB" dmesg > "$DMESG_BEFORE" 2>&1
        log_step "POWER_ON"
        ( echo 1 > /dev/wmtWifi ) 2>&1
        echo "  write rc=$?"

        # The vendor driver can return EIO before the asynchronous pre-cal and
        # firmware path completes. Poll for the actual netdev/probe outcome.
        log_step "POST_POWER_WAIT_0s"
        "$BB" sync
        wait_for_wifi_ready
        wifi_ready=$?
        "$BB" dmesg > "$DMESG_AFTER" 2>&1

        echo "## connsys/wlan dmesg after power-on wait"
        dump_wifi_dmesg

        if [ "$wifi_ready" = 0 ] || has_wlan_iface || has_probe_success; then
            result="READY"
        else
            result="NO_WLAN_IFACE"
        fi
    else
        echo "!! /dev/wmtWifi missing"
        "$BB" dmesg > "$DMESG_AFTER" 2>&1
        result="WMTWIFI_MISSING"
    fi

    dump_state
    log_step "$result"
    echo "## result: $result"
    echo "===== WIFI BRINGUP END $("$BB" date) ====="
    "$BB" sync
} 2>&1 | "$BB" tee "$LOG"
