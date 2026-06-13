#!/data/kexec/busybox sh
# WiFi connsys power-up probe for the lean kexec system (mt6895 / CONNAC2x).
#
# Run INSIDE lean:  adb -s 0123456789abcdef shell sh /data/kexec/wifi_probe.sh
# Answers the P0 question: does `echo 1 > /dev/wmtWifi` light up connsys
# (power island + firmware download) and register wlan0 in the stripped-down
# lean power state -- WITHOUT needing wpa_supplicant yet.
#
# Everything is tee'd to /data/kexec/wifi_probe.log, which lives on the shared
# /data f2fs, so it is readable from stock Android even if this crash-resets.

BB=/data/kexec/busybox
export PATH=/data/kexec:/system/bin:/vendor/bin
LOG=/data/kexec/wifi_probe.log

{
  echo "===== WIFI PROBE BEGIN $($BB date) ====="
  echo "## uname"; $BB uname -a

  echo "## connectivity modules loaded"
  $BB lsmod | $BB grep -iE 'conninfra|connfem|connadp|connscp|wmt_chrdev|wlan_drv|cfg80211|mac80211|emi_mpu' \
    || echo "  (NONE matched -- first-stage did not load connectivity modules)"

  echo "## /vendor + firmware in /proc/mounts"
  $BB grep -iE ' /vendor | /vendor_dlkm |firmware' /proc/mounts || echo "  (/vendor NOT mounted)"

  echo "## dm + by-name block nodes for vendor"
  $BB ls -l /dev/block/dm-* 2>/dev/null
  $BB ls -l /dev/block/by-name/vendor* 2>/dev/null

  echo "## control nodes"
  $BB ls -la /dev/wmtWifi /dev/conninfra_dev /dev/wmtdetect 2>&1
  echo "  /proc/devices wmt/conn:"; $BB grep -iE 'wmt|conn' /proc/devices 2>&1

  # If /vendor is not mounted, try to mount the erofs image so request_firmware
  # can find WIFI_RAM_CODE_*. dm-linear nodes are set up by first-stage init.
  if ! $BB grep -q ' /vendor ' /proc/mounts; then
    echo "## /vendor not mounted -> attempting erofs mount"
    for d in /dev/block/by-name/vendor_a /dev/block/dm-5 /dev/block/dm-4 /dev/block/dm-3 /dev/block/dm-2; do
      [ -e "$d" ] || continue
      $BB mkdir -p /vendor 2>/dev/null
      if $BB mount -t erofs -o ro "$d" /vendor 2>&1; then
        echo "  mounted $d -> /vendor"; break
      else
        echo "  mount $d failed"
      fi
    done
  fi

  echo "## firmware file reachable?"
  for f in /vendor/firmware/WIFI_RAM_CODE_soc7_0_1b_1.bin \
           /vendor/firmware/WIFI_RAM_CODE_soc7_0_1c_1.bin \
           /vendor/firmware/wifi.cfg /vendor/firmware/conninfra.cfg; do
    if [ -e "$f" ]; then echo "  OK   $f"; else echo "  MISS $f"; fi
  done
  echo "  firmware_class search path param:"; $BB cat /sys/module/firmware_class/parameters/path 2>&1

  echo "## wireless state BEFORE power-on"
  echo "  net wlan ifaces:"; $BB ls /sys/class/net/ | $BB grep -iE 'wlan|p2p|ap0' || echo "   (no wlan*)"
  echo "  /proc/net/wireless:"; $BB cat /proc/net/wireless 2>&1
  echo "  ieee80211 phys:";    $BB ls /sys/class/ieee80211/ 2>&1

  echo "## dmesg tail BEFORE"; $BB dmesg | $BB tail -3

  # ensure the control node exists (devtmpfs should have it; mknod fallback)
  if [ ! -e /dev/wmtWifi ]; then
    maj=$($BB awk '/wmtWifi/{print $1}' /proc/devices 2>/dev/null)
    [ -n "$maj" ] && $BB mknod /dev/wmtWifi c "$maj" 0 2>&1 && echo "## mknod /dev/wmtWifi c $maj 0"
  fi

  echo "===== WRITE 1 -> /dev/wmtWifi (power on STA) ====="
  $BB sync
  ( echo 1 > /dev/wmtWifi ) 2>&1
  echo "  write rc=$?"
  $BB sleep 5

  echo "## dmesg connsys/wlan AFTER"
  $BB dmesg | $BB grep -iE 'wlan|connsys|conninfra|connfem|connv|WIFI_RAM|gen4m|wmt|fw_own|download|firmware|coredump|assert|conn_pwr|emi_mpu|whole chip|patch' | $BB tail -60

  echo "## wireless state AFTER power-on"
  echo "  net wlan ifaces:"; $BB ls /sys/class/net/ | $BB grep -iE 'wlan|p2p|ap0' || echo "   (no wlan*)"
  echo "  wlan0 link:"; $BB ip link show wlan0 2>&1
  echo "  /proc/net/wireless:"; $BB cat /proc/net/wireless 2>&1
  echo "  ieee80211 phys:";    $BB ls /sys/class/ieee80211/ 2>&1

  echo "## bring wlan0 up"
  if $BB ip link set wlan0 up 2>&1; then echo "  wlan0 up OK"; else echo "  wlan0 up FAILED"; fi
  $BB sleep 1
  echo "  wlan0 after up:"; $BB ip link show wlan0 2>&1

  echo "===== WIFI PROBE END $($BB date) ====="
  $BB sync
} 2>&1 | $BB tee "$LOG"
