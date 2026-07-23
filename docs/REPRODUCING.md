# Developer Reproduction From Stock xaga

This is a developer workflow, not a binary distribution or a general-purpose
installer. Its target is one rooted Xiaomi xaga running a compatible stock
Android build. It deliberately does not publish a phone image, personal Ubuntu
rootfs, Wi-Fi credentials, SSH keys, or files under `sources/`, `work/`, and
`local/`.

## What "reproducible" means here

Starting with this repository, locked source trees, the official Ubuntu 26.04
ARM64 server ISO, and a rooted stock xaga, a developer can:

1. build the GKI kernel;
2. extract `boot` and `vendor_boot` from the connected phone;
3. build the direct-root kexec initrd;
4. install Ubuntu and the kexec runtime on the dedicated `linux` partition;
5. install the stock-side payload and test that systemd reaches Ubuntu.

`config/repro.lock.tsv` is the machine-readable record. It locks the Android
repo manifests, build-relevant repo projects, Xiaomi and OnePlus trees, and
records observed host-tool versions. `scripts/host/check_sources.sh` compares
the current checkout with that file.

The two external archives are locked by canonical URL and SHA-256:

- kexec-tools 2.0.28:
  `https://cdn.kernel.org/pub/linux/utils/kernel/kexec/kexec-tools-2.0.28.tar.xz`,
  SHA-256 `d2f0ef872f39e2fe4b1b01feb62b0001383207239b9f8041f98a95564161d053`.
- Ubuntu 26.04 live-server arm64 ISO:
  `https://cdimage.ubuntu.com/ubuntu/releases/26.04/release/ubuntu-26.04-live-server-arm64.iso`,
  SHA-256 `c9aa567e6560b2eddae3af03fc686002e35b6fee96f97fd5df3271e846439fdd`.

The ISO's `casper/install-sources.yaml` selects
`casper/ubuntu-server-minimal.squashfs` as the minimized server source.
`build_ubuntu_rootfs.sh` extracts exactly that member and records the derived
rootfs archive checksum.

## Safety model

Running the entry point with no action does not modify sources or the device and
does not use the network. Loading the shared environment may create ignored
`work/` subdirectories on the host:

```bash
bash scripts/host/reproduce_from_stock.sh
```

Source downloads require `--fetch-sources`. GPT writes require both
`--apply-partition` and `--confirm-destroy-userdata`. Rootfs deletion requires
both `--wipe-rootfs` and `--confirm-wipe-rootfs`, plus an independently
obtained checksum. Downloads occur only with an explicit `--fetch` or
`--download`, use a locked HTTPS URL, and are checked before extraction.

Partitioning destroys Android userdata. Back up the device and verify that it
can be restored to stock before using that stage. The partition script only
supports the xaga layout it validates and must run in ADB recovery.

## 1. Host preparation

A native Linux host is the least surprising setup. The observed development
host used Bash 5.2, Git 2.43, Android repo 2.36, ADB 36.0.2, and an
`aarch64-linux-gnu-gcc` 13.3 cross compiler. Exact observed versions are
recorded for diagnosis, not asserted as universal minimums.

Required commands are checked from the lock. Native Linux installations
normally use `ADB=adb`; this workspace defaults to `adb.exe` for its WSL host:

```text
bash git repo adb (or adb.exe) aarch64-linux-gnu-gcc magiskboot
make perl sed tar cpio gzip curl file sha256sum strings timeout modinfo unsquashfs
setcap getcap
```

Rootfs creation should run as real root so numeric owners, device nodes, ACLs,
xattrs and file capabilities survive the squashfs-to-tar conversion. On Linux,
install `bsdtar` or `xorriso` for ISO extraction. WSL may use Windows
`tar.exe`. fakeroot is deliberately rejected because it does not reliably
emulate `security.capability`/`setxattr`.

Copy `config/env.example` to the ignored `config/env` only when paths or the ADB
command differ from the defaults:

```bash
cp config/env.example config/env
```

For example, change its ADB line to `ADB=adb` on a native Linux host.

## 2. Fetch and verify source trees

The default check performs no network access:

```bash
bash scripts/host/check_sources.sh
```

On a fresh host, explicitly allow locked HTTPS clones/repo sync and application
of repository-reviewed patches:

```bash
bash scripts/host/fetch_sources.sh --fetch --apply-patches
```

The fetch script refuses non-HTTPS URLs. It first pins each manifest
checkout, runs `repo sync`, and then forcibly checks out the exact project
revisions listed in the lock. In particular, it replaces the manifest's stock
GKI `common` project with the locked public `mykernel-226` commit. The AOSP
manifest is the immutable `android-12.1.0_r21` tag; its modified build-relevant
projects are also checked against exact commits. The script then applies:

```text
patches/kernel-docker-nftables.patch
patches/aosp-init-kxsh-early-handoff.patch
patches/aosp-libmodprobe-kxsh-debug.patch
patches/adbd-kexec-ubuntu.patch
```

The checked-in `prebuilt/init_first_stage_kxsh` and `prebuilt/adbd` are used by
the normal build. Rebuild both from the patched AOSP checkout with:

```bash
bash scripts/host/reproduce_from_stock.sh --build-aosp-prebuilts
```

This builds `init_first_stage` and `adbd`, validates the direct-root/adbd
markers and arm64 outputs, atomically refreshes both prebuilt files, and prints
their SHA-256 values.

The same explicit fetch downloads and verifies the official kexec-tools
archive. Build its static arm64 binary with the recorded configure command:

```bash
bash scripts/host/build_kexec_tools.sh
```

The result is `sources/kexec-tools-2.0.28/build/sbin/kexec`.

## 3. Record the target stock device

Before modifying storage, record at least:

```bash
adb.exe shell 'getprop ro.product.device; getprop ro.build.fingerprint; getprop ro.boot.slot_suffix'
adb.exe shell "su -c 'sgdisk --print /dev/block/sdc'"
```

The total entry point rejects a non-xaga product unless the developer
deliberately sets `ALLOW_UNVERIFIED_DEVICE=1`. That override removes an
important safety check and does not make another device supported.

## 4. Create the Linux partition only when needed

With the phone booted into an ADB-capable recovery, inspect the plan:

```bash
bash scripts/host/reproduce_from_stock.sh --partition-plan
```

Only after reviewing the printed LBAs and accepting userdata loss:

```bash
bash scripts/host/reproduce_from_stock.sh \
  --apply-partition --confirm-destroy-userdata
```

This stage runs alone. Reboot to stock Android before installation. If a
correct `/dev/block/by-name/linux` partition already exists, skip it entirely.

## 5. Build and install

Build kexec-tools and the locked kernel without touching the phone:

```bash
bash scripts/host/reproduce_from_stock.sh --build-kexec
bash scripts/host/reproduce_from_stock.sh --build-aosp-prebuilts
bash scripts/host/reproduce_from_stock.sh --build-kernel
```

Check a local copy of the official ISO:

```bash
UBUNTU_ISO=/absolute/path/to/ubuntu-26.04-live-server-arm64.iso \
  bash scripts/host/build_ubuntu_rootfs.sh --check
```

Downloading is never implicit. If desired, explicitly download the locked ISO:

```bash
bash scripts/host/build_ubuntu_rootfs.sh --download
```

Generate the minimal rootfs as real root:

```bash
sudo --preserve-env=UBUNTU_ISO,ROOTFS_OUTPUT \
  bash scripts/host/build_ubuntu_rootfs.sh --build
```

The default output is
`work/output/ubuntu-26.04-server-minimal-arm64.tar.gz`, accompanied by a
SHA-256 file. GNU tar stores numeric owners, device nodes, ACLs, every xattr
namespace and file capabilities. `unsquashfs -strict-errors` makes reported
metadata loss fatal. Before extraction, the script also proves that a
capability and device node survive a GNU tar round trip on the work filesystem.

This artifact is only the official minimized Ubuntu server baseline. It has
systemd/systemd-sysv, cloud-init, and netplan, but not `openssh-server`,
`wpasupplicant`, Wi-Fi credentials, or project service configuration. The
runtime-install stage supplies the bundled USB adbd and project systemd units.
Wi-Fi association and OpenSSH require later package and site configuration; a
fresh minimal rootfs must not be claimed to provide them.

Replacing the Linux partition root remains explicit:

```bash
ROOTFS_TAR=work/output/ubuntu-26.04-server-minimal-arm64.tar.gz \
ROOTFS_SHA256="$(awk '{print $1}' work/output/ubuntu-26.04-server-minimal-arm64.tar.gz.sha256)" \
  bash scripts/host/reproduce_from_stock.sh \
    --wipe-rootfs --confirm-wipe-rootfs
```

The archive must contain `etc/os-release` and a usable `/bin/sh` or
`/usr/bin/sh`. The installer rejects absolute and parent-traversal tar entries.
It installs only the base rootfs; project systemd/runtime files are installed
in the next stage.

With rooted stock Android running:

```bash
ADB=adb.exe STOCK_SERIAL=<stock-serial> \
  bash scripts/host/reproduce_from_stock.sh --install
```

This invokes `full_rebuild_from_device.sh` with rootfs replacement disabled. It
pulls `boot` and `vendor_boot` from the active slot, builds the patched mbox
initrd, installs `/usr/local/libexec/kexec`, and stages the kernel, kexec,
initrd, and DTB under stock `/data/local/tmp`.

Run one guarded boot test. Baseline acceptance is systemd plus bundled USB
adbd, not Wi-Fi or SSH:

```bash
ADB=adb.exe STOCK_SERIAL=<stock-serial> MAX=1 PANIC_AFTER=600 \
  bash scripts/host/reproduce_from_stock.sh --boot-test
```

Expected proof after boot:

```bash
adb.exe -s ubuntu012345678 shell 'cat /proc/1/comm'
adb.exe -s ubuntu012345678 shell 'systemctl is-system-running'
adb.exe -s ubuntu012345678 shell 'systemctl --failed --no-legend'
```

The expected PID 1 is `systemd`; system state should be `running` or a
deliberately understood degraded state, and the Ubuntu ADB serial should be
present. Add OpenSSH/Wi-Fi acceptance only after installing and configuring
their userspace packages.

## Generated and private state

Do not commit these:

```text
sources/                  external source checkouts
work/                     builds, logs, pulled boot images
local/                    local boot inputs
ubuntu-rootfs.tar.gz      legacy local rootfs archive
*.img *.lz4 *.cpio *.dtb  generated device artifacts
```

The repository's `.gitignore` already excludes them. Stock `boot` and
`vendor_boot` remain target-device inputs by design and are pulled from the
active slot rather than redistributed.
