#!/usr/bin/env bash
set -euo pipefail

ROOT="${ROOT:-/home/in/work/kernels}"
ADB="${ADB:-adb.exe}"
# Single source of truth: the LEAN AOSP adbd is frozen into prebuilt/adbd
# (the recovery variant -- the only one built with LEAN_KEXEC_ADBD). Regenerate
# it from AOSP with the commands printed below if prebuilt/adbd is ever missing.
ADBD="${ADBD:-$ROOT/prebuilt/adbd}"
RAMDISK="${RAMDISK:-$ROOT/vendor/ramdisk_patched.cpio}"

runtime=(
  system/bin/linker64
  system/lib64/liblog.so
  system/lib64/libselinux.so
  system/lib64/libbase.so
  system/lib64/libadb_protos.so
  system/lib64/libprotobuf-cpp-lite.so
  system/lib64/libadbd_auth.so
  system/lib64/libadbd_fs.so
  system/lib64/libcrypto.so
  system/lib64/libc++.so
  system/lib64/libc.so
  system/lib64/libm.so
  system/lib64/libdl.so
)

if [ ! -s "$ADBD" ]; then
  echo "missing lean adbd: $ADBD" >&2
  echo "regenerate it from the AOSP recovery build:" >&2
  echo "  cd $ROOT/sources/android-12.1 && source build/envsetup.sh && lunch aosp_arm64-eng && m adbd" >&2
  echo "  cp out/soong/.intermediates/packages/modules/adb/adbd/android_recovery_arm64_armv8-a/adbd $ROOT/prebuilt/adbd" >&2
  exit 1
fi

if ! grep -qa 'LEAN_KEXEC_ADBD' "$ADBD"; then
  echo "refusing to install non-lean adbd: $ADBD" >&2
  echo "expected LEAN_KEXEC_ADBD markers in packages/modules/adb/daemon/main.cpp build output" >&2
  exit 1
fi

if [ ! -f "$RAMDISK" ]; then
  echo "missing runtime ramdisk: $RAMDISK" >&2
  exit 1
fi

tmp="$(mktemp -d)"
cleanup()
{
  rm -rf "$tmp"
}
trap cleanup EXIT

extract_runtime_with_magiskboot()
{
  command -v magiskboot >/dev/null 2>&1 || return 1

  mkdir -p "$tmp/magisk"
  (
    cd "$tmp/magisk"
    for path in "${runtime[@]}"; do
      out="${path##*/}"
      magiskboot cpio "$RAMDISK" "extract $path $out" >/dev/null 2>&1 || return 1
      mkdir -p "$tmp/root/${path%/*}"
      mv "$out" "$tmp/root/$path"
    done
  )
}

extract_runtime_with_cpio()
{
  mkdir -p "$tmp/root"
  (
    cd "$tmp/root"
    cpio -idm "${runtime[@]}" < "$RAMDISK" >/dev/null 2>&1
  )
}

if ! extract_runtime_with_magiskboot; then
  extract_runtime_with_cpio
fi

for path in "${runtime[@]}"; do
  if [ ! -s "$tmp/root/$path" ]; then
    echo "missing runtime payload: $path" >&2
    exit 1
  fi
done

mkdir -p "$tmp/push/adblib"
cp "$ADBD" "$tmp/push/adbd"
cp "$tmp/root/system/bin/linker64" "$tmp/push/linker64"
for lib in "$tmp"/root/system/lib64/*.so; do
  cp "$lib" "$tmp/push/adblib/"
done
chmod 0755 "$tmp/push/adbd" "$tmp/push/linker64"

"$ADB" push "$tmp/push" /data/local/tmp/kexec-adbd >/dev/null
"$ADB" shell "su -c 'rm -rf /data/kexec/adblib; mkdir -p /data/kexec/adblib'"
"$ADB" shell "su -c 'cp /data/local/tmp/kexec-adbd/adbd /data/kexec/adbd'"
"$ADB" shell "su -c 'cp /data/local/tmp/kexec-adbd/linker64 /data/kexec/linker64'"
"$ADB" shell "su -c 'cp /data/local/tmp/kexec-adbd/adblib/*.so /data/kexec/adblib/'"
"$ADB" shell "su -c 'chmod 0755 /data/kexec/adbd /data/kexec/linker64; chmod 0644 /data/kexec/adblib/*.so; rm -rf /data/local/tmp/kexec-adbd; sync'"
"$ADB" shell "su -c 'sha256sum /data/kexec/adbd; ls -l /data/kexec/adbd /data/kexec/linker64 /data/kexec/adblib'"
