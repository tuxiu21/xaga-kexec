#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/env.sh"

"$ROOT/scripts/install_kexec_payload.sh"

aarch64-linux-gnu-gcc -static -Os -s \
  -o "$OUTPUT_DIR/system_kxsh.elf" \
  "$ROOT/src/system_kxsh.c"

aarch64-linux-gnu-gcc -static -Os -s \
  -o "$OUTPUT_DIR/watchdog_feeder" \
  "$ROOT/src/watchdog_feeder.c"

"$ADB" push "$OUTPUT_DIR/system_kxsh.elf" /data/local/tmp/kxsh.elf
"$ADB" shell "su -c 'mount -o rw,remount /'"
"$ADB" shell "su -c 'cp /data/local/tmp/kxsh.elf /system/bin/kxsh'"
"$ADB" shell "su -c 'chown root:shell /system/bin/kxsh'"
"$ADB" shell "su -c 'chmod 0755 /system/bin/kxsh'"
"$ADB" shell "su -c 'chcon u:object_r:shell_exec:s0 /system/bin/kxsh 2>/dev/null || true'"

"$ADB" shell "su -c 'mkdir -p /data/kexec /data/kexec/root/.ssh /data/kexec/run'"
"$ADB" push "$ROOT/prebuilt/busybox" /data/local/tmp/busybox.kexec
"$ADB" push "$ROOT/prebuilt/dropbear" /data/local/tmp/dropbear
"$ADB" push "$ROOT/prebuilt/dropbearkey" /data/local/tmp/dropbearkey
"$ADB" push "$OUTPUT_DIR/watchdog_feeder" /data/local/tmp/watchdog_feeder
"$ADB" push "$ROOT/src/kxsh.sh" /data/local/tmp/kxsh.sh
"$ADB" push "$ROOT/scripts/wifi_bringup.sh" /data/local/tmp/wifi_bringup.sh
"$ADB" push "$ROOT/scripts/enter_ubuntu.sh" /data/local/tmp/enter-ubuntu.sh

"$ADB" shell "su -c 'cp /data/local/tmp/busybox.kexec /data/kexec/busybox'"
"$ADB" shell "su -c 'cp /data/local/tmp/dropbear /data/kexec/dropbear'"
"$ADB" shell "su -c 'cp /data/local/tmp/dropbearkey /data/kexec/dropbearkey'"
"$ADB" shell "su -c 'cp /data/local/tmp/watchdog_feeder /data/kexec/watchdog_feeder'"
"$ADB" shell "su -c 'cp /data/local/tmp/kxsh.sh /data/kexec/kxsh.sh'"
"$ADB" shell "su -c 'cp /data/local/tmp/wifi_bringup.sh /data/kexec/wifi_bringup.sh'"
"$ADB" shell "su -c 'cp /data/local/tmp/enter-ubuntu.sh /data/kexec/enter-ubuntu.sh'"
"$ADB" shell "su -c 'chmod 0755 /data/kexec/busybox /data/kexec/dropbear /data/kexec/dropbearkey /data/kexec/watchdog_feeder /data/kexec/kxsh.sh /data/kexec/wifi_bringup.sh /data/kexec/enter-ubuntu.sh'"
"$ADB" shell "su -c '/data/kexec/busybox ln -sf /data/kexec/enter-ubuntu.sh /data/kexec/enter_ubuntu.sh'"
"$ADB" shell "su -c '/data/kexec/busybox ln -sf /data/kexec/busybox /data/kexec/sh'"

"$ROOT/scripts/install_adbd.sh"

"$ADB" shell "su -c 'printf \"root::0:0:root:/data/kexec/root:/data/kexec/sh\n\" > /data/kexec/passwd'"
"$ADB" shell "su -c 'printf \"root:x:0:\n\" > /data/kexec/group'"
"$ADB" shell "su -c 'printf \"root::10933:0:99999:7:::\n\" > /data/kexec/shadow'"
"$ADB" shell "su -c 'cp /data/kexec/authorized_keys /data/kexec/root/.ssh/authorized_keys 2>/dev/null || true'"
"$ADB" shell "su -c 'chmod 700 /data/kexec/root /data/kexec/root/.ssh'"
"$ADB" shell "su -c 'chmod 600 /data/kexec/root/.ssh/authorized_keys /data/kexec/shadow 2>/dev/null || true'"
"$ADB" shell "su -c 'chmod 644 /data/kexec/passwd /data/kexec/group'"
"$ADB" shell "su -c 'echo 180 > /data/kexec/panic_after'"
"$ADB" shell "su -c 'sync; ls -lZ /system/bin/kxsh; ls -l /data/kexec'"
