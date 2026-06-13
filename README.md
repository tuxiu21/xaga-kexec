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
GKI ramdisk exists at unpack_gki/ramdisk
```

## Active Scripts

Build initrds:

```text
scripts/build_vendor_base_initrd.sh
    Pulls vendor_boot_a from the device and creates vendor/ramdisk_patched.cpio.

scripts/build_system_initrd.sh
    Builds output/combined_ramdisk_kexec_system.lz4 for normal lean ADB/Dropbear.

scripts/build_patched_mbox_initrd.sh
    Rebuilds patched mtk-mbox.ko, replaces it in the vendor ramdisk, and builds
    output/combined_ramdisk_kexec_system_mbox.lz4 for Wi-Fi bring-up.
```

Install/runtime:

```text
scripts/install_system_dropbear.sh
    Installs /system/bin/kxsh, /data/kexec runtime files, lean adbd, Dropbear,
    wifi_bringup.sh, and enter-ubuntu.sh. Also installs the kexec payload.

scripts/install_kexec_payload.sh
    Pushes kernel, kexec binary, selected initrd, and patched.dtb.

scripts/install_adbd.sh
    Installs prebuilt/adbd plus runtime linker/libs.

scripts/enable_wifi_bringup_once.sh
    Sets /data/kexec/run_wifi_probe so the next lean boot runs wifi_bringup.sh.

scripts/kexec_adb_until_new.sh
    Boots and captures retries until lean ADB enumerates.
```

Support:

```text
scripts/build_always_on_dtb.sh
scripts/apply_adbd_patch.sh
scripts/force_stock_adb_recovery.sh
scripts/enter_ubuntu.sh
scripts/wifi_bringup.sh
```

Historical probes and one-off debug scripts live under `old/scripts-20260613/`.

## Build

Build the base vendor ramdisk when `vendor_boot_a` changes:

```bash
cd /home/in/work/kernels
bash scripts/build_vendor_base_initrd.sh
```

Build the normal lean initrd:

```bash
bash scripts/build_system_initrd.sh
```

Build the Wi-Fi-capable initrd:

```bash
bash scripts/build_patched_mbox_initrd.sh
```

`build_patched_mbox_initrd.sh` is the Wi-Fi-specialized equivalent of
`build_system_initrd.sh`: it repeats the GKI `/system/bin/init` ->
`/system/bin/kxsh` patch and additionally replaces `mtk-mbox.ko`.

## Install

The lean `adbd` is frozen into `prebuilt/adbd` (the AOSP recovery variant with
the `LEAN_KEXEC_ADBD` patch). Apply the patch after a fresh AOSP checkout or
repo sync:

```bash
cd /home/in/work/kernels
bash scripts/apply_adbd_patch.sh
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
bash scripts/install_system_dropbear.sh
```

That script also runs `scripts/install_kexec_payload.sh` and
`scripts/install_adbd.sh`.

## Boot

Normal lean ADB boot:

```bash
cd /home/in/work/kernels
PANIC_AFTER=90 bash scripts/kexec_adb_until_new.sh output/combined_ramdisk_kexec_system.lz4
```

Wi-Fi boot:

```bash
cd /home/in/work/kernels
bash scripts/build_patched_mbox_initrd.sh
PANIC_AFTER=300 bash scripts/enable_wifi_bringup_once.sh
PANIC_AFTER=300 bash scripts/kexec_adb_until_new.sh output/combined_ramdisk_kexec_system_mbox.lz4
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

MTK reset reason is visible after returning to Android via `/proc/aed/reboot-reason`
and `/proc/cmdline` fields such as `aee_aed.pureason` and `poffreason`; they describe
the previous reset.

## Layout

```text
src/                        lean init shim and runtime shell
scripts/                    current build/install/boot helpers
patches/                    source patches kept outside repo-managed trees
prebuilt/                   busybox, adbd, dropbear, dropbearkey
vendor/                     unpacked and patched vendor ramdisk payloads
unpack_gki/ramdisk          GKI ramdisk input
output/                     generated initrds and binaries
sources/                    AOSP/kernel/tool source trees
logs/                       captured kexec logs
old/                        archived boot images, old probes, experiments
```

## Remaining Work

```text
make kexec reach kxsh more consistently
persist the Wi-Fi connection workflow into a script
bring up Docker in the lean Ubuntu runtime
validate thermal throttling under sustained CPU load
auto-kexec on Android boot with a debug-disable flag
make slot handling automatic instead of assuming vendor_boot_a
```
