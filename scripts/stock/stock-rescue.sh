#!/system/bin/sh

RESCUE_DIR="${RESCUE_DIR:-/data/local/tmp/stock-rescue}"
CONF_FILE="${CONF_FILE:-$RESCUE_DIR/stock-rescue.conf}"
LOG_FILE="${LOG_FILE:-/data/local/tmp/stock-rescue.log}"

DROPBEAR_LISTEN="${DROPBEAR_LISTEN:-127.0.0.1:22}"
DROPBEAR_EXTRA_LISTEN="${DROPBEAR_EXTRA_LISTEN:-}"
DROPBEAR_BIN="${DROPBEAR_BIN:-$RESCUE_DIR/dropbear}"
DROPBEARKEY_BIN="${DROPBEARKEY_BIN:-$RESCUE_DIR/dropbearkey}"
DROPBEAR_PID="${DROPBEAR_PID:-$RESCUE_DIR/dropbear.pid}"
DROPBEAR_ED25519_KEY="${DROPBEAR_ED25519_KEY:-$RESCUE_DIR/dropbear_ed25519_host_key}"
DROPBEAR_RSA_KEY="${DROPBEAR_RSA_KEY:-$RESCUE_DIR/dropbear_rsa_host_key}"
AUTHORIZED_KEYS="${AUTHORIZED_KEYS:-$RESCUE_DIR/authorized_keys}"

SSH_CLIENT_BIN="${SSH_CLIENT_BIN:-${DBCLIENT_BIN:-}}"
SSH_CLIENT_TYPE="${SSH_CLIENT_TYPE:-dropbear}"
ORACLE_HOST="${ORACLE_HOST:-}"
ORACLE_USER="${ORACLE_USER:-}"
ORACLE_PORT="${ORACLE_PORT:-22}"
ORACLE_IDENTITY="${ORACLE_IDENTITY:-$RESCUE_DIR/oracle_ed25519}"
ORACLE_REMOTE_BIND="${ORACLE_REMOTE_BIND:-127.0.0.1}"
ORACLE_REMOTE_PORT="${ORACLE_REMOTE_PORT:-22023}"

BOOT_WAIT_SEC="${BOOT_WAIT_SEC:-180}"
NET_WAIT_SEC="${NET_WAIT_SEC:-180}"
REVERSE_RETRY_SEC="${REVERSE_RETRY_SEC:-30}"

[ -r "$CONF_FILE" ] && . "$CONF_FILE"

mkdir -p "$RESCUE_DIR" "$(dirname "$LOG_FILE")"

log()
{
    printf '%s stock-rescue: %s\n' "$(date -Is 2>/dev/null || date)" "$*" >> "$LOG_FILE"
    printf 'stock-rescue: %s\n' "$*" > /dev/kmsg 2>/dev/null || true
}

wait_boot_completed()
{
    deadline=$(( $(date +%s 2>/dev/null || echo 0) + BOOT_WAIT_SEC ))
    while :; do
        [ "$(getprop sys.boot_completed 2>/dev/null)" = 1 ] && return 0
        now="$(date +%s 2>/dev/null || echo 0)"
        [ "$now" -ge "$deadline" ] && return 1
        sleep 2
    done
}

wait_network()
{
    deadline=$(( $(date +%s 2>/dev/null || echo 0) + NET_WAIT_SEC ))
    while :; do
        if ip route show default 2>/dev/null | grep -q .; then
            return 0
        fi
        now="$(date +%s 2>/dev/null || echo 0)"
        [ "$now" -ge "$deadline" ] && return 1
        sleep 3
    done
}

install_authorized_keys()
{
    [ -s "$AUTHORIZED_KEYS" ] || {
        log "missing authorized_keys at $AUTHORIZED_KEYS"
        return 1
    }

    mkdir -p "$RESCUE_DIR/root/.ssh" 2>/dev/null || true
    cp "$AUTHORIZED_KEYS" "$RESCUE_DIR/root/.ssh/authorized_keys" 2>/dev/null || true
    chmod 700 "$RESCUE_DIR/root" "$RESCUE_DIR/root/.ssh" 2>/dev/null || true
    chmod 600 "$RESCUE_DIR/root/.ssh/authorized_keys" 2>/dev/null || true

    if [ -w /etc ] || touch /etc/.stock-rescue-test 2>/dev/null; then
        rm -f /etc/.stock-rescue-test 2>/dev/null || true
        printf 'root:x:0:0:root:%s/root:/system/bin/sh\n' "$RESCUE_DIR" > /etc/passwd 2>/dev/null || true
        printf 'root:!:1::::::\n' > /etc/shadow 2>/dev/null || true
        printf 'root:x:0:\n' > /etc/group 2>/dev/null || true
        chmod 644 /etc/passwd /etc/group 2>/dev/null || true
        chmod 600 /etc/shadow 2>/dev/null || true
    fi

    # Keep common fallback locations populated if the stock rootfs allows it.
    for home in / /root "$RESCUE_DIR/root"; do
        mkdir -p "$home/.ssh" 2>/dev/null || continue
        cp "$AUTHORIZED_KEYS" "$home/.ssh/authorized_keys" 2>/dev/null || continue
        chmod 700 "$home/.ssh" 2>/dev/null || true
        chmod 600 "$home/.ssh/authorized_keys" 2>/dev/null || true
    done
}

ensure_host_keys()
{
    [ -x "$DROPBEARKEY_BIN" ] || return 0
    if [ ! -s "$DROPBEAR_ED25519_KEY" ]; then
        "$DROPBEARKEY_BIN" -t ed25519 -f "$DROPBEAR_ED25519_KEY" >> "$LOG_FILE" 2>&1 || true
    fi
    if [ ! -s "$DROPBEAR_RSA_KEY" ]; then
        "$DROPBEARKEY_BIN" -t rsa -s 2048 -f "$DROPBEAR_RSA_KEY" >> "$LOG_FILE" 2>&1 || true
    fi
}

dropbear_supports()
{
    "$DROPBEAR_BIN" -h 2>&1 | grep -q -- "$1"
}

start_dropbear()
{
    [ -x "$DROPBEAR_BIN" ] || {
        log "missing dropbear at $DROPBEAR_BIN"
        return 1
    }

    if [ -s "$DROPBEAR_PID" ] && kill -0 "$(cat "$DROPBEAR_PID")" 2>/dev/null; then
        log "dropbear already running pid=$(cat "$DROPBEAR_PID")"
        return 0
    fi

    install_authorized_keys || true
    ensure_host_keys

    opts="-E -F -m -T 3 -p $DROPBEAR_LISTEN -P $DROPBEAR_PID"
    [ -n "$DROPBEAR_EXTRA_LISTEN" ] && opts="$opts -p $DROPBEAR_EXTRA_LISTEN"
    [ -s "$DROPBEAR_ED25519_KEY" ] && opts="$opts -r $DROPBEAR_ED25519_KEY"
    [ -s "$DROPBEAR_RSA_KEY" ] && opts="$opts -r $DROPBEAR_RSA_KEY"
    dropbear_supports "^-s" && opts="$opts -s"
    dropbear_supports "^-g" && opts="$opts -g"

    log "starting dropbear listen=$DROPBEAR_LISTEN extra=${DROPBEAR_EXTRA_LISTEN:-none}"
    # shellcheck disable=SC2086
    "$DROPBEAR_BIN" $opts >> "$LOG_FILE" 2>&1 &
}

reverse_ssh_ready()
{
    [ -n "$SSH_CLIENT_BIN" ] || return 1
    [ -x "$SSH_CLIENT_BIN" ] || return 1
    [ -n "$ORACLE_HOST" ] || return 1
    [ -n "$ORACLE_USER" ] || return 1
    [ -s "$ORACLE_IDENTITY" ] || return 1
    return 0
}

run_reverse_ssh()
{
    case "$SSH_CLIENT_TYPE" in
        openssh)
            "$SSH_CLIENT_BIN" \
                -N \
                -o ServerAliveInterval=30 \
                -o ServerAliveCountMax=4 \
                -o ExitOnForwardFailure=yes \
                -o StrictHostKeyChecking=accept-new \
                -i "$ORACLE_IDENTITY" \
                -p "$ORACLE_PORT" \
                -R "${ORACLE_REMOTE_BIND}:${ORACLE_REMOTE_PORT}:${DROPBEAR_LISTEN}" \
                "$ORACLE_USER@$ORACLE_HOST"
            ;;
        *)
            "$SSH_CLIENT_BIN" \
                -N \
                -y \
                -K 30 \
                -I 120 \
                -i "$ORACLE_IDENTITY" \
                -p "$ORACLE_PORT" \
                -R "${ORACLE_REMOTE_BIND}:${ORACLE_REMOTE_PORT}:${DROPBEAR_LISTEN}" \
                "$ORACLE_USER@$ORACLE_HOST"
            ;;
    esac
}

reverse_ssh_loop()
{
    reverse_ssh_ready || {
        log "reverse ssh disabled or incomplete"
        return 0
    }

    while :; do
        log "starting reverse ssh ${ORACLE_REMOTE_BIND}:${ORACLE_REMOTE_PORT} -> $DROPBEAR_LISTEN via $ORACLE_USER@$ORACLE_HOST"
        run_reverse_ssh >> "$LOG_FILE" 2>&1
        rc=$?
        log "reverse ssh exited rc=$rc; retrying in ${REVERSE_RETRY_SEC}s"
        sleep "$REVERSE_RETRY_SEC"
    done
}

main()
{
    : > "$LOG_FILE"
    log "start rescue_dir=$RESCUE_DIR"
    wait_boot_completed || log "boot_completed wait timed out"
    wait_network || log "network wait timed out"
    start_dropbear || true
    reverse_ssh_loop &
    log "ready"
}

main "$@"
