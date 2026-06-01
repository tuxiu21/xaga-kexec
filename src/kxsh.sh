#!/data/kexec/busybox sh

BB=/data/kexec/busybox
DATA_BASE=/data/kexec
PATH=/data/kexec:/system/bin:/vendor/bin
export PATH

log()
{
    echo "kexec-system-init: $*" > /dev/kmsg 2>/dev/null
}

mount_if_needed()
{
    mp="$1"
    type="$2"
    src="$3"
    opts="$4"

    "$BB" mkdir -p "$mp"
    "$BB" grep -q " $mp " /proc/mounts 2>/dev/null && return 0
    if [ -n "$opts" ]; then
        "$BB" mount -t "$type" -o "$opts" "$src" "$mp" 2>/dev/null
    else
        "$BB" mount -t "$type" "$src" "$mp" 2>/dev/null
    fi
}

prepare_base()
{
    "$BB" --install -s /data/kexec 2>/dev/null
    mount_if_needed /proc proc proc ""
    mount_if_needed /sys sysfs sysfs ""
    mount_if_needed /dev devtmpfs devtmpfs "mode=0755"
    mount_if_needed /dev/pts devpts devpts "mode=0620,ptmxmode=0666"
    mount_if_needed /etc tmpfs tmpfs "mode=0755"
    mount_if_needed /run tmpfs tmpfs "mode=0755"
    mount_if_needed /tmp tmpfs tmpfs "mode=1777"
    mount_if_needed /config configfs configfs ""
    "$BB" ln -sf /dev/pts/ptmx /dev/ptmx 2>/dev/null
}

prepare_accounts()
{
    "$BB" mkdir -p /etc "$DATA_BASE/root/.ssh" "$DATA_BASE/run"
    echo 'root::0:0:root:/data/kexec/root:/data/kexec/sh' > /etc/passwd 2>/dev/null
    echo 'root:x:0:' > /etc/group 2>/dev/null
    echo 'root::10933:0:99999:7:::' > /etc/shadow 2>/dev/null
    "$BB" chmod 644 /etc/passwd /etc/group 2>/dev/null
    "$BB" chmod 600 /etc/shadow 2>/dev/null

    if [ -s "$DATA_BASE/authorized_keys" ]; then
        "$BB" cp "$DATA_BASE/authorized_keys" "$DATA_BASE/root/.ssh/authorized_keys" 2>/dev/null
        "$BB" chmod 700 "$DATA_BASE/root" "$DATA_BASE/root/.ssh" 2>/dev/null
        "$BB" chmod 600 "$DATA_BASE/root/.ssh/authorized_keys" 2>/dev/null
    fi
}

start_watchdog_feeder()
{
    for node in /sys/class/watchdog/watchdog*/dev; do
        [ -r "$node" ] || continue
        name="${node%/dev}"
        name="${name##*/}"
        major_minor="$("$BB" cat "$node" 2>/dev/null)"
        major="${major_minor%:*}"
        minor="${major_minor#*:}"
        case "$major:$minor" in
            *[!0-9:]*|:|*:)
                continue
                ;;
        esac
        [ -e "/dev/$name" ] || "$BB" mknod "/dev/$name" c "$major" "$minor" 2>/dev/null
        [ -e /dev/watchdog ] || "$BB" ln -s "/dev/$name" /dev/watchdog 2>/dev/null
    done

    (
        while true; do
            [ -e /dev/watchdog ] && echo V > /dev/watchdog 2>/dev/null
            [ -e /dev/watchdog0 ] && echo V > /dev/watchdog0 2>/dev/null
            "$BB" sleep 5
        done
    ) &
    log "watchdog feeder started"
}

start_panic_timer()
{
    after=90
    if [ -s "$DATA_BASE/panic_after" ]; then
        after="$("$BB" cat "$DATA_BASE/panic_after" 2>/dev/null)"
    fi

    case "$after" in
        ''|*[!0-9]*|0)
            log "panic timer disabled"
            return 0
            ;;
    esac

    (
        log "panic timer armed: ${after}s"
        "$BB" sleep "$after"
        log "panic timer firing"
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
        echo c > /proc/sysrq-trigger 2>/dev/null
        echo panic > /proc/sysrq-trigger 2>/dev/null
    ) &
}

setup_usb_rndis()
{
    [ -d /sys/class/udc ] || return 0
    [ -d /config/usb_gadget ] || return 0
    udc="$("$BB" ls /sys/class/udc 2>/dev/null | "$BB" head -n 1)"
    [ -n "$udc" ] || return 0

    g=/config/usb_gadget/g1
    if [ ! -d "$g" ]; then
        log "creating rndis gadget"
        "$BB" mkdir -p "$g/strings/0x409" "$g/configs/c.1/strings/0x409" 2>/dev/null
        echo 0x18d1 > "$g/idVendor" 2>/dev/null
        echo 0x4ee4 > "$g/idProduct" 2>/dev/null
        echo 0x0200 > "$g/bcdUSB" 2>/dev/null
        echo 0x0100 > "$g/bcdDevice" 2>/dev/null
        echo kexec-dropbear > "$g/strings/0x409/manufacturer" 2>/dev/null
        echo rescue-rndis > "$g/strings/0x409/product" 2>/dev/null
        echo 0123456789abcdef > "$g/strings/0x409/serialnumber" 2>/dev/null
        echo rndis > "$g/configs/c.1/strings/0x409/configuration" 2>/dev/null
        echo 500 > "$g/configs/c.1/MaxPower" 2>/dev/null
        "$BB" mkdir -p "$g/functions/rndis.gs4" 2>/dev/null || return 0
        "$BB" ln -s "$g/functions/rndis.gs4" "$g/configs/c.1/rndis.gs4" 2>/dev/null
    fi

    cur="$("$BB" cat "$g/UDC" 2>/dev/null)"
    if [ -z "$cur" ] && [ -w "$g/UDC" ]; then
        log "binding rndis gadget to $udc"
        echo "$udc" > "$g/UDC" 2>/dev/null
        "$BB" sleep 2
    fi
}

setup_network()
{
    "$BB" ifconfig lo up 2>/dev/null
    setup_usb_rndis
    for iface in usb0 rndis0 eth0 enx0; do
        [ -d "/sys/class/net/$iface" ] || continue
        log "configuring $iface"
        "$BB" ifconfig "$iface" 192.168.66.2 netmask 255.255.255.0 up 2>/dev/null
        "$BB" ip addr add 198.18.0.2/15 dev "$iface" 2>/dev/null
    done
}

start_dropbear()
{
    if [ ! -x "$DATA_BASE/dropbear" ]; then
        log "missing $DATA_BASE/dropbear"
        return 1
    fi

    if [ ! -s "$DATA_BASE/dropbear_ed25519_host_key" ] && [ -x "$DATA_BASE/dropbearkey" ]; then
        log "generating ed25519 host key"
        "$DATA_BASE/dropbearkey" -t ed25519 -f "$DATA_BASE/dropbear_ed25519_host_key" > /dev/kmsg 2>&1
    fi

    if [ ! -s "$DATA_BASE/dropbear_rsa_host_key" ] && [ -x "$DATA_BASE/dropbearkey" ]; then
        log "generating rsa host key"
        "$DATA_BASE/dropbearkey" -t rsa -s 2048 -f "$DATA_BASE/dropbear_rsa_host_key" > /dev/kmsg 2>&1
    fi

    log "starting dropbear on 0.0.0.0:22"
    "$DATA_BASE/dropbear" -E -F -p 0.0.0.0:22 -P "$DATA_BASE/run/dropbear.pid" \
        -r "$DATA_BASE/dropbear_ed25519_host_key" \
        -r "$DATA_BASE/dropbear_rsa_host_key" \
        > /dev/kmsg 2>&1 &
}

log "entered /data/kexec/kxsh.sh"
prepare_base
prepare_accounts
start_watchdog_feeder
start_panic_timer
setup_network
start_dropbear
log "ready; try ssh root@192.168.66.2"

while true; do
    "$BB" sleep 10
done
