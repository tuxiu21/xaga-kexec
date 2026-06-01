#!/usr/bin/env bash
# 循环 kexec, 直到 console-ramoops 不再是旧内核 Bye 日志就停。
# 用法:  bash kexec_until_new.sh [initrd] [最大轮数] [normal]
# 例:    bash kexec_until_new.sh combined_ramdisk260530_mt6315_no7.lz4 20
#        bash kexec_until_new.sh combined_ramdisk260530_mt6315_no7_no_devapc.lz4 20 normal
set -u
ADB=adb.exe
INITRD="${1:-combined_ramdisk260530_mt6315_no7.lz4}"
MAX="${2:-20}"
MODE="${3:-reuse}"
OUT="/home/in/work/kernels/kexec_until_new_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$OUT"

say(){ printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$OUT/log.txt"; }

wait_boot(){
  $ADB wait-for-device >/dev/null 2>&1
  for _ in $(seq 1 60); do
    [ "$($ADB shell getprop sys.boot_completed 2>/dev/null | tr -d '\r')" = "1" ] && { sleep 3; return; }
    sleep 2
  done
}

say "initrd=$INITRD max=$MAX mode=$MODE out=$OUT"
for r in $(seq 1 "$MAX"); do
  wait_boot
  # 清旧 pstore
  $ADB shell "su -c 'rm -f /sys/fs/pstore/console-ramoops-0 /sys/fs/pstore/dmesg-ramoops-*'" >/dev/null 2>&1
  say "round $r: kexec"
  if [ "$MODE" = "normal" ]; then
    base_cmdline="$($ADB shell "su -c 'cat /proc/cmdline'" 2>/dev/null | tr -d '\r\n')"
    bootconfig_args="$($ADB shell "su -c 'cat /proc/bootconfig 2>/dev/null'" | tr -d '\r' | awk '
      /^androidboot[.]/ {
        key=$1
        sub(/^[^=]*=[[:space:]]*/, "")
        gsub(/["[:space:]]/, "")
        print key "=" $0
      }' | tr '\n' ' ')"
    normal_args="$bootconfig_args androidboot.force_normal_boot=1 androidboot.mode=normal androidboot.bootmode=normal androidboot.slot_suffix=_a androidboot.hardware=mt6895 androidboot.init_fatal_panic=true androidboot.init_fatal_reboot_target=bootloader loglevel=7 ignore_loglevel printk.devkmsg=on"
    cmdline="$base_cmdline $normal_args"
    printf '%s\n' "$cmdline" > "$OUT/round_${r}_cmdline.txt"
    $ADB shell "su -c 'cd /data/local/tmp && echo 0 > /proc/sys/kernel/kptr_restrict && ./kexec -c -l kernel --initrd=$INITRD --append=\"$cmdline\" && ./kexec -f -e'" >/dev/null 2>&1
  else
    $ADB shell "su -c 'cd /data/local/tmp && echo 0 > /proc/sys/kernel/kptr_restrict && ./kexec -c -l kernel --initrd=$INITRD --reuse-cmdline && ./kexec -f -e'" >/dev/null 2>&1
  fi
  sleep 10
  wait_boot
  f="$OUT/round_${r}_console.txt"
  $ADB shell "su -c 'cat /sys/fs/pstore/console-ramoops-0 2>&1'" > "$f" 2>&1
  if ! grep -q 'Bye!' "$f"; then
    say "round $r: ★ 非旧 Bye 日志 -> $f"
    echo
    echo "================= 命中! 关键行 ================="
    grep -a -nE 'Booting Linux|Linux version|Freeing unused kernel memory|Run /init|init:|first stage|Unable to handle|Internal error|DEVAPC|SPI3|PMIF|VIO_INFO|mt6315|kernel BUG|Call trace|panic|Reason:' "$f" | head -80
    echo "==============================================="
    echo "完整日志: $f"
    exit 0
  fi
  say "round $r: 旧 Bye, 重试"
done
say "跑满 $MAX 轮仍未拿到新内核日志"
exit 1
