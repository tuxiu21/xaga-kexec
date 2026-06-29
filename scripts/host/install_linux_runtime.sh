#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

LINUX_DEV="${LINUX_DEV:-/dev/block/by-name/linux}"
LINUX_DEV_FALLBACK="${LINUX_DEV_FALLBACK:-/dev/block/sdc88}"
LINUX_MOUNT="${LINUX_MOUNT:-/mnt/linux_kexec}"
LINUX_ROOT="${LINUX_ROOT:-$LINUX_MOUNT}"
LEAN_DIR="${LEAN_DIR:-$LINUX_ROOT/lean}"
LINUX_RUNTIME="${LINUX_RUNTIME:-$LEAN_DIR}"
LEAN_RUNTIME="${LEAN_RUNTIME:-/kexec/lean}"
ADB_STAGE="${ADB_STAGE:-/data/local/tmp/linux_runtime_stage}"
RAMDISK="${RAMDISK:-$VENDOR_DIR/ramdisk_patched.cpio}"
ADBD="${ADBD:-$ROOT/prebuilt/adbd}"

adb_root_shell()
{
  local script="$1"
  if [ "$("$ADB" shell 'id -u 2>/dev/null' | tr -d '\r')" = "0" ]; then
    "$ADB" shell "$script"
  else
    "$ADB" shell "su -c '$script'"
  fi
}

runtime_paths=(
  system/bin/linker64
  system/lib64/liblog.so
  system/lib64/libselinux.so
  system/lib64/libpcre2.so
  system/lib64/libpackagelistparser.so
  system/lib64/libbase.so
  system/lib64/libadb_protos.so
  system/lib64/libprotobuf-cpp-lite.so
  system/lib64/libadbd_auth.so
  system/lib64/libadbd_fs.so
  system/lib64/libcrypto.so
  system/lib64/libc++.so
  system/lib64/libc.so
  system/lib64/libm.so
  system/lib64/libdl.so
)

for path in "$ADBD" "$RAMDISK" "$ROOT/prebuilt/busybox" "$ROOT/prebuilt/dropbear" "$ROOT/prebuilt/dropbearkey"; do
  if [ ! -s "$path" ]; then
    echo "missing required file: $path" >&2
    exit 1
  fi
done

aarch64-linux-gnu-gcc -static -Os -s \
  -o "$OUTPUT_DIR/watchdog_feeder" \
  "$ROOT/src/watchdog_feeder.c"

aarch64-linux-gnu-gcc -static -Os -s \
  -o "$OUTPUT_DIR/boot_ubuntu_rootfs" \
  "$ROOT/src/boot_ubuntu_rootfs.c"

tmp="$(mktemp -d "$TMP_ROOT/linux_runtime.XXXXXX")"
cleanup()
{
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/root" "$tmp/push/adblib"

if ! magiskboot cpio "$RAMDISK" "extract system/bin/linker64 $tmp/push/linker64" >/dev/null 2>&1; then
  echo "failed to extract system/bin/linker64 from $RAMDISK" >&2
  exit 1
fi

for path in "${runtime_paths[@]}"; do
  case "$path" in
    system/bin/linker64)
      continue
      ;;
  esac
  out="$tmp/push/adblib/${path##*/}"
  magiskboot cpio "$RAMDISK" "extract $path $out" >/dev/null 2>&1 || {
    echo "failed to extract $path from $RAMDISK" >&2
    exit 1
  }
done

cp "$ADBD" "$tmp/push/adbd"
cp "$ROOT/prebuilt/busybox" "$tmp/push/busybox"
cp "$ROOT/prebuilt/dropbear" "$tmp/push/dropbear"
cp "$ROOT/prebuilt/dropbearkey" "$tmp/push/dropbearkey"
cp "$OUTPUT_DIR/watchdog_feeder" "$tmp/push/watchdog_feeder"
cp "$OUTPUT_DIR/boot_ubuntu_rootfs" "$tmp/push/boot_ubuntu_rootfs"
cp "$ROOT/src/kxsh.sh" "$tmp/push/kxsh.sh"
cp "$ROOT/scripts/device/ubuntu_phase_a_init.sh" "$tmp/push/ubuntu_phase_a_init.sh"
cp "$ROOT/scripts/device/wifi_bringup.sh" "$tmp/push/wifi_bringup.sh"
cp "$ROOT/scripts/device/enter_ubuntu.sh" "$tmp/push/enter-ubuntu.sh"

chmod 0755 "$tmp/push"/adbd "$tmp/push"/busybox "$tmp/push"/dropbear \
  "$tmp/push"/dropbearkey "$tmp/push"/watchdog_feeder \
  "$tmp/push"/boot_ubuntu_rootfs "$tmp/push"/*.sh "$tmp/push/linker64"
chmod 0644 "$tmp/push"/adblib/*.so

wifi_modules="mtk-mbox mtk_rpmsg_mbox mtk_tinysys_ipi mtk-ssc connadp mcupm gpueb fhctl mtk-afe-external scp connscp mtk_low_battery_throttling mtk_dynamic_loading_throttling mtk_mdpm mtk_pbm ccci_util_lib ccci_auxadc rps_perf ccmni ccci_md_all conninfra connfem wmt_chrdev_wifi_connac2 mddp wlan_drv_gen4m_6895"
wifi_firmware_patterns="WIFI_RAM_CODE_soc7_0* soc7_0_ram_wmmcu* conninfra.cfg wifi.cfg wifi_sigma.cfg txpowerctrl.cfg"

adb_root_shell "
  set -e
  mkdir -p \"$LINUX_MOUNT\"
  if ! grep -q \" $LINUX_MOUNT \" /proc/mounts; then
    mount -t ext4 -o rw,noatime \"$LINUX_DEV\" \"$LINUX_MOUNT\" 2>/dev/null ||
      mount -t ext4 -o rw,noatime \"$LINUX_DEV_FALLBACK\" \"$LINUX_MOUNT\"
  fi
  rm -rf \"$LINUX_RUNTIME/.stage\" \"$ADB_STAGE\"
  mkdir -p \"$ADB_STAGE\"
  chmod 0777 \"$ADB_STAGE\"
"

"$ADB" push "$tmp/push/." "$ADB_STAGE/"

adb_root_shell "
  set -e
  mkdir -p \"$LINUX_RUNTIME\" \"$LINUX_RUNTIME/root/.ssh\" \"$LINUX_RUNTIME/run\" \"$LINUX_RUNTIME/adblib\"
  find \"$LINUX_RUNTIME\" -maxdepth 1 -type l -lname \"$LEAN_RUNTIME/busybox\" -delete 2>/dev/null || true
  rm -rf \"$LINUX_RUNTIME/kexec\" \"$LINUX_RUNTIME/linux_kexec\" \
    \"$LINUX_RUNTIME/kxshbinxx\" \"$LINUX_RUNTIME/kxshbinxxxx.disabled\"
  cp -R \"$ADB_STAGE/.\" \"$LINUX_RUNTIME/\"
  rm -rf \"$ADB_STAGE\" \"$LINUX_RUNTIME/.stage\"
  ln -sf \"$LEAN_RUNTIME/busybox\" \"$LINUX_RUNTIME/sh\"
  ln -sf \"$LEAN_RUNTIME/enter-ubuntu.sh\" \"$LINUX_RUNTIME/enter_ubuntu.sh\"
  printf \"root::0:0:root:$LEAN_RUNTIME/root:$LEAN_RUNTIME/sh\n\" > \"$LINUX_RUNTIME/passwd\"
  printf \"root:x:0:\n\" > \"$LINUX_RUNTIME/group\"
  printf \"root::10933:0:99999:7:::\n\" > \"$LINUX_RUNTIME/shadow\"
  chmod 700 \"$LINUX_RUNTIME/root\" \"$LINUX_RUNTIME/root/.ssh\"
  chmod 600 \"$LINUX_RUNTIME/root/.ssh/authorized_keys\" \"$LINUX_RUNTIME/shadow\" 2>/dev/null || true
  chmod 644 \"$LINUX_RUNTIME/passwd\" \"$LINUX_RUNTIME/group\"
  chmod 0755 \"$LINUX_RUNTIME\"
  chmod 0755 \"$LINUX_RUNTIME\"/busybox \"$LINUX_RUNTIME\"/dropbear \"$LINUX_RUNTIME\"/dropbearkey \"$LINUX_RUNTIME\"/watchdog_feeder \"$LINUX_RUNTIME\"/boot_ubuntu_rootfs \"$LINUX_RUNTIME\"/kxsh.sh \"$LINUX_RUNTIME\"/ubuntu_phase_a_init.sh \"$LINUX_RUNTIME\"/wifi_bringup.sh \"$LINUX_RUNTIME\"/enter-ubuntu.sh \"$LINUX_RUNTIME\"/linker64 \"$LINUX_RUNTIME\"/adbd 2>/dev/null || true
  chmod 0644 \"$LINUX_RUNTIME\"/adblib/*.so 2>/dev/null || true
  rm -rf \"$LINUX_RUNTIME/modules\"
  mkdir -p \"$LINUX_RUNTIME/modules\"
  for mod in $wifi_modules; do
    for d in /vendor_dlkm/lib/modules /vendor/lib/modules; do
      [ -f \"\$d/\$mod.ko\" ] && cp \"\$d/\$mod.ko\" \"$LINUX_RUNTIME/modules/\" && break
    done
  done
  chmod 0644 \"$LINUX_RUNTIME/modules\"/*.ko 2>/dev/null || true
  rm -rf \"$LINUX_RUNTIME/firmware\"
  mkdir -p \"$LINUX_RUNTIME/firmware\"
  for pattern in $wifi_firmware_patterns; do
    for d in /vendor/firmware /vendor/etc/firmware; do
      for fw in \"\$d\"/\$pattern; do
        [ -f \"\$fw\" ] && cp \"\$fw\" \"$LINUX_RUNTIME/firmware/\"
      done
    done
  done
  chmod 0644 \"$LINUX_RUNTIME/firmware\"/* 2>/dev/null || true
  echo 180 > \"$LINUX_RUNTIME/panic_after\"
  sync
  ls -l \"$LINUX_RUNTIME\" | sed -n \"1,120p\"
  ls -l \"$LINUX_RUNTIME/firmware\" | sed -n \"1,80p\"
"
