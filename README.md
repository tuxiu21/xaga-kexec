# Kexec Lean Linux on mt6895

This project boots a lean rescue userspace, and optionally a direct-root Ubuntu
rootfs, on xaga/mt6895 hardware through `kexec`. The current default path does
not modify `/system`; Ubuntu and the lean runtime are stored on the dedicated
`linux` partition, not on `/data`.

## Active Handoff

```text
GKI ramdisk /init
  -> run ramdisk /kxshbin --prepare
      -> create early /dev/block nodes when needed
      -> mount the linux partition directly at /kexec
      -> verify /kexec/lean/busybox and /kexec/lean/kxsh.sh
  -> FreeRamdisk()
      -> delete only files still on the old ramdisk st_dev
      -> leave /kexec alone because it is an ext4 mount
  -> execve /kexec/lean/busybox sh /kexec/lean/kxsh.sh
      -> start lean adbd, Dropbear, watchdog, optional Wi-Fi bring-up
      -> or, if /kexec/lean/boot_ubuntu_rootfs.once exists,
         switch_root to the Ubuntu rootfs at /kexec
```

The linux partition is expected at `/dev/block/by-name/linux`; `/dev/block/sdc88`
is also recognized because by-name links may not exist yet in first-stage init.
When stock Android is running, scripts mount the same partition at
`/mnt/linux_kexec` for installation and log collection. That stock-side mount
point is not used by the lean runtime.

The linux partition root is reserved for the Ubuntu rootfs. The lean rescue
runtime lives under `/lean` on that partition, which appears as `/kexec/lean`
after kexec.

## Current State

- Lean ADB works. The lean serial is `0123456789abcdef`.
- Direct-root Ubuntu handoff is implemented through
  `/kexec/lean/boot_ubuntu_rootfs`; the Ubuntu ADB serial is
  `ubuntu012345678`.
- The GKI ramdisk embeds `/kxshbin`; no external `/mnt/kxshbinxxxx` handoff
  binary is required.
- `prebuilt/init_first_stage_kxsh` is a rebuilt AOSP first-stage init. It runs
  `/kxshbin --prepare` before `DoFirstStageMount()`. If prepare succeeds, it
  skips Android first-stage mounts, frees the old ramdisk, and execs
  `/kexec/lean/busybox sh /kexec/lean/kxsh.sh`. If prepare fails or `/kxshbin` is missing,
  it falls back to normal `/system/bin/init selinux_setup`.
- `kxshbin` is a small static ramdisk bootstrap built from `src/system_kxsh.c`.
  `--prepare` mounts `/kexec` and verifies `/kexec/lean`, then returns to init.
- `scripts/host/install_linux_runtime.sh` installs runtime files into the linux
  partition's `/lean` directory. It uses `/data/local/tmp/linux_runtime_stage` only as a
  temporary stock Android transfer staging directory and removes it after copy.
- `patched.dtb` carries the regulator always-on fix used by kexec tests.
- Before each kexec test jump, the host scripts pin stock Android's
  `mm_infra` power domain on through genpd/runtime PM. This avoids the first
  kexec boot entering the new kernel with `mm_infra` off and hanging when
  `mtk-scpsys-mt6895` first touches `mminfra_config`.
- Wi-Fi modules load from `/kexec/lean/modules`; firmware is copied to
  `/kexec/lean/firmware`, and kexec cmdline sets `firmware_class.path=/kexec/lean/firmware`.
  Current direct-root testing skips Android `DoFirstStageMount()`, so real
  `/vendor` and `/vendor_dlkm` are not mounted by Android first-stage init.
  This differs from the older `/system/bin/init` handoff path where Wi-Fi once
  worked after Android mounted vendor partitions.
- Lean USB ADB may need a UDC replug after kexec. `src/kxsh.sh` records USB mode
  and state, writes the MTK controller mode node, binds `11201000.usb0`, and
  rebinds the UDC until the state becomes `configured`.

## Safety Notes

- Do not run `fastboot reboot recovery` on xaga; it can leave the BCB set to
  `boot-recovery`.
- Keep `panic_after` nonzero while debugging. Use a larger value such as `600`
  for Wi-Fi tests so the panic timer does not interrupt long power-on waits.
- Do not repeatedly kexec after a failed boot without collecting pstore or lean
  logs. Ramoops is small and useful evidence is easy to overwrite.

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

Generated state lives under `work/`, which is also gitignored.

## Reproducible Patches And Prebuilts

The AOSP init patch is stored in:

```text
patches/aosp-init-kxsh-early-handoff.patch
```

It applies to `sources/android-12.1`. The patch adds an early `/kxshbin
--prepare` path before `DoFirstStageMount()`. On success, init frees the old
ramdisk and execs `/kexec/lean/busybox sh /kexec/lean/kxsh.sh`; otherwise it continues to
the normal Android handoff.

Prebuilt runtime-critical binaries:

```text
prebuilt/init_first_stage_kxsh
    Rebuilt static AOSP first-stage init with the /kxshbin early handoff.

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

Full rebuild from the connected stock Android device:

```bash
cd /home/in/work/kernels
ADB=adb.exe STOCK_SERIAL=U89PBYJBFQKNLZEY RUN_MODE=lean MAX=4 \
  bash scripts/host/full_rebuild_from_device.sh
```

This pulls `boot${slot}` and `vendor_boot${slot}` from the current slot, rebuilds
the combined mbox initrd, installs the linux partition runtime, installs the
kexec launcher payload, and runs the selected test. Use `RUN_MODE=ubuntu` to
switch to the Ubuntu rootfs test, or `RUN_MODE=none` to stop after installation.
Set `INSTALL_UBUNTU=1 ROOTFS_TAR=/path/to/ubuntu-rootfs.tar.gz` to reinstall
the Ubuntu rootfs into the linux partition root during the same run.

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
- leave linux partition mounting to `/kxshbin --prepare`.

Build the GKI kernel and optional replacement blocktag:

```bash
bash scripts/host/build_gki_logged.sh
bash scripts/host/build_blocktag_ko.sh
bash scripts/host/build_patched_mbox_initrd.sh
```

## Install

Install or refresh the Ubuntu rootfs:

```bash
cd /home/in/work/kernels
ADB=adb.exe ROOTFS_TAR=ubuntu-rootfs.tar.gz \
  bash scripts/host/install_ubuntu_rootfs.sh
```

This mounts the linux partition under stock Android at `/mnt/linux_kexec`,
preserves `/mnt/linux_kexec/lean`, removes the old Ubuntu rootfs contents by
default, and extracts the tarball into the partition root. Set `WIPE_UBUNTU=0`
to overlay without deleting existing Ubuntu files.

Install the linux partition runtime:

```bash
cd /home/in/work/kernels
ADB=adb.exe bash scripts/host/install_linux_runtime.sh
```

This mounts the linux partition under stock Android at `/mnt/linux_kexec`,
pushes files through `/data/local/tmp/linux_runtime_stage`, copies lean runtime
files into `/mnt/linux_kexec/lean`, and removes the staging directory. At kexec
boot, the same partition is mounted at `/kexec`.

Install the kexec payload:

```bash
ADB=adb.exe bash scripts/host/install_kexec_payload.sh
```

This pushes the kernel image, `kexec`, the selected combined ramdisk, and
`patched.dtb` to `/data/local/tmp`. This use of `/data/local/tmp` is only the
stock Android kexec launcher staging area.

## Boot And Test

### MT6895 pre-kexec mm_infra cleanup

`scripts/host/kexec_adb_until_lean.sh` and
`scripts/host/kexec_adb_until_ubuntu.sh` run this step automatically before
`kexec -l/-e`:

```sh
echo on > /sys/devices/platform/disable_unused/disable_unused:disable-unused-pd-mm_infra/power/control
```

This uses the stock kernel's own runtime PM path. On the failing path,
`mm_infra` starts as `off-0` and the new kernel can hang on the first
`mminfra_config` access. After this step, `mm_infra` is `on/active` and the
first kexec boot reaches the same `0xc000000d` state as successful later boots.

Run it manually if needed:

```bash
ADB=adb.exe STOCK_SERIAL=U89PBYJBFQKNLZEY \
  bash scripts/host/pre_kexec_mminfra_on.sh
```

Disable it only for regression testing:

```bash
PRE_KEXEC_MMINFRA_ON=0 bash scripts/host/kexec_adb_until_lean.sh
```

Lean ADB boot, using the mbox initrd by default:

```bash
cd /home/in/work/kernels
ADB=adb.exe STOCK_SERIAL=U89PBYJBFQKNLZEY PANIC_AFTER=600 \
  bash scripts/host/kexec_adb_until_lean.sh \
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

Ubuntu direct-root boot:

```bash
cd /home/in/work/kernels
ADB=adb.exe STOCK_SERIAL=U89PBYJBFQKNLZEY UBUNTU_WIFI=0 PANIC_AFTER=180 \
  bash scripts/host/kexec_adb_until_ubuntu.sh \
  work/output/combined_ramdisk_kexec_system_mbox.lz4 4
```

Success marker:

```text
*** UBUNTU ADB SHELL IS UP (serial ubuntu012345678) ***
```

Early-death retry policy:

- retry only when the last valid pstore kernel log line contains
  `mtk_scpsys_mt6895`;
- stop immediately for any other pre-kxsh failure.

## Runtime Logs

From lean:

```text
/kexec/lean/kxsh.log
/kexec/lean/adbd.log
/kexec/lean/wifi_bringup.log
/kexec/lean/dropbear.log
/kexec/lean/boot_ubuntu_rootfs.log
/kexec/lean/ubuntu_phase_a.log
/kexec/lean/adbd_ubuntu.log
```

From stock Android after reboot:

```bash
adb.exe shell "su -c 'mkdir -p /mnt/linux_kexec; mount | grep -q \" /mnt/linux_kexec \" || mount -t ext4 -o rw,noatime /dev/block/by-name/linux /mnt/linux_kexec 2>/dev/null || mount -t ext4 -o rw,noatime /dev/block/sdc88 /mnt/linux_kexec; ls -lh /mnt/linux_kexec; tail -120 /mnt/linux_kexec/lean/kxsh.log'"
```

Useful markers:

```text
kexec-system-init: prepare linux runtime begin
kexec-system-init: mounted linux root at /kexec, lean runtime at /kexec/lean
kexec-system-init: prepare linux runtime ok
kexec-system-init: entered /kexec/lean/kxsh.sh
kexec-system-init: adbd published FunctionFS endpoints
kexec-system-init: host enumerated (udc state=configured
kexec-system-init: starting dropbear on 0.0.0.0:22
```

## Wi-Fi

Run from lean:

```bash
adb.exe -s 0123456789abcdef shell \
  'KEXEC_BASE=/kexec/lean WIFI_POWER_WAIT_SECS=420 /kexec/lean/busybox sh /kexec/lean/wifi_bringup.sh'
```

Check progress:

```sh
cat /kexec/lean/wifi_load_progress.txt
tail -220 /kexec/lean/wifi_bringup.log
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
/kexec/lean/bin/udhcpc -i wlan0
```

## Layout

```text
src/                        static bootstrap, lean shell, watchdog, switch-root helpers
scripts/host/               host-side build/install/boot/test helpers
scripts/device/             device-side scripts installed into /kexec/lean
scripts/lib/                shared host-side shell configuration
patches/                    source patches kept outside repo-managed source trees
prebuilt/                   init_first_stage_kxsh, adbd, busybox, Dropbear
sources/                    AOSP/kernel/tool source trees
work/                       generated local state: logs, output, vendor, temp
old/                        archived boot images, old probes, experiments
```

## Remaining Work

```text
make kexec reach kxsh more consistently
mount or recreate Android vendor/vendor_dlkm paths before Wi-Fi bring-up
debug /dev/wmtWifi I/O error after Wi-Fi modules load and phy0 appears
persist Wi-Fi connection workflow into a script after wlan0 appears
validate Docker bridge/NAT and networked containers
```
