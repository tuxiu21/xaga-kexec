#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

ADBKEY_PUB="${ADBKEY_PUB:-/mnt/c/Users/Rin/.android/adbkey.pub}"
CLEAR_BCB=1

usage()
{
  cat <<EOF
Usage: $0 [--no-clear-bcb]

Run from recovery adb. This forces stock Android USB adb on xaga by:
  - mounting /data
  - writing /data/property/persistent_properties with:
      persist.sys.usb.config=adb
      persist.security.adbinput=1
  - writing /data/misc/adb/adb_keys from ADBKEY_PUB
  - backing up /dev/block/by-name/misc and clearing the BCB boot-recovery command

Environment:
  ADB=adb.exe
  ADBKEY_PUB=/mnt/c/Users/Rin/.android/adbkey.pub
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-clear-bcb)
      CLEAR_BCB=0
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
  shift
done

if [ ! -s "$ADBKEY_PUB" ]; then
  echo "missing adb public key: $ADBKEY_PUB" >&2
  exit 1
fi

state="$("$ADB" get-state 2>/dev/null | tr -d '\r' || true)"
case "$state" in
  device|recovery)
    ;;
  *)
    echo "adb transport is not available; current state: ${state:-none}" >&2
    "$ADB" devices >&2 || true
    exit 1
    ;;
esac

bootmode="$("$ADB" shell 'getprop ro.bootmode 2>/dev/null' | tr -d '\r')"
if [ "$bootmode" != "recovery" ]; then
  echo "refusing to run: ro.bootmode is '$bootmode', expected recovery" >&2
  exit 1
fi

ts="$(date +%Y%m%d_%H%M%S)"
backup_dir="$LOG_ROOT/force_stock_adb_$ts"
tmp="$(mktemp -d)"
cleanup()
{
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$backup_dir"

cp "$ADBKEY_PUB" "$tmp/adbkey.pub"
printf '\0%.0s' $(seq 1 2048) > "$tmp/zero2048.bin"

echo "mounting /data"
"$ADB" shell 'mount | grep -q " /data " || mount -t f2fs /dev/block/by-name/userdata /data'

echo "backing up existing adb/property files to $backup_dir"
"$ADB" pull /data/property/persistent_properties "$backup_dir/persistent_properties.before" \
  >/dev/null 2>&1 || true
"$ADB" pull /data/misc/adb/adb_keys "$backup_dir/adb_keys.before" \
  >/dev/null 2>&1 || true

if [ "$CLEAR_BCB" = 1 ]; then
  echo "backing up misc to $backup_dir/misc.before.img"
  "$ADB" pull /dev/block/by-name/misc "$backup_dir/misc.before.img" >/dev/null
fi

if [ -s "$backup_dir/persistent_properties.before" ]; then
  cp "$backup_dir/persistent_properties.before" "$tmp/persistent_properties.before"
else
  : > "$tmp/persistent_properties.before"
fi

python3 - "$tmp/persistent_properties.before" "$tmp/persistent_properties" <<'PY'
import sys
from pathlib import Path

src = Path(sys.argv[1]).read_bytes()
dst = Path(sys.argv[2])


def read_varint(data, off):
    value = 0
    shift = 0
    while off < len(data):
        b = data[off]
        off += 1
        value |= (b & 0x7f) << shift
        if not (b & 0x80):
            return value, off
        shift += 7
    raise ValueError("truncated varint")


def write_varint(value):
    out = bytearray()
    while value >= 0x80:
        out.append((value & 0x7f) | 0x80)
        value >>= 7
    out.append(value)
    return bytes(out)


def parse_record(data):
    off = 0
    name = None
    value = None
    while off < len(data):
        key, off = read_varint(data, off)
        field = key >> 3
        wire = key & 7
        if wire != 2:
            raise ValueError(f"unsupported record wire type {wire}")
        size, off = read_varint(data, off)
        blob = data[off:off + size]
        off += size
        if field == 1:
            name = blob.decode()
        elif field == 2:
            value = blob.decode()
    if name:
        return name, value or ""
    return None


def parse_props(data):
    props = {}
    off = 0
    while off < len(data):
        key, off = read_varint(data, off)
        field = key >> 3
        wire = key & 7
        if field != 1 or wire != 2:
            raise ValueError(f"unsupported outer field={field} wire={wire}")
        size, off = read_varint(data, off)
        parsed = parse_record(data[off:off + size])
        off += size
        if parsed:
            props[parsed[0]] = parsed[1]
    return props


def field_string(field, text):
    raw = text.encode()
    return write_varint((field << 3) | 2) + write_varint(len(raw)) + raw


def build_props(props):
    out = bytearray()
    for name in sorted(props):
        rec = field_string(1, name) + field_string(2, props[name])
        out += write_varint((1 << 3) | 2) + write_varint(len(rec)) + rec
    return bytes(out)


props = parse_props(src) if src else {}
props["persist.sys.usb.config"] = "adb"
props["persist.security.adbinput"] = "1"
dst.write_bytes(build_props(props))
PY

echo "installing persistent_properties and adb_keys"
"$ADB" push "$tmp/persistent_properties" /tmp/persistent_properties.force_adb >/dev/null
"$ADB" push "$tmp/adbkey.pub" /tmp/adbkey.pub >/dev/null
"$ADB" shell '
  set -e
  mkdir -p /data/property /data/misc/adb
  cp /tmp/persistent_properties.force_adb /data/property/persistent_properties
  cp /tmp/adbkey.pub /data/misc/adb/adb_keys
  chown root:root /data/property /data/property/persistent_properties
  chmod 0700 /data/property
  chmod 0600 /data/property/persistent_properties
  chown system:shell /data/misc/adb /data/misc/adb/adb_keys 2>/dev/null || chown 1000:2000 /data/misc/adb /data/misc/adb/adb_keys
  chmod 0750 /data/misc/adb
  chmod 0640 /data/misc/adb/adb_keys
  chcon u:object_r:property_data_file:s0 /data/property /data/property/persistent_properties 2>/dev/null || true
  chcon u:object_r:adb_keys_file:s0 /data/misc/adb /data/misc/adb/adb_keys 2>/dev/null || true
  sync
'

if [ "$CLEAR_BCB" = 1 ]; then
  echo "clearing misc BCB bootloader_message"
  "$ADB" push "$tmp/zero2048.bin" /tmp/zero2048.bin >/dev/null
  "$ADB" shell 'dd if=/tmp/zero2048.bin of=/dev/block/by-name/misc bs=2048 count=1 conv=notrunc >/dev/null 2>&1; sync'
fi

echo "verification"
"$ADB" shell '
  mount | grep -q " /data " || mount -t f2fs /dev/block/by-name/userdata /data
  echo "persistent_properties:"
  ls -lZ /data/property/persistent_properties
  od -An -tx1 /data/property/persistent_properties
  echo "adb_keys:"
  ls -lZ /data/misc/adb/adb_keys
  wc -c /data/misc/adb/adb_keys
  echo "misc strings:"
  dd if=/dev/block/by-name/misc bs=2048 count=4 2>/dev/null | strings -a | head -20
'

cat <<EOF
Done.
Backup directory: $backup_dir

Next:
  $ADB reboot
  $ADB kill-server
  $ADB start-server
  $ADB devices -l
EOF
