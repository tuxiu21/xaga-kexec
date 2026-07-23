#!/usr/bin/env bash
# Derive an installable Ubuntu rootfs tarball from the locked official ISO.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

LOCK="${REPRO_LOCK:-$ROOT/config/repro.lock.tsv}"

lock_field()
{
  local id="$1" field="$2"
  awk -F'|' -v id="$id" -v field="$field" \
    '$1 !~ /^#/ && $2 == id { print $field; found=1; exit }
     END { if (!found) exit 1 }' "$LOCK"
}

ISO_URL="$(lock_field ubuntu_iso 5)"
ISO_MEMBER="$(lock_field ubuntu_iso 7)"
ISO_SHA256="$(lock_field ubuntu_iso 8)"
ISO="${UBUNTU_ISO:-$LOCAL_DIR/ubuntu-26.04-live-server-arm64.iso}"
OUTPUT="${ROOTFS_OUTPUT:-$OUTPUT_DIR/ubuntu-26.04-server-minimal-arm64.tar.gz}"
DOWNLOAD=0
BUILD=0
FORCE=0
CHECK=0

usage()
{
  cat <<EOF
Usage: $0 [--iso PATH] [--output PATH] [--check] [--download] [--build] [--force]

Default is a no-write plan. --download explicitly fetches only the locked
HTTPS ISO and verifies SHA-256. --build verifies a local ISO, extracts
$ISO_MEMBER, and creates the rootfs tarball.

Extraction requires real root, unsquashfs, GNU tar and gzip. fakeroot is not
accepted because it does not reliably emulate security.capability/setxattr.
ISO extraction uses bsdtar or xorriso on Linux, with tar.exe as a WSL fallback.
--force is required to replace an existing output archive.
EOF
}

if [ "${1:-}" = --internal-build ]; then
  shift
  ISO="$1"
  OUTPUT="$2"
  ISO_MEMBER="$3"
  FORCE="$4"

  command -v unsquashfs >/dev/null 2>&1 || {
    echo "unsquashfs is required" >&2
    exit 1
  }
  tar --version 2>/dev/null | grep -q 'GNU tar' || {
    echo "GNU tar is required to preserve numeric owners, xattrs, ACLs and capabilities" >&2
    exit 1
  }
  command -v gzip >/dev/null 2>&1 || { echo "gzip is required" >&2; exit 1; }
  command -v setcap >/dev/null 2>&1 || { echo "setcap is required" >&2; exit 1; }
  command -v getcap >/dev/null 2>&1 || { echo "getcap is required" >&2; exit 1; }

  temp="$(mktemp -d "$TMP_ROOT/ubuntu-rootfs.XXXXXX")"
  cleanup()
  {
    rm -rf "$temp"
  }
  trap cleanup EXIT
  iso_stage="$temp/iso"
  squashfs="$temp/ubuntu-server-minimal.squashfs"
  rootfs="$temp/rootfs"
  archive="$temp/rootfs.tar.gz"
  mkdir -p "$iso_stage" "$rootfs" "$(dirname "$OUTPUT")"

  # Prove that the work filesystem and tar round-trip preserve device nodes and
  # security.capability before touching the large squashfs.
  mkdir -p "$temp/metadata-src" "$temp/metadata-dst"
  cp /bin/true "$temp/metadata-src/cap-probe"
  setcap cap_net_raw=ep "$temp/metadata-src/cap-probe"
  mknod "$temp/metadata-src/null-probe" c 1 3
  tar --numeric-owner --acls --xattrs --xattrs-include='*' --selinux \
    -C "$temp/metadata-src" -cpf "$temp/metadata.tar" .
  tar --numeric-owner --acls --xattrs --xattrs-include='*' --selinux \
    -C "$temp/metadata-dst" -xpf "$temp/metadata.tar"
  getcap "$temp/metadata-dst/cap-probe" |
    grep -q 'cap_net_raw=ep' || {
      echo "filesystem/tar capability round-trip failed" >&2
      exit 1
    }
  [ -c "$temp/metadata-dst/null-probe" ] || {
    echo "filesystem/tar device-node round-trip failed" >&2
    exit 1
  }

  if command -v bsdtar >/dev/null 2>&1; then
    bsdtar -xOf "$ISO" "$ISO_MEMBER" > "$squashfs"
  elif command -v xorriso >/dev/null 2>&1; then
    xorriso -osirrox on -indev "$ISO" \
      -extract "/$ISO_MEMBER" "$squashfs"
  elif command -v tar.exe >/dev/null 2>&1 &&
       command -v wslpath >/dev/null 2>&1; then
    tar.exe -xf "$(wslpath -w "$ISO")" \
      -C "$(wslpath -w "$iso_stage")" "$ISO_MEMBER"
    cp "$iso_stage/$ISO_MEMBER" "$squashfs"
  else
    echo "cannot extract ISO: install bsdtar or xorriso (WSL may use tar.exe)" >&2
    exit 1
  fi

  [ -s "$squashfs" ] || {
    echo "ISO member extraction produced no data: $ISO_MEMBER" >&2
    exit 1
  }
  unsquashfs -stat "$squashfs" >/dev/null
  # Strict errors make loss of owners, device nodes or privileged xattrs fatal.
  unsquashfs -strict-errors -no-progress -d "$rootfs" "$squashfs"
  [ -f "$rootfs/etc/os-release" ] || {
    echo "minimal squashfs lacks etc/os-release" >&2
    exit 1
  }
  [ -x "$rootfs/sbin/init" ] || [ -x "$rootfs/usr/lib/systemd/systemd" ] || {
    echo "minimal squashfs lacks systemd init" >&2
    exit 1
  }

  # Keep numeric uid/gid, device nodes, ACLs, every xattr namespace and file
  # capabilities. gzip -n removes the gzip header timestamp/name.
  tar --sort=name --numeric-owner --acls --xattrs --xattrs-include='*' \
    --selinux -C "$rootfs" -cpf - . |
    gzip -n -9 > "$archive"
  tar --acls --xattrs --xattrs-include='*' --selinux -tzf "$archive" >/dev/null

  if [ -e "$OUTPUT" ] && [ "$FORCE" != 1 ]; then
    echo "refusing to replace existing output without --force: $OUTPUT" >&2
    exit 1
  fi
  mv -f "$archive" "$OUTPUT"
  (
    cd "$(dirname "$OUTPUT")"
    sha256sum "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256"
  )
  if command -v getcap >/dev/null 2>&1; then
    getcap -r "$rootfs" > "$OUTPUT.capabilities.txt" || true
  fi
  ls -lh "$OUTPUT" "$OUTPUT.sha256"
  exit 0
fi

while [ "$#" -gt 0 ]; do
  case "$1" in
    --iso) ISO="$2"; shift ;;
    --output) OUTPUT="$2"; shift ;;
    --check) CHECK=1 ;;
    --download) DOWNLOAD=1 ;;
    --build) BUILD=1 ;;
    --force) FORCE=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

ISO="$(realpath -m "$ISO")"
OUTPUT="$(realpath -m "$OUTPUT")"
case "$ISO_URL" in
  https://*) ;;
  *) echo "refusing non-HTTPS locked ISO URL: $ISO_URL" >&2; exit 1 ;;
esac

verify_iso()
{
  [ -s "$ISO" ] || { echo "missing Ubuntu ISO: $ISO" >&2; return 1; }
  printf '%s  %s\n' "$ISO_SHA256" "$ISO" | sha256sum -c -
}

if [ "$DOWNLOAD" = 1 ]; then
  if [ -e "$ISO" ]; then
    verify_iso
  else
    command -v curl >/dev/null 2>&1 || {
      echo "curl is required for --download" >&2
      exit 1
    }
    mkdir -p "$(dirname "$ISO")"
    temp_iso="$(mktemp "$(dirname "$ISO")/ubuntu-iso.XXXXXX")"
    cleanup_download()
    {
      rm -f "$temp_iso"
    }
    trap cleanup_download EXIT
    curl --fail --location --proto '=https' --tlsv1.2 \
      --output "$temp_iso" "$ISO_URL"
    printf '%s  %s\n' "$ISO_SHA256" "$temp_iso" | sha256sum -c -
    mv "$temp_iso" "$ISO"
    trap - EXIT
  fi
fi

if [ "$CHECK" = 1 ]; then
  verify_iso
  printf 'member: %s\noutput: %s\n' "$ISO_MEMBER" "$OUTPUT"
fi

if [ "$BUILD" = 1 ]; then
  verify_iso
  if [ -e "$OUTPUT" ] && [ "$FORCE" != 1 ]; then
    echo "refusing to replace existing output without --force: $OUTPUT" >&2
    exit 1
  fi
  if [ "$(id -u)" != 0 ]; then
    echo "real root is required; fakeroot cannot reliably preserve security.capability" >&2
    exit 1
  fi
  "$0" --internal-build "$ISO" "$OUTPUT" "$ISO_MEMBER" "$FORCE"
fi

if [ "$DOWNLOAD" = 0 ] && [ "$BUILD" = 0 ] && [ "$CHECK" = 0 ]; then
  cat <<EOF
Locked Ubuntu ISO: $ISO_URL
SHA256:            $ISO_SHA256
Local ISO:         $ISO
Squashfs member:   $ISO_MEMBER
Output:            $OUTPUT

No writes performed. Use --iso PATH --check, then --build.
Use --download explicitly only if you want the script to fetch the locked ISO.
EOF
fi
