#!/usr/bin/env bash
# Recreate source checkouts pinned by config/repro.lock.tsv.
#
# Default is read-only. Network access and checkout creation require --fetch.
# Repository patches require the additional --apply-patches flag.
set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

LOCK="${REPRO_LOCK:-$ROOT/config/repro.lock.tsv}"
JOBS="${JOBS:-4}"
FETCH=0
APPLY_PATCHES=0

usage()
{
  cat <<EOF
Usage: $0 [--check] [--fetch [--apply-patches]]

  --check          verify existing trees (no source/device writes or network)
  --fetch          clone/sync only HTTPS URLs recorded in $LOCK
  --apply-patches  apply this repository's reviewed patches after fetching

The pinned kexec-tools archive is fetched by --fetch. The much larger Ubuntu
ISO is handled separately by build_ubuntu_rootfs.sh --download.
EOF
}

while [ "$#" -gt 0 ]; do
  case "$1" in
    --check) ;;
    --fetch) FETCH=1 ;;
    --apply-patches) APPLY_PATCHES=1 ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown argument: $1" >&2; usage >&2; exit 2 ;;
  esac
  shift
done

[ -f "$LOCK" ] || { echo "missing reproduction lock: $LOCK" >&2; exit 1; }

if [ "$FETCH" != 1 ]; then
  exec bash "$ROOT/scripts/host/check_sources.sh"
fi

require_https()
{
  case "$1" in
    https://*) ;;
    *) echo "refusing non-HTTPS source URL: $1" >&2; exit 1 ;;
  esac
}

checkout_exact()
{
  local path="$1" url="$2" ref="$3" revision="$4"

  require_https "$url"
  if [ ! -d "$path" ] ||
     [ "$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)" != "$(realpath -m "$path")" ]; then
    [ ! -e "$path" ] || {
      echo "refusing to clone over a non-checkout path: $path" >&2
      exit 1
    }
    mkdir -p "$(dirname "$path")"
    git clone --no-checkout "$url" "$path"
  fi
  if [ "$(git -C "$path" rev-parse HEAD 2>/dev/null || true)" = "$revision" ]; then
    return
  fi
  [ -z "$(git -C "$path" status --porcelain 2>/dev/null)" ] || {
    echo "refusing to replace dirty source tree: $path" >&2
    exit 1
  }
  git -C "$path" fetch "$url" "$revision"
  git -C "$path" checkout --detach "$revision"
  printf 'pinned %s (%s) at %s\n' "$path" "$ref" "$revision"
}

sync_repo_checkout()
{
  local path="$1" url="$2" ref="$3" revision="$4"

  require_https "$url"
  command -v repo >/dev/null 2>&1 || {
    echo "Android repo launcher is required to fetch $path" >&2
    exit 1
  }
  mkdir -p "$path"
  if [ ! -d "$path/.repo" ]; then
    (
      cd "$path"
      repo init -u "$url" -b "$ref" --no-clone-bundle
    )
  fi
  git -C "$path/.repo/manifests" fetch "$url" "$revision"
  git -C "$path/.repo/manifests" checkout --detach "$revision"
  (
    cd "$path"
    repo sync -c -j"$JOBS"
  )
}

while IFS='|' read -r group id kind rel_path url ref revision sha256; do
  case "$group" in ""|\#*) continue ;; esac
  [ "$group" = source ] || continue
  path="$ROOT/$rel_path"
  case "$kind" in
    repo-manifest) sync_repo_checkout "$path" "$url" "$ref" "$revision" ;;
    repo-project|git) checkout_exact "$path" "$url" "$ref" "$revision" ;;
    *) echo "unsupported source kind for $id: $kind" >&2; exit 1 ;;
  esac
done < "$LOCK"

fetch_kexec_archive()
{
  local path="$1" url="$2" top_dir="$3" expected_sha="$4"
  local downloads archive tmp entry

  [ -d "$path" ] && {
    echo "kexec-tools source already exists: $path"
    return
  }
  require_https "$url"
  command -v curl >/dev/null 2>&1 || {
    echo "curl is required for the explicit kexec-tools fetch" >&2
    exit 1
  }
  downloads="$WORK_DIR/downloads"
  archive="$downloads/${url##*/}"
  mkdir -p "$downloads"
  if [ ! -f "$archive" ]; then
    tmp="$(mktemp "$downloads/kexec-tools.XXXXXX")"
    if ! curl --fail --location --proto '=https' --tlsv1.2 \
      --output "$tmp" "$url"; then
      rm -f "$tmp"
      return 1
    fi
    if ! printf '%s  %s\n' "$expected_sha" "$tmp" | sha256sum -c -; then
      rm -f "$tmp"
      return 1
    fi
    mv "$tmp" "$archive"
  fi
  printf '%s  %s\n' "$expected_sha" "$archive" | sha256sum -c -
  while IFS= read -r entry; do
    case "$entry" in
      "$top_dir"|"$top_dir"/*) ;;
      *) echo "unsafe/unexpected kexec archive member: $entry" >&2; exit 1 ;;
    esac
  done < <(tar -tJf "$archive")
  mkdir -p "$(dirname "$path")"
  tar -xJf "$archive" -C "$(dirname "$path")"
  [ -f "$path/configure" ] || {
    echo "kexec-tools extraction did not create $path/configure" >&2
    exit 1
  }
}

while IFS='|' read -r group id kind rel_path url ref revision sha256; do
  case "$group" in ""|\#*) continue ;; esac
  if [ "$group" = external ] && [ "$id" = kexec_tools ] &&
     [ "$kind" = archive-source ]; then
    fetch_kexec_archive "$ROOT/$rel_path" "$url" "$revision" "$sha256"
  fi
done < "$LOCK"

apply_patch_once()
{
  local tree="$1" patch="$2"

  if git -C "$tree" apply --reverse --check "$patch" >/dev/null 2>&1; then
    printf 'already applied: %s\n' "$patch"
  elif git -C "$tree" apply --check "$patch"; then
    git -C "$tree" apply "$patch"
    printf 'applied: %s\n' "$patch"
  else
    echo "patch is neither cleanly applicable nor already applied: $patch" >&2
    exit 1
  fi
}

if [ "$APPLY_PATCHES" = 1 ]; then
  apply_patch_once "$AK/common" "$ROOT/patches/kernel-docker-nftables.patch"
  apply_patch_once "$AOSP_DIR" "$ROOT/patches/aosp-init-kxsh-early-handoff.patch"
  apply_patch_once "$AOSP_DIR" "$ROOT/patches/aosp-libmodprobe-kxsh-debug.patch"
  apply_patch_once "$AOSP_DIR" "$ROOT/patches/adbd-kexec-ubuntu.patch"
fi

bash "$ROOT/scripts/host/check_sources.sh"
