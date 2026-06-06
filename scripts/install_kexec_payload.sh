#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/home/in/work/kernels}"
ADB="${ADB:-adb.exe}"
BOOTIMG="${BOOTIMG:-$ROOT/old/5.10.226/260531-ramsize-docker.img}"
KEXEC_BIN="${KEXEC_BIN:-$ROOT/sources/kexec-tools-2.0.28/build/sbin/kexec}"
INITRD="${INITRD:-$ROOT/output/combined_ramdisk_kexec_system.lz4}"
EXPECTED_KERNEL_TAG="${EXPECTED_KERNEL_TAG:-5.10.226-android12-9-00004-gb34cbf2f8043-dirty}"

for path in "$BOOTIMG" "$KEXEC_BIN" "$INITRD"; do
  if [ ! -s "$path" ]; then
    echo "missing required file: $path" >&2
    exit 1
  fi
done

if ! command -v magiskboot >/dev/null 2>&1; then
  echo "missing magiskboot in PATH" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup()
{
  rm -rf "$tmp"
}
trap cleanup EXIT

(
  cd "$tmp"
  magiskboot unpack "$BOOTIMG" >/dev/null
)

if [ ! -s "$tmp/kernel" ]; then
  echo "failed to unpack kernel from $BOOTIMG" >&2
  exit 1
fi

strings "$tmp/kernel" > "$tmp/kernel.strings"

if ! grep -qF "$EXPECTED_KERNEL_TAG" "$tmp/kernel.strings"; then
  echo "unpacked kernel does not contain expected tag:" >&2
  echo "  $EXPECTED_KERNEL_TAG" >&2
  echo "found:" >&2
  grep -m 5 -E 'Linux version|5[.]10[.]226|android12' "$tmp/kernel.strings" >&2 || true
  exit 1
fi

echo "installing kexec runtime payload"
echo "kernel: $BOOTIMG"
grep -m 1 -F "Linux version $EXPECTED_KERNEL_TAG" "$tmp/kernel.strings" || \
  grep -m 1 -F "$EXPECTED_KERNEL_TAG" "$tmp/kernel.strings"

"$ADB" push "$tmp/kernel" /data/local/tmp/kernel
"$ADB" push "$KEXEC_BIN" /data/local/tmp/kexec
"$ADB" push "$INITRD" "/data/local/tmp/$(basename "$INITRD")"
"$ADB" shell "su -c 'chmod 0644 /data/local/tmp/kernel /data/local/tmp/$(basename "$INITRD"); chmod 0755 /data/local/tmp/kexec; sync'"

"$ROOT/scripts/build_always_on_dtb.sh"

"$ADB" shell "su -c 'chmod 0644 /data/local/tmp/patched.dtb; sync'"
"$ADB" shell "su -c 'sync; ls -l /data/local/tmp/kernel /data/local/tmp/kexec /data/local/tmp/$(basename "$INITRD") /data/local/tmp/patched.dtb; sha256sum /data/local/tmp/kernel; toybox file /data/local/tmp/kernel 2>/dev/null || true'"
