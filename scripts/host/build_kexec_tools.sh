#!/usr/bin/env bash
# Build the locked kexec-tools release as a static arm64 executable.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

SOURCE="${SOURCE:-$KEXEC_TOOLS}"
JOBS="${JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"
CHECK_ONLY=0

case "${1:-}" in
  "") ;;
  --check) CHECK_ONLY=1 ;;
  -h|--help)
    cat <<EOF
Usage: $0 [--check]

Build:
  ./configure --host=aarch64-linux-gnu CFLAGS=-static LDFLAGS=-static
  make -j<JOBS>

The source must first be obtained and hash-verified by fetch_sources.sh
--fetch, or independently verified against config/repro.lock.tsv.
EOF
    exit 0
    ;;
  *) echo "unknown argument: $1" >&2; exit 2 ;;
esac

[ -x "$SOURCE/configure" ] || {
  echo "missing kexec-tools source: $SOURCE" >&2
  echo "run scripts/host/fetch_sources.sh --fetch first" >&2
  exit 1
}
command -v aarch64-linux-gnu-gcc >/dev/null 2>&1 || {
  echo "missing aarch64-linux-gnu-gcc" >&2
  exit 1
}

if [ "$CHECK_ONLY" = 1 ]; then
  if [ -x "$SOURCE/build/sbin/kexec" ]; then
    strings "$SOURCE/build/sbin/kexec" | grep -m 1 '^kexec-tools ' || true
    file "$SOURCE/build/sbin/kexec"
  else
    echo "source ready; build output is absent: $SOURCE/build/sbin/kexec"
  fi
  exit 0
fi

(
  cd "$SOURCE"
  ./configure --host=aarch64-linux-gnu CFLAGS=-static LDFLAGS=-static
  make -j"$JOBS"
)

[ -x "$SOURCE/build/sbin/kexec" ] || {
  echo "build completed without build/sbin/kexec" >&2
  exit 1
}
strings "$SOURCE/build/sbin/kexec" | grep -m 1 '^kexec-tools ' || true
file "$SOURCE/build/sbin/kexec"
