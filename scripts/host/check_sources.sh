#!/usr/bin/env bash
# Print the source-tree status needed to reproduce this workspace.

set -u

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

show_git()
{
  local label="$1"
  local path="$2"

  printf '\n[%s]\n' "$label"
  if [ ! -d "$path" ]; then
    echo "missing: $path"
    return
  fi

  echo "path: $path"
  if git -C "$path" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    local branch
    git -C "$path" remote -v 2>/dev/null | sed 's/^/remote: /' | head -4
    branch="$(git -C "$path" branch --show-current 2>/dev/null || true)"
    printf 'branch: %s\n' "${branch:-<detached>}"
    printf 'head: '
    git -C "$path" rev-parse --short HEAD 2>/dev/null || true
  else
    echo "not a git checkout"
  fi
}

show_git "GKI manifest" "$AK/.repo/manifests"
show_git "GKI common" "$AK/common"
show_git "GKI build" "$AK/build"
show_git "Xiaomi xaga source" "$XIAOMI"
show_git "OnePlus MTK source" "$ONEPLUS_SRC"
show_git "AOSP platform manifest" "$AOSP_DIR/.repo/manifests"
show_git "AOSP adbd" "$AOSP_DIR/packages/modules/adb"

printf '\n[Build outputs]\n'
for path in \
  "$AK/out/android12-5.10/dist/Image" \
  "$AK/out/android12-5.10/common" \
  "$KEXEC_TOOLS/build/sbin/kexec" \
  "$GKI_BOOT_IMAGE" \
  "$UNPACK_GKI_DIR/ramdisk" \
  "$BLOCKTAG_BUILD_DIR/blocktag.ko" \
  "$OUTPUT_DIR/combined_ramdisk_kexec_system_mbox.lz4"; do
  if [ -e "$path" ]; then
    ls -ld "$path"
  else
    echo "missing: $path"
  fi
done
