#!/data/kexec/busybox sh
set -eu

BB="${BB:-/data/kexec/busybox}"
ROOTFS="${ROOTFS:-/data/kexec/ubuntu-rootfs}"

die()
{
    echo "enter-ubuntu: $*" >&2
    exit 1
}

mount_if_needed()
{
    mp="$1"
    type="$2"
    src="$3"
    opts="${4:-}"

    "$BB" mkdir -p "$mp"
    "$BB" grep -q " $mp " /proc/mounts 2>/dev/null && return 0
    if [ -n "$opts" ]; then
        "$BB" mount -t "$type" -o "$opts" "$src" "$mp"
    else
        "$BB" mount -t "$type" "$src" "$mp"
    fi
}

bind_if_needed()
{
    src="$1"
    dst="$2"

    "$BB" mkdir -p "$dst"
    "$BB" grep -q " $dst " /proc/mounts 2>/dev/null && return 0
    "$BB" mount -o bind "$src" "$dst"
}

ensure_reasonable_time()
{
    min_epoch=1781272800
    now="$("$BB" date +%s 2>/dev/null || echo 0)"
    case "$now" in
        ''|*[!0-9]*)
            now=0
            ;;
    esac

    if [ "$now" -lt "$min_epoch" ]; then
        "$BB" date -u -s "2026-06-12 14:00:00" >/dev/null 2>&1 || \
            echo "enter-ubuntu: failed to apply time fallback" >&2
    fi
}

[ -x "$BB" ] || die "missing busybox at $BB"
[ -d "$ROOTFS" ] || die "missing rootfs at $ROOTFS"
[ -x "$ROOTFS/bin/sh" ] || die "missing shell in $ROOTFS"

ensure_reasonable_time

mount_if_needed /proc proc proc
mount_if_needed /sys sysfs sysfs
mount_if_needed /dev devtmpfs devtmpfs "mode=0755"
mount_if_needed /dev/pts devpts devpts "mode=0620,ptmxmode=0666"

bind_if_needed /dev "$ROOTFS/dev"
mount_if_needed "$ROOTFS/proc" proc proc
mount_if_needed "$ROOTFS/sys" sysfs sysfs
mount_if_needed "$ROOTFS/dev/pts" devpts devpts "mode=0620,ptmxmode=0666"
mount_if_needed "$ROOTFS/run" tmpfs tmpfs "mode=0755"

if [ -L "$ROOTFS/etc/resolv.conf" ]; then
    "$BB" rm -f "$ROOTFS/etc/resolv.conf"
fi
if [ ! -e "$ROOTFS/etc/resolv.conf" ] || [ ! -s "$ROOTFS/etc/resolv.conf" ]; then
    "$BB" mkdir -p "$ROOTFS/etc"
    printf 'nameserver 1.1.1.1\nnameserver 8.8.8.8\n' > "$ROOTFS/etc/resolv.conf"
fi

export HOME=/root
export TERM="${TERM:-linux}"
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

if [ "$#" -gt 0 ]; then
    exec "$BB" chroot "$ROOTFS" /usr/bin/env -i \
        HOME="$HOME" TERM="$TERM" PATH="$PATH" "$@"
fi

exec "$BB" chroot "$ROOTFS" /usr/bin/env -i \
    HOME="$HOME" TERM="$TERM" PATH="$PATH" /bin/bash -l
