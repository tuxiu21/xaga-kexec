#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/env.sh"

PANIC_AFTER="${PANIC_AFTER:-300}"

"$ADB" wait-for-device
"$ADB" shell "su -c 'rm -f /data/local/tmp/kxsh.sh /data/local/tmp/wifi_bringup.sh'"
"$ADB" push "$ROOT/src/kxsh.sh" /data/local/tmp/kxsh.sh
"$ADB" push "$ROOT/scripts/wifi_bringup.sh" /data/local/tmp/wifi_bringup.sh
"$ADB" shell "su -c 'mkdir -p /data/kexec; cp /data/local/tmp/kxsh.sh /data/kexec/kxsh.sh; cp /data/local/tmp/wifi_bringup.sh /data/kexec/wifi_bringup.sh; chmod 0755 /data/kexec/kxsh.sh /data/kexec/wifi_bringup.sh; rm -f /data/kexec/wifi_bringup.log /data/kexec/wifi_load_progress.txt; echo $PANIC_AFTER > /data/kexec/panic_after; touch /data/kexec/run_wifi_probe; sync; ls -l /data/kexec/kxsh.sh /data/kexec/wifi_bringup.sh /data/kexec/run_wifi_probe /data/kexec/panic_after'"
