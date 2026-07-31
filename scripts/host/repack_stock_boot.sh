#!/usr/bin/env bash
# Repack the active stock boot image with the isolated xaga stock kernel.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

MODE="${STOCK_BOOT_MODE:-plan}"
CONFIRM="${STOCK_BOOT_CONFIRM:-0}"
STOCK_SERIAL="${STOCK_SERIAL:-}"
KERNEL_IMAGE="${KERNEL_IMAGE:-$KERNEL_STOCK_DIST/Image}"
KERNEL_CONFIG="${KERNEL_CONFIG:-$KERNEL_STOCK_OUT/common-stock/.config}"
STOCK_BOOT_OUTPUT="${STOCK_BOOT_OUTPUT:-}"

say()
{
  printf '%s %s\n' "$(date +%H:%M:%S)" "$*"
}

detect_stock_serial()
{
  local candidate count

  [ -n "$STOCK_SERIAL" ] && return 0
  candidate="$("$ADB" devices 2>/dev/null | tr -d '\r' |
    awk 'NR>1 && $2=="device"{print $1}')"
  count="$(printf '%s\n' "$candidate" | sed '/^$/d' | wc -l)"
  [ "$count" = 1 ] || {
    echo "expected exactly one ready ADB device; pass --serial" >&2
    return 1
  }
  STOCK_SERIAL="$candidate"
}

adb_device()
{
  "$ADB" -s "$STOCK_SERIAL" "$@"
}

adb_root_shell()
{
  local script="$1"

  if [ "$(adb_device shell 'id -u 2>/dev/null' | tr -d '\r')" = 0 ]; then
    adb_device shell "$script"
  else
    adb_device shell "su -c '$script'"
  fi
}

case "$MODE" in
  plan|apply) ;;
  *) echo "STOCK_BOOT_MODE must be plan or apply" >&2; exit 2 ;;
esac
[ "$MODE" != apply ] || [ "$CONFIRM" = 1 ] || {
  echo "apply requires STOCK_BOOT_CONFIRM=1" >&2
  exit 2
}

for path in "$KERNEL_IMAGE" "$KERNEL_CONFIG"; do
  [ -s "$path" ] || {
    echo "missing stock kernel artifact: $path" >&2
    echo "run ./xaga build kernel stock first" >&2
    exit 1
  }
done

grep -qx 'CONFIG_KSU=y' "$KERNEL_CONFIG" || {
  echo "refusing stock repack: CONFIG_KSU=y is absent" >&2
  exit 1
}
grep -qx '# CONFIG_NF_TABLES is not set' "$KERNEL_CONFIG" || {
  echo "refusing stock repack: NF_TABLES is enabled" >&2
  exit 1
}
grep -qx '# CONFIG_DEVTMPFS is not set' "$KERNEL_CONFIG" || {
  echo "refusing stock repack: DEVTMPFS is enabled" >&2
  exit 1
}

detect_stock_serial
product="$(adb_device shell getprop ro.product.device | tr -d '\r\n')"
[ "$product" = xaga ] || {
  echo "refusing non-xaga device: ${product:-unknown}" >&2
  exit 1
}

slot="$(adb_device shell getprop ro.boot.slot_suffix | tr -d '\r\n')"
case "$slot" in
  _a|_b) ;;
  *) echo "invalid active slot from device: ${slot:-empty}" >&2; exit 1 ;;
esac

part="/dev/block/by-name/boot${slot}"
partition_bytes="$(adb_root_shell "blockdev --getsize64 $part" | tr -d '\r\n')"
case "$partition_bytes" in
  ''|*[!0-9]*) echo "cannot read size of $part" >&2; exit 1 ;;
esac

stamp="$(date +%Y%m%d_%H%M%S)"
backup_dir="$BACKUP_ROOT/stock-kernel/$stamp"
mkdir -p "$backup_dir" "$OUTPUT_DIR"
original="$backup_dir/boot${slot}.img"
remote_original="/data/local/tmp/xaga-boot${slot}-original.img"

say "pulling active $part ($partition_bytes bytes)"
adb_root_shell "dd if=$part of=$remote_original bs=4M; chmod 0644 $remote_original; sync"
adb_device pull "$remote_original" "$original"
adb_root_shell "rm -f $remote_original"

original_bytes="$(stat -c %s "$original")"
[ "$original_bytes" = "$partition_bytes" ] || {
  echo "active boot backup size mismatch: image=$original_bytes partition=$partition_bytes" >&2
  exit 1
}

work="$(mktemp -d "$TMP_ROOT/stock-boot.XXXXXX")"
cleanup()
{
  rm -rf "$work"
}
trap cleanup EXIT

cp "$original" "$work/boot.img"
(
  cd "$work"
  magiskboot unpack -h boot.img
)
[ -s "$work/kernel" ] || {
  echo "magiskboot did not extract the stock kernel" >&2
  exit 1
}

original_kernel_sha="$(sha256sum "$work/kernel" | awk '{print $1}')"
new_kernel_sha="$(sha256sum "$KERNEL_IMAGE" | awk '{print $1}')"
cp "$KERNEL_IMAGE" "$work/kernel"
(
  cd "$work"
  magiskboot repack boot.img repacked.img
)

repacked="$work/repacked.img"
[ -s "$repacked" ] || {
  echo "magiskboot did not create repacked.img" >&2
  exit 1
}
repacked_bytes="$(stat -c %s "$repacked")"
[ "$repacked_bytes" = "$partition_bytes" ] || {
  echo "refusing partial boot image: repacked=$repacked_bytes partition=$partition_bytes" >&2
  exit 1
}

mkdir "$work/verify"
cp "$repacked" "$work/verify/boot.img"
(
  cd "$work/verify"
  magiskboot unpack boot.img
)
verified_kernel_sha="$(sha256sum "$work/verify/kernel" | awk '{print $1}')"
[ "$verified_kernel_sha" = "$new_kernel_sha" ] || {
  echo "repacked kernel hash mismatch" >&2
  exit 1
}

if [ -z "$STOCK_BOOT_OUTPUT" ]; then
  STOCK_BOOT_OUTPUT="$OUTPUT_DIR/xaga-stock-boot${slot}.img"
fi
cp "$repacked" "$STOCK_BOOT_OUTPUT"
image_sha="$(sha256sum "$STOCK_BOOT_OUTPUT" | awk '{print $1}')"
verified_state="$(adb_device shell getprop ro.boot.verifiedbootstate | tr -d '\r\n')"

{
  printf 'device=%s\n' "$product"
  printf 'serial=%s\n' "$STOCK_SERIAL"
  printf 'slot=%s\n' "$slot"
  printf 'partition=%s\n' "$part"
  printf 'partition_bytes=%s\n' "$partition_bytes"
  printf 'verified_boot_state=%s\n' "$verified_state"
  printf 'original_boot=%s\n' "$original"
  printf 'original_boot_sha256=%s\n' "$(sha256sum "$original" | awk '{print $1}')"
  printf 'original_kernel_sha256=%s\n' "$original_kernel_sha"
  printf 'stock_kernel=%s\n' "$KERNEL_IMAGE"
  printf 'stock_kernel_sha256=%s\n' "$new_kernel_sha"
  printf 'repacked_boot=%s\n' "$STOCK_BOOT_OUTPUT"
  printf 'repacked_boot_sha256=%s\n' "$image_sha"
} > "$backup_dir/manifest.txt"

say "verified stock boot image: $STOCK_BOOT_OUTPUT"
say "original backup: $original"
say "original kernel sha256: $original_kernel_sha"
say "new kernel sha256: $new_kernel_sha"
say "repacked boot sha256: $image_sha"

if [ "$MODE" = plan ]; then
  say "plan complete; no partition was written"
  exit 0
fi

[ "$verified_state" = orange ] || {
  echo "refusing active-slot write: verified boot state is '$verified_state', expected orange" >&2
  exit 1
}

remote_repacked="/data/local/tmp/xaga-stock-boot${slot}.img"
say "uploading verified image for active-slot write"
adb_device push "$STOCK_BOOT_OUTPUT" "$remote_repacked"
remote_sha="$(adb_root_shell "sha256sum $remote_repacked" | awk '{print $1}' | tr -d '\r')"
[ "$remote_sha" = "$image_sha" ] || {
  echo "uploaded image hash mismatch" >&2
  exit 1
}

say "writing $part; the device will not reboot automatically"
adb_root_shell "dd if=$remote_repacked of=$part bs=4M; sync"
readback_sha="$(adb_root_shell "sha256sum $part" | awk '{print $1}' | tr -d '\r')"
adb_root_shell "rm -f $remote_repacked"
[ "$readback_sha" = "$image_sha" ] || {
  echo "FATAL: boot partition readback mismatch: $readback_sha" >&2
  echo "restore immediately from $original" >&2
  exit 1
}

say "active $part readback verified: $readback_sha"
say "flash complete; reboot remains a separate explicit action"
