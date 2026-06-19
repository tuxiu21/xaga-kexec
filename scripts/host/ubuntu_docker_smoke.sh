#!/usr/bin/env bash
# Start Docker inside the Lean Ubuntu rootfs and run an offline container smoke test.
#
# Assumes Lean ADB is already up. This intentionally uses vfs and disables
# Docker-managed iptables/bridge networking until overlay2 and bridge NAT are
# solved separately.

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

SERIAL="${SERIAL:-0123456789abcdef}"
ROOTFS="${ROOTFS:-/data/kexec/ubuntu-rootfs}"
DATA_ROOT="${DATA_ROOT:-/var/lib/docker-vfs}"
IMAGE_TAG="${IMAGE_TAG:-local/busybox:lean-vfs-userns}"

"$ADB" -s "$SERIAL" shell "cat > /data/kexec/docker_smoke.sh" <<'EOF'
#!/data/kexec/busybox sh
set -eu

BB=/data/kexec/busybox
ROOTFS="${ROOTFS:-/data/kexec/ubuntu-rootfs}"
DATA_ROOT="${DATA_ROOT:-/var/lib/docker-vfs}"
IMAGE_TAG="${IMAGE_TAG:-local/busybox:lean-vfs-userns}"

"$BB" cp /data/kexec/busybox "$ROOTFS/tmp/busybox"
"$BB" chmod 0755 "$ROOTFS/tmp/busybox"

"$BB" grep -q " $ROOTFS " /proc/mounts 2>/dev/null || \
  "$BB" mount -o bind "$ROOTFS" "$ROOTFS"

ROOTFS="$ROOTFS" DATA_ROOT="$DATA_ROOT" IMAGE_TAG="$IMAGE_TAG" \
/data/kexec/enter-ubuntu.sh /bin/bash -lc '
set -euo pipefail
set -x

pkill dockerd 2>/dev/null || true
pkill containerd 2>/dev/null || true
sleep 2

mkdir -p /sys/fs/cgroup /var/run /run "$DATA_ROOT"
mountpoint -q /sys/fs/cgroup || mount -t cgroup2 none /sys/fs/cgroup
mountpoint -q "$DATA_ROOT" || mount -o bind "$DATA_ROOT" "$DATA_ROOT"

nohup dockerd \
  --debug \
  --iptables=false \
  --ip6tables=false \
  --bridge=none \
  --data-root="$DATA_ROOT" \
  --storage-driver=vfs \
  > /tmp/dockerd.vfs.log 2>&1 &

for i in $(seq 1 20); do
  docker info >/tmp/docker.info 2>&1 && break
  sleep 1
done

docker info | sed -n "1,120p"

rm -rf /tmp/miniroot /tmp/miniroot.tar
mkdir -p /tmp/miniroot/bin
cp /tmp/busybox /tmp/miniroot/bin/busybox
ln -sf busybox /tmp/miniroot/bin/sh
tar -C /tmp/miniroot -cf /tmp/miniroot.tar .

docker import /tmp/miniroot.tar "$IMAGE_TAG"
docker run --rm --network=none "$IMAGE_TAG" /bin/busybox echo docker-run-ok

tail -80 /tmp/dockerd.vfs.log
'
EOF

"$ADB" -s "$SERIAL" shell "chmod 0755 /data/kexec/docker_smoke.sh && ROOTFS='$ROOTFS' DATA_ROOT='$DATA_ROOT' IMAGE_TAG='$IMAGE_TAG' /data/kexec/docker_smoke.sh"
