#!/data/kexec/busybox sh
# Minimal Wi-Fi bring-up for the lean kexec environment on mt6895/xaga.
#
# Requirements:
# - patched mtk-mbox.ko in the initrd, otherwise SCP mailbox bring-up can BUG
#   or spin on unmatched recv IRQ bits after kexec.
# - vendor_dlkm mounted by Android first-stage init before /system/bin/kxsh.
# - /data/kexec/busybox available.
#
# Output:
# - /data/kexec/wifi_bringup.log
# - /data/kexec/wifi_load_progress.txt

BB=/data/kexec/busybox
export PATH=/data/kexec:/system/bin:/vendor/bin
LOG=/data/kexec/wifi_bringup.log
PROG=/data/kexec/wifi_load_progress.txt
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

{
    echo "===== WIFI BRINGUP BEGIN $("$BB" date) ====="
    : > "$PROG"

    for ko in $MODULE_ORDER; do
        load_module "$ko"
    done
    log_step "MODULES_DONE"

    create_dev_nodes
    dump_state

    if [ -c /dev/wmtWifi ]; then
        echo "===== power on STA via /dev/wmtWifi ====="
        log_step "POWER_ON"
        ( echo 1 > /dev/wmtWifi ) 2>&1
        echo "  write rc=$?"

        # The vendor driver can return EIO before the asynchronous pre-cal and
        # firmware path completes. On this target wlanProbe success appears
        # roughly 60 seconds later, so wait before checking interfaces.
        log_step "POST_POWER_WAIT"
        "$BB" sync
        "$BB" sleep 90

        echo "## connsys/wlan dmesg after power-on wait"
        dump_wifi_dmesg
    else
        echo "!! /dev/wmtWifi missing"
    fi

    dump_state
    log_step "DONE"
    echo "===== WIFI BRINGUP END $("$BB" date) ====="
    "$BB" sync
} 2>&1 | "$BB" tee "$LOG"
