#!/data/kexec/busybox sh
# WiFi bring-up probe v9: v8 loaded the full module chain and later kernel logs
# showed wlanProbe success after the script had already checked interfaces. Keep
# the v8 order, but wait long enough after WMT power-on for pre-cal/FW probe.

BB=/data/kexec/busybox
export PATH=/data/kexec:/system/bin:/vendor/bin
LOG=/data/kexec/wifi_probe9.log
PROG=/data/kexec/wifi_load_progress.txt
DIRS="/vendor_dlkm/lib/modules /vendor/lib/modules"

ORDER="mtk-mbox mtk_rpmsg_mbox mtk_tinysys_ipi mtk-ssc
connadp
mcupm gpueb fhctl
mtk-afe-external scp
connscp
mtk_low_battery_throttling mtk_dynamic_loading_throttling mtk_mdpm mtk_pbm
ccci_util_lib ccci_auxadc rps_perf ccmni ccci_md_all
conninfra connfem wmt_chrdev_wifi_connac2 mddp wlan_drv_gen4m_6895"

load_one()
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
    [ -n "$path" ] || {
        echo "  MISS  $ko"
        return 0
    }

    echo "$ko" > "$PROG"
    "$BB" sync
    out="$("$BB" insmod "$path" 2>&1)"
    rc=$?
    if [ "$rc" = 0 ]; then
        echo "  ok    $ko"
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

dump_state()
{
    echo "## wlan ifaces"
    "$BB" ls /sys/class/net/ | "$BB" grep -iE 'wlan|p2p|ap' || echo "  (none)"
    echo "## ieee80211 phys"
    "$BB" ls /sys/class/ieee80211/ 2>&1
    echo "## dev nodes"
    "$BB" ls -la /dev/wmtWifi /dev/conninfra_dev /dev/connfem 2>&1
}

{
    echo "===== WIFI PROBE v9 (long post-power wait) BEGIN $("$BB" date) ====="
    : > "$PROG"
    for ko in $ORDER; do
        load_one "$ko"
    done
    echo "MODULES_DONE" > "$PROG"
    "$BB" sync

    echo "## key modules"
    "$BB" lsmod | "$BB" grep -iE '^wlan_drv|^mddp|^wmt_chrdev|^conninfra|^connfem|^connscp|^scp |^connadp|^ccci|^ccmni|^rps_perf|^mtk_pbm|^mtk_mdpm|^mtk_dynamic|^mtk_low' || echo "  (NONE)"

    for spec in "wmtWifi:mtk_wmt_wifi_chrdev" "conninfra_dev:conninfra_drv" "connfem:connfem"; do
        node="/dev/${spec%%:*}"
        name="${spec##*:}"
        maj="$("$BB" awk -v x="$name" '$2==x{print $1}' /proc/devices)"
        [ -n "$maj" ] && { [ -c "$node" ] || "$BB" mknod "$node" c "$maj" 0; }
    done
    dump_state

    if [ -c /dev/wmtWifi ]; then
        echo "===== echo 1 > /dev/wmtWifi (power on STA) ====="
        echo "POWER_ON" > "$PROG"
        "$BB" sync
        ( echo 1 > /dev/wmtWifi ) 2>&1
        echo "  write rc=$?"
        echo "POST_POWER_WAIT" > "$PROG"
        "$BB" sync
        "$BB" sleep 90
        echo "## connsys/wlan dmesg AFTER long wait"
        "$BB" dmesg | "$BB" grep -iE 'conn_pwr|conninfra_pwr|connsys|conn_infra|pre_cal|WIFI_RAM|download|firmware|gen4m|wmt turn|func_ctrl|chip_ver|wlan0|p2p|wlanProbe|probe success|netif|patch.*dl|MBOX Error|drop unmatched|Unknown symbol' | "$BB" tail -220
    else
        echo "!! /dev/wmtWifi missing"
    fi

    dump_state
    echo "DONE" > "$PROG"
    echo "===== WIFI PROBE v9 END $("$BB" date) ====="
    "$BB" sync
} 2>&1 | "$BB" tee "$LOG"
