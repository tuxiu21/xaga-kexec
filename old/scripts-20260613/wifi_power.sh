#!/data/kexec/busybox sh
# Connsys power-on test. Modules are already loaded (wifi_probe2). The WMT/conn
# char devices exist (see /proc/devices) but lean has no ueventd to create the
# /dev nodes, so make them by major, then power on via /dev/wmtWifi.
BB=/data/kexec/busybox
export PATH=/data/kexec:/system/bin:/vendor/bin
LOG=/data/kexec/wifi_power.log
{
  echo "===== WIFI POWER-ON TEST $($BB date) ====="
  for spec in "wmtWifi:mtk_wmt_wifi_chrdev" "conninfra_dev:conninfra_drv" "connfem:connfem"; do
    node="/dev/${spec%%:*}"; name="${spec##*:}"
    maj="$($BB awk -v n="$name" '$2==n{print $1}' /proc/devices)"
    if [ -n "$maj" ]; then
      [ -c "$node" ] || $BB mknod "$node" c "$maj" 0
      echo "  $node -> c $maj 0 : $($BB ls -la "$node" 2>&1)"
    else
      echo "  no major in /proc/devices for $name"
    fi
  done

  echo "===== echo 1 > /dev/wmtWifi (power on STA) ====="
  $BB sync
  ( echo 1 > /dev/wmtWifi ) 2>&1
  echo "  write rc=$?"
  $BB sleep 8

  echo "## dmesg connsys/wlan after power-on"
  $BB dmesg | $BB grep -iE 'connsys|conninfra|WIFI_RAM|gen4m|wmt|download|firmware|patch| cal |power on|coredump|assert|fail|fwdl|rom|ready|wlan0|whole chip|pwr_on' | $BB tail -80

  echo "## wlan ifaces"; $BB ls /sys/class/net/ | $BB grep -iE 'wlan|p2p' || echo "  (none)"
  echo "## wlan0 link"; $BB ip link show wlan0 2>&1
  echo "## ieee80211 phys"; $BB ls /sys/class/ieee80211/ 2>&1
  echo "## /proc/net/wireless"; $BB cat /proc/net/wireless 2>&1
  echo "===== END $($BB date) ====="
  $BB sync
} 2>&1 | $BB tee "$LOG"
