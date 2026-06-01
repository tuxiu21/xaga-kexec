#!/usr/bin/env bash
set -euo pipefail

cd /home/in/work/kernels
bash /home/in/work/kernels/scripts/kexec_dropbear_until_new.sh \
  output/combined_ramdisk_kexec_system.lz4 \
  "${1:-20}" \
  "${2:-198.18.0.2}" \
  "${3:-22}"
