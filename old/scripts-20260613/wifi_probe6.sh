#!/data/kexec/busybox sh
# WiFi bring-up probe v6: avoid the SCP/connadp race seen in v5.
#
# v5 loaded scp before connadp. On this device that lets SCP emit CONNSYS IPI
# before the connsys consumer has registered its mailbox callback, hitting:
#   [MBOX Error]null ptr dev=scp_mboxdev ipi_id=32
#   BUG at drivers/soc/mediatek/mtk-mbox.c:549
#
# Android's modules.load lists connadp before scp. Keep that ordering, then
# start scp, wait for its noisy init path to settle, and only then load connscp.
BB=/data/kexec/busybox
export PATH=/data/kexec:/system/bin:/vendor/bin
LOG=/data/kexec/wifi_probe6.log
PROG=/data/kexec/wifi_load_progress.txt
DIRS="/vendor_dlkm/lib/modules /vendor/lib/modules"

ORDER="mtk-mbox mtk_rpmsg_mbox mtk_tinysys_ipi mtk-ssc
connadp
mcupm gpueb fhctl
mtk-afe-external scp
connscp sspm_v3
ccci_util_lib ccci_auxadc rps_perf ccmni ccci_md_all
mtk_low_battery_throttling mtk_dynamic_loading_throttling mtk_mdpm mtk_pbm
conninfra connfem wmt_chrdev_wifi_connac2 mddp wlan_drv_gen4m_6895"

load_one()
{
    ko="$1"
    lname="$(echo "$ko" | $BB tr '-' '_')"
    if $BB lsmod | $BB grep -q "^$lname "; then
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
    $BB sync
    out="$($BB insmod "$path" 2>&1)"
    rc=$?
    if [ "$rc" = 0 ]; then
        echo "  ok    $ko"
    else
        echo "  rc=$rc $ko : $out"
    fi
    $BB sync

    case "$ko" in
        connadp)
            echo "  settle after connadp"
            $BB sleep 2
            ;;
        scp)
            echo "  settle after scp"
            $BB sleep 8
            ;;
    esac
}

{
    echo "===== WIFI PROBE v6 (connadp before scp) BEGIN $($BB date) ====="
    : > "$PROG"
    for ko in $ORDER; do
        load_one "$ko"
    done
    echo "DONE" > "$PROG"
    $BB sync

    echo "## key modules"
    $BB lsmod | $BB grep -iE '^connadp|^scp |^connscp|^sspm|^conninfra|^wmt_chrdev|^wlan_drv|^fhctl|^mcupm|^gpueb' || echo "  (NONE)"

    echo "## recent scp/conn/mbox dmesg"
    $BB dmesg | $BB grep -iE 'MBOX Error|connadp|connscp|scp |scp_|conninfra|connsys|pre_cal|WIFI_RAM|wlan0|gen4m' | $BB tail -80

    for spec in "wmtWifi:mtk_wmt_wifi_chrdev" "conninfra_dev:conninfra_drv" "connfem:connfem"; do
        node="/dev/${spec%%:*}"
        name="${spec##*:}"
        maj="$($BB awk -v x="$name" '$2==x{print $1}' /proc/devices)"
        [ -n "$maj" ] && { [ -c "$node" ] || $BB mknod "$node" c "$maj" 0; }
    done
    $BB ls -la /dev/wmtWifi 2>&1

    if [ -c /dev/wmtWifi ]; then
        echo "===== echo 1 > /dev/wmtWifi (power on STA) ====="
        $BB sync
        ( echo 1 > /dev/wmtWifi ) 2>&1
        echo "  write rc=$?"
        $BB sleep 12
        echo "## connsys/wlan dmesg AFTER power-on"
        $BB dmesg | $BB grep -iE 'conn_pwr|conninfra_pwr|connsys|conn_infra|pre_cal|WIFI_RAM|download|gen4m|wmt turn|func_ctrl|sspm|chip_ver|wlan0|cal.*done|power.*on.*ok|whole chip|patch.*dl|MBOX Error' | $BB grep -ivE 'pre_cal_blocking.*ret=\[1\]' | $BB tail -80
        echo "## pre_cal_blocking count"
        $BB dmesg | $BB grep -c 'pre_cal_blocking'
    else
        echo "!! /dev/wmtWifi missing"
    fi

    echo "## wlan ifaces"
    $BB ls /sys/class/net/ | $BB grep -iE 'wlan|p2p' || echo "  (none)"
    echo "## ieee80211 phys"
    $BB ls /sys/class/ieee80211/ 2>&1
    echo "===== WIFI PROBE v6 END $($BB date) ====="
    $BB sync
} 2>&1 | $BB tee "$LOG"
