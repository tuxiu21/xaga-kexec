#!/usr/bin/env bash
# Read-only audit of the source, tool and external-input reproduction lock.
set -uo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

LOCK="${REPRO_LOCK:-$ROOT/config/repro.lock.tsv}"
STRICT="${STRICT:-0}"
errors=0
warnings=0

[ -f "$LOCK" ] || { echo "missing reproduction lock: $LOCK" >&2; exit 1; }

ok() { printf 'OK    %s\n' "$*"; }
warn() { printf 'WARN  %s\n' "$*" >&2; warnings=$((warnings + 1)); }
bad() { printf 'ERROR %s\n' "$*" >&2; errors=$((errors + 1)); }

check_git()
{
  local id="$1" path="$2" revision="$3" head top
  top="$(git -C "$path" rev-parse --show-toplevel 2>/dev/null || true)"
  if [ -z "$top" ] || [ "$top" != "$(realpath -m "$path")" ]; then
    bad "$id missing git checkout: $path"
    return
  fi
  head="$(git -C "$path" rev-parse HEAD 2>/dev/null || true)"
  if [ "$head" = "$revision" ]; then
    ok "$id $revision"
  else
    bad "$id HEAD=$head expected=$revision"
  fi
}

check_commands()
{
  local id="$1" csv="$2" item missing=0
  local old_ifs="$IFS"
  IFS=,
  for item in $csv; do
    if ! command -v "$item" >/dev/null 2>&1; then
      bad "$id missing command: $item"
      missing=1
    fi
  done
  IFS="$old_ifs"
  [ "$missing" = 1 ] || ok "$id commands present"
}

check_kernel_submodule()
{
  local id="$1" tree="$2" path="$3" expected actual

  expected="$(git -C "$tree" ls-tree HEAD "$path" 2>/dev/null |
    awk '{print $3}')"
  actual="$(git -C "$tree/$path" rev-parse HEAD 2>/dev/null || true)"
  if [ -n "$expected" ] && [ "$actual" = "$expected" ]; then
    ok "$id $path $actual"
  else
    bad "$id $path HEAD=${actual:-missing} expected=${expected:-missing}"
  fi
}

while IFS='|' read -r group id kind rel_path url ref revision sha256; do
  case "$group" in ""|\#*) continue ;; esac
  path="$ROOT/$rel_path"
  case "$kind" in
    repo-manifest)
      check_git "$id manifest" "$path/.repo/manifests" "$revision"
      ;;
    repo-project|git|git-worktree)
      check_git "$id" "$path" "$revision"
      ;;
    archive-source)
      if [ "$id" = kexec_tools ] && [ -x "$path/configure" ] &&
         [ -x "$path/build/sbin/kexec" ]; then
        version="$(strings "$path/build/sbin/kexec" | grep -m 1 '^kexec-tools ' || true)"
        case "$version" in
          *"$ref"*) ok "$id official archive locked; local binary: $version" ;;
          *) bad "$id binary version '$version' does not match $ref" ;;
        esac
      elif [ -d "$path" ]; then
        warn "$id source exists but build output is absent: $path/build/sbin/kexec"
      else
        bad "$id source is absent; run fetch_sources.sh --fetch"
      fi
      ;;
    https-archive)
      input_path="$path"
      [ "$id" = ubuntu_iso ] && input_path="${UBUNTU_ISO:-$path}"
      if [ -s "$input_path" ]; then
        actual="$(sha256sum "$input_path" | awk '{print $1}')"
        if [ "$actual" = "$sha256" ]; then
          ok "$id verified local archive: $input_path"
        else
          bad "$id sha256=$actual expected=$sha256"
        fi
      else
        ok "$id official HTTPS input locked; local archive not present"
      fi
      ;;
    iso-member|derived-tar|derived-binary)
      ok "$id derived by $revision from $url:$ref"
      ;;
    command)
      if command -v "$rel_path" >/dev/null 2>&1; then
        ok "$id command=$(command -v "$rel_path") observed-version=$ref"
      else
        bad "$id missing command: $rel_path"
      fi
      ;;
    env-command)
      if [ "$rel_path" = ADB ] && command -v "$ADB" >/dev/null 2>&1; then
        ok "$id command=$(command -v "$ADB") observed-version=$ref"
      else
        bad "$id missing command from environment variable: $rel_path"
      fi
      ;;
    commands)
      check_commands "$id" "$rel_path"
      ;;
    *)
      bad "$id unknown lock kind: $kind"
      ;;
  esac
done < "$LOCK"

for profile in stock ubuntu; do
  profile_path="$AK/common-$profile"
  if [ -d "$profile_path" ]; then
    check_kernel_submodule "gki_common_$profile" "$profile_path" KernelSU
  fi
done

check_patch()
{
  local tree="$1" patch="$2"
  if git -C "$tree" apply --reverse --check "$patch" >/dev/null 2>&1; then
    ok "patch applied: ${patch#"$ROOT/"}"
  elif git -C "$tree" apply --check "$patch" >/dev/null 2>&1; then
    warn "patch not applied yet: ${patch#"$ROOT/"}"
  else
    bad "patch state is inconsistent: ${patch#"$ROOT/"}"
  fi
}

if [ -d "$AOSP_DIR/.repo" ]; then
  check_patch "$AOSP_DIR" "$ROOT/patches/aosp-init-kxsh-early-handoff.patch"
  check_patch "$AOSP_DIR" "$ROOT/patches/aosp-libmodprobe-kxsh-debug.patch"
  check_patch "$AOSP_DIR" "$ROOT/patches/adbd-kexec-ubuntu.patch"
fi

printf '\nsource check: errors=%s warnings=%s strict=%s\n' "$errors" "$warnings" "$STRICT"
if [ "$errors" -ne 0 ] || { [ "$STRICT" = 1 ] && [ "$warnings" -ne 0 ]; }; then
  exit 1
fi
