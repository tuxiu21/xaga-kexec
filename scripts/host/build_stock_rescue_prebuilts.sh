#!/usr/bin/env bash
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

DROPBEAR_REPO="https://github.com/mkj/dropbear.git"
DROPBEAR_TAG="DROPBEAR_2025.89"
DROPBEAR_COMMIT="179de98f7b9584a309ffc48e39c61da940760740"
CROSS_COMPILE="${CROSS_COMPILE:-aarch64-linux-gnu-}"
JOBS="${JOBS:-4}"

for command in git make "${CROSS_COMPILE}gcc" "${CROSS_COMPILE}strip"; do
  command -v "$command" >/dev/null || {
    echo "missing required command: $command" >&2
    exit 1
  }
done

build_root="$(mktemp -d "${TMPDIR:-/tmp}/xaga-stock-rescue.XXXXXX")"
cleanup()
{
  rm -rf "$build_root"
}
trap cleanup EXIT

src="$build_root/dropbear"
git clone --quiet --depth 1 --branch "$DROPBEAR_TAG" "$DROPBEAR_REPO" "$src"
actual_commit="$(git -C "$src" rev-parse HEAD)"
[ "$actual_commit" = "$DROPBEAR_COMMIT" ] || {
  echo "Dropbear tag resolved to unexpected commit: $actual_commit" >&2
  exit 1
}

cat > "$src/localoptions.h" <<'EOF'
#define DROPBEAR_SVR_PASSWORD_AUTH 0
#define DROPBEAR_SVR_PAM_AUTH 0
EOF

source_date_epoch="$(git -C "$src" show -s --format=%ct HEAD)"
export LC_ALL=C
export SOURCE_DATE_EPOCH="$source_date_epoch"
export TZ=UTC

(
  cd "$src"
  CFLAGS="-Os -ffile-prefix-map=$src=. -fdebug-prefix-map=$src=." \
    ./configure \
      --host="${CROSS_COMPILE%-}" \
      --enable-static \
      --disable-harden \
      --disable-zlib \
      --disable-lastlog \
      --disable-utmp \
      --disable-utmpx \
      --disable-wtmp \
      --disable-wtmpx \
      --disable-loginfunc \
      --disable-syslog
  make -j"$JOBS" PROGRAMS="dropbear dbclient dropbearkey"
)

ns_bin="$build_root/dropbear-ns"
"${CROSS_COMPILE}gcc" \
  -static -Os -Wall -Wextra -Werror \
  -ffile-prefix-map="$ROOT"=. -fdebug-prefix-map="$ROOT"=. \
  -o "$ns_bin" "$ROOT/tools/dropbear_ns.c"

for name in dropbear dbclient dropbearkey; do
  "${CROSS_COMPILE}strip" "$src/$name"
done
"${CROSS_COMPILE}strip" "$ns_bin"

mkdir -p "$ROOT/prebuilt"
for name in dropbear dbclient dropbearkey; do
  install -m 0755 "$src/$name" "$ROOT/prebuilt/.$name.new"
done
install -m 0755 "$ns_bin" "$ROOT/prebuilt/.dropbear-ns.new"

for name in dropbear dbclient dropbearkey; do
  mv -f "$ROOT/prebuilt/.$name.new" "$ROOT/prebuilt/$name"
done
mv -f "$ROOT/prebuilt/.dropbear-ns.new" "$ROOT/prebuilt/dropbear-ns"

echo "Dropbear source: $DROPBEAR_TAG $DROPBEAR_COMMIT"
sha256sum \
  "$ROOT/prebuilt/dropbear" \
  "$ROOT/prebuilt/dbclient" \
  "$ROOT/prebuilt/dropbearkey" \
  "$ROOT/prebuilt/dropbear-ns"
