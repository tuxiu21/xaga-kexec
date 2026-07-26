#!/usr/bin/env bash
# Internal implementation for `./xaga backup`.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

serial="${STOCK_SERIAL:-}"
output_dir=
linux_dev="${LINUX_DEV:-/dev/block/by-name/linux}"
mountpoint=/mnt/linux_backup
timestamp="$(date +%Y%m%d_%H%M%S)"
remote_tar_log="/data/local/tmp/xaga-backup-${timestamp}-tar.log"
remote_zstd_log="/data/local/tmp/xaga-backup-${timestamp}-zstd.log"

die()
{
  printf 'xaga backup: %s\n' "$*" >&2
  exit 1
}

usage()
{
  cat <<EOF
Usage: ./xaga backup [--serial SERIAL] [--output-dir DIR]

Creates an offline file-level Ubuntu backup with owners, ACLs, xattrs,
capabilities, device nodes and sparse files preserved. Run from stock Android;
the linux partition must not already be mounted.

Default output root: $BACKUP_ROOT
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --serial)
      [ "$#" -ge 2 ] || die "--serial requires a value"
      serial="$2"
      shift 2
      ;;
    --output-dir)
      [ "$#" -ge 2 ] || die "--output-dir requires a path"
      output_dir="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

command -v zstd >/dev/null 2>&1 || die "host zstd is required"
command -v sha256sum >/dev/null 2>&1 || die "host sha256sum is required"

if [ -z "$serial" ]; then
  serial="$("$ADB" devices 2>/dev/null | tr -d '\r' |
    awk 'NR>1 && $2=="device" && $1!="ubuntu012345678" {print $1; exit}')"
fi
[ -n "$serial" ] || die "stock Android adb device not found; use --serial"

adb_target=(-s "$serial")
state="$("$ADB" "${adb_target[@]}" get-state 2>/dev/null | tr -d '\r' || true)"
[ "$state" = device ] || die "adb device is not ready: ${state:-<none>}"

adb_root_shell()
{
  local script="$1"
  if [ "$("$ADB" "${adb_target[@]}" shell 'id -u 2>/dev/null' |
      tr -d '\r\n')" = 0 ]; then
    "$ADB" "${adb_target[@]}" shell "$script"
  else
    "$ADB" "${adb_target[@]}" shell "su -c '$script'"
  fi
}

adb_root_exec_out()
{
  local script="$1"
  if [ "$("$ADB" "${adb_target[@]}" shell 'id -u 2>/dev/null' |
      tr -d '\r\n')" = 0 ]; then
    "$ADB" "${adb_target[@]}" exec-out "$script"
  else
    "$ADB" "${adb_target[@]}" exec-out "su -c '$script'"
  fi
}

uid="$(adb_root_shell 'id -u' | tr -d '\r\n')"
[ "$uid" = 0 ] || die "root adb shell or su is required"
product="$(adb_root_shell 'getprop ro.product.device' | tr -d '\r\n')"
[ "$product" = xaga ] || die "refusing non-xaga device: ${product:-<unknown>}"
bootmode="$(adb_root_shell 'getprop ro.bootmode' | tr -d '\r\n')"
[ "$bootmode" != recovery ] ||
  die "boot stock Android normally before backup"

mounted="$(adb_root_shell \
  "mount | grep -E \"by-name/linux|sdc88|$mountpoint\" || true" |
  tr -d '\r')"
[ -z "$mounted" ] ||
  die "linux partition is already mounted; refusing inconsistent backup"

linux_size="$(adb_root_shell "blockdev --getsize64 $linux_dev" |
  tr -d '\r\n')"
case "$linux_size" in
  ''|*[!0-9]*) die "failed to read linux partition size" ;;
esac

if [ -z "$output_dir" ]; then
  output_dir="$BACKUP_ROOT/ubuntu_$timestamp"
fi
output_dir="$(realpath -m "$output_dir")"
[ ! -e "$output_dir" ] ||
  die "output directory already exists: $output_dir"
mkdir -p "$output_dir"

partial="$output_dir/ubuntu-rootfs.tar.zst.partial"
archive="$output_dir/ubuntu-rootfs.tar.zst"
mounted_by_us=0

cleanup()
{
  if [ "$mounted_by_us" = 1 ]; then
    adb_root_shell "umount $mountpoint 2>/dev/null || true" >/dev/null 2>&1 || true
  fi
}
trap cleanup EXIT INT TERM

{
  printf 'created_at=%s\n' "$(date --iso-8601=seconds)"
  printf 'adb_serial=%s\n' "$serial"
  printf 'product=%s\n' "$product"
  printf 'bootmode=%s\n' "$bootmode"
  printf 'linux_device=%s\n' "$linux_dev"
  printf 'linux_size_bytes=%s\n' "$linux_size"
  adb_root_shell 'getprop ro.build.fingerprint'
  adb_root_shell 'sgdisk --info=88 /dev/block/sdc 2>/dev/null || true'
} | tr -d '\r' > "$output_dir/partition-info.txt"

printf 'Backing up offline Ubuntu filesystem to:\n  %s\n' "$archive"
mounted_by_us=1
remote_command="set -o pipefail; \
mkdir -p $mountpoint; \
mount -t ext4 -o ro,noload $linux_dev $mountpoint; \
trap \"umount $mountpoint\" EXIT; \
chroot $mountpoint /usr/bin/tar \
  --one-file-system --sparse --sort=name --numeric-owner \
  --acls --xattrs --xattrs-include=\"*\" --selinux \
  -C / -cpf - . 2>$remote_tar_log | \
chroot $mountpoint /usr/bin/zstd -T0 -3 -c 2>$remote_zstd_log"
adb_root_exec_out "$remote_command" > "$partial"
mounted_by_us=0

"$ADB" "${adb_target[@]}" pull "$remote_tar_log" \
  "$output_dir/tar.stderr.log" >/dev/null 2>&1 || true
"$ADB" "${adb_target[@]}" pull "$remote_zstd_log" \
  "$output_dir/zstd.stderr.log" >/dev/null 2>&1 || true

mv "$partial" "$archive"
printf 'Checking zstd frame...\n'
zstd -T0 -t "$archive"
printf 'Checking complete tar stream...\n'
zstd -dc "$archive" | tar -tf - >/dev/null
sha256sum "$archive" > "$archive.sha256"

compressed_bytes="$(stat -c %s "$archive")"
{
  printf 'backup_type=file-level-offline-tar\n'
  printf 'completed_at=%s\n' "$(date --iso-8601=seconds)"
  printf 'compressed_size_bytes=%s\n' "$compressed_bytes"
} > "$output_dir/COMPLETED"

printf 'Backup complete:\n'
ls -lh "$archive" "$archive.sha256"
cat "$archive.sha256"
