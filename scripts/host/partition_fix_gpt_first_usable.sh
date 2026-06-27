#!/usr/bin/env bash
# Fix xaga's GPT first_usable_lba so GPT metadata matches the real misc start.
#
# Default is dry-run. Pass --apply to write only the primary and backup GPT
# headers. Partition entries and partition data are not modified.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

DEVICE="${DEVICE:-/dev/block/sdc}"
EXPECTED_OLD="${EXPECTED_OLD:-34}"
EXPECTED_NEW="${EXPECTED_NEW:-8}"
APPLY=0

usage()
{
  cat <<EOF
Usage: $0 [--apply]

Fixes GPT header first_usable_lba on $DEVICE:
  $EXPECTED_OLD -> $EXPECTED_NEW

Safety checks:
  - device must be in adb recovery state
  - logical block size must be 4096
  - GPT entry array must be LBA 2-5 with 128 entries
  - partition #1 must start at LBA 8
  - primary and backup headers must currently report first_usable_lba=34

Without --apply, only reads, validates, and prepares patched headers locally.
EOF
}

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

state="$("$ADB" get-state 2>/dev/null | tr -d '\r' || true)"
if [ "$state" != "recovery" ]; then
  echo "device is not in adb recovery state: ${state:-<offline>}" >&2
  exit 1
fi

sector_size="$("$ADB" shell "blockdev --getss $DEVICE" | tr -d '\r\n')"
device_bytes="$("$ADB" shell "blockdev --getsize64 $DEVICE" | tr -d '\r\n')"
if [ "$sector_size" != "4096" ]; then
  echo "unexpected logical sector size: $sector_size" >&2
  exit 1
fi

last_lba=$(( device_bytes / sector_size - 1 ))
out="$DIAG_ROOT/gpt_first_usable/gpt_first_usable_fix_$(date +%Y%m%d_%H%M%S)"
mkdir -p "$out"

"$ADB" exec-out "dd if=$DEVICE bs=4096 skip=1 count=1 2>/dev/null" > "$out/primary-gpt-header.bin"
"$ADB" exec-out "dd if=$DEVICE bs=4096 skip=2 count=4 2>/dev/null" > "$out/gpt-entries.bin"
"$ADB" exec-out "dd if=$DEVICE bs=4096 skip=$last_lba count=1 2>/dev/null" > "$out/backup-gpt-header.bin"

python3 - "$out" "$EXPECTED_OLD" "$EXPECTED_NEW" "$last_lba" <<'PY'
import binascii
import pathlib
import struct
import sys

out = pathlib.Path(sys.argv[1])
expected_old = int(sys.argv[2])
expected_new = int(sys.argv[3])
last_lba = int(sys.argv[4])

primary_path = out / "primary-gpt-header.bin"
backup_path = out / "backup-gpt-header.bin"
entries_path = out / "gpt-entries.bin"

def read_exact(path, size):
    data = path.read_bytes()
    if len(data) != size:
        raise SystemExit(f"{path.name}: expected {size} bytes, got {len(data)}")
    return bytearray(data)

primary = read_exact(primary_path, 4096)
backup = read_exact(backup_path, 4096)
entries = read_exact(entries_path, 4096 * 4)

def u32(data, off):
    return struct.unpack_from("<I", data, off)[0]

def u64(data, off):
    return struct.unpack_from("<Q", data, off)[0]

def put_u32(data, off, val):
    struct.pack_into("<I", data, off, val)

def put_u64(data, off, val):
    struct.pack_into("<Q", data, off, val)

def check_header(data, label):
    if bytes(data[:8]) != b"EFI PART":
        raise SystemExit(f"{label}: bad GPT signature")
    header_size = u32(data, 12)
    if header_size < 92 or header_size > 4096:
        raise SystemExit(f"{label}: bad header size {header_size}")

    old_crc = u32(data, 16)
    tmp = bytearray(data[:header_size])
    put_u32(tmp, 16, 0)
    calc = binascii.crc32(tmp) & 0xffffffff
    if calc != old_crc:
        raise SystemExit(f"{label}: header CRC mismatch stored={old_crc:08x} calc={calc:08x}")

    first_usable = u64(data, 40)
    entry_lba = u64(data, 72)
    entry_count = u32(data, 80)
    entry_size = u32(data, 84)
    entry_crc = u32(data, 88)

    if first_usable != expected_old:
        raise SystemExit(f"{label}: first_usable_lba is {first_usable}, expected {expected_old}")
    if entry_count != 128 or entry_size != 128:
        raise SystemExit(f"{label}: unexpected entry layout count={entry_count} size={entry_size}")
    if entry_crc != (binascii.crc32(entries) & 0xffffffff):
        raise SystemExit(f"{label}: partition-entry CRC mismatch")
    return header_size, entry_lba

primary_size, primary_entry_lba = check_header(primary, "primary")
backup_size, backup_entry_lba = check_header(backup, "backup")
primary_last_usable = u64(primary, 48)
backup_last_usable = u64(backup, 48)

if primary_entry_lba != 2:
    raise SystemExit(f"primary: partition_entry_lba is {primary_entry_lba}, expected 2")
if primary_last_usable != backup_last_usable:
    raise SystemExit(f"last_usable mismatch primary={primary_last_usable} backup={backup_last_usable}")
if not (primary_last_usable < backup_entry_lba < last_lba):
    raise SystemExit(
        f"backup: partition_entry_lba {backup_entry_lba} is not between "
        f"last_usable {primary_last_usable} and backup header {last_lba}"
    )
if backup_entry_lba + 4 - 1 >= last_lba:
    raise SystemExit(
        f"backup: partition-entry array {backup_entry_lba}-{backup_entry_lba + 3} "
        f"overlaps backup header {last_lba}"
    )

first_entry = entries[:128]
part1_first_lba = u64(first_entry, 32)
part1_last_lba = u64(first_entry, 40)
if part1_first_lba != expected_new:
    raise SystemExit(f"partition #1 first_lba is {part1_first_lba}, expected {expected_new}")
if part1_last_lba < part1_first_lba:
    raise SystemExit("partition #1 has invalid LBA range")

def patch_header(data, header_size, label):
    patched = bytearray(data)
    put_u64(patched, 40, expected_new)
    put_u32(patched, 16, 0)
    crc = binascii.crc32(patched[:header_size]) & 0xffffffff
    put_u32(patched, 16, crc)
    (out / f"{label}-gpt-header.patched.bin").write_bytes(patched)
    return crc

primary_crc = patch_header(primary, primary_size, "primary")
backup_crc = patch_header(backup, backup_size, "backup")

report = out / "report.txt"
report.write_text(
    "\n".join([
        f"last_lba={last_lba}",
        f"primary_entry_lba={primary_entry_lba}",
        f"backup_entry_lba={backup_entry_lba}",
        f"entry_count=128",
        f"entry_size=128",
        f"partition_1_first_lba={part1_first_lba}",
        f"partition_1_last_lba={part1_last_lba}",
        f"first_usable_lba={expected_old}->{expected_new}",
        f"primary_new_crc={primary_crc:08x}",
        f"backup_new_crc={backup_crc:08x}",
        "",
    ])
)
print(report.read_text(), end="")
PY

sha256sum "$out"/* > "$out/SHA256SUMS"

cat <<EOF
Prepared patched GPT headers in:
  $out
EOF

if [ "$APPLY" != 1 ]; then
  cat <<EOF

Dry-run only. To write only GPT headers:
  $0 --apply
EOF
  exit 0
fi

tmp_primary="/tmp/primary-gpt-header.patched.bin"
tmp_backup="/tmp/backup-gpt-header.patched.bin"

echo "Pushing patched GPT headers to recovery tmpfs..."
"$ADB" push "$out/primary-gpt-header.patched.bin" "$tmp_primary" >/dev/null
"$ADB" push "$out/backup-gpt-header.patched.bin" "$tmp_backup" >/dev/null

echo "Writing primary and backup GPT headers only..."
"$ADB" shell "dd if=$tmp_primary of=$DEVICE bs=4096 seek=1 count=1 conv=fsync"
"$ADB" shell "dd if=$tmp_backup of=$DEVICE bs=4096 seek=$last_lba count=1 conv=fsync"
"$ADB" shell "sync; sgdisk --verify $DEVICE || true"

echo "GPT first_usable_lba fix complete."
