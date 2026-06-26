#!/usr/bin/env bash
# Split the tail of userdata into a dedicated ext4 Linux partition.
#
# Default is dry-run. Pass --apply to write GPT and format filesystems.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

DEVICE="${DEVICE:-/dev/block/sdc}"
USERDATA_PART="${USERDATA_PART:-86}"
FLASHINFO_PART="${FLASHINFO_PART:-87}"
LINUX_PART="${LINUX_PART:-88}"
ANDROID_DATA_GIB="${ANDROID_DATA_GIB:-32}"
LINUX_NAME="${LINUX_NAME:-linux}"
GPT_ENTRIES="${GPT_ENTRIES:-128}"
APPLY=0
FORMAT_USERDATA=1
FORMAT_LINUX=1
AUTO_UNMOUNT=1
FORMAT_ONLY=0

usage()
{
  cat <<EOF
Usage: $0 [--apply] [--android-data-gib N] [--linux-name NAME]

Creates this layout on $DEVICE:
  userdata(part $USERDATA_PART) = N GiB, starting at the original userdata start
  linux   (part $LINUX_PART)   = remaining space before flashinfo(part $FLASHINFO_PART)
  flashinfo remains unmoved

Defaults:
  --android-data-gib $ANDROID_DATA_GIB
  --linux-name       $LINUX_NAME
  GPT_ENTRIES        $GPT_ENTRIES

Safety:
  Without --apply, prints the planned layout only.
  With --apply, /data must be unmounted and userdata will be reformatted.
  Use --format-only after rebooting recovery if GPT was written but sdc88 was
  not visible until reboot.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --apply)
      APPLY=1
      ;;
    --android-data-gib)
      ANDROID_DATA_GIB="$2"
      shift
      ;;
    --linux-name)
      LINUX_NAME="$2"
      shift
      ;;
    --no-format-userdata)
      FORMAT_USERDATA=0
      ;;
    --no-format-linux)
      FORMAT_LINUX=0
      ;;
    --no-auto-unmount)
      AUTO_UNMOUNT=0
      ;;
    --format-only)
      FORMAT_ONLY=1
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

adb_shell()
{
  "$ADB" shell "$@"
}

require_recovery()
{
  local state
  state="$("$ADB" get-state 2>/dev/null | tr -d '\r' || true)"
  if [ "$state" != "recovery" ]; then
    echo "device is not in adb recovery state: ${state:-<offline>}" >&2
    exit 1
  fi
}

wait_recovery()
{
  local i state

  for i in $(seq 1 60); do
    state="$("$ADB" get-state 2>/dev/null | tr -d '\r' || true)"
    [ "$state" = "recovery" ] && return 0
    sleep 1
  done

  echo "timed out waiting for adb recovery state" >&2
  return 1
}

part_field()
{
  local part="$1"
  local label="$2"
  adb_shell "sgdisk --info=$part $DEVICE 2>/dev/null | sed -n 's/^$label: //p' | head -1" | tr -d '\r'
}

part_name()
{
  local part="$1"
  adb_shell "sgdisk --info=$part $DEVICE 2>/dev/null | sed -n \"s/^Partition name: '\\(.*\\)'/\\1/p\" | head -1" | tr -d '\r'
}

ceil_div()
{
  local n="$1"
  local d="$2"
  echo $(( (n + d - 1) / d ))
}

require_recovery

userdata_mounts()
{
  adb_shell "mount | grep -E 'sdc$USERDATA_PART|/dev/block/by-name/userdata| /data | /sdcard ' || true" | tr -d '\r'
}

unmount_userdata()
{
  [ "$AUTO_UNMOUNT" = 1 ] || return 0

  if [ -z "$(userdata_mounts)" ]; then
    return 0
  fi

  echo "userdata is mounted; trying recovery/TWRP unmount path..."
  adb_shell "setprop ctl.stop vibratorfeature-hal-service 2>/dev/null || true" || true
  adb_shell "command -v twrp >/dev/null 2>&1 && twrp unmount /sdcard >/dev/null 2>&1 || true" || true
  wait_recovery
  adb_shell "command -v twrp >/dev/null 2>&1 && twrp unmount /data >/dev/null 2>&1 || true" || true
  wait_recovery
  adb_shell "sync; umount /sdcard 2>/dev/null || true; umount /data 2>/dev/null || true" || true
  wait_recovery
}

sector_size="$(adb_shell "blockdev --getss $DEVICE 2>/dev/null || cat /sys/block/${DEVICE##*/}/queue/logical_block_size" | tr -d '\r\n')"
case "$sector_size" in
  ''|*[!0-9]*)
    echo "failed to read sector size for $DEVICE" >&2
    exit 1
    ;;
esac

userdata_name="$(part_name "$USERDATA_PART")"
flashinfo_name="$(part_name "$FLASHINFO_PART")"
if [ "$userdata_name" != "userdata" ]; then
  echo "partition $USERDATA_PART is '$userdata_name', expected userdata" >&2
  exit 1
fi
if [ "$flashinfo_name" != "flashinfo" ]; then
  echo "partition $FLASHINFO_PART is '$flashinfo_name', expected flashinfo" >&2
  exit 1
fi

misc_start="$(part_field 1 "First sector")"
disk_first_usable="$(adb_shell "sgdisk --print $DEVICE 2>/dev/null | sed -n 's/^First usable sector is \\([0-9][0-9]*\\),.*/\\1/p' | head -1" | tr -d '\r')"
misc_start="${misc_start%% *}"
if [ "${disk_first_usable:-}" = "34" ] && [ "${misc_start:-}" = "8" ]; then
  echo "GPT first usable LBA is 34 while misc starts at LBA 8." >&2
  echo "Run scripts/host/partition_fix_gpt_first_usable.sh --apply first, then rerun this script." >&2
  exit 1
fi

userdata_start="$(part_field "$USERDATA_PART" "First sector")"
userdata_old_end="$(part_field "$USERDATA_PART" "Last sector")"
flashinfo_start="$(part_field "$FLASHINFO_PART" "First sector")"
flashinfo_end="$(part_field "$FLASHINFO_PART" "Last sector")"
userdata_type="$(part_field "$USERDATA_PART" "Partition GUID code" | awk '{print $1}')"
linux_existing=0
if adb_shell "sgdisk --info=$LINUX_PART $DEVICE 2>/dev/null | grep -q '^Partition GUID code:'"; then
  linux_existing=1
  linux_name_existing="$(part_name "$LINUX_PART")"
  linux_start_existing="$(part_field "$LINUX_PART" "First sector")"
  linux_end_existing="$(part_field "$LINUX_PART" "Last sector")"
  linux_start_existing="${linux_start_existing%% *}"
  linux_end_existing="${linux_end_existing%% *}"
fi

for v in userdata_start userdata_old_end flashinfo_start flashinfo_end; do
  val="${!v}"
  case "$val" in
    ''|[!0-9]*)
      echo "failed to parse $v from sgdisk output: '$val'" >&2
      exit 1
      ;;
  esac
  printf -v "$v" '%s' "${val%% *}"
done

android_bytes=$(( ANDROID_DATA_GIB * 1024 * 1024 * 1024 ))
userdata_sectors="$(ceil_div "$android_bytes" "$sector_size")"
userdata_new_end=$(( userdata_start + userdata_sectors - 1 ))
linux_start=$(( userdata_new_end + 1 ))
linux_end=$(( flashinfo_start - 1 ))
linux_sectors=$(( linux_end - linux_start + 1 ))

if [ "$userdata_new_end" -ge "$flashinfo_start" ] || [ "$linux_sectors" -le 0 ]; then
  echo "requested Android data size leaves no room before flashinfo" >&2
  exit 1
fi

linux_gib="$(awk -v s="$linux_sectors" -v ss="$sector_size" 'BEGIN { printf "%.2f", s * ss / 1024 / 1024 / 1024 }')"

if [ "$linux_existing" = 1 ]; then
  if [ "$userdata_old_end" != "$userdata_new_end" ] ||
     [ "$linux_start_existing" != "$linux_start" ] ||
     [ "$linux_end_existing" != "$linux_end" ] ||
     [ "$linux_name_existing" != "$LINUX_NAME" ]; then
    echo "partition $LINUX_PART already exists but does not match the planned layout" >&2
    echo "existing linux: name=$linux_name_existing start=$linux_start_existing end=$linux_end_existing" >&2
    echo "planned  linux: name=$LINUX_NAME start=$linux_start end=$linux_end" >&2
    echo "existing userdata end=$userdata_old_end planned userdata end=$userdata_new_end" >&2
    exit 1
  fi
fi

cat <<EOF
Device:              $DEVICE
Sector size:         $sector_size bytes
Android userdata:    part $USERDATA_PART, $ANDROID_DATA_GIB GiB
Linux ext4:          part $LINUX_PART, $linux_gib GiB, name '$LINUX_NAME'
Flashinfo:           part $FLASHINFO_PART, unchanged

Current:
  userdata  start=$userdata_start end=$userdata_old_end
  flashinfo start=$flashinfo_start end=$flashinfo_end

Planned:
  userdata  start=$userdata_start end=$userdata_new_end
  $LINUX_NAME start=$linux_start end=$linux_end
  flashinfo start=$flashinfo_start end=$flashinfo_end
EOF

if [ "$APPLY" != 1 ]; then
  cat <<EOF

Dry-run only. To write GPT and format:
  ANDROID_DATA_GIB=$ANDROID_DATA_GIB LINUX_NAME=$LINUX_NAME $0 --apply
EOF
  exit 0
fi

unmount_userdata

if [ -n "$(userdata_mounts)" ]; then
  echo "userdata appears to be mounted. Unmount /sdcard and /data before applying." >&2
  userdata_mounts >&2
  exit 1
fi

if [ "$linux_existing" != 1 ] && [ "$FORMAT_ONLY" != 1 ]; then
  echo "Writing GPT..."
  adb_shell "sgdisk \
    --resize-table=$GPT_ENTRIES \
    --delete=$USERDATA_PART \
    --new=$USERDATA_PART:$userdata_start:$userdata_new_end \
    --change-name=$USERDATA_PART:userdata \
    --typecode=$USERDATA_PART:${userdata_type:-EBD0A0A2-B9E5-4433-87C0-68B6B72699C7} \
    --new=$LINUX_PART:$linux_start:$linux_end \
    --change-name=$LINUX_PART:$LINUX_NAME \
    --typecode=$LINUX_PART:8300 \
    $DEVICE"
elif [ "$FORMAT_ONLY" = 1 ]; then
  echo "Format-only mode: leaving GPT unchanged"
else
  echo "GPT already matches planned layout; leaving GPT unchanged"
fi

adb_shell "blockdev --rereadpt $DEVICE 2>/dev/null || true"
adb_shell "sgdisk --verify $DEVICE || true"

if ! adb_shell "[ -b /dev/block/sdc$USERDATA_PART ] && [ -b /dev/block/sdc$LINUX_PART ]"; then
  echo "new block nodes are not visible yet (/dev/block/sdc$LINUX_PART missing)." >&2
  echo "Reboot recovery, then run:" >&2
  echo "  ANDROID_DATA_GIB=$ANDROID_DATA_GIB LINUX_NAME=$LINUX_NAME $0 --format-only" >&2
  exit 3
fi

if [ "$FORMAT_USERDATA" = 1 ]; then
  echo "Formatting userdata as f2fs..."
  adb_shell "make_f2fs -f /dev/block/sdc$USERDATA_PART"
fi

if [ "$FORMAT_LINUX" = 1 ]; then
  echo "Formatting /dev/block/sdc$LINUX_PART as ext4..."
  adb_shell "mke2fs -t ext4 -F -L $LINUX_NAME /dev/block/sdc$LINUX_PART"
fi

echo "Done. Reboot recovery or Android if new /dev/block/by-name links are not visible yet."
