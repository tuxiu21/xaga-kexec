# Kexec Lean Linux on mt6895

This project boots a lean Linux userspace on the phone's hardware via `kexec`.
Android first-stage init runs far enough to hand off to `/system/bin/init`; the
combined ramdisk patches that handoff to `/system/bin/kxsh`, which then enters the
`/data/kexec` runtime.

The host-side management path is **adb over USB**. Dropbear still runs inside the
lean system, but it is reached through `adb forward tcp:2222 tcp:22`, not through
RNDIS.

## Safety Notes

- Do **not** run `fastboot reboot recovery` on xaga. It can leave the BCB set to
  `boot-recovery` and force repeated recovery boots. Enter recovery only through a
  verified safe device-specific path.
- Do not repeatedly kexec after a failed boot without collecting adb, pstore, or
  bootloader state. Ramoops is small and useful evidence is easy to overwrite.

## Current State

- kexec can reach the lean userspace intermittently; retrying is expected.
- Known outcomes per attempt are roughly: reaches `kxsh`, old-kernel `Bye!` only,
  or early init/module hang.
- The correct kexec kernel is extracted from
  `old/5.10.226/260531-ramsize-docker.img`.
- `patched.dtb` carries the `regulator-always-on` fix that avoids the old ~31.7s
  regulator cleanup death.
- `src/kxsh.sh` sets up an adb-only USB gadget and starts lean `adbd`; USB
  enumeration is verified working (host sees serial `0123456789abcdef` with a
  root shell).
- RNDIS is deprecated for this workflow. The Windows/RNDIS host route was too
  fragile and is no longer the primary debug path.

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

## Important Files

```text
src/system_kxsh.c          static second-stage init shim installed as /system/bin/kxsh
src/kxsh.sh                /data/kexec runtime: mounts, watchdog, adb gadget, dropbear
src/dtb_always_on.c        libfdt DTB patcher for regulator-always-on

scripts/install_kexec_payload.sh
                            installs kernel, kexec binary, initrd, patched.dtb
scripts/install_adbd.sh     installs prebuilt/adbd (lean) plus runtime linker/libs
scripts/install_system_dropbear.sh
                            installs /system/bin/kxsh and /data/kexec runtime files
scripts/build_system_initrd.sh
                            builds output/combined_ramdisk_kexec_system.lz4
scripts/build_always_on_dtb.sh
                            generates and pushes /data/local/tmp/patched.dtb
scripts/force_stock_adb_recovery.sh
                            recovery-side helper to force stock adb and clear BCB
scripts/kexec_adb_until_new.sh
                            kexec boot/capture loop; stops when lean adb
                            enumerates (serial 0123456789abcdef)
scripts/kexec_dropbear_until_new.sh
                            same loop judged by SSH; holds the watchdog /
                            regulator / Bye! / partial debugging notes

vendor/                     unpacked vendor ramdisk payloads
unpack_gki/ramdisk          GKI ramdisk patched from init -> kxsh
output/                     generated initrds and binaries
sources/                    AOSP/kernel/tool source trees
logs/                       captured kexec logs
old/                        archived boot images and experiments
```

## Build And Install

Build the vendor base and system initrd when the ramdisk inputs change:

```bash
cd /home/in/work/kernels
bash scripts/build_vendor_base_initrd.sh
bash scripts/build_system_initrd.sh
```

The lean `adbd` is frozen into `prebuilt/adbd` (the AOSP **recovery** variant --
the only one built with the `LEAN_KEXEC_ADBD` marker). `scripts/install_adbd.sh`
installs from there and refuses any `adbd` without that marker. Rebuild it only
when the AOSP source changes:

```bash
cd /home/in/work/kernels/sources/android-12.1
source build/envsetup.sh
lunch aosp_arm64-eng
m adbd
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

## Boot And Access

Set a short panic timer while debugging so logs return to stock Android quickly:

```bash
adb.exe shell "su -c 'echo 45 > /data/kexec/panic_after'"
```

Boot with the existing kexec/test scripts. A successful lean adb transport should
enumerate as serial `0123456789abcdef`.

```bash
adb.exe devices
adb.exe -s 0123456789abcdef shell
```

For a full dropbear session over adb:

```bash
adb.exe -s 0123456789abcdef forward tcp:2222 tcp:22
ssh -p 2222 root@127.0.0.1
```

If stock Android returns but `adb devices` stays empty, unplug/replug the USB cable
or restart the Windows adb server. The device can be back in stock while the host
USB transport is still stale.

## Debug Markers

Persistent lean logs:

```text
/data/kexec/kxsh.log
/data/kexec/adbd.log
```

Useful `kxsh.log` markers:

```text
kexec-system-init: entered /data/kexec/kxsh.sh
kexec-system-init: setup_usb_adb: begin
kexec-system-init: mounted adb FunctionFS
kexec-system-init: starting lean adbd
kexec-system-init: adbd published FunctionFS endpoints
kexec-system-init: binding adb gadget to 11201000.usb0
kexec-system-init: starting dropbear on 0.0.0.0:22
kexec-system-init: panic cleanup: begin
```

Failure interpretation:

```text
no /data/kexec/kxsh.log        did not reach kxsh; inspect pstore
only ep0 in /dev/usb-ffs/adb   adbd did not write FunctionFS descriptors
adb shows unauthorized         wrong adbd was installed or auth was not disabled
stock adb needs replug         host USB transport stayed stale after kexec/panic
```

MTK reset reason is visible after returning to Android via `/proc/aed/reboot-reason`
and `/proc/cmdline` fields such as `aee_aed.pureason` and `poffreason`; they describe
the previous reset.

## Remaining Work

```text
make kexec reach kxsh more consistently (single-kexec ~50%; retry covers it)
bring up Docker in the lean runtime
validate thermal throttling under sustained CPU load
auto-kexec on Android boot with a debug-disable flag
make slot handling automatic instead of assuming vendor_boot_a
```
