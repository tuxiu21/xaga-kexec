#!/usr/bin/env bash
# Build the Android GKI kernel while keeping verbose output under work/logs/.
#
# Useful knobs:
#   KERNEL_PROFILE=stock scripts/host/build_gki_logged.sh
#   KERNEL_PROFILE=ubuntu scripts/host/build_gki_logged.sh
#   TAIL_LINES=120 scripts/host/build_gki_logged.sh   # print last N lines at finish
#   FOLLOW=1 scripts/host/build_gki_logged.sh         # stream the log while building
#   KASAN_INLINE_ONLY=1 scripts/host/build_gki_logged.sh
#       # switch KASAN to generic inline mode without changing LTO/CFI/SCS
#   CHECK_CONFIG_ONLY=1 scripts/host/build_gki_logged.sh
#       # generate/check final .config in this log directory without touching the main out dir
#   REQUIRED_KERNEL_CONFIGS='CONFIG_DEVTMPFS=y !CONFIG_KASAN_HW_TAGS'
#       # extra config assertions, checked after build/config generation
#   COPY_DIST_ARTIFACTS=1 scripts/host/build_gki_logged.sh
#       # copy Image/Image.lz4/System.map/vmlinux into the log directory

set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

TAIL_LINES="${TAIL_LINES:-40}"
FOLLOW="${FOLLOW:-0}"
KASAN_INLINE_ONLY="${KASAN_INLINE_ONLY:-0}"
CHECK_CONFIG_ONLY="${CHECK_CONFIG_ONLY:-0}"
REQUIRED_KERNEL_CONFIGS="${REQUIRED_KERNEL_CONFIGS:-}"
COPY_DIST_ARTIFACTS="${COPY_DIST_ARTIFACTS:-0}"
KERNEL_PROFILE="${KERNEL_PROFILE:-ubuntu}"
case "$KERNEL_PROFILE" in
  stock)
    KERNEL_DIR_VALUE="common-stock"
    DEFAULT_BUILD_CONFIG_FRAGMENTS="build.config.ccache"
    KERNEL_OUT_DIR="$KERNEL_STOCK_OUT"
    KERNEL_DIST_DIR="$KERNEL_STOCK_DIST"
    PROFILE_REQUIRED_CONFIGS="CONFIG_KSU=y !CONFIG_DEVTMPFS !CONFIG_NF_TABLES"
    ;;
  ubuntu)
    KERNEL_DIR_VALUE="common-ubuntu"
    DEFAULT_BUILD_CONFIG_FRAGMENTS="build.config.ccache common-ubuntu/build.config.docker"
    KERNEL_OUT_DIR="$KERNEL_UBUNTU_OUT"
    KERNEL_DIST_DIR="$KERNEL_UBUNTU_DIST"
    PROFILE_REQUIRED_CONFIGS="!CONFIG_KSU CONFIG_DEVTMPFS=y CONFIG_NF_TABLES=y"
    ;;
  *)
    echo "invalid KERNEL_PROFILE: $KERNEL_PROFILE (expected stock or ubuntu)" >&2
    exit 2
    ;;
esac
OUT="$LOG_ROOT/gki_${KERNEL_PROFILE}_build_$(date +%Y%m%d_%H%M%S)"
LOG="$OUT/build.log"
STATUS="$OUT/status.txt"
BUILD_CONFIG_VALUE="$KERNEL_DIR_VALUE/build.config.gki.aarch64"
BUILD_CONFIG_FRAGMENTS_VALUE="${BUILD_CONFIG_FRAGMENTS:-$DEFAULT_BUILD_CONFIG_FRAGMENTS}"
USER_GKI_DEFCONFIG_FRAGMENT="${GKI_DEFCONFIG_FRAGMENT:-}"
GKI_DEFCONFIG_FRAGMENT_VALUE="$USER_GKI_DEFCONFIG_FRAGMENT"

mkdir -p "$OUT"

if [ "$KASAN_INLINE_ONLY" = "1" ]; then
  if [ -n "$USER_GKI_DEFCONFIG_FRAGMENT" ]; then
    GKI_DEFCONFIG_FRAGMENT_VALUE="$OUT/gki_defconfig_fragment.kasan_inline_only"
cat > "$GKI_DEFCONFIG_FRAGMENT_VALUE" <<EOF
source "$USER_GKI_DEFCONFIG_FRAGMENT"
source $KERNEL_DIR_VALUE/build.config.kasan_inline_only
EOF
  else
    GKI_DEFCONFIG_FRAGMENT_VALUE="$KERNEL_DIR_VALUE/build.config.kasan_inline_only"
  fi
fi
if [ "$CHECK_CONFIG_ONLY" = "1" ]; then
  BUILD_CONFIG_FRAGMENTS_VALUE="$BUILD_CONFIG_FRAGMENTS_VALUE $KERNEL_DIR_VALUE/build.config.config_only"
  KERNEL_OUT_DIR="$OUT/config-out"
  KERNEL_DIST_DIR="$OUT/config-dist"
fi
KERNEL_CONFIG_PATH="$KERNEL_OUT_DIR/$KERNEL_DIR_VALUE/.config"

say() {
  printf '%s %s\n' "$(date +%H:%M:%S)" "$*" | tee -a "$STATUS"
}

require_config() {
  local want="$1"
  local key value

  case "$want" in
    !CONFIG_*)
      key="${want#!}"
      if grep -q "^${key}=y$" "$KERNEL_CONFIG_PATH"; then
        say "config check failed: expected $key to be unset"
        return 1
      fi
      if grep -q "^# ${key} is not set$" "$KERNEL_CONFIG_PATH"; then
        say "config check ok: $want"
        return 0
      fi
      say "config check failed: $key is neither unset marker nor absent from .config"
      return 1
      ;;
    CONFIG_*=*)
      key="${want%%=*}"
      value="${want#*=}"
      if grep -q "^${key}=${value}$" "$KERNEL_CONFIG_PATH"; then
        say "config check ok: $want"
        return 0
      fi
      say "config check failed: expected $want"
      grep -n -E "^(${key}=|# ${key} is not set$)" "$KERNEL_CONFIG_PATH" | tee -a "$STATUS" || true
      return 1
      ;;
    *)
      say "config check failed: unsupported assertion '$want'"
      return 1
      ;;
  esac
}

check_kernel_config() {
  local rc=0
  local checks="$REQUIRED_KERNEL_CONFIGS"

  say "config summary:"
  grep -n -E '^(CONFIG_KASAN|# CONFIG_KASAN|CONFIG_DEVTMPFS|# CONFIG_DEVTMPFS|CONFIG_KFENCE|# CONFIG_KFENCE|CONFIG_LTO|# CONFIG_LTO|CONFIG_CFI|# CONFIG_CFI|CONFIG_SHADOW_CALL_STACK|# CONFIG_SHADOW_CALL_STACK|CONFIG_KCOV|# CONFIG_KCOV)' \
    "$KERNEL_CONFIG_PATH" | tee "$OUT/config-summary.txt" || true

  for check in $checks; do
    require_config "$check" || rc=1
  done

  return "$rc"
}

snapshot_build_outputs() {
  local out_dir
  local dist_dir="$KERNEL_DIST_DIR"
  local artifact

  out_dir="$(dirname "$KERNEL_CONFIG_PATH")"

  if [ -f "$out_dir/.config" ]; then
    cp -p "$out_dir/.config" "$OUT/final.config"
    say "saved final config: $OUT/final.config"
  fi

  {
    echo "dist_dir=$dist_dir"
    for artifact in Image Image.lz4 System.map vmlinux modules.builtin modules.builtin.modinfo vmlinux.symvers .config; do
      if [ -f "$dist_dir/$artifact" ]; then
        ls -lh "$dist_dir/$artifact"
        sha256sum "$dist_dir/$artifact"
      fi
    done
  } > "$OUT/dist-artifacts.txt"
  say "saved artifact manifest: $OUT/dist-artifacts.txt"

  if [ "$COPY_DIST_ARTIFACTS" = "1" ]; then
    mkdir -p "$OUT/dist"
    for artifact in Image Image.lz4 System.map vmlinux modules.builtin modules.builtin.modinfo vmlinux.symvers .config; do
      if [ -f "$dist_dir/$artifact" ]; then
        cp -p "$dist_dir/$artifact" "$OUT/dist/$artifact"
      fi
    done
    say "copied dist artifacts: $OUT/dist"
  fi
}

if [ ! -d "$AK" ]; then
  say "android-kernel tree not found: $AK"
  exit 2
fi
if [ ! -d "$AK/$KERNEL_DIR_VALUE" ]; then
  say "missing $KERNEL_PROFILE kernel worktree: $AK/$KERNEL_DIR_VALUE"
  say "run ./xaga prepare to create the locked profile worktrees"
  exit 2
fi

say "kernel profile: $KERNEL_PROFILE"
say "kernel tree: $AK/$KERNEL_DIR_VALUE"
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
KERNEL_PROFILE=$KERNEL_PROFILE
BUILD_CONFIG=$BUILD_CONFIG_VALUE
BUILD_CONFIG_FRAGMENTS=$BUILD_CONFIG_FRAGMENTS_VALUE
OUT_DIR=$KERNEL_OUT_DIR
DIST_DIR=$KERNEL_DIST_DIR
KASAN_INLINE_ONLY=$KASAN_INLINE_ONLY
GKI_DEFCONFIG_FRAGMENT=$GKI_DEFCONFIG_FRAGMENT_VALUE
CHECK_CONFIG_ONLY=$CHECK_CONFIG_ONLY
REQUIRED_KERNEL_CONFIGS=$REQUIRED_KERNEL_CONFIGS
PROFILE_REQUIRED_CONFIGS=$PROFILE_REQUIRED_CONFIGS
COPY_DIST_ARTIFACTS=$COPY_DIST_ARTIFACTS
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
  BUILD_CONFIG="$BUILD_CONFIG_VALUE" \
  BUILD_CONFIG_FRAGMENTS="$BUILD_CONFIG_FRAGMENTS_VALUE" \
  OUT_DIR="$KERNEL_OUT_DIR" \
  DIST_DIR="$KERNEL_DIST_DIR" \
  GKI_DEFCONFIG_FRAGMENT="$GKI_DEFCONFIG_FRAGMENT_VALUE" \
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

if [ "$rc" -eq 0 ]; then
  REQUIRED_KERNEL_CONFIGS="$PROFILE_REQUIRED_CONFIGS $REQUIRED_KERNEL_CONFIGS"
  check_kernel_config || rc=1
fi

if [ "$rc" -eq 0 ]; then
  snapshot_build_outputs
fi

say "full log: $LOG"
exit "$rc"
