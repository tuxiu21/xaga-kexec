# Kexec Lean-Linux Host on mt6895 (production)

This project boots a **lean Linux userspace on the phone's own hardware via kexec**,
to run production workloads (Docker, pure-CPU) with minimal Android overhead. It
lets Android first-stage init finish, then replaces the normal second-stage
`/system/bin/init` handoff with a custom static `/system/bin/kxsh`, which mounts
`/data`, brings up networking, and starts an SSH server (dropbear) for access.

**This is not a rescue system** — it is the device's intended runtime. dropbear is
just how we reach it.

**Why kexec instead of flashing a custom boot:** the bootloader is unlockable, but
kexec is deliberate. If the lean system fails to boot or dies, the device falls
back to Android (adb reachable), so it can be re-kexec'd remotely with no physical
access. Combined with the hardware watchdog and an auto-kexec-on-boot step, this is
a self-healing loop: `lean system hangs → watchdog reset → Android → auto re-kexec`.

## What works now

- kexec reliably boots the lean kernel + initrd (single-boot success ~60%; the boot
  loop retries until a full boot).
- second-stage handoff to `/system/bin/kxsh`; `/data` mounted as f2fs; `kxsh.sh` runs.
- USB RNDIS gadget reaches `USB_STATE=CONFIGURED`; dropbear starts on `:22`.
- **survives the kernel's ~30s "disable unused regulators" cleanup** (previously a
  hard ~31.7s death) via a DTB `regulator-always-on` patch — full boots now run well
  past 31s.

Boot-reliability fixes (in `scripts/kexec_dropbear_until_new.sh`):

- device-side `--initrd` uses the **basename** — a host-relative path made `kexec -l`
  fail silently, so the device never rebooted and every round re-read a stale log.
- the **AP hardware watchdog is kicked right before the kexec jump** — it would
  otherwise time out before the new kernel reaches its own feeder (`AP_WDT`).
- `--dtb=patched.dtb` carries `regulator-always-on` (see step 6).
- the loop retries until it captures a **full** boot (reached kxsh), keeping the best
  partial; freshness is decided by a per-round `/dev/kmsg` nonce, not by "Bye!".

## In progress / not yet solved

- **thermal under sustained CPU load is untested** (screen removed for cooling) —
  verify in-kernel throttling before running real production load.
- host-side route over USB RNDIS (USB 2.0 is slow; wifi planned, load on demand).
- Docker bring-up inside kxsh (cgroup v2, overlayfs, `/var/lib/docker` on `/data`).
- auto-kexec on Android boot; kernel-module whitelist; baking the DTB patch into
  vendor_boot for permanence; narrowing the 9 always-on rails by bisection.
- ~20% `AP_WDT` + ~20% `scpsys`/SSPM early-boot deaths — scattered, no clean
  kernel-side fix found; the boot loop's retry absorbs them.

## Requirements

Host tools:

```bash
adb.exe
magiskboot
aarch64-linux-gnu-gcc
gcc                      # builds the libfdt DTB patcher
perl
sed
```

Device assumptions:

```text
root access is available through su (KernelSU/Magisk)
/system can be remounted read-write
/data is not encrypted for this boot path
active slot is currently assumed to be _a
GKI ramdisk already exists at unpack_gki/ramdisk
```

Known limitations:

```text
scripts/build_vendor_base_initrd.sh prints the slot suffix but still reads vendor_boot_a
scripts do not extract unpack_gki/ramdisk from boot.img
authorized_keys must be prepared by the user
host-side USB/RNDIS route still needs work
```

## Directory Layout

```text
src/
  system_kxsh.c          static ELF installed to /system/bin/kxsh (2nd-stage init)
  kxsh.sh                /data/kexec second-stage userspace bringup (mount /data, USB, dropbear)
  dtb_always_on.c        libfdt in-place DTB patcher (adds regulator-always-on)

prebuilt/
  busybox
  dropbear
  dropbearkey

scripts/
  build_vendor_base_initrd.sh
  build_kxsh.sh
  install_system_dropbear.sh
  build_system_initrd.sh
  push_initrd.sh
  build_always_on_dtb.sh        generate + push patched.dtb (regulator-always-on)
  test_dropbear_initrd.sh
  kexec_dropbear_until_new.sh

vendor/                  unpacked from vendor_boot_a.img (ramdisk, base dtb)
unpack_gki/ramdisk       GKI ramdisk (patched init -> kxsh)
output/                  combined initrds + system_kxsh.elf
sources/                 kernel / tool source trees kept as project context
logs/                    kexec boot logs
old/                     recycle bin for old experiments
```

## Full Flow

### 1. Build Known-Good Vendor Base Initrd

Pulls `vendor_boot_a`, unpacks it, applies the known MT6315 and DEVAPC patches, and
builds the baseline combined initrd.

```bash
cd /home/in/work/kernels
bash scripts/build_vendor_base_initrd.sh
```

```text
patch mt6315-regulator.ko:  mediatek,mt6315_7-regulator -> mediatek,mt6315_x-regulator
remove device-apc-mt6895.ko (ko + modules.load + modules.load.recovery + modules.dep)
```

### 2. Build Static kxsh

```bash
bash scripts/build_kxsh.sh
# == aarch64-linux-gnu-gcc -static -Os -s -o output/system_kxsh.elf src/system_kxsh.c
```

### 3. Install kxsh + runtime files

Installs `/system/bin/kxsh` and the `/data/kexec` payload (busybox, dropbear,
dropbearkey, kxsh.sh, passwd/group/shadow, panic_after).

```bash
bash scripts/install_system_dropbear.sh
```

`/data/local/tmp` is only an adb push staging area; the persistent files live under
`/data/kexec`.

### 4. Build kexec System Initrd

Removes vendor ramdisk `/init`, patches GKI `/init` from `/system/bin/init` to
`/system/bin/kxsh`, then concatenates patched GKI + patched vendor ramdisk.

```bash
bash scripts/build_system_initrd.sh
# -> output/combined_ramdisk_kexec_system.lz4
```

### 5. Push Initrd to Device

```bash
bash scripts/push_initrd.sh
# -> /data/local/tmp/combined_ramdisk_kexec_system.lz4
```

### 6. Build & Push the regulator-always-on DTB

A minimal userspace leaves some PMIC rails unclaimed, so the kernel's 30s "disable
unused regulators" cleanup cuts them and the SoC browns out (~31.7s). This pulls the
device's **live** DTB (`/sys/firmware/fdt` — the bootloader's finished product, with
its memory / reserved-memory fixups), adds `regulator-always-on` to the affected
rails **in place** with libfdt (no decompile, no source rebuild), and pushes it.

```bash
bash scripts/build_always_on_dtb.sh
# -> /data/local/tmp/patched.dtb   (used via --dtb; see DTB_DEV below)
```

### 7. Boot / capture loop

`kexec_dropbear_until_new.sh` kexecs (kicking the watchdog, passing `--dtb`), then
retries until it captures a full boot or SSH comes up.

```bash
bash scripts/test_dropbear_initrd.sh            # 20 rounds, ssh probe 198.18.0.2:22
bash scripts/test_dropbear_initrd.sh 20 192.168.66.2 22
# knobs: DTB_DEV=patched.dtb (default; set empty to reuse live FDT),
#        STALE_MAX / BYE_MAX / NOEXEC_MAX
```

Logs: `logs/kexec_dropbear_until_new_YYYYMMDD_HHMMSS/`.

## Debug Notes

Full-boot pstore markers:

```text
kexec-system-init: entered static /system/bin/kxsh
kexec-system-init: mounted /data as f2fs
kexec-system-init: entered /data/kexec/kxsh.sh
kexec-system-init: creating rndis gadget / binding rndis gadget to 11201000.usb0
USB_STATE=CONFIGURED
kexec-system-init: starting dropbear on 0.0.0.0:22
```

Decode a reset reason (MTK): `/proc/aed/reboot-reason` (e.g. `WDT status: 2` = AP
watchdog timeout) and `/proc/cmdline` `aee_aed.pureason` / `poffreason` (these
describe the *previous* reset). The live DTB carries per-boot fields the static base
does not — patch the live one, never vendor_boot's base or the kernel-source `.dts`.

Remaining work:

```text
validate thermal throttling under sustained CPU load
solve host-side USB/RNDIS route (then wifi)
bring up Docker (cgroup v2, overlayfs) inside kxsh
auto-kexec on Android boot (with retry + a debug-disable flag)
module whitelist; narrow the always-on rails; bake the DTB patch into vendor_boot
make slot handling automatic instead of hardcoding vendor_boot_a
```
