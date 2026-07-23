#!/usr/bin/env bash
# Safe developer entry point for reproducing the xaga Ubuntu kexec setup.
#
# With no action flags this does not alter sources or the device and performs no
# network access. env.sh may create ignored work directories on the host.
# Destructive operations require explicit flags.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

FETCH_SOURCES=0
PARTITION_PLAN=0
APPLY_PARTITION=0
CONFIRM_PARTITION=0
BUILD_KERNEL=0
BUILD_KEXEC=0
BUILD_ROOTFS=0
BUILD_AOSP_PREBUILTS=0
WIPE_ROOTFS=0
CONFIRM_ROOTFS=0
INSTALL=0
BOOT_TEST=0
MAX="${MAX:-1}"

usage()
{
  cat <<EOF
Usage: $0 [actions]

Read-only/default:
  --check                  check tools, locked sources and official inputs
  --fetch-sources          explicit network/write: fetch locked sources + patches
  --partition-plan         inspect the xaga GPT plan in recovery (no writes)

Build/install:
  --build-kernel           build the locked GKI tree
  --build-kexec            build static arm64 kexec-tools from locked source
  --build-rootfs           derive Ubuntu minimal tarball from the verified ISO
  --build-aosp-prebuilts   rebuild patched first-stage init and adbd
  --install                pull stock boot images, build initrd, install payload
  --boot-test              same as --install, then perform a kexec Ubuntu test

Destructive (requires paired confirmation):
  --apply-partition --confirm-destroy-userdata
                           rewrite GPT and format userdata/linux in recovery
  --wipe-rootfs --confirm-wipe-rootfs
                           erase linux partition contents and extract ROOTFS_TAR

Required for --wipe-rootfs:
  ROOTFS_TAR=/absolute/path/to/rootfs.tar.gz
  ROOTFS_SHA256=<trusted checksum obtained independently>

No source archive or rootfs is downloaded implicitly.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) ;;
    --fetch-sources) FETCH_SOURCES=1 ;;
    --partition-plan) PARTITION_PLAN=1 ;;
    --apply-partition) APPLY_PARTITION=1 ;;
    --confirm-destroy-userdata) CONFIRM_PARTITION=1 ;;
    --build-kernel) BUILD_KERNEL=1 ;;
    --build-kexec) BUILD_KEXEC=1 ;;
    --build-rootfs) BUILD_ROOTFS=1 ;;
    --build-aosp-prebuilts) BUILD_AOSP_PREBUILTS=1 ;;
    --wipe-rootfs) WIPE_ROOTFS=1 ;;
    --confirm-wipe-rootfs) CONFIRM_ROOTFS=1 ;;
    --install) INSTALL=1 ;;
    --boot-test) BOOT_TEST=1; INSTALL=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

if [ "$APPLY_PARTITION" = 1 ] && [ "$CONFIRM_PARTITION" != 1 ]; then
  echo "--apply-partition requires --confirm-destroy-userdata" >&2
  exit 2
fi
if [ "$WIPE_ROOTFS" = 1 ] && [ "$CONFIRM_ROOTFS" != 1 ]; then
  echo "--wipe-rootfs requires --confirm-wipe-rootfs" >&2
  exit 2
fi
if [ "$APPLY_PARTITION" = 1 ] &&
   { [ "$BUILD_KERNEL" = 1 ] || [ "$BUILD_KEXEC" = 1 ] ||
     [ "$BUILD_ROOTFS" = 1 ] || [ "$WIPE_ROOTFS" = 1 ] ||
     [ "$BUILD_AOSP_PREBUILTS" = 1 ] ||
     [ "$INSTALL" = 1 ]; }; then
  echo "partition apply must run alone; reboot to stock and rerun later stages" >&2
  exit 2
fi

if [ -n "${STOCK_SERIAL:-}" ]; then
  export ANDROID_SERIAL="$STOCK_SERIAL"
fi

verify_xaga_device()
{
  local expected_role="$1" state bootmode product uid
  local -a adb_target=()
  if [ -n "${STOCK_SERIAL:-}" ]; then
    adb_target=(-s "$STOCK_SERIAL")
  fi
  state="$("$ADB" "${adb_target[@]}" get-state 2>/dev/null | tr -d '\r' || true)"
  case "$state" in
    device|recovery) ;;
    *)
      echo "expected a connected adb device, got '${state:-<none>}'" >&2
      exit 1
      ;;
  esac
  bootmode="$("$ADB" "${adb_target[@]}" shell \
    'getprop ro.bootmode 2>/dev/null' | tr -d '\r\n')"
  if [ "$expected_role" = recovery ] && [ "$bootmode" != recovery ]; then
    echo "expected recovery boot mode, got '${bootmode:-<unknown>}'" >&2
    exit 1
  fi
  if [ "$expected_role" = stock ] && [ "$bootmode" = recovery ]; then
    echo "expected stock Android, but the device is in recovery" >&2
    exit 1
  fi
  product="$("$ADB" "${adb_target[@]}" shell \
    'getprop ro.product.device; getprop ro.product.vendor.device' |
    tr -d '\r' | sed '/^$/d' | paste -sd, -)"
  case ",$product," in
    *,xaga,*) ;;
    *)
      [ "${ALLOW_UNVERIFIED_DEVICE:-0}" = 1 ] || {
        echo "refusing unverified device '$product'; this workflow is xaga-only" >&2
        exit 1
      }
      ;;
  esac
  uid="$("$ADB" "${adb_target[@]}" shell \
    'su -c id -u 2>/dev/null || id -u 2>/dev/null' | tr -d '\r\n')"
  [ "$uid" = 0 ] || { echo "root shell (direct or through su) is required" >&2; exit 1; }
}

if [ "$FETCH_SOURCES" = 1 ]; then
  echo "== explicit locked source fetch =="
  bash "$ROOT/scripts/host/fetch_sources.sh" --fetch --apply-patches
else
  echo "== reproduction source/tool check =="
  bash "$ROOT/scripts/host/check_sources.sh"
fi

if [ "$PARTITION_PLAN" = 1 ] || [ "$APPLY_PARTITION" = 1 ]; then
  verify_xaga_device recovery
  if [ "$APPLY_PARTITION" = 1 ]; then
    bash "$ROOT/scripts/host/partition_create_linux_ext4.sh" --apply
    echo "Partitioning complete. Reboot to stock before rootfs/install stages."
    exit 0
  fi
  bash "$ROOT/scripts/host/partition_create_linux_ext4.sh"
fi

if [ "$BUILD_KERNEL" = 1 ]; then
  echo "== build GKI kernel =="
  bash "$ROOT/scripts/host/build_gki_logged.sh"
fi

if [ "$BUILD_KEXEC" = 1 ]; then
  echo "== build static arm64 kexec-tools =="
  bash "$ROOT/scripts/host/build_kexec_tools.sh"
fi

if [ "$BUILD_ROOTFS" = 1 ]; then
  echo "== derive Ubuntu minimal rootfs from locked ISO =="
  bash "$ROOT/scripts/host/build_ubuntu_rootfs.sh" --build
fi

if [ "$BUILD_AOSP_PREBUILTS" = 1 ]; then
  echo "== rebuild patched AOSP prebuilts =="
  bash "$ROOT/scripts/host/build_aosp_prebuilts.sh"
fi

if [ "$WIPE_ROOTFS" = 1 ] || [ "$INSTALL" = 1 ]; then
  verify_xaga_device stock
fi

if [ "$WIPE_ROOTFS" = 1 ]; then
  : "${ROOTFS_TAR:?set ROOTFS_TAR to a trusted Ubuntu arm64 rootfs archive}"
  : "${ROOTFS_SHA256:?set ROOTFS_SHA256 to its independently obtained checksum}"
  [ -f "$ROOTFS_TAR" ] || { echo "missing ROOTFS_TAR: $ROOTFS_TAR" >&2; exit 1; }
  printf '%s  %s\n' "$ROOTFS_SHA256" "$ROOTFS_TAR" | sha256sum -c -
  echo "== destructive Ubuntu rootfs replacement =="
  ROOTFS_TAR="$ROOTFS_TAR" WIPE_UBUNTU=1 \
    bash "$ROOT/scripts/host/install_ubuntu_rootfs.sh"
fi

if [ "$INSTALL" = 1 ]; then
  run_mode=none
  [ "$BOOT_TEST" = 1 ] && run_mode=ubuntu
  echo "== pull stock images, build initrd and install payload =="
  RUN_MODE="$run_mode" INSTALL_UBUNTU=0 MAX="$MAX" \
    bash "$ROOT/scripts/host/full_rebuild_from_device.sh"
fi

if [ "$FETCH_SOURCES" = 0 ] && [ "$PARTITION_PLAN" = 0 ] &&
   [ "$BUILD_KERNEL" = 0 ] && [ "$BUILD_KEXEC" = 0 ] &&
   [ "$BUILD_ROOTFS" = 0 ] && [ "$BUILD_AOSP_PREBUILTS" = 0 ] &&
   [ "$WIPE_ROOTFS" = 0 ] &&
   [ "$INSTALL" = 0 ]; then
  cat <<EOF

No mutation requested. See docs/REPRODUCING.md.
Typical existing-partition flow:
  $0 --build-kexec
  $0 --build-aosp-prebuilts
  $0 --build-kernel
  UBUNTU_ISO=/path/ubuntu-26.04-live-server-arm64.iso $0 --build-rootfs
  ROOTFS_TAR=/path/rootfs.tar.gz ROOTFS_SHA256=<trusted-sha256> \\
    $0 --wipe-rootfs --confirm-wipe-rootfs
  $0 --install --boot-test
EOF
fi
