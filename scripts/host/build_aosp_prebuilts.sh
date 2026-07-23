#!/usr/bin/env bash
# Rebuild the two AOSP-derived binaries checked into prebuilt/.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

JOBS="${JOBS:-4}"
PRODUCT="${AOSP_PRODUCT:-generic_arm64}"
INIT_SRC="$AOSP_DIR/out/target/product/$PRODUCT/ramdisk/init"
ADBD_SRC="$AOSP_DIR/out/target/product/$PRODUCT/apex/com.android.adbd/bin/adbd"
INIT_DST="$ROOT/prebuilt/init_first_stage_kxsh"
ADBD_DST="$ROOT/prebuilt/adbd"
CHECK_ONLY=0

case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help)
    cat <<EOF
Usage: $0 [--check]

Builds AOSP aosp_arm64-eng targets init_first_stage and adbd, validates their
expected kexec markers, then atomically refreshes:
  prebuilt/init_first_stage_kxsh
  prebuilt/adbd
EOF
    exit 0
    ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

[ -f "$AOSP_DIR/build/envsetup.sh" ] || {
  echo "missing AOSP checkout: $AOSP_DIR" >&2
  exit 1
}

validate_outputs()
{
  for path in "$INIT_SRC" "$ADBD_SRC"; do
    [ -x "$path" ] || { echo "missing AOSP build output: $path" >&2; return 1; }
    file "$path" | grep -q 'ARM aarch64' || {
      echo "not an arm64 executable: $path" >&2
      return 1
    }
  done
  grep -aFq 'boot_ubuntu_rootfs' "$INIT_SRC" || {
    echo "init output lacks the kexec direct-root marker" >&2
    return 1
  }
  grep -aFq 'KEXEC_UBUNTU_ADBD' "$ADBD_SRC" || {
    echo "adbd output lacks the KEXEC_UBUNTU_ADBD marker" >&2
    return 1
  }
}

if [ "$CHECK_ONLY" != 1 ]; then
  (
    set +u
    cd "$AOSP_DIR"
    # shellcheck disable=SC1091
    source build/envsetup.sh
    lunch aosp_arm64-eng
    m -j"$JOBS" init_first_stage adbd
  )
fi

validate_outputs

if [ "$CHECK_ONLY" = 1 ]; then
  sha256sum "$INIT_SRC" "$ADBD_SRC"
  exit 0
fi

init_tmp="$(mktemp "$ROOT/prebuilt/.init_first_stage_kxsh.XXXXXX")"
adbd_tmp="$(mktemp "$ROOT/prebuilt/.adbd.XXXXXX")"
cleanup()
{
  rm -f "$init_tmp" "$adbd_tmp"
}
trap cleanup EXIT

cp "$INIT_SRC" "$init_tmp"
cp "$ADBD_SRC" "$adbd_tmp"
chmod 0755 "$init_tmp" "$adbd_tmp"
mv -f "$init_tmp" "$INIT_DST"
mv -f "$adbd_tmp" "$ADBD_DST"
trap - EXIT

sha256sum "$INIT_DST" "$ADBD_DST"
