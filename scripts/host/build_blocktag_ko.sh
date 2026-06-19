#!/usr/bin/env bash
# Build a replacement MediaTek blocktag.ko against the current GKI output tree.
#
# The source is taken from the OnePlus MTK kernel tree and built as an external
# module. For CONFIG_USER_NS=y kernels, proc_set_user(make_kuid/make_kgid) pulls
# in non-exported symbols, so this script removes that proc ownership tweak.

set -euo pipefail

. "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/env.sh"

SRC="$ONEPLUS_SRC/drivers/misc/mediatek/blocktag"
OUT="${OUT:-$BLOCKTAG_BUILD_DIR}"
KOUT="${KOUT:-$AK/out/android12-5.10/common}"
CLANG_BIN="${CLANG_BIN:-$AK/prebuilts-master/clang/host/linux-x86/clang-r416183b/bin}"

for path in "$AK/common" "$KOUT" "$SRC" "$CLANG_BIN"; do
  if [ ! -e "$path" ]; then
    echo "missing required path: $path" >&2
    exit 1
  fi
done

mkdir -p "$OUT"
cp "$SRC"/* "$OUT"/

cat > "$OUT/Makefile" <<'EOF'
ONEPLUS_SRC ?= @ONEPLUS_SRC@

ccflags-y += -DCONFIG_MTK_BLOCK_IO_TRACER_MODULE=1
ccflags-y += -I$(src)
ccflags-y += -I$(ONEPLUS_SRC)/drivers/misc/mediatek/include/mt-plat/
ccflags-y += -I$(ONEPLUS_SRC)/drivers/misc/mediatek/include/
ccflags-y += -I$(ONEPLUS_SRC)/drivers/misc/mediatek/aee/mrdump/
ccflags-y += -I$(ONEPLUS_SRC)/drivers/scsi/ufs/
ccflags-y += -I$(ONEPLUS_SRC)/drivers/mmc/core
ccflags-y += -I$(ONEPLUS_SRC)/drivers/mmc/host

obj-m += blocktag.o
blocktag-y := blocktag-core.o blocktag-index.o blocktag-ufs.o blocktag-mmc.o
EOF
perl -0pi -e "s#\@ONEPLUS_SRC\@#$ONEPLUS_SRC#g" "$OUT/Makefile"

# CONFIG_USER_NS makes init_user_ns/make_kuid/make_kgid non-exported for this
# external module use case. The proc node can keep default ownership.
perl -0pi -e '
  s/\n\s*kuid_t uid;\n\s*kgid_t gid;\n/\n/s;
  s/\n\s*uid = make_kuid\(&init_user_ns, 0\);\n\s*gid = make_kgid\(&init_user_ns, 1001\);\n/\n/s;
  s/\n\s*if \(proc_entry\)\n\s*proc_set_user\(proc_entry, uid, gid\);\n\s*else\n\s*pr_info/\n\tif (!proc_entry)\n\t\tpr_info/s;
' "$OUT/blocktag-core.c"

PATH="$CLANG_BIN:$PATH" make -C "$AK/common" \
  O="$KOUT" \
  ARCH=arm64 \
  LLVM=1 \
  LLVM_IAS=1 \
  CLANG_TRIPLE=aarch64-linux-gnu- \
  CROSS_COMPILE=aarch64-linux-gnu- \
  CROSS_COMPILE_COMPAT=arm-linux-gnueabi- \
  DEPMOD=depmod \
  M="$OUT" \
  KBUILD_MODPOST_WARN=1 \
  modules

if "$CLANG_BIN/llvm-nm" -u "$OUT/blocktag.ko" | grep -Eq 'init_user_ns|make_kuid|make_kgid'; then
  echo "blocktag.ko still references non-exported user namespace helpers" >&2
  exit 1
fi

modinfo "$OUT/blocktag.ko" | sed -n '1,30p'
sha256sum "$OUT/blocktag.ko"
