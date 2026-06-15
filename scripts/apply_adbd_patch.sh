#!/usr/bin/env bash
set -euo pipefail

# Apply the LEAN_KEXEC_ADBD source patch into the AOSP adb module.
#
# The lean adbd is a few localized changes on top of stock AOSP adb
# (daemon/main.cpp + daemon/auth.cpp): force auth off, keep root, USB-only
# transport, and guard out three threads that would busy-loop a full CPU each
# in the lean runtime (no property service): the adb_wifi observer, the
# adbd_auth framework thread, and the watchdog PropertyMonitor.
#
# These live as a patch in this repo (not committed in the repo-managed AOSP
# tree, where a `repo sync` could strand them). Run this after a fresh AOSP
# checkout / re-sync, then rebuild per the README.
#
# Patch was generated against adb rev 73fcdbf (AOSP android-12.1,
# BUILD_ID SQ3A.220705.001.B2).

. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/env.sh"

ADB_SRC="${ADB_SRC:-$AOSP_DIR/packages/modules/adb}"
PATCH="${PATCH:-$ROOT/patches/adbd-lean-kexec.patch}"

[ -d "$ADB_SRC/.git" ] || { echo "adb source git repo not found at $ADB_SRC" >&2; exit 1; }
[ -f "$PATCH" ]        || { echo "patch not found: $PATCH" >&2; exit 1; }

cd "$ADB_SRC"

# Idempotent: if the markers are already present in both files, do nothing.
if grep -qa 'LEAN_KEXEC_ADBD' daemon/main.cpp && grep -qa 'LEAN_KEXEC_ADBD' daemon/auth.cpp; then
  echo "LEAN_KEXEC_ADBD already present in $ADB_SRC/daemon -> nothing to do"
  exit 0
fi

# Verify it applies before touching anything.
if ! git apply --check "$PATCH" 2>/dev/null; then
  echo "patch does not apply cleanly to $ADB_SRC (rev $(git rev-parse --short HEAD))." >&2
  echo "the adb tree may have moved; reset daemon/main.cpp + daemon/auth.cpp to a" >&2
  echo "clean state, or regenerate the patch from a known-good tree." >&2
  exit 1
fi

git apply "$PATCH"
echo "applied $PATCH to $ADB_SRC (rev $(git rev-parse --short HEAD))"
echo "next: rebuild the recovery variant and refresh prebuilt/adbd (see README rebuild section)"
