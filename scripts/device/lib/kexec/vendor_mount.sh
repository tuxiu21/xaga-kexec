#!/bin/sh

resolve_dm_by_name()
{
    name="$1"

    for n in /sys/block/dm-*; do
        [ -e "$n/dm/name" ] || continue
        if [ "$(cat "$n/dm/name" 2>/dev/null)" = "$name" ]; then
            echo "/dev/block/${n##*/}"
            return 0
        fi
    done
    return 1
}

ensure_dm_node()
{
    node="$1"
    base="${node##*/}"
    devno="$(cat "/sys/block/$base/dev" 2>/dev/null || true)"
    [ -n "$devno" ] || return 1
    maj="${devno%:*}"
    min="${devno#*:}"
    mkdir -p /dev/block /dev/mapper
    [ -b "$node" ] || mknod "$node" b "$maj" "$min" 2>/dev/null || true
}

mount_one_vendor_path()
{
    part="$1"
    mp="$2"
    dev="$(resolve_dm_by_name "$part" 2>/dev/null || true)"
    [ -n "$dev" ] || return 1
    ensure_dm_node "$dev" || true
    mkdir -p "$mp"
    grep -q " $mp " /proc/mounts 2>/dev/null && return 0
    mount -t erofs -o ro "$dev" "$mp" 2>/dev/null ||
        mount -o ro "$dev" "$mp" 2>/dev/null
}

ensure_vendor_mounts()
{
    mount_if_needed /proc proc proc ""
    mount_if_needed /sys sysfs sysfs ""
    mount_if_needed /dev devtmpfs devtmpfs "mode=0755"

    slot="_a"
    if [ -r /proc/cmdline ]; then
        slot="$(sed -n 's/.*androidboot.slot_suffix=\([^ ]*\).*/\1/p' /proc/cmdline | head -n 1)"
        [ -n "$slot" ] || slot="_a"
    fi

    log "vendor mount: begin slot=$slot"
    mapper=/usr/local/libexec/kexec/map_super_partitions.py
    if [ -x "$mapper" ]; then
        if ! resolve_dm_by_name "vendor${slot}" >/dev/null 2>&1 ||
           ! resolve_dm_by_name "vendor_dlkm${slot}" >/dev/null 2>&1; then
            "$mapper" --slot "$slot" \
                --partition "vendor${slot}" \
                --partition "vendor_dlkm${slot}" >> "$LOG" 2>&1 || \
                log "vendor mount: map_super_partitions.py failed"
        fi
    else
        log "vendor mount: missing $mapper"
    fi

    mount_one_vendor_path "vendor${slot}" /vendor || true
    mount_one_vendor_path "vendor_dlkm${slot}" /vendor_dlkm || true

    {
        echo "--- vendor mounts ---"
        grep -E ' /(vendor|vendor_dlkm) ' /proc/mounts 2>/dev/null || true
        echo "--- vendor paths ---"
        ls -la /vendor/firmware /vendor/etc/firmware /vendor/lib/modules /vendor_dlkm/lib/modules 2>&1 | sed -n '1,160p'
    } >> "$LOG" 2>&1
    return 0
}
