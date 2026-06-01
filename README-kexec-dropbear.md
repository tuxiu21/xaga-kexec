# Kexec Dropbear Rescue Flow

This project builds a kexec initrd that lets Android first-stage init finish, then replaces the normal second-stage `/system/bin/init` handoff with a custom static `/system/bin/kxsh`.

Current proven state:

- first-stage init completes
- `/system/bin/kxsh` is executed
- `/data` is mounted from `/dev/block/sdc86`
- `/data/kexec/kxsh.sh` runs
- USB RNDIS gadget is created and reaches `USB_STATE=CONFIGURED`
- dropbear starts from `/data/kexec/dropbear`

Current not-yet-solved state:

- host-side SSH route/RNDIS networking is not fully solved
- watchdog/SSPM long-running stability is not fully solved
- this is not yet a clean one-command path to an interactive SSH shell

## Requirements

Host tools:

```bash
adb.exe
magiskboot
aarch64-linux-gnu-gcc
perl
sed
```

Device assumptions:

```text
root access is available through su
/system can be remounted read-write
/data is not encrypted for this boot path
active slot is currently assumed to be _a
GKI ramdisk already exists at unpack_gki/ramdisk
```

Important current limitations:

```text
scripts/build_vendor_base_initrd.sh prints the slot suffix but still reads vendor_boot_a
scripts do not extract unpack_gki/ramdisk from boot.img
authorized_keys must be prepared by the user
USB networking still needs host-side debugging
```

## Directory Layout

```text
src/
  system_kxsh.c          static ELF installed to /system/bin/kxsh
  kxsh.sh                /data/kexec second-stage rescue script

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
  test_dropbear_initrd.sh
  kexec_dropbear_until_new.sh

vendor/
  vendor_boot_a.img
  ramdisk.cpio
  ramdisk_patched.cpio
  vendor_ramdisk_patched.lz4

unpack_gki/
  ramdisk

output/
  combined_ramdisk_known_good_base.lz4
  combined_ramdisk_kexec_system.lz4
  system_kxsh.elf

sources/
  kernel/tool source trees kept as project context

old/
  recycle bin for old experiments, logs, old images, old custom-ramdisk tree

logs/
  new kexec test logs
```

## Full Flow

### 1. Build Known-Good Vendor Base Initrd

This pulls `vendor_boot_a`, unpacks it, applies the known MT6315 and DEVAPC patches, and builds the baseline combined initrd.

```bash
cd /home/in/work/kernels
bash scripts/build_vendor_base_initrd.sh
```

Outputs:

```text
vendor/ramdisk_patched.cpio
vendor/vendor_ramdisk_patched.lz4
output/combined_ramdisk_known_good_base.lz4
```

This corresponds to the original known-good flow:

```text
patch mt6315-regulator.ko:
  mediatek,mt6315_7-regulator -> mediatek,mt6315_x-regulator

remove device-apc-mt6895.ko:
  remove ko file
  remove modules.load entry
  remove modules.load.recovery entry
  remove modules.dep entry
```

### 2. Build Static kxsh

```bash
cd /home/in/work/kernels
bash scripts/build_kxsh.sh
```

Output:

```text
output/system_kxsh.elf
```

Equivalent direct command:

```bash
aarch64-linux-gnu-gcc -static -Os -s \
  -o output/system_kxsh.elf \
  src/system_kxsh.c
```

### 3. Install System/Data Rescue Files

This installs:

```text
/system/bin/kxsh
/data/kexec/busybox
/data/kexec/dropbear
/data/kexec/dropbearkey
/data/kexec/kxsh.sh
/data/kexec/passwd
/data/kexec/group
/data/kexec/shadow
/data/kexec/panic_after
```

Run:

```bash
cd /home/in/work/kernels
bash scripts/install_system_dropbear.sh
```

Note: `/data/local/tmp` is used only as an adb push staging area. The persistent files live under `/data/kexec`.

### 4. Build kexec System Initrd

This removes vendor ramdisk `/init`, patches GKI `/init` from:

```text
/system/bin/init
```

to:

```text
/system/bin/kxsh
```

Then it concatenates patched GKI ramdisk plus patched vendor ramdisk.

```bash
cd /home/in/work/kernels
bash scripts/build_system_initrd.sh
```

Output:

```text
output/combined_ramdisk_kexec_system.lz4
```

### 5. Push Initrd to Device

```bash
cd /home/in/work/kernels
bash scripts/push_initrd.sh
```

Device output path:

```text
/data/local/tmp/combined_ramdisk_kexec_system.lz4
```

### 6. Test kexec/dropbear

```bash
cd /home/in/work/kernels
bash scripts/test_dropbear_initrd.sh
```

Default SSH probe target:

```text
198.18.0.2:22
```

Override example:

```bash
bash scripts/test_dropbear_initrd.sh 20 192.168.66.2 22
```

Logs are written under:

```text
logs/kexec_dropbear_until_new_YYYYMMDD_HHMMSS/
```

## Debug Notes

Known good pstore markers:

```text
kexec-system-init: entered static /system/bin/kxsh
kexec-system-init: created /dev/block/sdc86 major=259 minor=70
kexec-system-init: mounted /data as f2fs
kexec-system-init: entered /data/kexec/kxsh.sh
kexec-system-init: creating rndis gadget
kexec-system-init: binding rndis gadget to 11201000.usb0
USB_STATE=CONFIGURED
kexec-system-init: starting dropbear on 0.0.0.0:22
```

Current remaining work:

```text
make slot handling automatic instead of hardcoding vendor_boot_a
extract or document GKI ramdisk source
make authorized_keys setup explicit
solve host-side USB/RNDIS route to dropbear
verify or replace watchdog feeding
```
