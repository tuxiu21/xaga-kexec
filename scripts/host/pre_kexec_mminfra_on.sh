#!/usr/bin/env bash
# Pin MT6895 mm_infra on in the stock kernel immediately before kexec.
#
# Without this, the first kexec boot can enter the new kernel with mm_infra in
# an off/partial state. The new mtk-scpsys-mt6895 path then hangs when it first
# touches mminfra_config. Use stock genpd/runtime PM instead of raw MMIO.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

SERIAL="${1:-${STOCK_SERIAL:-}}"
if [ -z "$SERIAL" ]; then
  SERIAL="$("$ADB" devices 2>/dev/null | tr -d '\r' | awk 'NR>1 && $2=="device"{print $1; exit}')"
fi
[ -n "$SERIAL" ] || { echo "pre-kexec mminfra: no stock adb serial found" >&2; exit 2; }

remote='
set -eu
mount -t debugfs debugfs /sys/kernel/debug 2>/dev/null || true

pd=/sys/devices/platform/disable_unused/disable_unused:disable-unused-pd-mm_infra
clk=/sys/devices/platform/disable_unused/disable_unused:disable-unused-clk-mminfra_config

if [ ! -e "$pd/power/control" ]; then
	echo "pre-kexec mminfra: missing $pd/power/control" >&2
	exit 20
fi

echo "pre-kexec mminfra: before"
cat /sys/kernel/debug/pm_genpd/mm_infra/current_state 2>/dev/null || true
cat "$pd/power/runtime_status" 2>/dev/null || true
cat "$pd/power/control" 2>/dev/null || true

echo on > "$pd/power/control"

if [ -e "$clk/power/control" ]; then
	echo on > "$clk/power/control" 2>/dev/null || true
fi

sleep 1

state="$(cat /sys/kernel/debug/pm_genpd/mm_infra/current_state 2>/dev/null || true)"
runtime="$(cat "$pd/power/runtime_status" 2>/dev/null || true)"
control="$(cat "$pd/power/control" 2>/dev/null || true)"

echo "pre-kexec mminfra: after"
echo "$state"
echo "$runtime"
echo "$control"

for c in mminfra_smi mminfra_gce_d mminfra_gce_m mminfra_gce_26m; do
	if [ -d "/sys/kernel/debug/clk/$c" ]; then
		printf "%s prepare=" "$c"
		cat "/sys/kernel/debug/clk/$c/clk_prepare_count"
		printf "%s enable=" "$c"
		cat "/sys/kernel/debug/clk/$c/clk_enable_count"
	fi
done

[ "$state" = "on" ] || {
	echo "pre-kexec mminfra: mm_infra state is not on: $state" >&2
	exit 21
}
[ "$runtime" = "active" ] || {
	echo "pre-kexec mminfra: mm_infra runtime is not active: $runtime" >&2
	exit 22
}
'

if [ "$("$ADB" -s "$SERIAL" shell 'id -u 2>/dev/null' | tr -d '\r')" = "0" ]; then
  "$ADB" -s "$SERIAL" shell "$remote"
else
  "$ADB" -s "$SERIAL" shell "su -c '$remote'"
fi
