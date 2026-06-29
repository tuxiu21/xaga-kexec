#!/usr/bin/env bash
# Pull boot/vendor_boot from the connected stock Android device, rebuild the
# current kexec initrd, install runtime/payload, then optionally run a boot test.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

RUN_MODE="${RUN_MODE:-lean}"        # lean, ubuntu, none
INSTALL_UBUNTU="${INSTALL_UBUNTU:-0}"
MAX="${MAX:-4}"
INITRD="${INITRD:-$OUTPUT_DIR/combined_ramdisk_kexec_system_mbox.lz4}"
DEVICE_IMAGE_DIR="${DEVICE_IMAGE_DIR:-$WORK_DIR/device_images}"
BOOT_IMAGE="${BOOT_IMAGE:-}"
VENDOR_BOOT_IMAGE="${VENDOR_BOOT_IMAGE:-}"
SLOT_SUFFIX="${SLOT_SUFFIX:-}"
STOCK_SERIAL="${STOCK_SERIAL:-}"

say()
{
  printf '%s %s\n' "$(date +%H:%M:%S)" "$*" >&2
}

adb_root_shell()
{
  local script="$1"
  if [ "$("$ADB" shell 'id -u 2>/dev/null' | tr -d '\r')" = "0" ]; then
    "$ADB" shell "$script"
  else
    "$ADB" shell "su -c '$script'"
  fi
}

detect_stock_serial()
{
  if [ -n "$STOCK_SERIAL" ]; then
    return 0
  fi

  STOCK_SERIAL="$("$ADB" devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && $2=="device"{print $1; exit}')"
  [ -n "$STOCK_SERIAL" ]
}

wait_stock_ready()
{
  "$ADB" wait-for-device >/dev/null 2>&1
  local i
  for i in $(seq 1 60); do
    [ "$("$ADB" shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && return 0
    sleep 2
  done
  return 1
}

detect_slot()
{
  if [ -z "$SLOT_SUFFIX" ]; then
    SLOT_SUFFIX="$("$ADB" shell getprop ro.boot.slot_suffix | tr -d '\r\n')"
  fi
  [ -n "$SLOT_SUFFIX" ] || SLOT_SUFFIX="_a"
}

pull_partition_image()
{
  local name="$1"
  local part="/dev/block/by-name/${name}${SLOT_SUFFIX}"
  local remote="/data/local/tmp/${name}${SLOT_SUFFIX}.img"
  local local_path="$DEVICE_IMAGE_DIR/${name}${SLOT_SUFFIX}.img"

  # Pull through /data/local/tmp because adb cannot read block devices directly.
  say "pull $part -> $local_path"
  adb_root_shell "dd if=$part of=$remote bs=4M && sync"
  "$ADB" pull "$remote" "$local_path"
  adb_root_shell "rm -f $remote"
  printf '%s\n' "$local_path"
}

case "$RUN_MODE" in
  lean|ubuntu|none) ;;
  *)
    echo "RUN_MODE must be lean, ubuntu, or none" >&2
    exit 2
    ;;
esac

mkdir -p "$DEVICE_IMAGE_DIR"

say "waiting for stock Android"
wait_stock_ready || say "stock boot_completed not seen; continuing anyway"
detect_stock_serial || { echo "failed to detect stock adb serial; set STOCK_SERIAL=..." >&2; exit 5; }
detect_slot
say "stock=$STOCK_SERIAL slot=$SLOT_SUFFIX run_mode=$RUN_MODE max=$MAX"

if [ -z "$BOOT_IMAGE" ]; then
  BOOT_IMAGE="$(pull_partition_image boot)"
fi
if [ -z "$VENDOR_BOOT_IMAGE" ]; then
  VENDOR_BOOT_IMAGE="$(pull_partition_image vendor_boot)"
fi

# GKI and vendor_boot are rebuilt from images pulled from the same active slot.
say "build GKI base ramdisk"
GKI_BOOT_IMAGE="$BOOT_IMAGE" bash "$ROOT/scripts/host/build_gki_base_initrd.sh"

say "build patched vendor ramdisk"
SLOT_SUFFIX="$SLOT_SUFFIX" VENDOR_BOOT_IMAGE="$VENDOR_BOOT_IMAGE" \
  bash "$ROOT/scripts/host/build_vendor_base_initrd.sh"

# The mbox initrd is the current default because Wi-Fi probing needs mtk-mbox.
say "build mbox kexec initrd"
bash "$ROOT/scripts/host/build_patched_mbox_initrd.sh"

if [ "$INSTALL_UBUNTU" = "1" ]; then
  say "install Ubuntu rootfs"
  bash "$ROOT/scripts/host/install_ubuntu_rootfs.sh"
fi

say "install linux partition runtime"
bash "$ROOT/scripts/host/install_linux_runtime.sh"

say "install kexec payload"
INITRD="$INITRD" bash "$ROOT/scripts/host/install_kexec_payload.sh"

case "$RUN_MODE" in
  none)
    say "done: built and installed payload; kexec test skipped"
    ;;
  lean)
    say "run lean kexec test"
    STOCK_SERIAL="$STOCK_SERIAL" bash "$ROOT/scripts/host/kexec_adb_until_lean.sh" "$INITRD" "$MAX"
    ;;
  ubuntu)
    say "run Ubuntu kexec test"
    STOCK_SERIAL="$STOCK_SERIAL" bash "$ROOT/scripts/host/kexec_adb_until_ubuntu.sh" "$INITRD" "$MAX"
    ;;
esac
