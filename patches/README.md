# Patches

## `aosp-init-kxsh-early-handoff.patch`

Applies to `sources/android-12.1` / AOSP Android 12.1 `system/core/init`.

It makes first-stage init exec `/kxshbin` before `DoFirstStageMount()`, while the
ramdisk root is still visible. If `/kxshbin` is missing or cannot be executed,
init logs the error and continues to the normal `/system/bin/init` handoff.

Rebuild the prebuilt init:

```sh
cd sources/android-12.1
patch -p1 < ../../patches/aosp-init-kxsh-early-handoff.patch
source build/envsetup.sh
lunch aosp_arm64-eng
m -j4 init_first_stage
cp out/target/product/generic_arm64/ramdisk/init ../../prebuilt/init_first_stage_kxsh
```

The initrd build scripts use `prebuilt/init_first_stage_kxsh` by default. Override
with `INIT_KXSH=/path/to/init` when testing another build.

The ramdisk bootstrap is built from `src/system_kxsh.c` by the initrd build
scripts:

```sh
cd /home/in/work/kernels
aarch64-linux-gnu-gcc -static -Os -s -o work/output/ramdisk_kxshbin src/system_kxsh.c
```

Override with `RAMDISK_KXSH=/path/to/kxshbin` when testing another bootstrap.
