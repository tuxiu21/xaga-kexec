# Patches

## `aosp-init-kxsh-early-handoff.patch`

Applies to `sources/android-12.1` / AOSP Android 12.1 `system/core/init`.

The patch adds an early kexec handoff before `DoFirstStageMount()`:

```text
/init
  -> find executable /kxshbin or /first_stage_ramdisk/kxshbin
  -> fork/exec kxshbin --prepare
      -> mount the linux partition at /kexec
      -> verify /kexec/lean/busybox and /kexec/lean/kxsh.sh
  -> on success, skip Android first-stage mount
  -> FreeRamdisk()
  -> execve /kexec/lean/busybox sh /kexec/lean/kxsh.sh
```

The linux partition root is now reserved for the Ubuntu rootfs. The lean rescue
runtime is installed under `/lean` on that partition, visible as `/kexec/lean`
after kexec.

If `/kxshbin` is missing or `--prepare` fails, init continues to the normal
`/system/bin/init selinux_setup` handoff.

Rebuild the prebuilt init:

```sh
cd sources/android-12.1
patch -p1 < ../../patches/aosp-init-kxsh-early-handoff.patch
source build/envsetup.sh
lunch aosp_arm64-eng
m -j4 init_first_stage
cp out/target/product/generic_arm64/ramdisk/init ../../prebuilt/init_first_stage_kxsh
```

The initrd build scripts use `prebuilt/init_first_stage_kxsh` by default.
Override with `INIT_KXSH=/path/to/init` when testing another build.

The ramdisk bootstrap is built from `src/system_kxsh.c` by the initrd build
scripts:

```sh
cd /home/in/work/kernels
aarch64-linux-gnu-gcc -static -Os -s -o work/output/ramdisk_kxshbin src/system_kxsh.c
```

Override with `RAMDISK_KXSH=/path/to/kxshbin` when testing another bootstrap.
