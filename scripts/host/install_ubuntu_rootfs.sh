#!/usr/bin/env bash
# Install an Ubuntu rootfs tarball into the linux partition root.
#
# Layout after install:
#   linux partition /      -> Ubuntu rootfs
#   linux partition /lean  -> lean rescue runtime, preserved by this script
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

ROOTFS_TAR="${ROOTFS_TAR:-$ROOT/ubuntu-rootfs.tar.gz}"
LINUX_DEV="${LINUX_DEV:-/dev/block/by-name/linux}"
LINUX_DEV_FALLBACK="${LINUX_DEV_FALLBACK:-/dev/block/sdc88}"
LINUX_MOUNT="${LINUX_MOUNT:-/mnt/linux_kexec}"
ADB_STAGE="${ADB_STAGE:-/data/local/tmp/ubuntu_rootfs_stage}"
EXTRACTOR="${EXTRACTOR:-$ROOT/prebuilt/busybox}"
WIPE_UBUNTU="${WIPE_UBUNTU:-1}"

adb_root_shell()
{
  local script="$1"
  if [ "$("$ADB" shell 'id -u 2>/dev/null' | tr -d '\r')" = "0" ]; then
    "$ADB" shell "$script"
  else
    "$ADB" shell "su -c '$script'"
  fi
}

die()
{
  echo "install_ubuntu_rootfs: $*" >&2
  exit 1
}

[ -s "$ROOTFS_TAR" ] || die "missing rootfs tarball: $ROOTFS_TAR"
[ -s "$EXTRACTOR" ] || die "missing busybox extractor: $EXTRACTOR"

# Reject archives that could overwrite /lean or escape the target root.
while IFS= read -r entry; do
  case "$entry" in
    ""|"./") continue ;;
    /*|*"/../"*|../*|*"/.."|..)
      die "unsafe tar entry: $entry"
      ;;
    lean|lean/*|./lean|./lean/*)
      die "rootfs archive contains /lean; refusing to overwrite lean runtime"
      ;;
  esac
done < <(tar -tf "$ROOTFS_TAR")

echo "installing Ubuntu rootfs"
echo "rootfs: $ROOTFS_TAR"
echo "target: $LINUX_DEV mounted at $LINUX_MOUNT"
echo "wipe existing Ubuntu root: $WIPE_UBUNTU"

adb_root_shell "
  set -e
  mkdir -p '$LINUX_MOUNT' '$ADB_STAGE'
  if ! grep -q \" $LINUX_MOUNT \" /proc/mounts; then
    mount -t ext4 -o rw,noatime '$LINUX_DEV' '$LINUX_MOUNT' 2>/dev/null ||
      mount -t ext4 -o rw,noatime '$LINUX_DEV_FALLBACK' '$LINUX_MOUNT'
  fi
  chmod 0777 '$ADB_STAGE'
"

"$ADB" push "$EXTRACTOR" "$ADB_STAGE/busybox"
"$ADB" push "$ROOTFS_TAR" "$ADB_STAGE/rootfs.tar.gz"

adb_root_shell "
  set -e
  chmod 0755 '$ADB_STAGE/busybox'
  mkdir -p '$LINUX_MOUNT/lean'
  if [ '$WIPE_UBUNTU' = '1' ]; then
    find '$LINUX_MOUNT' -mindepth 1 -maxdepth 1 \
      ! -name lean ! -name lost+found -exec rm -rf {} +
  fi
  '$ADB_STAGE/busybox' tar -xzf '$ADB_STAGE/rootfs.tar.gz' -C '$LINUX_MOUNT'
  [ -e '$LINUX_MOUNT/etc/os-release' ] || {
    echo 'missing etc/os-release after extract' >&2
    exit 1
  }
  [ -e '$LINUX_MOUNT/bin/sh' ] || [ -e '$LINUX_MOUNT/usr/bin/sh' ] || {
    echo 'missing shell after extract' >&2
    exit 1
  }
  sync
  rm -rf '$ADB_STAGE'
  echo 'Ubuntu rootfs installed:'
  ls -la '$LINUX_MOUNT' | sed -n '1,80p'
  echo 'os-release:'
  sed -n '1,12p' '$LINUX_MOUNT/etc/os-release'
"
