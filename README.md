# Kexec Lean Linux on mt6895

This project boots a lean Linux userspace on xaga/mt6895 hardware through
`kexec`. The current path does not modify `/system` and does not use `/data` for
the lean runtime.

The active handoff is:

```text
GKI ramdisk /init
  -> exec /kxshbin before Android first-stage mount
      -> mount linux partition at /mnt
      -> exec /mnt/kexec/busybox sh /mnt/kexec/kxsh.sh
          -> start lean adbd, Dropbear, watchdog, optional Wi-Fi bring-up
```

The linux partition is expected at `/dev/block/by-name/linux`; `/dev/block/sdc88`
is also recognized because the by-name links may not exist yet this early. In
the lean environment it is mounted at `/mnt`, and the runtime lives under
`/mnt/kexec`.

## Current State

- Lean ADB works. The lean serial is `0123456789abcdef`.
- The current GKI ramdisk embeds `/kxshbin`; no `/mnt/kxshbinxxxx` external
  handoff binary is required.
- `prebuilt/init_first_stage_kxsh` is a rebuilt AOSP first-stage init that
  checks `/kxshbin` before `DoFirstStageMount()`.
- `kxshbin` is a small static ramdisk bootstrap built from `src/system_kxsh.c`
  by the initrd build scripts.
- `scripts/host/install_linux_runtime.sh` installs the runtime to the linux
  partition without using `/data/local/tmp` as a staging area.
- `patched.dtb` carries the regulator always-on fix used by the kexec tests.
- Wi-Fi bring-up works with the mbox initrd when the module set is installed in
  `/mnt/kexec/modules`.

## Safety Notes

- Do not run `fastboot reboot recovery` on xaga; it can leave the BCB set to
  `boot-recovery`.
- Keep `panic_after` nonzero while debugging. The lean runtime panics back to
  stock Android if it hangs.
- Do not repeatedly kexec after a failed boot without collecting pstore or
  lean logs. Ramoops is small and useful evidence is easy to overwrite.

## Requirements

Host tools:

```text
adb.exe
magiskboot
aarch64-linux-gnu-gcc
gcc
perl
sed
```

Device assumptions:

```text
root access is available through su
linux partition exists at /dev/block/by-name/linux or /dev/block/sdc88
active slot is currently assumed to be _a by some scripts
local/boot-5.10.img exists, or GKI_BOOT_IMAGE points at the downloaded GKI boot image
```

## Source Trees

`sources/` is intentionally gitignored. A fresh machine needs these trees for
full rebuilds:

```text
sources/android-kernel
    Android 12 5.10 GKI build tree. Used by build_gki_logged.sh and as the
    Kbuild output base for external modules.

sources/Xiaomi_Kernel_OpenSource
    Xiaomi xaga vendor kernel source. Used for patched mtk-mbox.ko.

sources/android_kernel_5.10_oneplus_mt6895
    OnePlus MTK 5.10 vendor kernel source. Used for replacement blocktag.ko.

sources/kexec-tools-2.0.28
    kexec-tools source/build output. install_kexec_payload.sh expects
    build/sbin/kexec here.

sources/android-12.1
    AOSP Android 12.1 checkout. Needed to rebuild prebuilt/init_first_stage_kxsh
    and prebuilt/adbd.
```

Generated state lives under `work/`, which is also gitignored:

```text
work/logs/                 captured build, kexec, and recovery logs
work/output/               generated initrds and helper binaries
work/vendor/               extracted and patched vendor ramdisk payloads
work/unpack_gki/ramdisk    GKI ramdisk input
work/tmp/                  temporary build directories
```

Operator-provided inputs live under `local/`:

```text
local/boot-5.10.img        Google-downloaded GKI boot image used to extract the
                           base GKI ramdisk
```

## Reproducible Patches And Prebuilts

The AOSP init patch is stored in:

```text
patches/aosp-init-kxsh-early-handoff.patch
```

It applies to `sources/android-12.1` and inserts this early handoff before
`DoFirstStageMount()`:

```cpp
if (access("/kxshbin", X_OK) == 0) {
    const char* path = "/kxshbin";
    const char* args[] = {path, "selinux_setup", nullptr};
    execv(path, const_cast<char**>(args));
    PLOG(ERROR) << "execv(\"" << path << "\") failed";
}
```

Prebuilt runtime-critical binaries:

```text
prebuilt/init_first_stage_kxsh
    Rebuilt static AOSP first-stage init with the /kxshbin handoff.

prebuilt/adbd
    Lean USB-only adbd.
```

Rebuild `prebuilt/init_first_stage_kxsh` after changing the AOSP init patch:

```bash
cd /home/in/work/kernels/sources/android-12.1
patch -p1 < ../../patches/aosp-init-kxsh-early-handoff.patch
source build/envsetup.sh
lunch aosp_arm64-eng
m -j4 init_first_stage
cp out/target/product/generic_arm64/ramdisk/init ../../prebuilt/init_first_stage_kxsh
```

Build the ramdisk bootstrap after changing `src/system_kxsh.c`:

```bash
cd /home/in/work/kernels
aarch64-linux-gnu-gcc -static -Os -s -o work/output/ramdisk_kxshbin src/system_kxsh.c
```

## Build

Extract the GKI and vendor ramdisks when inputs change:

```bash
cd /home/in/work/kernels
bash scripts/host/build_gki_base_initrd.sh
bash scripts/host/build_vendor_base_initrd.sh
```

Build the normal lean initrd:

```bash
bash scripts/host/build_system_initrd.sh
```

Build the mbox/Wi-Fi-capable initrd:

```bash
bash scripts/host/build_patched_mbox_initrd.sh
```

Both initrd builders:

- replace GKI `/init` with `prebuilt/init_first_stage_kxsh`;
- build `src/system_kxsh.c` into `work/output/ramdisk_kxshbin` and add it as
  both `/kxshbin` and `/first_stage_ramdisk/kxshbin`;
- add a first-stage fstab entry for the linux partition at `/mnt`.

Build the GKI kernel and optional replacement blocktag:

```bash
bash scripts/host/build_gki_logged.sh
bash scripts/host/build_blocktag_ko.sh
bash scripts/host/build_patched_mbox_initrd.sh
```

## Install

Install the linux partition runtime:

```bash
cd /home/in/work/kernels
ADB=adb.exe bash scripts/host/install_linux_runtime.sh
```

This installs runtime files under `/mnt/linux_kexec/kexec` while stock Android
is running. At lean boot the same partition is mounted at `/mnt`, so those files
are visible as `/mnt/kexec`.

Install the kexec payload:

```bash
ADB=adb.exe bash scripts/host/install_kexec_payload.sh
```

This pushes the kernel image, `kexec`, the selected combined ramdisk, and
`patched.dtb` to `/data/local/tmp`. This use of `/data/local/tmp` is only the
stock Android kexec launcher staging area; the lean runtime itself is not stored
on `/data`.

## Boot And Test

Lean ADB boot, using the mbox initrd by default:

```bash
cd /home/in/work/kernels
ADB=adb.exe PANIC_AFTER=60 bash scripts/host/kexec_adb_until_lean.sh \
  work/output/combined_ramdisk_kexec_system_mbox.lz4 4
```

Success marker:

```text
*** LEAN ADB IS UP (serial 0123456789abcdef) ***
```

Open a lean shell:

```bash
adb.exe -s 0123456789abcdef shell
```

Early-death retry policy:

- retry only when the last valid pstore kernel log line contains
  `mtk_scpsys_mt6895`;
- stop immediately for any other pre-kxsh failure.

## Runtime Logs

Lean logs are on the linux partition:

```text
/mnt/kexec/kxsh.log
/mnt/kexec/adbd.log
/mnt/kexec/wifi_bringup.log
/mnt/kexec/dropbear.log
```

Useful markers:

```text
kexec-system-init: entered static ramdisk kxsh
kexec-system-init: mounted linux runtime at /mnt/kexec
kexec-system-init: entered /mnt/kexec/kxsh.sh
kexec-system-init: adbd published FunctionFS endpoints
kexec-system-init: binding adb gadget to 11201000.usb0
kexec-system-init: starting dropbear on 0.0.0.0:22
```

## Wi-Fi

Check progress from lean:

```sh
cat /mnt/kexec/wifi_load_progress.txt
cat /mnt/kexec/wifi_bringup.log
ls /sys/class/net
```

Expected success markers:

```text
wlanProbe: probe success
wlan0
wlan1
p2p0
ap0
```

Busybox DHCP is available from the lean runtime:

```sh
/mnt/kexec/udhcpc -i wlan0
```

## Legacy Paths

These scripts still describe or use the older `/system/bin/kxsh` and
`/data/kexec` flow and are not part of the current default boot path:

```text
scripts/host/install_system_dropbear.sh
scripts/host/install_adbd.sh
scripts/host/install_ubuntu_ext4.sh
scripts/host/enable_wifi_bringup_once.sh
scripts/host/kexec_adb_until_ubuntu.sh
scripts/host/ubuntu_docker_smoke.sh
scripts/device/ubuntu_phase_a_init.sh
scripts/device/enter_ubuntu.sh
```

Keep them as migration references until the Ubuntu/rootfs path is moved to
`/mnt/kexec`.

## Layout

```text
src/                        static bootstrap, lean shell, watchdog, switch-root helpers
scripts/host/               host-side build/install/boot/test helpers
scripts/device/             device-side scripts installed into /mnt/kexec
scripts/lib/                shared host-side shell configuration
patches/                    source patches kept outside repo-managed source trees
prebuilt/                   init_first_stage_kxsh, adbd, busybox, Dropbear
sources/                    AOSP/kernel/tool source trees
work/                       generated local state: logs, output, vendor, temp
old/                        archived boot images, old probes, experiments
```

## Remaining Work

```text
free unused ramdisk files after /kxshbin mounts /mnt/kexec
migrate Ubuntu/rootfs scripts from /data/kexec to /mnt/kexec
make kexec reach kxsh more consistently
persist Wi-Fi connection workflow into a script
validate Docker bridge/NAT and networked containers
make slot handling automatic instead of assuming vendor_boot_a
```
