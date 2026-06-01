#!/usr/bin/env bash
set -euo pipefail

cd /home/in/work/kernels

aarch64-linux-gnu-gcc -static -Os -s \
  -o output/system_kxsh.elf \
  src/system_kxsh.c

ls -lh output/system_kxsh.elf
