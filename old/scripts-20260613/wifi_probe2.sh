#!/data/kexec/busybox sh
# WiFi bring-up probe v2 for the lean kexec system (mt6895 / CONNAC2x).
# v1 proved: /vendor + /vendor_dlkm mounted, firmware reachable, BUT the
# connectivity driver stack is NOT loaded (Android loads it in 2nd-stage init,
# which lean skips). So: load the wlan dependency closure from
# /vendor_dlkm/lib/modules in order, THEN power on connsys via /dev/wmtWifi.
#
# Run INSIDE lean.  Tees to /data/kexec/wifi_probe2.log (shared /data, survives
# a fall-back to stock).

BB=/data/kexec/busybox
export PATH=/data/kexec:/system/bin:/vendor/bin
LOG=/data/kexec/wifi_probe2.log
MDIR=/vendor_dlkm/lib/modules

# wlan_drv_gen4m_6895 full dependency closure, in load order (deepest dep first;
# reverse of the modules.dep line). Already-loaded ones EEXIST harmlessly.
ORDER="mtk_low_battery_throttling mtk_dynamic_loading_throttling mtk_mdpm mtk_pbm
ccci_util_lib ccci_auxadc rps_perf ccmni ccci_md_all connadp conninfra
connfem wmt_chrdev_wifi_connac2 mddp wlan_drv_gen4m_6895"

{
  echo "===== WIFI PROBE v2 BEGIN $($BB date) ====="
  $BB uname -a

  echo "## loading connectivity stack from $MDIR"
  for m in $ORDER; do
    if $BB lsmod | $BB grep -q "^$m "; then
      echo "  skip  $m (already loaded)"
      continue
    fi
    ko="$MDIR/$m.ko"
    if [ ! -e "$ko" ]; then echo "  MISS  $ko"; continue; fi
    out="$($BB insmod "$ko" 2>&1)"
    rc=$?
    if [ "$rc" = 0 ]; then echo "  ok    insmod $m"; else echo "  rc=$rc insmod $m : $out"; fi
  done

  echo "## connectivity modules after load"
  $BB lsmod | $BB grep -iE 'conninfra|connfem|connadp|wmt_chrdev|wlan_drv|mddp|ccci_md_all|cfg80211' || echo "  (none!)"

  echo "## control nodes after load"
  $BB ls -la /dev/wmtWifi /dev/conninfra_dev /dev/wmtdetect 2>&1
  echo "  /proc/devices wmt/conn:"; $BB grep -iE 'wmt|conn' /proc/devices 2>&1

  echo "## dmesg from module load (conninfra/wlan/connsys)"
  $BB dmesg | $BB grep -iE 'conninfra|connfem|connadp|wmt|wlan|gen4m|connsys|ccci|conn_pwr|connsys|emi_mpu' | $BB tail -40

  # power on only if the real char node exists now
  if [ -c /dev/wmtWifi ]; then
    echo "===== WRITE 1 -> /dev/wmtWifi (real char node, power on STA) ====="
    $BB sync
    ( echo 1 > /dev/wmtWifi ) 2>&1
    echo "  write rc=$?"
    $BB sleep 6
    echo "## dmesg connsys/wlan AFTER power-on"
    $BB dmesg | $BB grep -iE 'connsys|conninfra|WIFI_RAM|gen4m|wlan|wmt|fw_own|download|firmware|patch|coredump|assert|cal |power on|whole chip' | $BB tail -60
  else
    echo "!! /dev/wmtWifi is not a char device -> driver did not create it; skipping power-on"
  fi

  echo "## wireless state"
  echo "  net wlan ifaces:"; $BB ls /sys/class/net/ | $BB grep -iE 'wlan|p2p' || echo "   (no wlan*)"
  echo "  wlan0 link:"; $BB ip link show wlan0 2>&1
  echo "  /proc/net/wireless:"; $BB cat /proc/net/wireless 2>&1
  echo "  ieee80211 phys:"; $BB ls /sys/class/ieee80211/ 2>&1
  if [ -e /sys/class/net/wlan0 ]; then
    echo "## bring wlan0 up"
    $BB ip link set wlan0 up 2>&1 && echo "  wlan0 up OK" || echo "  wlan0 up FAILED"
  fi

  echo "===== WIFI PROBE v2 END $($BB date) ====="
  $BB sync
} 2>&1 | $BB tee "$LOG"
