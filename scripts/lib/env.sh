#!/usr/bin/env bash

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ROOT="${ROOT:-$(cd "$SCRIPT_DIR/.." && pwd)}"

if [ -f "$ROOT/config/env" ]; then
  # shellcheck disable=SC1091
  . "$ROOT/config/env"
fi

WORK_DIR="${WORK_DIR:-$ROOT/work}"
LOCAL_DIR="${LOCAL_DIR:-$ROOT/local}"

AK="${AK:-$ROOT/sources/android-kernel}"
XIAOMI="${XIAOMI:-$ROOT/sources/Xiaomi_Kernel_OpenSource}"
ONEPLUS_SRC="${ONEPLUS_SRC:-$ROOT/sources/android_kernel_5.10_oneplus_mt6895}"
AOSP_DIR="${AOSP_DIR:-$ROOT/sources/android-12.1}"
KEXEC_TOOLS="${KEXEC_TOOLS:-$ROOT/sources/kexec-tools-2.0.28}"
GKI_BOOT_IMAGE="${GKI_BOOT_IMAGE:-$LOCAL_DIR/boot-5.10.img}"

LOG_ROOT="${LOG_ROOT:-$WORK_DIR/logs}"
OUTPUT_DIR="${OUTPUT_DIR:-$WORK_DIR/output}"
VENDOR_DIR="${VENDOR_DIR:-$WORK_DIR/vendor}"
UNPACK_GKI_DIR="${UNPACK_GKI_DIR:-$WORK_DIR/unpack_gki}"
TMP_ROOT="${TMP_ROOT:-$WORK_DIR/tmp}"
BLOCKTAG_BUILD_DIR="${BLOCKTAG_BUILD_DIR:-$TMP_ROOT/blocktag_build}"

ADB="${ADB:-adb.exe}"

mkdir -p "$LOG_ROOT" "$OUTPUT_DIR" "$VENDOR_DIR" "$TMP_ROOT"
