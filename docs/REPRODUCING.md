# Reproduce Xaga Ubuntu From Stock

This is a developer workflow for one rooted Xiaomi xaga. It reproduces the
kernel, direct-root initrd, kexec runtime and an official Ubuntu 26.04 minimal
rootfs. It does not distribute a phone image, credentials or personal data.

All public operations use one repository-root command:

```bash
./xaga help
```

Scripts below `scripts/` are internal implementation units, not additional
user entry points.

## Safety boundary

These commands are read-only with respect to the phone:

```bash
./xaga doctor
./xaga build all
```

These commands change host source/build state:

```bash
./xaga prepare
./xaga build rootfs --iso /absolute/path/to/ubuntu.iso
```

These commands change the phone:

```bash
./xaga install
./xaga boot
./xaga test --unattended --rounds 10
./xaga flash stock-kernel --apply --confirm-active-slot
```

Partition creation destroys Android userdata and therefore requires a separate
paired confirmation. Rootfs replacement also requires an archive, an
independently obtained SHA-256 and a paired confirmation.

## 1. Prepare the host

A native Linux host is recommended; WSL is supported. Required tools include
Bash, Git, Android repo, ADB, an AArch64 cross compiler, magiskboot, make,
cpio, curl, unsquashfs, GNU tar, setcap and getcap.

This workspace defaults to `adb.exe`. On native Linux, create the ignored local
configuration:

```bash
cp config/env.example config/env
sed -i 's/^ADB=.*/ADB=adb/' config/env
```

Run the read-only diagnosis:

```bash
./xaga doctor
```

On a fresh checkout it will report missing locked source trees. Explicitly
allow the source download:

```bash
./xaga prepare
```

Then require an exact clean lock match:

```bash
STRICT=1 ./xaga doctor
```

`config/repro.lock.tsv` pins the Android manifests/projects, the independent
`xaga-stock` and `xaga-ubuntu` kernel worktrees, Xiaomi and OnePlus trees,
kexec-tools archive and official Ubuntu ISO checksum. Downloads use locked
HTTPS URLs and are verified before extraction.

## 2. Prepare the phone partition once

Skip this section when `/dev/block/by-name/linux` already has the expected
layout.

Boot an ADB-capable recovery and inspect the xaga GPT plan:

```bash
./xaga partition --plan
```

Only after backing up the phone and accepting userdata loss:

```bash
./xaga partition --apply --confirm-destroy-userdata
```

This stage runs alone. Reboot into rooted stock Android before installation.

## 3. Build the project

Build static ARM64 kexec-tools, patched AOSP first-stage init/adbd and the
Ubuntu-profile GKI kernel:

```bash
./xaga build all
```

Individual targets remain available when iterating:

```bash
./xaga build kexec
./xaga build aosp
./xaga build kernel ubuntu
./xaga build kernel stock
```

The two kernel builds use independent Git worktrees and independent outputs:

```text
sources/android-kernel/common-stock
sources/android-kernel/common-ubuntu
sources/android-kernel/out-stock/android12-5.10/dist
sources/android-kernel/out-ubuntu/android12-5.10/dist
```

The stock build asserts `CONFIG_KSU=y`, `CONFIG_NF_TABLES` disabled and
`CONFIG_DEVTMPFS` disabled. The Ubuntu build asserts the opposite profile
boundary. Build logs and other artifacts stay under ignored directories.

## 4. Repack a stock debug boot image

With the device running rooted stock Android, create a host-side plan:

```bash
./xaga flash stock-kernel --plan --serial <stock-adb-serial>
```

This does not write a partition. It:

1. resolves the actual active slot;
2. copies the full active boot partition into a timestamped backup;
3. replaces only the unpacked kernel with the stock-profile Image;
4. repacks and re-unpacks the boot image;
5. verifies the embedded kernel hash and exact partition size.

The verified image is written under `work/output/`; the original boot image
and manifest are retained under `work/backups/stock-kernel/`.

Only after reviewing the plan and ensuring an external bootloader recovery
path is available:

```bash
./xaga flash stock-kernel --apply \
  --confirm-active-slot \
  --serial <stock-adb-serial>
```

Apply refuses a non-orange verified-boot state, verifies the uploaded image,
writes only the resolved active `boot_<slot>`, verifies a full-partition
readback hash, and deliberately leaves reboot as a separate action.

## 5. Build the Ubuntu rootfs

The locked input is the official Ubuntu 26.04 live-server ARM64 ISO:

```text
https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/
ubuntu-26.04-live-server-arm64.iso
```

Locked SHA-256:

```text
c9aa567e6560b2eddae3af03fc686002e35b6fee96f97fd5df3271e846439fdd
```

Rootfs extraction must run as real root so owners, device nodes, ACLs, xattrs
and file capabilities survive:

```bash
sudo --preserve-env=ADB \
  ./xaga build rootfs \
    --iso /absolute/path/to/ubuntu-26.04-live-server-arm64.iso
```

Output:

```text
work/output/ubuntu-26.04-server-minimal-arm64.tar.gz
work/output/ubuntu-26.04-server-minimal-arm64.tar.gz.sha256
```

This is the official minimized server baseline. It contains systemd,
cloud-init and netplan, but it does not claim to include configured Wi-Fi,
OpenSSH, personal users or credentials. The project installer adds the bundled
USB adbd and project runtime units.

## 6. Install

First record the rooted stock Android ADB serial:

```bash
./xaga status
```

For a new or intentionally replaced Ubuntu installation:

```bash
rootfs=work/output/ubuntu-26.04-server-minimal-arm64.tar.gz
rootfs_sha256="$(awk '{print $1}' "$rootfs.sha256")"

./xaga install \
  --serial <stock-adb-serial> \
  --rootfs "$rootfs" \
  --sha256 "$rootfs_sha256" \
  --confirm-wipe-rootfs
```

This verifies xaga, rooted stock Android, the checksum and safe archive paths
before replacing the Linux-partition root. It then pulls active-slot `boot`
and `vendor_boot`, rebuilds the direct-root initrd, installs the Linux runtime
and stages the kexec payload.

When Ubuntu already exists and only the project runtime needs refreshing:

```bash
./xaga install --serial <stock-adb-serial>
```

## 7. Boot and verify

Run one normal boot:

```bash
./xaga boot \
  --serial <stock-adb-serial>
```

The default profile is `dev`. Use `./xaga boot prod` only after unattended
watchdog validation; it selects health-gated recovery with real hardware reset.

The panic timer defaults to disabled. For a timed test reset, pass a non-zero
`--panic-after SECONDS` explicitly.

Verify the Ubuntu USB ADB target:

```bash
./xaga status
```

The baseline acceptance criterion is PID 1 `systemd` plus bundled USB adbd.
Wi-Fi and SSH are separate site configuration.

For repeated unattended validation:

```bash
./xaga test --unattended \
  --serial <stock-adb-serial> \
  --rounds 10 \
  --panic-after 600
```

Logs are collected below `work/logs/`.

## 8. Back up the working Ubuntu

Boot rooted stock Android so the Linux partition is unmounted:

```bash
./xaga backup \
  --serial <stock-adb-serial> \
  --output-dir /safe/backup/location/ubuntu_$(date +%Y%m%d)
```

The command uses an offline read-only mount and creates:

```text
ubuntu-rootfs.tar.zst
ubuntu-rootfs.tar.zst.sha256
partition-info.txt
tar.stderr.log
zstd.stderr.log
COMPLETED
```

It validates both the zstd frame and the complete tar stream before writing
`COMPLETED`. Runtime Unix sockets may be reported as ignored; they are
ephemeral and should not be restored.

## Private and generated state

Do not commit:

```text
sources/
work/
local/
personal rootfs backups
Wi-Fi credentials
SSH private keys
```

For implementation call graphs and low-level debugging, see
[INTERNALS.md](INTERNALS.md).
