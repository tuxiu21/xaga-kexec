#!/data/kexec/busybox sh
# WiFi bring-up probe v4: replicate Android's FULL second-stage module load.
# Android boots via init.insmod.sh -> `modprobe -a -d /vendor/lib/modules
# $(cat modules.load)` = load ALL ~200 modules in modules.load order. My earlier
# probes only loaded the wlan symbol-dependency closure (modules.dep), which
# MISSES probe-time/order deps -- notably fhctl (the PLL clock parent SCP needs;
# loading scp without it = "cannot get 1st clock parent" -> Oops) and the power
# coprocessors mcupm/sspm_v3. Here we load modules.load in order, then power on.
#
# Crash breadcrumb: the module about to be insmod'd is written to
# /data/kexec/wifi_load_progress.txt (synced) BEFORE each insmod, so if a module
# panics the kernel, that file names the culprit after the fall-back to stock.
BB=/data/kexec/busybox
export PATH=/data/kexec:/system/bin:/vendor/bin
LOG=/data/kexec/wifi_probe4.log
PROG=/data/kexec/wifi_load_progress.txt
LOADLIST=/vendor/lib/modules/modules.load
DIRS="/vendor_dlkm/lib/modules /vendor/lib/modules"

is_key() {
  case "$1" in
    fhctl|mcupm|sspm_v3|vcp|scp|connadp|connscp|conninfra|connfem|\
    wmt_chrdev_wifi_connac2|wlan_drv_gen4m_6895|mtk-lpm|cpudvfs|mtk-dvfsrc-start|mddp) return 0 ;;
  esac
  return 1
}

{
  echo "===== WIFI PROBE v4 (full modules.load replicate) BEGIN $($BB date) ====="
  : > "$PROG"
  n=0; ok=0; skip=0; fail=0; miss=0
  for ko in $($BB cat "$LOADLIST" | $BB sed 's/\.ko$//'); do
    n=$((n+1))
    lname="$(echo "$ko" | $BB tr '-' '_')"
    if $BB lsmod | $BB grep -q "^$lname "; then skip=$((skip+1)); is_key "$ko" && echo "  already $ko"; continue; fi
    path=""
    for d in $DIRS; do [ -e "$d/$ko.ko" ] && { path="$d/$ko.ko"; break; }; done
    [ -n "$path" ] || { miss=$((miss+1)); continue; }
    echo "$ko" > "$PROG"; $BB sync                 # breadcrumb before the risky call
    out="$($BB insmod "$path" 2>&1)"; rc=$?
    if [ "$rc" = 0 ]; then ok=$((ok+1)); is_key "$ko" && echo "  KEY-ok  $ko";
    else fail=$((fail+1)); echo "  rc=$rc  $ko : $out"; fi
  done
  echo "DONE" > "$PROG"; $BB sync
  echo "  -- modules.load: total=$n loaded=$ok already=$skip miss=$miss fail=$fail --"

  echo "## key power/coproc/conn modules present?"
  $BB lsmod | $BB grep -iE '^fhctl|^mcupm|^sspm|^scp |^vcp |^connscp|^conninfra|^wmt_chrdev|^wlan_drv' || echo "  (NONE)"
  echo "## scp/sspm dmesg"
  $BB dmesg | $BB grep -iE 'scp |sspm|fhctl|clock parent|invalid resource|connscp' | $BB grep -ivE 'scpsys' | $BB tail -20

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
    $BB sleep 10
    echo "## connsys/pre_cal dmesg AFTER power-on"
    $BB dmesg | $BB grep -iE 'conn_pwr|conninfra_pwr|connsys|conn_infra|pre_cal|WIFI_RAM|download|gen4m|wmt turn|func_ctrl|sspm|chip_ver|wlan0|cal.*done|power.*on.*ok|whole chip' | $BB grep -ivE 'pre_cal_blocking.*ret=\[1\]' | $BB tail -55
    echo "## pre_cal_blocking ret=1 still looping? count:"; $BB dmesg | $BB grep -c 'pre_cal_blocking'
  else
    echo "!! /dev/wmtWifi missing"
  fi
  echo "## wlan ifaces"; $BB ls /sys/class/net/ | $BB grep -iE 'wlan|p2p' || echo "  (none)"
  echo "## ieee80211 phys"; $BB ls /sys/class/ieee80211/ 2>&1
  echo "===== WIFI PROBE v4 END $($BB date) ====="
  $BB sync
} 2>&1 | $BB tee "$LOG"
