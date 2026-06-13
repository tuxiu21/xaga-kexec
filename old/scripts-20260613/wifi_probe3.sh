#!/data/kexec/busybox sh
# WiFi bring-up probe v3: experiment 1 -- also load the SCP + connsys-SCP link
# (scp/connscp), which v2 skipped, then power on connsys. v2 proved the wlan
# stack loads+probes (wiphy phy0) but `echo 1 > /dev/wmtWifi` stalls in
# conninfra pre_cal (connsys never really powers up). Hypothesis: connsys needs
# the SCP coprocessor coordination. Tees to /data/kexec/wifi_probe3.log.
BB=/data/kexec/busybox
export PATH=/data/kexec:/system/bin:/vendor/bin
LOG=/data/kexec/wifi_probe3.log
MDIR=/vendor_dlkm/lib/modules

# SCP chain (exp1) first, then connsys-SCP link, then the wlan dep closure.
ORDER="mtk-mbox mtk_rpmsg_mbox mtk_tinysys_ipi mtk-afe-external scp
connadp connscp
mtk_low_battery_throttling mtk_dynamic_loading_throttling mtk_mdpm mtk_pbm
ccci_util_lib ccci_auxadc rps_perf ccmni ccci_md_all
conninfra connfem wmt_chrdev_wifi_connac2 mddp wlan_drv_gen4m_6895"

{
  echo "===== WIFI PROBE v3 (exp1: +scp/connscp) BEGIN $($BB date) ====="

  echo "## loading modules from $MDIR"
  for m in $ORDER; do
    if $BB lsmod | $BB grep -q "^$m "; then echo "  skip  $m (loaded)"; continue; fi
    ko="$MDIR/$m.ko"
    [ -e "$ko" ] || { echo "  MISS  $ko"; continue; }
    out="$($BB insmod "$ko" 2>&1)"; rc=$?
    if [ "$rc" = 0 ]; then echo "  ok    $m"; else echo "  rc=$rc $m : $out"; fi
    $BB sync
  done

  echo "## scp / connscp / conninfra loaded?"
  $BB lsmod | $BB grep -iE '^scp |^connscp|^conninfra|^wlan_drv|^wmt_chrdev' || echo "  (none!)"
  echo "## scp dmesg (ready?)"
  $BB dmesg | $BB grep -iE 'scp|connscp|sram|tinysys' | $BB grep -ivE 'scpsys' | $BB tail -20

  # make the WMT/conn /dev nodes by major from /proc/devices (no ueventd in lean)
  for spec in "wmtWifi:mtk_wmt_wifi_chrdev" "conninfra_dev:conninfra_drv" "connfem:connfem"; do
    node="/dev/${spec%%:*}"; name="${spec##*:}"
    maj="$($BB awk -v n="$name" '$2==n{print $1}' /proc/devices)"
    [ -n "$maj" ] && { [ -c "$node" ] || $BB mknod "$node" c "$maj" 0; echo "  node $node c $maj 0"; }
  done

  if [ -c /dev/wmtWifi ]; then
    echo "===== echo 1 > /dev/wmtWifi (power on STA) ====="
    $BB sync
    ( echo 1 > /dev/wmtWifi ) 2>&1
    echo "  write rc=$?"
    $BB sleep 8
    echo "## dmesg connsys/wlan/pre_cal AFTER power-on"
    $BB dmesg | $BB grep -iE 'conn_pwr|conninfra_pwr|connsys|conn_infra|pre_cal|WIFI_RAM|download|gen4m|wmt turn|func_ctrl|scp|connscp|chip_ver|cal_|sema|wlan0|whole chip|clock|clkbuf|co_clock' | $BB grep -ivE 'pre_cal_blocking.*ret=\[1\]' | $BB tail -60
    echo "## (pre_cal_blocking ret count -- still looping?)"
    $BB dmesg | $BB grep -c 'pre_cal_blocking'
  else
    echo "!! /dev/wmtWifi missing -> skip power-on"
  fi

  echo "## wlan ifaces"; $BB ls /sys/class/net/ | $BB grep -iE 'wlan|p2p' || echo "  (none)"
  echo "## ieee80211"; $BB ls /sys/class/ieee80211/ 2>&1
  echo "===== WIFI PROBE v3 END $($BB date) ====="
  $BB sync
} 2>&1 | $BB tee "$LOG"
