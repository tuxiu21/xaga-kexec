#!/usr/bin/env bash
# Restore the sdc GPT areas from a backup directory made before repartitioning.
#
# Default is dry-run. Pass --apply to write the saved head/tail images.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

DEVICE="${DEVICE:-/dev/block/sdc}"
APPLY=0

usage()
{
  cat <<EOF
Usage: $0 BACKUP_DIR [--apply]

BACKUP_DIR must contain:
  sdc-head-64M.img
  sdc-tail-64M.img

Without --apply, prints what would be restored.
With --apply, writes the saved GPT head/tail back to $DEVICE.
This restores the old partition table only; it does not restore userdata data.
EOF
}

if [ "$#" -lt 1 ]; then
  usage >&2
  exit 2
fi

BACKUP_DIR="$1"
shift

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=1
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "unknown argument: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
  shift
done

HEAD="$BACKUP_DIR/sdc-head-64M.img"
TAIL="$BACKUP_DIR/sdc-tail-64M.img"

if [ ! -s "$HEAD" ] || [ ! -s "$TAIL" ]; then
  echo "missing backup images in $BACKUP_DIR" >&2
  exit 1
fi

state="$("$ADB" get-state 2>/dev/null | tr -d '\r' || true)"
if [ "$state" != "recovery" ]; then
  echo "device is not in adb recovery state: ${state:-<offline>}" >&2
  exit 1
fi

device_bytes="$("$ADB" shell "blockdev --getsize64 $DEVICE" | tr -d '\r\n')"
tail_bytes="$(wc -c < "$TAIL")"
head_bytes="$(wc -c < "$HEAD")"
block_bytes=$(( 4 * 1024 * 1024 ))

if [ "$head_bytes" -ne $(( 64 * 1024 * 1024 )) ] || [ "$tail_bytes" -ne $(( 64 * 1024 * 1024 )) ]; then
  echo "expected 64MiB head and tail images" >&2
  exit 1
fi

tail_skip=$(( device_bytes / block_bytes - tail_bytes / block_bytes ))

cat <<EOF
Device:      $DEVICE
Backup dir:  $BACKUP_DIR
Head image:  $HEAD
Tail image:  $TAIL
Tail skip:   $tail_skip blocks of 4MiB
EOF

if [ "$APPLY" != 1 ]; then
  cat <<EOF

Dry-run only. To restore GPT head/tail:
  $0 "$BACKUP_DIR" --apply
EOF
  exit 0
fi

mounted="$("$ADB" shell "mount | grep -E ' /data | /sdcard |sdc86|sdc88|/dev/block/by-name/linux' || true" | tr -d '\r')"
if [ -n "$mounted" ]; then
  echo "refusing to restore GPT while affected partitions are mounted:" >&2
  printf '%s\n' "$mounted" >&2
  echo "Unmount /sdcard, /data, and linux before restoring." >&2
  exit 1
fi

tmp_head="/tmp/sdc-head-64M.img"
tmp_tail="/tmp/sdc-tail-64M.img"

echo "Pushing backup images to recovery tmpfs..."
"$ADB" push "$HEAD" "$tmp_head" >/dev/null
"$ADB" push "$TAIL" "$tmp_tail" >/dev/null

echo "Writing saved head and tail areas..."
"$ADB" shell "dd if=$tmp_head of=$DEVICE bs=4M count=16 conv=fsync"
"$ADB" shell "dd if=$tmp_tail of=$DEVICE bs=4M seek=$tail_skip count=16 conv=fsync"
"$ADB" shell "sync; blockdev --rereadpt $DEVICE 2>/dev/null || true; sgdisk --verify $DEVICE || true"

echo "Restore write complete. Reboot recovery or Android before relying on /proc/partitions."
