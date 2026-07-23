# Patches

## `kernel-docker-nftables.patch`

Applies to the locked xaga GKI `common` tree. It records the nftables options
that were previously only an uncommitted source-tree delta, so a fresh checkout
gets the same Docker-facing kernel configuration.

## `aosp-init-kxsh-early-handoff.patch`

Applies to `sources/android-12.1` / AOSP Android 12.1 `system/core/init`.

The patch adds an early kexec handoff before `DoFirstStageMount()`:

```text
/init
  -> find executable /kxshbin or /first_stage_ramdisk/kxshbin
  -> fork/exec kxshbin --prepare
      -> mount the linux partition at /kexec
      -> verify /kexec/usr/local/libexec/kexec/boot_ubuntu_rootfs
  -> on success, skip Android first-stage mount
  -> FreeRamdisk()
  -> execve /kexec/usr/local/libexec/kexec/boot_ubuntu_rootfs
```

The linux partition root is the Ubuntu rootfs. Runtime helpers are installed
under `/usr/local/libexec/kexec`; no intermediate rescue userspace is entered.

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

## `aosp-libmodprobe-kxsh-debug.patch`

Applies to `sources/android-12.1` / AOSP Android 12.1 `system/core/libmodprobe`.

This is a diagnostic patch for intermittent first-stage module load failures.
It logs the parsed module load/dependency/alias state, the full dependency
walk, and every `finit_module()` attempt as `begin` / `ok` / `failed` /
`eexist` records under the `kxsh-modprobe-debug` tag. It also keeps focused
`mt6375_charger` alias/existence logging for the earlier charger failure mode.

Rebuild the prebuilt init after applying it:

```sh
cd sources/android-12.1
patch -p1 < ../../patches/aosp-libmodprobe-kxsh-debug.patch
source build/envsetup.sh
lunch aosp_arm64-eng
m -j4 init_first_stage
cp out/target/product/generic_arm64/ramdisk/init ../../prebuilt/init_first_stage_kxsh
```
