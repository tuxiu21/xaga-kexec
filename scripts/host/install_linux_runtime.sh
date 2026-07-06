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
  -o "$OUTPUT_DIR/boot_ubuntu_rootfs" \
  "$ROOT/src/boot_ubuntu_rootfs.c"

tmp="$(mktemp -d "$TMP_ROOT/linux_runtime.XXXXXX")"
cleanup()
{
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/root" "$tmp/push/adblib"
mkdir -p "$tmp/push/systemd" "$tmp/push/bin" "$tmp/push/lib"

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
cp "$OUTPUT_DIR/boot_ubuntu_rootfs" "$tmp/push/boot_ubuntu_rootfs"
cp "$ROOT/src/kxsh.sh" "$tmp/push/kxsh.sh"
cp "$ROOT/scripts/device/prepare_ubuntu_kexec_boot.sh" "$tmp/push/prepare_ubuntu_kexec_boot.sh"
cp "$ROOT/scripts/device/wifi_bringup.sh" "$tmp/push/wifi_bringup.sh"
cp "$ROOT/scripts/device/xaga-watchdog.conf" "$tmp/push/xaga-watchdog.conf"
cp "$ROOT/scripts/device/map_super_partitions.py" "$tmp/push/map_super_partitions.py"
cp "$ROOT/scripts/device/enter_ubuntu.sh" "$tmp/push/enter-ubuntu.sh"
cp -R "$ROOT/scripts/device/bin/." "$tmp/push/bin/"
cp -R "$ROOT/scripts/device/lib/." "$tmp/push/lib/"
cp -R "$ROOT/scripts/device/systemd/." "$tmp/push/systemd/"

chmod 0755 "$tmp/push"/adbd "$tmp/push"/busybox "$tmp/push"/dropbear \
  "$tmp/push"/dropbearkey \
  "$tmp/push"/boot_ubuntu_rootfs "$tmp/push"/*.sh \
  "$tmp/push"/map_super_partitions.py "$tmp/push/linker64" \
  "$tmp/push"/bin/kexec-*
chmod 0644 "$tmp/push"/lib/kexec/*.sh
chmod 0644 "$tmp/push"/adblib/*.so

wifi_modules="mtk-mbox mtk_rpmsg_mbox mtk_tinysys_ipi mtk-ssc connadp mcupm gpueb fhctl mtk-afe-external scp connscp mtk_low_battery_throttling mtk_dynamic_loading_throttling mtk_mdpm mtk_pbm ccci_util_lib ccci_auxadc rps_perf ccmni ccci_md_all conninfra connfem wmt_chrdev_wifi_connac2 mddp wlan_drv_gen4m_6895"

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
  rm -f \"$LINUX_RUNTIME/ubuntu_phase_a_init.sh\" \"$LINUX_RUNTIME/watchdog_feeder\"
  chmod 0755 \"$LINUX_RUNTIME\"/busybox \"$LINUX_RUNTIME\"/dropbear \"$LINUX_RUNTIME\"/dropbearkey \"$LINUX_RUNTIME\"/boot_ubuntu_rootfs \"$LINUX_RUNTIME\"/kxsh.sh \"$LINUX_RUNTIME\"/prepare_ubuntu_kexec_boot.sh \"$LINUX_RUNTIME\"/wifi_bringup.sh \"$LINUX_RUNTIME\"/map_super_partitions.py \"$LINUX_RUNTIME\"/enter-ubuntu.sh \"$LINUX_RUNTIME\"/linker64 \"$LINUX_RUNTIME\"/adbd \"$LINUX_RUNTIME\"/bin/kexec-* 2>/dev/null || true
  chmod 0644 \"$LINUX_RUNTIME\"/lib/kexec/*.sh 2>/dev/null || true
  chmod 0644 \"$LINUX_RUNTIME\"/adblib/*.so 2>/dev/null || true
  mkdir -p \"$LINUX_ROOT/etc/systemd/system\" \"$LINUX_ROOT/etc/systemd/network\" \
    \"$LINUX_ROOT/etc/systemd/system/multi-user.target.wants\" \
    \"$LINUX_ROOT/etc/systemd/system/sysinit.target.wants\"
  cp \"$LINUX_RUNTIME/systemd/\"*.service \"$LINUX_RUNTIME/systemd/\"*.target \"$LINUX_ROOT/etc/systemd/system/\"
  cp -R \"$LINUX_RUNTIME/systemd/\"*.service.d \"$LINUX_ROOT/etc/systemd/system/\" 2>/dev/null || true
  cp \"$LINUX_RUNTIME/systemd/\"*.network \"$LINUX_ROOT/etc/systemd/network/\" 2>/dev/null || true
  cp \"$LINUX_RUNTIME/systemd/\"*.link \"$LINUX_ROOT/etc/systemd/network/\" 2>/dev/null || true
  if [ ! -e \"$LINUX_ROOT/etc/xaga-watchdog.conf\" ]; then
    cp \"$LINUX_RUNTIME/xaga-watchdog.conf\" \"$LINUX_ROOT/etc/xaga-watchdog.conf\"
  fi
  chmod 0644 \"$LINUX_ROOT/etc/systemd/system\"/kexec-*.service \"$LINUX_ROOT/etc/systemd/system\"/kexec-*.target 2>/dev/null || true
  chmod 0644 \"$LINUX_ROOT/etc/xaga-watchdog.conf\" 2>/dev/null || true
  chmod 0644 \"$LINUX_ROOT/etc/systemd/system\"/*.service.d/*.conf \"$LINUX_ROOT/etc/systemd/network\"/*.network \"$LINUX_ROOT/etc/systemd/network\"/*.link 2>/dev/null || true
  rm -f \"$LINUX_ROOT/etc/systemd/system/kexec-phase-a.service\" \
    \"$LINUX_ROOT/etc/systemd/system/multi-user.target.wants/kexec-phase-a.service\"
  rm -rf \"$LINUX_ROOT/etc/systemd/system/kexec-phase-a.service.d\"
  for unit in \
    kexec-time-keeper.service \
    kexec-watchdog.service \
    kexec-panic-timer.service \
    kexec-vendor-mount.service \
    kexec-adbd.service \
    kexec-wifi.service; do
    ln -sfn \"../\$unit\" \"$LINUX_ROOT/etc/systemd/system/multi-user.target.wants/\$unit\"
  done
  ln -sfn /lib/systemd/system/systemd-networkd.service \"$LINUX_ROOT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service\"
  rm -f \"$LINUX_ROOT/etc/systemd/system/systemd-resolved.service\"
  ln -sfn /lib/systemd/system/systemd-resolved.service \"$LINUX_ROOT/etc/systemd/system/sysinit.target.wants/systemd-resolved.service\"
  ln -sfn /lib/systemd/system/systemd-resolved.service \"$LINUX_ROOT/etc/systemd/system/dbus-org.freedesktop.resolve1.service\"
  ln -sfn ../run/systemd/resolve/stub-resolv.conf \"$LINUX_ROOT/etc/resolv.conf\"
  ln -sfn /lib/systemd/system/wpa_supplicant@.service \"$LINUX_ROOT/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service\"
  rm -rf \"$LINUX_RUNTIME/modules\"
  mkdir -p \"$LINUX_RUNTIME/modules\"
  for mod in $wifi_modules; do
    for d in /vendor_dlkm/lib/modules /vendor/lib/modules; do
      [ -f \"\$d/\$mod.ko\" ] && cp \"\$d/\$mod.ko\" \"$LINUX_RUNTIME/modules/\" && break
    done
  done
  chmod 0644 \"$LINUX_RUNTIME/modules\"/*.ko 2>/dev/null || true
  rm -rf \"$LINUX_RUNTIME/firmware\"
  echo 900 > \"$LINUX_RUNTIME/panic_after\"
  sync
  ls -l \"$LINUX_RUNTIME\" | sed -n \"1,120p\"
"
