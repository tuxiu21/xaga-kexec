# Kexec Lean Linux on mt6895

This project boots a lean Linux userspace on xaga/mt6895 hardware via `kexec`.
Android first-stage init runs far enough to hand off to `/system/bin/init`; the
combined ramdisk patches that handoff to `/system/bin/kxsh`, which enters the
`/data/kexec` runtime.

The primary management path is **ADB over USB**. Dropbear also runs in the lean
system and can now be reached over Wi-Fi once `wlan0` is up.

## Safety Notes

- Do **not** run `fastboot reboot recovery` on xaga. It can leave the BCB set to
  `boot-recovery` and force repeated recovery boots.
- Keep `/data/kexec/panic_after` nonzero while debugging. The lean runtime uses
  it to panic back to stock Android if the system hangs.
- Do not repeatedly kexec after a failed boot without collecting adb, pstore, or
  bootloader state. Ramoops is small and useful evidence is easy to overwrite.

## Current State

- Lean ADB enumeration works. The lean serial is `0123456789abcdef`.
- `patched.dtb` carries the `regulator-always-on` fix that avoids the old ~31.7s
  regulator cleanup death.
- Wi-Fi bring-up works with the patched mbox initrd. `wlanProbe success` creates
  `wlan0`, `wlan1`, `p2p0`, and `ap0`; SSID scan has been verified with `iw`.
- Wi-Fi is slow to appear. The WMT write can return `Input/output error` and log
  a 10s timeout, then firmware/pre-cal continues asynchronously and succeeds
  around 80-100s later.
- Dropbear over Wi-Fi works with key auth. `/etc/shells` must list
  `/data/kexec/sh`; `src/kxsh.sh` now creates that file.
- Ubuntu chroot is available at `/data/kexec/ubuntu-rootfs` and entered with
  `/data/kexec/enter-ubuntu.sh` once installed.
- Docker can start inside the Ubuntu rootfs with cgroup v2, `vfs` storage, and
  bridge/iptables disabled. The offline smoke test has run successfully with
  `docker-run-ok`.
- The current Docker test kernel enables the container namespace/cgroup options
  in `common/arch/arm64/configs/docker_gki.fragment` and keeps `CONFIG_KSU`
  disabled. KernelSU exec hooks crashed this guest kernel during Docker startup.
- The stock `blocktag.ko` is not ABI-safe after enabling options such as
  `CONFIG_SYSVIPC`; rebuild it against the current GKI output with
  `scripts/host/build_blocktag_ko.sh` and include it in the mbox initrd.

## Requirements

Host tools:

```bash
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
/system can be remounted read-write for installing /system/bin/kxsh
/data is usable from the lean runtime
active slot is currently assumed to be _a by some scripts
local/boot-5.10.img exists, or GKI_BOOT_IMAGE points at the downloaded GKI boot image
```

## Source Trees

`sources/` is intentionally gitignored. A fresh machine needs these trees before
the build and install scripts are fully reproducible:

```text
sources/android-kernel
    Android 12 5.10 GKI build tree. Used by build_gki_logged.sh and as the
    Kbuild output base for external modules. The current local manifest is from
    https://android.googlesource.com/kernel/manifest with common-android12-5.10
    projects and android12-5.10 kernel/common. Verified anchors:
    manifest d49bde8, common 450a2c1e4bef, build dbfab7e0.

sources/Xiaomi_Kernel_OpenSource
    Xiaomi xaga vendor kernel source. Current branch: xaga-s-oss. Used for
    libfdt helpers and rebuilding the patched mtk-mbox.ko. Verified anchor:
    56ec519f6.

sources/android_kernel_5.10_oneplus_mt6895
    OnePlus MTK 5.10 vendor kernel source. Current branch:
    oneplus/mt6895_v_15.0.0_ace_race, Makefile SUBLEVEL=236. Used only for
    rebuilding blocktag.ko against the current GKI output. Verified anchor:
    05dd76e8b.

sources/kexec-tools-2.0.28
    kexec-tools source/build output. install_kexec_payload.sh expects
    build/sbin/kexec here.

sources/android-12.1
    AOSP android-12.1.0_r21 platform checkout. Only needed when rebuilding the
    patched lean adbd; otherwise prebuilt/adbd is enough. Verified anchors:
    platform manifest eafeb3b, packages/modules/adb 73fcdbf.

sources/KernelSU
    Historical/experimental source. The current Docker guest kernel keeps
    CONFIG_KSU disabled because KernelSU exec hooks crashed during Docker tests.

sources/android_bootable_recovery, sources/clang-prebuilt
    Historical/support checkouts. They are not in the current main boot path.
```

Generated and extracted local state lives under `work/`, which is also
gitignored:

```text
work/logs/                 captured build, kexec, and recovery logs
work/output/               generated initrds, helper binaries, module builds
work/vendor/               extracted and patched vendor ramdisk payloads
work/unpack_gki/ramdisk    GKI ramdisk input
work/tmp/                  temporary build directories, including blocktag_build
```

`local/` is for operator-provided inputs that are needed to reproduce the build
but should not be committed:

```text
local/boot-5.10.img        Google-downloaded GKI boot image used to extract the
                           base GKI ramdisk
```

`old/` is only a local archive. Scripts do not depend on it.

Suggested bootstrap shape:

```bash
mkdir -p /home/in/work/kernels/sources

cd /home/in/work/kernels/sources
mkdir android-kernel && cd android-kernel
repo init -u https://android.googlesource.com/kernel/manifest -b common-android12-5.10
repo sync -c -j"$(nproc)"

cd /home/in/work/kernels/sources
git clone -b xaga-s-oss https://github.com/MiCode/Xiaomi_Kernel_OpenSource.git
git clone -b oneplus/mt6895_v_15.0.0_ace_race \
  https://github.com/OnePlusOSS/android_kernel_5.10_oneplus_mt6895.git
```

For adbd rebuilds:

```bash
cd /home/in/work/kernels/sources
mkdir android-12.1 && cd android-12.1
repo init -u https://android.googlesource.com/platform/manifest -b android-12.1.0_r21
repo sync -c -j"$(nproc)"
```

Most scripts allow path overrides:

```text
AK=/path/to/android-kernel
XIAOMI=/path/to/Xiaomi_Kernel_OpenSource
ONEPLUS_SRC=/path/to/android_kernel_5.10_oneplus_mt6895
KEXEC_BIN=/path/to/kexec
KERNEL_IMAGE=/path/to/Image
```

## Configuration

Scripts source `scripts/lib/env.sh`. Copy `config/env.example` to `config/env`
only when local paths differ from the defaults:

```bash
cp config/env.example config/env
```

The default layout is:

```text
sources/    external source trees
work/       generated local state
```

## Active Scripts

Build:

```text
scripts/host/build_gki_logged.sh
    Builds the Android GKI kernel and writes full logs under work/logs.

scripts/host/build_gki_base_initrd.sh
    Extracts the GKI ramdisk from GKI_BOOT_IMAGE, defaulting to
    local/boot-5.10.img, into work/unpack_gki/ramdisk.

scripts/host/build_blocktag_ko.sh
    Builds replacement blocktag.ko into work/tmp/blocktag_build.

scripts/host/build_vendor_base_initrd.sh
    Pulls vendor_boot_a from the device and creates work/vendor/ramdisk_patched.cpio.

scripts/host/build_system_initrd.sh
    Builds work/output/combined_ramdisk_kexec_system.lz4 for normal lean ADB/Dropbear.

scripts/host/build_patched_mbox_initrd.sh
    Rebuilds patched mtk-mbox.ko, replaces it in the vendor ramdisk, and builds
    work/output/combined_ramdisk_kexec_system_mbox.lz4 for Wi-Fi bring-up. If
    work/tmp/blocktag_build/blocktag.ko exists, it is included too.

scripts/host/build_ubuntu_ext4.sh
    Converts ubuntu-rootfs.tar.gz into work/rootfs/ubuntu.ext4. Defaults to a
    16G sparse ext4 image and uses fakeroot + mkfs.ext4 -d when available, so
    host sudo is not required.

scripts/host/build_always_on_dtb.sh
    Pulls the live device DTB, marks required regulators always-on, and pushes
    patched.dtb to /data/local/tmp.
```

Install and boot:

```text
scripts/host/install_system_dropbear.sh
    Installs /system/bin/kxsh, /data/kexec runtime files, lean adbd, Dropbear,
    boot_ubuntu_ext4, wifi_bringup.sh, and enter-ubuntu.sh. Also installs
    the kexec payload.

scripts/host/install_ubuntu_ext4.sh
    Pushes work/rootfs/ubuntu.ext4 and boot_ubuntu_ext4 into /data/kexec.

scripts/host/install_kexec_payload.sh
    Pushes the current GKI dist/Image, kexec binary, selected initrd, and
    patched.dtb. Set KERNEL_IMAGE=... to override.

scripts/host/install_adbd.sh
    Installs prebuilt/adbd plus runtime linker/libs.

scripts/host/enable_wifi_bringup_once.sh
    Sets /data/kexec/run_wifi_probe so the next lean boot runs wifi_bringup.sh.

scripts/host/kexec_adb_until_new.sh
    Boots and captures retries until lean ADB enumerates. Defaults to the mbox
    initrd. Set BOOT_UBUNTU_EXT4_ONCE=1 to make the next lean boot loop-mount
    /data/kexec/ubuntu.ext4 and switch_roots into it. The current default init
    target is /data/kexec/ubuntu_phase_a_init.sh, which writes validation logs
    and then panics back to stock Android.
```

Runtime tests:

```text
scripts/host/ubuntu_docker_smoke.sh
    Starts Docker inside the Lean Ubuntu rootfs and runs an offline container.

scripts/device/wifi_bringup.sh
    Device-side Wi-Fi module/probe script.

scripts/device/enter_ubuntu.sh
    Device-side Ubuntu chroot entry script.

scripts/device/ubuntu_phase_a_init.sh
    Device-side Ubuntu switch-root validation init. Starts the Ubuntu-stage
    watchdog feeder, writes validation logs, and currently panics back to stock
    Android.
```

Maintenance:

```text
scripts/host/check_sources.sh
    Prints local source-tree and key build-output status.

scripts/host/apply_adbd_patch.sh
    Applies the lean adbd patch to the AOSP adb source tree.

scripts/host/force_stock_adb_recovery.sh
    Recovery-side helper to restore stock Android ADB access.
```

Historical probes and one-off debug scripts live under `old/scripts-20260613/`.

## Build

Build the base vendor ramdisk when `vendor_boot_a` changes:

```bash
cd /home/in/work/kernels
bash scripts/host/build_gki_base_initrd.sh
bash scripts/host/build_vendor_base_initrd.sh
```

Build the normal lean initrd:

```bash
bash scripts/host/build_system_initrd.sh
```

Build the Wi-Fi-capable initrd:

```bash
bash scripts/host/build_patched_mbox_initrd.sh
```

`build_patched_mbox_initrd.sh` is the Wi-Fi-specialized equivalent of
`build_system_initrd.sh`: it repeats the GKI `/system/bin/init` ->
`/system/bin/kxsh` patch and additionally replaces `mtk-mbox.ko`.

Build the Docker test kernel and replacement `blocktag.ko`:

```bash
bash scripts/host/build_gki_logged.sh
bash scripts/host/build_blocktag_ko.sh
bash scripts/host/build_patched_mbox_initrd.sh
```

The kernel build log is written under `work/logs/gki_build_*`. Use `TAIL_LINES=120`
or `FOLLOW=1` when you need more output without loading the full build log.

## Install

The lean `adbd` is frozen into `prebuilt/adbd` (the AOSP recovery variant with
the `LEAN_KEXEC_ADBD` patch). Apply the patch after a fresh AOSP checkout or
repo sync:

```bash
cd /home/in/work/kernels
bash scripts/host/apply_adbd_patch.sh
```

Rebuild only when the adbd source changes:

```bash
cd /home/in/work/kernels/sources/android-12.1
source build/envsetup.sh
lunch aosp_arm64-eng
m out/soong/.intermediates/packages/modules/adb/adbd/android_recovery_arm64_armv8-a/adbd
cp out/soong/.intermediates/packages/modules/adb/adbd/android_recovery_arm64_armv8-a/adbd \
   /home/in/work/kernels/prebuilt/adbd
```

Install the runtime payload:

```bash
cd /home/in/work/kernels
bash scripts/host/install_system_dropbear.sh
```

That script also runs `scripts/host/install_kexec_payload.sh` and
`scripts/host/install_adbd.sh`.

## Boot

Default lean ADB boot, using the mbox/Wi-Fi initrd:

```bash
cd /home/in/work/kernels
PANIC_AFTER=300 bash scripts/host/kexec_adb_until_new.sh
```

Wi-Fi boot with one-shot bring-up:

```bash
cd /home/in/work/kernels
bash scripts/host/build_patched_mbox_initrd.sh
PANIC_AFTER=300 bash scripts/host/enable_wifi_bringup_once.sh
PANIC_AFTER=300 bash scripts/host/kexec_adb_until_new.sh
```

A successful lean ADB transport enumerates as:

```bash
adb.exe -s 0123456789abcdef shell
```

## Wi-Fi

Check progress:

```sh
cat /data/kexec/wifi_load_progress.txt
cat /data/kexec/wifi_bringup.log
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

Enter Ubuntu and scan:

```sh
/data/kexec/enter-ubuntu.sh
ip link set wlan0 up
iw dev wlan0 scan | grep SSID
```

Connect with WPA/WPA2:

```sh
cat > /tmp/wpa.conf <<'EOF'
network={
    ssid="YOUR_SSID"
    psk="YOUR_PASSWORD"
}
EOF

wpa_supplicant -B -i wlan0 -c /tmp/wpa.conf
dhclient wlan0
ip addr show wlan0
```

Busybox DHCP is also available from the lean runtime:

```sh
/data/kexec/udhcpc -i wlan0
```

## Docker

Run the current offline Docker smoke test after lean ADB is up:

```bash
cd /home/in/work/kernels
bash scripts/host/ubuntu_docker_smoke.sh
```

Expected marker:

```text
docker-run-ok
```

Current limitations:

```text
overlay2 on /data/f2fs still fails with EINVAL, so the smoke test uses vfs
Docker-managed bridge/NAT is disabled with --iptables=false --bridge=none
networked containers have not been validated yet
CONFIG_KSU is disabled in the guest kernel because its exec hook crashed Docker
```

## SSH

Dropbear reads root keys from:

```text
/data/kexec/root/.ssh/authorized_keys
```

Permissions must be strict:

```sh
chmod 700 /data/kexec/root /data/kexec/root/.ssh
chmod 600 /data/kexec/root/.ssh/authorized_keys
```

If Dropbear logs `User 'root' has invalid shell`, make sure `/etc/shells`
contains `/data/kexec/sh`. Current `src/kxsh.sh` creates this automatically.

Useful checks:

```sh
ps | grep dropbear
cat /data/kexec/dropbear.log
cat /etc/passwd
cat /etc/shells
```

## Debug Logs

Persistent lean logs:

```text
/data/kexec/kxsh.log
/data/kexec/adbd.log
/data/kexec/wifi_bringup.log
/data/kexec/dropbear.log
```

Useful `kxsh.log` markers:

```text
kexec-system-init: entered /data/kexec/kxsh.sh
kexec-system-init: setup_usb_adb: begin
kexec-system-init: adbd published FunctionFS endpoints
kexec-system-init: binding adb gadget to 11201000.usb0
kexec-system-init: starting dropbear on 0.0.0.0:22
kexec-system-init: running one-shot wifi_bringup.sh
kexec-system-init: panic cleanup: begin
```

Failure interpretation:

```text
no /data/kexec/kxsh.log        did not reach kxsh; inspect pstore
only ep0 in /dev/usb-ffs/adb   adbd did not write FunctionFS descriptors
adb shows unauthorized         wrong adbd was installed or auth was not disabled
stock adb needs replug         host USB transport stayed stale after kexec/panic
no wlan0 after DONE            inspect wifi_bringup.log and pstore for mbox/SCP errors
```

When `adb.exe` is run from WSL, errors such as
`UtilAcceptVsock: accept4 failed 110` or `UtilBindVsockAnyPort: socket failed`
can occur intermittently on the host side. They are usually transient WSL/ADB
transport errors; rerun the same command before treating them as a device-side
failure.

MTK reset reason is visible after returning to Android via `/proc/aed/reboot-reason`
and `/proc/cmdline` fields such as `aee_aed.pureason` and `poffreason`; they describe
the previous reset.

## Layout

```text
src/                        lean init shim, watchdog feeder, and switch-root helpers
scripts/host/               host-side build/install/boot/test helpers
scripts/device/             device-side scripts pushed into /data/kexec
scripts/lib/                shared host-side shell configuration
patches/                    source patches kept outside repo-managed trees
prebuilt/                   busybox, adbd, dropbear, dropbearkey
sources/                    AOSP/kernel/tool source trees
work/                       generated local state: logs, output, vendor, temp
old/                        archived boot images, old probes, experiments
```

## Remaining Work

```text
make kexec reach kxsh more consistently
persist the Wi-Fi connection workflow into a script
validate Docker bridge/NAT and networked containers
try Docker overlay2 on an ext4 data-root or switch-root Ubuntu setup
validate thermal throttling under sustained CPU load
auto-kexec on Android boot with a debug-disable flag
make slot handling automatic instead of assuming vendor_boot_a
```
