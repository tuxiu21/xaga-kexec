#!/usr/bin/env bash
set -euo pipefail

ROOT="/home/in/work/kernels"

aarch64-linux-gnu-gcc -static -Os -s \
  -o "$ROOT/output/system_kxsh.elf" \
  "$ROOT/src/system_kxsh.c"

adb.exe push "$ROOT/output/system_kxsh.elf" /data/local/tmp/kxsh.elf
adb.exe shell "su -c 'mount -o rw,remount /'"
adb.exe shell "su -c 'cp /data/local/tmp/kxsh.elf /system/bin/kxsh'"
adb.exe shell "su -c 'chown root:shell /system/bin/kxsh'"
adb.exe shell "su -c 'chmod 0755 /system/bin/kxsh'"
adb.exe shell "su -c 'chcon u:object_r:shell_exec:s0 /system/bin/kxsh 2>/dev/null || true'"

adb.exe shell "su -c 'mkdir -p /data/kexec /data/kexec/root/.ssh /data/kexec/run'"
adb.exe push "$ROOT/prebuilt/busybox" /data/local/tmp/busybox.kexec
adb.exe push "$ROOT/prebuilt/dropbear" /data/local/tmp/dropbear
adb.exe push "$ROOT/prebuilt/dropbearkey" /data/local/tmp/dropbearkey
adb.exe push "$ROOT/src/kxsh.sh" /data/local/tmp/kxsh.sh

adb.exe shell "su -c 'cp /data/local/tmp/busybox.kexec /data/kexec/busybox'"
adb.exe shell "su -c 'cp /data/local/tmp/dropbear /data/kexec/dropbear'"
adb.exe shell "su -c 'cp /data/local/tmp/dropbearkey /data/kexec/dropbearkey'"
adb.exe shell "su -c 'cp /data/local/tmp/kxsh.sh /data/kexec/kxsh.sh'"
adb.exe shell "su -c 'chmod 0755 /data/kexec/busybox /data/kexec/dropbear /data/kexec/dropbearkey /data/kexec/kxsh.sh'"
adb.exe shell "su -c '/data/kexec/busybox ln -sf /data/kexec/busybox /data/kexec/sh'"

adb.exe shell "su -c 'printf \"root::0:0:root:/data/kexec/root:/data/kexec/sh\n\" > /data/kexec/passwd'"
adb.exe shell "su -c 'printf \"root:x:0:\n\" > /data/kexec/group'"
adb.exe shell "su -c 'printf \"root::10933:0:99999:7:::\n\" > /data/kexec/shadow'"
adb.exe shell "su -c 'cp /data/kexec/authorized_keys /data/kexec/root/.ssh/authorized_keys 2>/dev/null || true'"
adb.exe shell "su -c 'chmod 700 /data/kexec/root /data/kexec/root/.ssh'"
adb.exe shell "su -c 'chmod 600 /data/kexec/root/.ssh/authorized_keys /data/kexec/shadow 2>/dev/null || true'"
adb.exe shell "su -c 'chmod 644 /data/kexec/passwd /data/kexec/group'"
adb.exe shell "su -c 'echo 180 > /data/kexec/panic_after'"
adb.exe shell "su -c 'sync; ls -lZ /system/bin/kxsh; ls -l /data/kexec'"
