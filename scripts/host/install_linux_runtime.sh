#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

LINUX_DEV="${LINUX_DEV:-/dev/block/by-name/linux}"
LINUX_DEV_FALLBACK="${LINUX_DEV_FALLBACK:-/dev/block/sdc88}"
LINUX_MOUNT="${LINUX_MOUNT:-/mnt/linux_kexec}"
RUNTIME_REL="${RUNTIME_REL:-usr/local/libexec/kexec}"
RUNTIME_DIR="${RUNTIME_DIR:-$LINUX_MOUNT/$RUNTIME_REL}"
ADB_STAGE="${ADB_STAGE:-/data/local/tmp/kexec_runtime_stage}"
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

for path in "$ADBD" "$RAMDISK"; do
  [ -s "$path" ] || { echo "missing required file: $path" >&2; exit 1; }
done

aarch64-linux-gnu-gcc -static -Os -s \
  -o "$OUTPUT_DIR/boot_ubuntu_rootfs" \
  "$ROOT/src/boot_ubuntu_rootfs.c"

tmp="$(mktemp -d "$TMP_ROOT/kexec_runtime.XXXXXX")"
cleanup()
{
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$tmp/push/adblib" "$tmp/push/systemd" "$tmp/push/bin" "$tmp/push/lib"

if ! magiskboot cpio "$RAMDISK" "extract system/bin/linker64 $tmp/push/linker64" >/dev/null 2>&1; then
  echo "failed to extract system/bin/linker64 from $RAMDISK" >&2
  exit 1
fi
for path in "${runtime_paths[@]}"; do
  [ "$path" = system/bin/linker64 ] && continue
  out="$tmp/push/adblib/${path##*/}"
  magiskboot cpio "$RAMDISK" "extract $path $out" >/dev/null 2>&1 || {
    echo "failed to extract $path from $RAMDISK" >&2
    exit 1
  }
done

cp "$ADBD" "$tmp/push/adbd"
cp "$OUTPUT_DIR/boot_ubuntu_rootfs" "$tmp/push/boot_ubuntu_rootfs"
cp "$ROOT/scripts/device/prepare_ubuntu_kexec_boot.sh" "$tmp/push/prepare_ubuntu_kexec_boot.sh"
cp "$ROOT/scripts/device/wifi_bringup.sh" "$tmp/push/wifi_bringup.sh"
cp "$ROOT/scripts/device/xaga-watchdog.conf" "$tmp/push/xaga-watchdog.conf"
cp "$ROOT/scripts/device/map_super_partitions.py" "$tmp/push/map_super_partitions.py"
cp -R "$ROOT/scripts/device/bin/." "$tmp/push/bin/"
cp -R "$ROOT/scripts/device/lib/." "$tmp/push/lib/"
cp -R "$ROOT/scripts/device/systemd/." "$tmp/push/systemd/"

chmod 0755 "$tmp/push"/adbd "$tmp/push"/boot_ubuntu_rootfs \
  "$tmp/push"/*.sh "$tmp/push"/map_super_partitions.py "$tmp/push/linker64" \
  "$tmp/push"/bin/kexec-*
chmod 0644 "$tmp/push"/lib/kexec/*.sh "$tmp/push"/adblib/*.so

wifi_modules="mtk-mbox mtk_rpmsg_mbox mtk_tinysys_ipi mtk-ssc connadp mcupm gpueb fhctl mtk-afe-external scp connscp mtk_low_battery_throttling mtk_dynamic_loading_throttling mtk_mdpm mtk_pbm ccci_util_lib ccci_auxadc rps_perf ccmni ccci_md_all conninfra connfem wmt_chrdev_wifi_connac2 mddp wlan_drv_gen4m_6895"

adb_root_shell "
  set -e
  mkdir -p '$LINUX_MOUNT'
  grep -q ' $LINUX_MOUNT ' /proc/mounts ||
    mount -t ext4 -o rw,noatime '$LINUX_DEV' '$LINUX_MOUNT' 2>/dev/null ||
    mount -t ext4 -o rw,noatime '$LINUX_DEV_FALLBACK' '$LINUX_MOUNT'
  rm -rf '$ADB_STAGE'
  mkdir -p '$ADB_STAGE'
  chmod 0777 '$ADB_STAGE'
"
"$ADB" push "$tmp/push/." "$ADB_STAGE/"

adb_root_shell "
  set -e
  rm -rf '$RUNTIME_DIR'
  mkdir -p '$RUNTIME_DIR'
  cp -R '$ADB_STAGE/.' '$RUNTIME_DIR/'
  rm -rf '$ADB_STAGE'
  chmod 0755 '$RUNTIME_DIR' '$RUNTIME_DIR'/adbd '$RUNTIME_DIR'/boot_ubuntu_rootfs \
    '$RUNTIME_DIR'/prepare_ubuntu_kexec_boot.sh '$RUNTIME_DIR'/wifi_bringup.sh \
    '$RUNTIME_DIR'/map_super_partitions.py '$RUNTIME_DIR'/linker64 '$RUNTIME_DIR'/bin/kexec-*
  chmod 0644 '$RUNTIME_DIR'/lib/kexec/*.sh '$RUNTIME_DIR'/adblib/*.so

  mkdir -p '$LINUX_MOUNT/var/lib/kexec-runtime' '$LINUX_MOUNT/var/log/kexec-runtime' \
    '$LINUX_MOUNT/etc/kexec-runtime' '$LINUX_MOUNT/etc/systemd/system' \
    '$LINUX_MOUNT/etc/systemd/network' \
    '$LINUX_MOUNT/etc/systemd/system/multi-user.target.wants' \
    '$LINUX_MOUNT/etc/systemd/system/sysinit.target.wants'
  cp '$RUNTIME_DIR/systemd/'*.service '$RUNTIME_DIR/systemd/'*.target \
    '$LINUX_MOUNT/etc/systemd/system/'
  cp -R '$RUNTIME_DIR/systemd/'*.service.d '$LINUX_MOUNT/etc/systemd/system/' 2>/dev/null || true
  cp '$RUNTIME_DIR/systemd/'*.network '$LINUX_MOUNT/etc/systemd/network/' 2>/dev/null || true
  cp '$RUNTIME_DIR/systemd/'*.link '$LINUX_MOUNT/etc/systemd/network/' 2>/dev/null || true
  [ -e '$LINUX_MOUNT/etc/xaga-watchdog.conf' ] ||
    cp '$RUNTIME_DIR/xaga-watchdog.conf' '$LINUX_MOUNT/etc/xaga-watchdog.conf'

  chmod 0644 '$LINUX_MOUNT/etc/systemd/system'/kexec-*.service \
    '$LINUX_MOUNT/etc/systemd/system'/kexec-*.target \
    '$LINUX_MOUNT/etc/xaga-watchdog.conf' 2>/dev/null || true
  chmod 0644 '$LINUX_MOUNT/etc/systemd/system'/*.service.d/*.conf \
    '$LINUX_MOUNT/etc/systemd/network'/*.network \
    '$LINUX_MOUNT/etc/systemd/network'/*.link 2>/dev/null || true

  rm -f '$LINUX_MOUNT/etc/systemd/system/kexec-phase-a.service' \
    '$LINUX_MOUNT/etc/systemd/system/multi-user.target.wants/kexec-phase-a.service' \
    '$LINUX_MOUNT/etc/systemd/system/multi-user.target.wants/wpa_supplicant@wlan0.service'
  rm -rf '$LINUX_MOUNT/etc/systemd/system/kexec-phase-a.service.d'
  rm -rf '$LINUX_MOUNT/etc/systemd/system/wpa_supplicant@wlan0.service.d'
  for unit in \
    kexec-time-keeper.service kexec-watchdog.service kexec-panic-timer.service \
    kexec-vendor-mount.service kexec-adbd.service kexec-wifi.service \
    kexec-wpa-supplicant.service; do
    ln -sfn '../'\$unit '$LINUX_MOUNT/etc/systemd/system/multi-user.target.wants/'\$unit
  done
  ln -sfn /lib/systemd/system/systemd-networkd.service \
    '$LINUX_MOUNT/etc/systemd/system/multi-user.target.wants/systemd-networkd.service'
  rm -f '$LINUX_MOUNT/etc/systemd/system/systemd-resolved.service'
  ln -sfn /lib/systemd/system/systemd-resolved.service \
    '$LINUX_MOUNT/etc/systemd/system/sysinit.target.wants/systemd-resolved.service'
  ln -sfn /lib/systemd/system/systemd-resolved.service \
    '$LINUX_MOUNT/etc/systemd/system/dbus-org.freedesktop.resolve1.service'
  ln -sfn ../run/systemd/resolve/stub-resolv.conf '$LINUX_MOUNT/etc/resolv.conf'
  rm -rf '$RUNTIME_DIR/modules'
  mkdir -p '$RUNTIME_DIR/modules'
  for mod in $wifi_modules; do
    for d in /vendor_dlkm/lib/modules /vendor/lib/modules; do
      [ -f \"\$d/\$mod.ko\" ] && cp \"\$d/\$mod.ko\" '$RUNTIME_DIR/modules/' && break
    done
  done
  chmod 0644 '$RUNTIME_DIR/modules/'*.ko 2>/dev/null || true

  # The direct-root design has no rescue userspace. Remove the legacy runtime
  # only after the new helper and services are installed successfully.
  [ -x '$RUNTIME_DIR/boot_ubuntu_rootfs' ]
  rm -rf '$LINUX_MOUNT/lean'
  sync
  find '$RUNTIME_DIR' -maxdepth 2 -type f -o -type l | sort | sed -n '1,160p'
"
