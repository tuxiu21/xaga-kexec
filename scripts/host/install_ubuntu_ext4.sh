#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

IMAGE="${IMAGE:-$WORK_DIR/rootfs/ubuntu.ext4}"
SKIP_IMAGE="${SKIP_IMAGE:-0}"

if [ "$SKIP_IMAGE" != 1 ] && [ ! -s "$IMAGE" ]; then
  echo "missing ext4 image: $IMAGE" >&2
  echo "build it with scripts/host/build_ubuntu_ext4.sh" >&2
  exit 1
fi

aarch64-linux-gnu-gcc -static -Os -s \
  -o "$OUTPUT_DIR/boot_ubuntu_ext4" \
  "$ROOT/src/boot_ubuntu_ext4.c"

"$ADB" shell "su -c 'mkdir -p /data/kexec'"
if [ "$SKIP_IMAGE" = 1 ]; then
  echo "SKIP_IMAGE=1: leaving existing /data/kexec/ubuntu.ext4 in place"
else
  "$ADB" push "$IMAGE" /data/local/tmp/ubuntu.ext4
  "$ADB" shell "su -c 'cp /data/local/tmp/ubuntu.ext4 /data/kexec/ubuntu.ext4'"
  "$ADB" shell "su -c 'chmod 0644 /data/kexec/ubuntu.ext4'"
fi
"$ADB" push "$OUTPUT_DIR/boot_ubuntu_ext4" /data/local/tmp/boot_ubuntu_ext4
"$ADB" push "$ROOT/scripts/device/ubuntu_phase_a_init.sh" /data/local/tmp/ubuntu_phase_a_init.sh
"$ADB" shell "su -c 'cp /data/local/tmp/boot_ubuntu_ext4 /data/kexec/boot_ubuntu_ext4'"
"$ADB" shell "su -c 'cp /data/local/tmp/ubuntu_phase_a_init.sh /data/kexec/ubuntu_phase_a_init.sh'"
"$ADB" shell "su -c 'chmod 0755 /data/kexec/boot_ubuntu_ext4 /data/kexec/ubuntu_phase_a_init.sh; sync'"
"$ADB" shell "su -c 'ls -lh /data/kexec/ubuntu.ext4 /data/kexec/boot_ubuntu_ext4 /data/kexec/ubuntu_phase_a_init.sh'"
