#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

REMOTE_DIR="${REMOTE_DIR:-/data/local/tmp/stock-rescue}"
SERVICE_PATH="${SERVICE_PATH:-/data/adb/service.d/stock-rescue.sh}"
XAGA_DIR="${XAGA_DIR:-/data/local/tmp/xaga}"
REBOOT_TO_UBUNTU="${REBOOT_TO_UBUNTU:-$XAGA_DIR/reboot-to-ubuntu.sh}"
AUTHORIZED_KEYS="${AUTHORIZED_KEYS:-$HOME/.ssh/authorized_keys}"
SSH_CLIENT_BIN="${SSH_CLIENT_BIN:-${DBCLIENT_BIN:-$ROOT/prebuilt/dbclient}}"
ORACLE_IDENTITY="${ORACLE_IDENTITY:-}"
CONF_FILE="${CONF_FILE:-}"

for path in "$ROOT/prebuilt/dropbear" "$ROOT/prebuilt/dropbearkey" "$ROOT/prebuilt/dbclient" \
  "$ROOT/prebuilt/dropbear-ns" "$ROOT/scripts/stock/stock-rescue.sh" \
  "$ROOT/scripts/stock/reboot-to-ubuntu.sh"; do
  [ -s "$path" ] || { echo "missing required file: $path" >&2; exit 1; }
done

if [ ! -s "$AUTHORIZED_KEYS" ]; then
  echo "missing AUTHORIZED_KEYS file: $AUTHORIZED_KEYS" >&2
  echo "pass AUTHORIZED_KEYS=/path/to/authorized_keys" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup()
{
  rm -rf "$tmp"
}
trap cleanup EXIT

cp "$ROOT/prebuilt/dropbear" "$tmp/dropbear"
cp "$ROOT/prebuilt/dropbearkey" "$tmp/dropbearkey"
cp "$ROOT/scripts/stock/stock-rescue.sh" "$tmp/stock-rescue.sh"
cp "$ROOT/prebuilt/dropbear-ns" "$tmp/dropbear-ns"
cp "$AUTHORIZED_KEYS" "$tmp/authorized_keys"

if [ -n "$CONF_FILE" ]; then
  [ -s "$CONF_FILE" ] || { echo "CONF_FILE not found: $CONF_FILE" >&2; exit 1; }
  cp "$CONF_FILE" "$tmp/stock-rescue.conf"
else
  cp "$ROOT/scripts/stock/stock-rescue.conf.sample" "$tmp/stock-rescue.conf"
fi

if [ -n "$SSH_CLIENT_BIN" ]; then
  [ -s "$SSH_CLIENT_BIN" ] || { echo "SSH_CLIENT_BIN not found: $SSH_CLIENT_BIN" >&2; exit 1; }
  cp "$SSH_CLIENT_BIN" "$tmp/ssh-client"
fi

if [ -n "$ORACLE_IDENTITY" ]; then
  [ -s "$ORACLE_IDENTITY" ] || { echo "ORACLE_IDENTITY not found: $ORACLE_IDENTITY" >&2; exit 1; }
  cp "$ORACLE_IDENTITY" "$tmp/oracle_ed25519"
fi

chmod 0755 "$tmp/dropbear" "$tmp/dropbearkey" "$tmp/stock-rescue.sh" \
  "$tmp/dropbear-ns"
[ ! -e "$tmp/ssh-client" ] || chmod 0755 "$tmp/ssh-client"
chmod 0600 "$tmp/authorized_keys"
[ ! -e "$tmp/oracle_ed25519" ] || chmod 0600 "$tmp/oracle_ed25519"

echo "installing stock rescue to $REMOTE_DIR"
"$ADB" push "$tmp/." "$REMOTE_DIR/"
"$ADB" shell "mkdir -p $XAGA_DIR"
"$ADB" push "$ROOT/scripts/stock/reboot-to-ubuntu.sh" "$REBOOT_TO_UBUNTU"
"$ADB" shell "su -c 'mkdir -p /data/adb/service.d; cp $REMOTE_DIR/stock-rescue.sh $SERVICE_PATH; chmod 0755 $XAGA_DIR $SERVICE_PATH $REMOTE_DIR/stock-rescue.sh $REMOTE_DIR/dropbear-ns $REMOTE_DIR/dropbear $REMOTE_DIR/dropbearkey $REBOOT_TO_UBUNTU; [ ! -e $REMOTE_DIR/ssh-client ] || chmod 0755 $REMOTE_DIR/ssh-client; chmod 0600 $REMOTE_DIR/authorized_keys; [ ! -e $REMOTE_DIR/oracle_ed25519 ] || chmod 0600 $REMOTE_DIR/oracle_ed25519; rm -f $REMOTE_DIR/reboot-to-ubuntu.sh /data/local/tmp/reboot-to-ubuntu.sh; sync; ls -l $SERVICE_PATH $REMOTE_DIR $REBOOT_TO_UBUNTU'"

echo "installed. Start without reboot:"
echo "  $ADB shell \"su -c '$SERVICE_PATH'\""
