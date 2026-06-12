#!/data/kexec/busybox sh

BB=/data/kexec/busybox
DATA_BASE=/data/kexec
LOG_FILE=/data/kexec/kxsh.log
ADBD_LOG=/data/kexec/adbd.log
PATH=/data/kexec:/system/bin:/vendor/bin
export PATH

log()
{
    msg="kexec-system-init: $*"
    echo "$msg" > /dev/kmsg 2>/dev/null
    echo "$msg" >> "$LOG_FILE" 2>/dev/null
}

log_file()
{
    label="$1"
    path="$2"

    if [ -e "$path" ]; then
        val="$("$BB" cat "$path" 2>/dev/null)"
        log "$label: $val"
    else
        log "$label: missing $path"
    fi
}

log_ls()
{
    label="$1"
    path="$2"

    log "$label:"
    "$BB" ls -la "$path" > /dev/kmsg 2>&1
    {
        echo "kexec-system-init: $label:"
        "$BB" ls -la "$path" 2>&1
    } >> "$LOG_FILE" 2>/dev/null
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
        "$BB" date -u -s "2026-06-12 14:00:00" >/dev/null 2>&1 && \
            log "time fallback applied: $("$BB" date -u 2>/dev/null)"
    else
        log "time ok: $("$BB" date -u 2>/dev/null)"
    fi
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
    "$BB" mkdir -p /system/bin /bin 2>/dev/null
    if [ -x "$DATA_BASE/linker64" ] && [ ! -e /system/bin/linker64 ]; then
        "$BB" mount -t tmpfs -o mode=0755 tmpfs /system/bin 2>/dev/null
    fi
    "$BB" ln -sf /data/kexec/sh /system/bin/sh 2>/dev/null
    "$BB" ln -sf /data/kexec/sh /bin/sh 2>/dev/null
    if [ -x "$DATA_BASE/linker64" ]; then
        "$BB" ln -sf "$DATA_BASE/linker64" /system/bin/linker64 2>/dev/null
    fi
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

    if [ -x "$DATA_BASE/watchdog_feeder" ]; then
        "$DATA_BASE/watchdog_feeder" 5 &
        log "watchdog C feeder started pid=$!"
        return 0
    fi

    (
        while true; do
            [ -e /dev/watchdog0 ] && echo V > /dev/watchdog0 2>/dev/null
            "$BB" sleep 5
        done
    ) &
    log "watchdog shell feeder started"
}

cleanup_usb_before_panic()
{
    log "panic cleanup: begin"

    g=/config/usb_gadget/g1
    if [ -e "$g/UDC" ]; then
        cur="$("$BB" cat "$g/UDC" 2>/dev/null)"
        if [ -n "$cur" ]; then
            log "panic cleanup: unbinding USB gadget from $cur"
            echo "" > "$g/UDC" 2>/dev/null
            log "panic cleanup: UDC unbind rc=$?"
        else
            log "panic cleanup: USB gadget already unbound"
        fi
    else
        log "panic cleanup: no gadget UDC node"
    fi

    if "$BB" pidof adbd >/dev/null 2>&1; then
        log "panic cleanup: stopping adbd"
        "$BB" killall adbd 2>/dev/null
        "$BB" sleep 1
    fi

    if "$BB" pidof dropbear >/dev/null 2>&1; then
        log "panic cleanup: stopping dropbear"
        "$BB" killall dropbear 2>/dev/null
    fi

    "$BB" sync 2>/dev/null
    log "panic cleanup: end"
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
        cleanup_usb_before_panic
        echo 1 > /proc/sys/kernel/sysrq 2>/dev/null
        echo c > /proc/sysrq-trigger 2>/dev/null
        echo panic > /proc/sysrq-trigger 2>/dev/null
    ) &
}

setup_usb_adb()
{
    log "setup_usb_adb: begin"
    "$BB" ifconfig lo up 2>/dev/null

    [ -d /sys/class/udc ] || {
        log "no UDC class; skipping adb gadget"
        return 0
    }
    [ -d /config/usb_gadget ] || {
        log "no configfs usb_gadget; skipping adb gadget"
        return 0
    }
    [ -x "$DATA_BASE/adbd" ] || {
        log "missing $DATA_BASE/adbd"
        return 0
    }
    [ -x "$DATA_BASE/linker64" ] || log "missing $DATA_BASE/linker64; adbd exec may fail"
    [ -e /system/bin/linker64 ] || log "missing /system/bin/linker64; adbd exec may fail"
    log_ls "system bin runtime" /system/bin

    log_ls "UDC candidates" /sys/class/udc

    if [ -e /sys/fs/selinux/enforce ]; then
        echo 0 > /sys/fs/selinux/enforce 2>/dev/null && log "SELinux set permissive"
        log_file "SELinux enforce" /sys/fs/selinux/enforce
    fi

    udc="$("$BB" ls /sys/class/udc 2>/dev/null | "$BB" head -n 1)"
    [ -n "$udc" ] || {
        log "no UDC available; skipping adb gadget"
        return 0
    }
    log "selected UDC: $udc"

    g=/config/usb_gadget/g1
    "$BB" mkdir -p "$g/strings/0x409" "$g/configs/c.1/strings/0x409" 2>/dev/null || {
        log "failed to create gadget directories"
        return 0
    }
    cur="$("$BB" cat "$g/UDC" 2>/dev/null)"
    log "initial gadget UDC: ${cur:-unbound}"
    if [ -n "$cur" ]; then
        echo "" > "$g/UDC" 2>/dev/null
        log "unbound existing gadget rc=$?"
    fi

    echo 0x2717 > "$g/idVendor" 2>/dev/null
    echo 0xff08 > "$g/idProduct" 2>/dev/null
    echo 0x0200 > "$g/bcdUSB" 2>/dev/null
    echo 0x0100 > "$g/bcdDevice" 2>/dev/null
    echo kexec-adbd > "$g/strings/0x409/manufacturer" 2>/dev/null
    echo rescue-adb > "$g/strings/0x409/product" 2>/dev/null
    echo 0123456789abcdef > "$g/strings/0x409/serialnumber" 2>/dev/null
    echo adb > "$g/configs/c.1/strings/0x409/configuration" 2>/dev/null
    echo 500 > "$g/configs/c.1/MaxPower" 2>/dev/null
    log_file "gadget idVendor" "$g/idVendor"
    log_file "gadget idProduct" "$g/idProduct"

    "$BB" mkdir -p "$g/functions/ffs.adb" /dev/usb-ffs/adb 2>/dev/null || {
        log "failed to create ffs.adb directories"
        return 0
    }
    log "created ffs.adb directories"
    "$BB" grep -q " /dev/usb-ffs/adb " /proc/mounts 2>/dev/null || \
        "$BB" mount -t functionfs adb /dev/usb-ffs/adb 2>/dev/null || {
            log "failed to mount adb FunctionFS"
            return 0
        }
    log "mounted adb FunctionFS"
    log_ls "adb FunctionFS before adbd" /dev/usb-ffs/adb

    if ! "$BB" pidof adbd >/dev/null 2>&1; then
        log "starting lean adbd"
        : > "$ADBD_LOG" 2>/dev/null
        LD_LIBRARY_PATH="$DATA_BASE/adblib" "$DATA_BASE/adbd" >> "$ADBD_LOG" 2>&1 &
        adbd_pid=$!
        log "adbd pid=$adbd_pid"
    else
        adbd_pid="$("$BB" pidof adbd 2>/dev/null)"
        log "adbd already running pid=$adbd_pid"
    fi

    "$BB" sleep 1
    if "$BB" kill -0 "$adbd_pid" 2>/dev/null; then
        log "adbd alive after 1s"
    else
        log "adbd not alive after 1s"
    fi
    log_ls "adb FunctionFS after adbd start" /dev/usb-ffs/adb

    ready=0
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [ -e /dev/usb-ffs/adb/ep1 ] && {
            ready=1
            break
        }
        "$BB" sleep 1
    done

    if [ "$ready" != "1" ]; then
        log "adbd did not publish FunctionFS endpoints"
        log_ls "adb FunctionFS endpoint wait failed" /dev/usb-ffs/adb
        if [ -s "$ADBD_LOG" ]; then
            log "adbd log:"
            "$BB" cat "$ADBD_LOG" > /dev/kmsg 2>&1
            {
                echo "kexec-system-init: adbd log:"
                "$BB" cat "$ADBD_LOG" 2>&1
            } >> "$LOG_FILE" 2>/dev/null
        fi
        return 0
    fi
    log "adbd published FunctionFS endpoints"

    if ! "$BB" pidof adbd >/dev/null 2>&1; then
        log "adbd exited before USB bind"
        return 0
    fi

    [ -e "$g/configs/c.1/ffs.adb" ] || \
        "$BB" ln -s "$g/functions/ffs.adb" "$g/configs/c.1/ffs.adb" 2>/dev/null
    ln_rc=$?
    log "linked ffs.adb into config rc=$ln_rc"
    log_ls "gadget config c.1" "$g/configs/c.1"

    cur="$("$BB" cat "$g/UDC" 2>/dev/null)"
    if [ -z "$cur" ] && [ -w "$g/UDC" ]; then
        log "binding adb gadget to $udc"
        echo "$udc" > "$g/UDC" 2>/dev/null
        bind_rc=$?
        log "UDC bind rc=$bind_rc"
        log_file "gadget UDC after bind" "$g/UDC"
    else
        log "skip UDC bind; cur=${cur:-empty} writable=$([ -w "$g/UDC" ] && echo yes || echo no)"
    fi

    # Verify the host actually enumerated us. /sys/class/udc/$udc/state reads
    # "configured" once the host has set our USB configuration. After a kexec
    # (especially rapid retry churn) the host USB stack can go stale and never
    # enumerate the fresh gadget: adbd then spins forever "waiting for
    # FUNCTIONFS_BIND" and `adb devices` shows nothing even though lean is fine.
    # Force a device-side re-plug -- drop then re-assert the UDC pull-up -- which
    # the host sees as a disconnect+new-connect and re-enumerates. Only toggle
    # when not yet "configured", so a normal fast enumeration is left untouched.
    state_node="/sys/class/udc/$udc/state"
    enumerated=0
    for attempt in 1 2 3 4 5; do
        "$BB" sleep 2
        st="$("$BB" cat "$state_node" 2>/dev/null)"
        if [ "$st" = "configured" ]; then
            log "host enumerated (udc state=configured, attempt $attempt)"
            enumerated=1
            break
        fi
        log "not enumerated (udc state=${st:-unknown}, attempt $attempt); re-plugging UDC pull-up"
        echo "" > "$g/UDC" 2>/dev/null
        "$BB" sleep 1
        echo "$udc" > "$g/UDC" 2>/dev/null
    done
    [ "$enumerated" = 1 ] || \
        log "host still not enumerated after retries (udc state=$("$BB" cat "$state_node" 2>/dev/null))"
    log "setup_usb_adb: end"
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

: > "$LOG_FILE" 2>/dev/null
log "entered /data/kexec/kxsh.sh"
prepare_base
ensure_reasonable_time
prepare_accounts
start_watchdog_feeder
start_panic_timer
setup_usb_adb
start_dropbear
log "ready; try adb shell, or adb forward tcp:2222 tcp:22"

# One-shot on-boot debug hook: if the flag exists, run a probe script and dump
# to /data/kexec (shared f2fs, survives the fall-back to stock). Decouples
# bring-up tests from the intermittent host enumeration of the lean adb gadget.
# The flag is removed first so it runs exactly once even across reboots.
if [ -f /data/kexec/run_wifi_probe ]; then
    "$BB" rm -f /data/kexec/run_wifi_probe
    log "running one-shot wifi_probe5.sh"
    "$BB" sh /data/kexec/wifi_probe5.sh >> "$LOG_FILE" 2>&1
    log "wifi_probe5.sh done; see /data/kexec/wifi_probe5.log"
fi

while true; do
    "$BB" sleep 10
done
