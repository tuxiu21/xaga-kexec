#!/data/kexec/busybox sh
# WiFi bring-up probe v5: the surgical "last native shot". Load the coprocessor
# + clock chain in CORRECT dependency order (deps first), which prior probes got
# wrong:
#   - probe3 crashed loading scp because fhctl (scp's PLL clock parent, a probe-
#     time clock dep INVISIBLE to modules.dep) wasn't loaded first.
#   - probe4's "unknown symbol" cascade was a bug: modules.load is a SET for
#     modprobe (which dep-orders), not a literal insmod order; I loaded gpueb
#     before its dep mtk-ssc.
# Correct order here (fhctl needs mcupm+gpueb+mtk-ssc+mbox; scp needs fhctl's
# clock). Per-module breadcrumb to /data/kexec/wifi_load_progress.txt so a
# coprocessor-firmware NULL-deref (like cm_mgr/scp did) names itself.
BB=/data/kexec/busybox
export PATH=/data/kexec:/system/bin:/vendor/bin
LOG=/data/kexec/wifi_probe5.log
PROG=/data/kexec/wifi_load_progress.txt
DIRS="/vendor_dlkm/lib/modules /vendor/lib/modules"

ORDER="mtk-mbox mtk_rpmsg_mbox mtk_tinysys_ipi mtk-ssc
mcupm gpueb fhctl
mtk-afe-external scp connadp connscp sspm_v3
ccci_util_lib ccci_auxadc rps_perf ccmni ccci_md_all
mtk_low_battery_throttling mtk_dynamic_loading_throttling mtk_mdpm mtk_pbm
conninfra connfem wmt_chrdev_wifi_connac2 mddp wlan_drv_gen4m_6895"

{
  echo "===== WIFI PROBE v5 (surgical coproc chain, dep-ordered) BEGIN $($BB date) ====="
  : > "$PROG"
  for ko in $ORDER; do
    lname="$(echo "$ko" | $BB tr '-' '_')"
    if $BB lsmod | $BB grep -q "^$lname "; then echo "  already $ko"; continue; fi
    path=""
    for d in $DIRS; do [ -e "$d/$ko.ko" ] && { path="$d/$ko.ko"; break; }; done
    [ -n "$path" ] || { echo "  MISS  $ko"; continue; }
    echo "$ko" > "$PROG"; $BB sync               # breadcrumb before the risky call
    out="$($BB insmod "$path" 2>&1)"; rc=$?
    if [ "$rc" = 0 ]; then echo "  ok    $ko"; else echo "  rc=$rc $ko : $out"; fi
    $BB sync
  done
  echo "DONE" > "$PROG"; $BB sync

  echo "## coproc/clock/conn modules present?"
  $BB lsmod | $BB grep -iE '^mcupm|^gpueb|^fhctl|^scp |^connscp|^sspm|^conninfra|^wmt_chrdev|^wlan_drv' || echo "  (NONE)"
  echo "## scp/fhctl/sspm dmesg (clock parent? resources? ready?)"
  $BB dmesg | $BB grep -iE 'fhctl|clock parent|invalid resource|scp |sspm|connscp|mcupm|gpueb' | $BB grep -ivE 'scpsys' | $BB tail -25

  for spec in "wmtWifi:mtk_wmt_wifi_chrdev" "conninfra_dev:conninfra_drv" "connfem:connfem"; do
    node="/dev/${spec%%:*}"; name="${spec##*:}"
    maj="$($BB awk -v x="$name" '$2==x{print $1}' /proc/devices)"
    [ -n "$maj" ] && { [ -c "$node" ] || $BB mknod "$node" c "$maj" 0; }
  done
  $BB ls -la /dev/wmtWifi 2>&1

  if [ -c /dev/wmtWifi ]; then
    echo "===== echo 1 > /dev/wmtWifi (power on STA) ====="
    $BB sync
    ( echo 1 > /dev/wmtWifi ) 2>&1; echo "  write rc=$?"
    $BB sleep 12
    echo "## connsys/pre_cal dmesg AFTER power-on"
    $BB dmesg | $BB grep -iE 'conn_pwr|conninfra_pwr|connsys|conn_infra|pre_cal|WIFI_RAM|download|gen4m|wmt turn|func_ctrl|sspm|chip_ver|wlan0|cal.*done|power.*on.*ok|whole chip|patch.*dl' | $BB grep -ivE 'pre_cal_blocking.*ret=\[1\]' | $BB tail -55
    echo "## pre_cal_blocking ret=1 still looping? count:"; $BB dmesg | $BB grep -c 'pre_cal_blocking'
  else
    echo "!! /dev/wmtWifi missing"
  fi
  echo "## wlan ifaces"; $BB ls /sys/class/net/ | $BB grep -iE 'wlan|p2p' || echo "  (none)"
  echo "## ieee80211 phys"; $BB ls /sys/class/ieee80211/ 2>&1
  echo "===== WIFI PROBE v5 END $($BB date) ====="
  $BB sync
} 2>&1 | $BB tee "$LOG"
