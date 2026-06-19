#!/usr/bin/env bash
# Build the Android GKI kernel while keeping verbose output under work/logs/.
#
# Useful knobs:
#   TAIL_LINES=120 scripts/host/build_gki_logged.sh   # print last N lines at finish
#   FOLLOW=1 scripts/host/build_gki_logged.sh         # stream the log while building

set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

OUT="$LOG_ROOT/gki_build_$(date +%Y%m%d_%H%M%S)"
LOG="$OUT/build.log"
STATUS="$OUT/status.txt"
TAIL_LINES="${TAIL_LINES:-40}"
FOLLOW="${FOLLOW:-0}"

mkdir -p "$OUT"

say() {
  printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$STATUS"
}

if [ ! -d "$AK" ]; then
  say "android-kernel tree not found: $AK"
  exit 2
fi

say "kernel tree: $AK"
say "log: $LOG"
say "status: $STATUS"

cat > "$OUT/env.txt" <<EOF
KMI_SYMBOL_LIST_STRICT_MODE=0
CCACHE_DIR=$AK/.ccache
CCACHE_BASEDIR=$AK
CCACHE_COMPILERCHECK=content
CCACHE_NOHASHDIR=true
CCACHE_PATH=$AK/prebuilts-master/clang/host/linux-x86/clang-r416183b/bin
LTO=thin
BUILD_CONFIG=common/build.config.gki.aarch64
BUILD_CONFIG_FRAGMENTS=build.config.ccache common/build.config.docker
EOF

say "build started"
(
  cd "$AK" || exit 2
  KMI_SYMBOL_LIST_STRICT_MODE=0 \
  CCACHE_DIR="$AK/.ccache" \
  CCACHE_BASEDIR="$AK" \
  CCACHE_COMPILERCHECK=content \
  CCACHE_NOHASHDIR=true \
  CCACHE_PATH="$AK/prebuilts-master/clang/host/linux-x86/clang-r416183b/bin" \
  LTO=thin \
  BUILD_CONFIG=common/build.config.gki.aarch64 \
  BUILD_CONFIG_FRAGMENTS="build.config.ccache common/build.config.docker" \
  build/build.sh
) >"$LOG" 2>&1 &

build_pid=$!
tail_pid=

if [ "$FOLLOW" = "1" ]; then
  tail -n "${TAIL_LINES}" -f "$LOG" &
  tail_pid=$!
fi

while kill -0 "$build_pid" 2>/dev/null; do
  sleep 30
  say "build still running; inspect with: tail -n ${TAIL_LINES} '$LOG'"
done

wait "$build_pid"
rc=$?

if [ -n "$tail_pid" ]; then
  kill "$tail_pid" 2>/dev/null || true
  wait "$tail_pid" 2>/dev/null || true
fi

if [ "$rc" -eq 0 ]; then
  say "build succeeded"
else
  say "build failed rc=$rc"
fi

if [ "${TAIL_LINES}" -gt 0 ] 2>/dev/null; then
  say "last ${TAIL_LINES} log lines:"
  tail -n "$TAIL_LINES" "$LOG" | tee "$OUT/tail.txt"
fi

say "full log: $LOG"
exit "$rc"
