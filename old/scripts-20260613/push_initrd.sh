#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/in/work/kernels"
adb.exe push "$ROOT/output/combined_ramdisk_kexec_system.lz4" \
  /data/local/tmp/combined_ramdisk_kexec_system.lz4
adb.exe shell "su -c 'sync; ls -l /data/local/tmp/combined_ramdisk_kexec_system.lz4'"
