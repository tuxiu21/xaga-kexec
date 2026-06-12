#!/usr/bin/env bash
set -euo pipefail

cd /home/in/work/kernels

aarch64-linux-gnu-gcc -static -Os -s \
  -o output/system_kxsh.elf \
  src/system_kxsh.c

aarch64-linux-gnu-gcc -static -Os -s \
  -o output/watchdog_feeder \
  src/watchdog_feeder.c

ls -lh output/system_kxsh.elf output/watchdog_feeder
