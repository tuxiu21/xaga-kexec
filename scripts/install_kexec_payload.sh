#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/env.sh"

KERNEL_IMAGE="${KERNEL_IMAGE:-$AK/out/android12-5.10/dist/Image}"
KEXEC_BIN="${KEXEC_BIN:-$KEXEC_TOOLS/build/sbin/kexec}"
INITRD="${INITRD:-$OUTPUT_DIR/combined_ramdisk_kexec_system_mbox.lz4}"

for path in "$KEXEC_BIN" "$INITRD"; do
  if [ ! -s "$path" ]; then
    echo "missing required file: $path" >&2
    exit 1
  fi
done

tmp="$(mktemp -d)"
cleanup()
{
  rm -rf "$tmp"
}
trap cleanup EXIT

if [ ! -s "$KERNEL_IMAGE" ]; then
  echo "missing required file: $KERNEL_IMAGE" >&2
  echo "build it with scripts/build_gki_logged.sh, or pass KERNEL_IMAGE=/path/to/Image" >&2
  exit 1
fi

strings "$KERNEL_IMAGE" > "$tmp/kernel.strings"

echo "installing kexec runtime payload"
echo "kernel: $KERNEL_IMAGE"
grep -m 1 -E 'Linux version|5[.]10[.]226|android12' "$tmp/kernel.strings" || true

"$ADB" push "$KERNEL_IMAGE" /data/local/tmp/kernel
"$ADB" push "$KEXEC_BIN" /data/local/tmp/kexec
"$ADB" push "$INITRD" "/data/local/tmp/$(basename "$INITRD")"
"$ADB" shell "su -c 'chmod 0644 /data/local/tmp/kernel /data/local/tmp/$(basename "$INITRD"); chmod 0755 /data/local/tmp/kexec; sync'"

"$ROOT/scripts/build_always_on_dtb.sh"

"$ADB" shell "su -c 'chmod 0644 /data/local/tmp/patched.dtb; sync'"
"$ADB" shell "su -c 'sync; ls -l /data/local/tmp/kernel /data/local/tmp/kexec /data/local/tmp/$(basename "$INITRD") /data/local/tmp/patched.dtb; sha256sum /data/local/tmp/kernel; toybox file /data/local/tmp/kernel 2>/dev/null || true'"
