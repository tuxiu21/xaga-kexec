#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

ROOTFS_TAR="${ROOTFS_TAR:-$ROOT/ubuntu-rootfs.tar.gz}"
OUT="${OUT:-$WORK_DIR/rootfs/ubuntu.ext4}"
SIZE="${SIZE:-16G}"
LABEL="${LABEL:-ubuntu-rootfs}"

if [ ! -s "$ROOTFS_TAR" ]; then
  echo "missing rootfs archive: $ROOTFS_TAR" >&2
  exit 1
fi

for tool in truncate mkfs.ext4 tar; do
  if ! command -v "$tool" >/dev/null 2>&1; then
    echo "missing host tool: $tool" >&2
    exit 1
  fi
done

mkdir -p "$(dirname "$OUT")"

if [ -e "$OUT" ] && [ "${FORCE:-0}" != 1 ]; then
  echo "refusing to overwrite existing image: $OUT" >&2
  echo "set FORCE=1 to rebuild it" >&2
  exit 1
fi

tmp="$(mktemp -d "$TMP_ROOT/ubuntu_ext4.XXXXXX")"
rootdir="$tmp/root"
img="$tmp/ubuntu.ext4"
cleanup()
{
  rm -rf "$tmp"
}
trap cleanup EXIT

mkdir -p "$rootdir"

echo "creating ext4 image: $OUT size=$SIZE"
truncate -s "$SIZE" "$img"

populate_rootdir()
{
  tar --numeric-owner --xattrs --no-acls -xzf "$ROOTFS_TAR" -C "$rootdir"
  mkdir -p \
    "$rootdir/proc" \
    "$rootdir/sys" \
    "$rootdir/dev" \
    "$rootdir/dev/pts" \
    "$rootdir/run" \
    "$rootdir/tmp" \
    "$rootdir/data" \
    "$rootdir/sys/fs/cgroup" \
    "$rootdir/var/lib/docker"
  chmod 1777 "$rootdir/tmp"

  if [ ! -s "$rootdir/etc/machine-id" ]; then
    mkdir -p "$rootdir/etc"
    : > "$rootdir/etc/machine-id"
  fi
}

if command -v fakeroot >/dev/null 2>&1; then
  fakeroot bash -euc "$(declare -f populate_rootdir); ROOTFS_TAR='$ROOTFS_TAR' rootdir='$rootdir'; populate_rootdir; mkfs.ext4 -F -L '$LABEL' -d '$rootdir' '$img' >/dev/null"
else
  echo "warning: fakeroot not found; ownership/device metadata may be incomplete" >&2
  populate_rootdir
  mkfs.ext4 -F -L "$LABEL" -d "$rootdir" "$img" >/dev/null
fi

if command -v e2fsck >/dev/null 2>&1; then
  e2fsck -fy "$img" >/dev/null
fi

mv "$img" "$OUT"
ls -lh "$OUT"
