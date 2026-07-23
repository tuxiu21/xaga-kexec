# Kexec Ubuntu on mt6895

This project boots a direct-root Ubuntu system on xaga/mt6895 through `kexec`.
Ubuntu and its runtime helpers live on the dedicated `linux` partition. There
is no intermediate lean/rescue userspace and no runtime dependency on `/data`.

## Active Handoff

```text
GKI ramdisk /init
  -> run ramdisk /kxshbin --prepare
      -> create early /dev/block nodes when needed
      -> mount the linux partition directly at /kexec
      -> verify /kexec/usr/local/libexec/kexec/boot_ubuntu_rootfs
  -> FreeRamdisk()
      -> delete only files still on the old ramdisk st_dev
      -> leave /kexec alone because it is an ext4 mount
  -> execve /kexec/usr/local/libexec/kexec/boot_ubuntu_rootfs
      -> arm the early hardware-watchdog/panic safety net
      -> move mounts, chroot to /kexec, and exec /sbin/init
  -> systemd multi-user.target
```

The linux partition is expected at `/dev/block/by-name/linux`; `/dev/block/sdc88`
is also recognized because by-name links may not exist yet in first-stage init.
When stock Android is running, scripts mount the same partition at
`/mnt/linux_kexec` for installation and log collection. That stock-side mount
point is not used after the handoff.

## Current State

- Direct-root Ubuntu handoff is implemented through
  `/kexec/usr/local/libexec/kexec/boot_ubuntu_rootfs`; the Ubuntu ADB serial is
  `ubuntu012345678`.
- The GKI ramdisk embeds `/kxshbin`; no external `/mnt/kxshbinxxxx` handoff
  binary is required.
- `prebuilt/init_first_stage_kxsh` is a rebuilt AOSP first-stage init. It runs
  `/kxshbin --prepare` before `DoFirstStageMount()`. If prepare succeeds, it
  skips Android first-stage mounts, frees the old ramdisk, and execs the static
  direct-root helper. If prepare fails or `/kxshbin` is missing, it falls back
  to normal `/system/bin/init selinux_setup`.
- `kxshbin` is a small static ramdisk bootstrap built from `src/system_kxsh.c`.
  `--prepare` mounts `/kexec` and verifies the direct-root helper, then returns
  to init.
- `scripts/host/install_linux_runtime.sh` installs runtime files into the linux
  partition's `/usr/local/libexec/kexec` directory. Persistent state is under
  `/var/lib/kexec-runtime`, logs under `/var/log/kexec-runtime`, and volatile
  state under `/run/kexec-runtime`.
- `patched.dtb` carries the regulator always-on fix used by kexec tests.
- Before each kexec test jump, the host scripts pin stock Android's
  `mm_infra` power domain on through genpd/runtime PM. This avoids the first
  kexec boot entering the new kernel with `mm_infra` off and hanging when
  `mtk-scpsys-mt6895` first touches `mminfra_config`.
- Wi-Fi module bring-up now recreates the needed Android dynamic partition
  mappings from the direct-root Ubuntu runtime, mounts `/vendor` and `/vendor_dlkm`,
  and loads modules from those mounted paths. The kexec cmdline keeps
  `firmware_class.path=/vendor/firmware`; `build_patched_mbox_initrd.sh` can
  optionally embed early firmware under `/vendor/firmware` in the GKI ramdisk
  by setting `WIFI_FIRMWARE_DIR`.
- Ubuntu direct-root starts systemd by execing `/sbin/init`. The stock rescue
  service is the recovery control plane if Ubuntu fails.
- Ubuntu hardware bring-up is managed by split systemd units. `kexec-wifi.service`
  only brings up the Wi-Fi hardware; `kexec-wpa-supplicant.service` and
  `systemd-networkd.service` handle AP association and DHCP when
  `/etc/wpa_supplicant/wpa_supplicant-wlan0.conf` exists.
- OpenSSH server is installed and enabled in the Ubuntu rootfs. It uses the
  root account's `/root/.ssh/authorized_keys` and disables password login.
- The Docker-oriented GKI config fragment enables overlayfs, bridge netfilter,
  legacy iptables NAT, and nftables support. A kernel built from this fragment
  has been kexec-booted into Ubuntu with `iptables-nft`, `nft list ruleset`,
  `systemctl start docker`, and `docker run --rm hello-world` all passing.
- The Ubuntu rootfs currently uses `mihomo.service` for the Clash/Mihomo
  subscription path. HTTP and SOCKS proxies listen on `127.0.0.1:7890` and
  `127.0.0.1:7891`; the Web UI listens on port `9090` and should keep a
  non-empty API secret when exposed beyond loopback.

## Safety Notes

- Do not run `fastboot reboot recovery` on xaga; it can leave the BCB set to
  `boot-recovery`.
- Production defaults `panic_after` to `0` (disabled). Host test loops pass a
  nonzero value explicitly; use at least `600` for long Wi-Fi tests.
- Do not repeatedly kexec after a failed boot without collecting pstore and
  `/var/log/kexec-runtime`. Ramoops is small and useful evidence is easy to
  overwrite.

## Stock Rescue

Stock Android can provide a small KernelSU rescue path after the Ubuntu
watchdog resets back to stock. The stock path is intentionally minimal:

```text
KernelSU service.d
  -> /data/adb/service.d/stock-rescue.sh
  -> start Dropbear on 127.0.0.1:22
  -> optionally reverse SSH to usjgw 127.0.0.1:22023
  -> keep /data/local/tmp/stock-rescue.log
```

Install the stock rescue files while stock ADB is available:

```bash
cd /home/in/work/kernels
ADB=adb.exe AUTHORIZED_KEYS=/path/to/authorized_keys \
  bash scripts/host/install_stock_rescue.sh
```

Reverse SSH to the Oracle VM uses the bundled aarch64 `prebuilt/dbclient` and a
dedicated private key installed on stock. The default sample configuration
targets `usjgw` as `ubuntu@129.146.190.204` and reserves port `22023` for stock:

```bash
ADB=adb.exe \
AUTHORIZED_KEYS=/path/to/authorized_keys \
ORACLE_IDENTITY=/path/to/oracle_ed25519 \
  bash scripts/host/install_stock_rescue.sh
```

If the reverse tunnel is up, connect from `usjgw` with:

```bash
ssh -p 22023 root@127.0.0.1
```

The helper `/data/local/tmp/stock-rescue/reboot-to-ubuntu.sh` is the single
stock-side launcher. It prepares the Ubuntu target, verifies and pins
`mm_infra`, derives a complete cmdline from stock cmdline/bootconfig, loads the
staged payload, and jumps into Ubuntu.

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
ramdisk and execs
`/kexec/usr/local/libexec/kexec/boot_ubuntu_rootfs`; otherwise it continues to
the normal Android handoff.

Prebuilt runtime-critical binaries:

```text
prebuilt/init_first_stage_kxsh
    Rebuilt static AOSP first-stage init with the /kxshbin early handoff.

prebuilt/adbd
    Ubuntu USB-only adbd.
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

For a new developer machine, start with
[`docs/REPRODUCING.md`](docs/REPRODUCING.md) and the safe default, which does
not modify sources or the device and does not use the network:

```bash
bash scripts/host/reproduce_from_stock.sh
```

The guide separates locked source preparation, optional destructive
partitioning, trusted rootfs installation, build/install, and the boot test.
The guide locks the official Ubuntu 26.04 server ISO and kexec-tools 2.0.28
archives by HTTPS URL and SHA-256, while keeping every download explicit.

Full rebuild from the connected stock Android device:

```bash
cd /home/in/work/kernels
ADB=adb.exe STOCK_SERIAL=U89PBYJBFQKNLZEY RUN_MODE=ubuntu MAX=4 \
  bash scripts/host/full_rebuild_from_device.sh
```

This pulls `boot${slot}` and `vendor_boot${slot}` from the current slot, rebuilds
the combined mbox initrd, installs the linux partition runtime, installs the
kexec launcher payload, and runs the Ubuntu rootfs test. Use `RUN_MODE=none`
to stop after installation.
Set `INSTALL_UBUNTU=1 ROOTFS_TAR=/path/to/ubuntu-rootfs.tar.gz` to reinstall
the Ubuntu rootfs into the linux partition root during the same run.

Extract the GKI and vendor ramdisks when inputs change:

```bash
cd /home/in/work/kernels
bash scripts/host/build_gki_base_initrd.sh
bash scripts/host/build_vendor_base_initrd.sh
```

Build the normal direct-root initrd:

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

`build_gki_logged.sh` loads `common/build.config.docker` by default. That
fragment merges `arch/arm64/configs/docker_gki.fragment` and
`arch/arm64/configs/kexec_ubuntu.fragment`, so the default GKI build includes
the Ubuntu/kexec baseline plus Docker-facing options such as:

```text
CONFIG_DEVTMPFS=y
CONFIG_OVERLAY_FS=y
CONFIG_BRIDGE_NETFILTER=y
CONFIG_IP_NF_NAT=y
CONFIG_IP_NF_TARGET_MASQUERADE=y
CONFIG_NF_TABLES=y
CONFIG_NF_TABLES_INET=y
CONFIG_NFT_COMPAT=y
CONFIG_NFT_NAT=y
CONFIG_NFT_MASQ=y
CONFIG_NFT_REJECT=y
```

Use config assertions when changing kernel fragments:

```bash
CHECK_CONFIG_ONLY=1 \
REQUIRED_KERNEL_CONFIGS='CONFIG_NF_TABLES=y CONFIG_NFT_NAT=y CONFIG_DEVTMPFS=y' \
  bash scripts/host/build_gki_logged.sh
```

## Install

Install or refresh the Ubuntu rootfs:

```bash
cd /home/in/work/kernels
ADB=adb.exe ROOTFS_TAR=ubuntu-rootfs.tar.gz \
  bash scripts/host/install_ubuntu_rootfs.sh
```

This mounts the linux partition under stock Android at `/mnt/linux_kexec`,
removes the old Ubuntu rootfs contents by default, and extracts the tarball
into the partition root. Set `WIPE_UBUNTU=0` to overlay without deleting
existing Ubuntu files.

Install the linux partition runtime:

```bash
cd /home/in/work/kernels
ADB=adb.exe bash scripts/host/install_linux_runtime.sh
```

This mounts the linux partition under stock Android at `/mnt/linux_kexec`,
pushes files through `/data/local/tmp/kexec_runtime_stage`, installs programs
under `/mnt/linux_kexec/usr/local/libexec/kexec`, installs systemd units and
configuration into the Ubuntu root, then removes the obsolete
`/mnt/linux_kexec/lean` tree. At kexec boot, the partition is mounted at
`/kexec`.

Install the kexec payload:

```bash
ADB=adb.exe bash scripts/host/install_kexec_payload.sh
```

This pushes the kernel image, `kexec`, the selected combined ramdisk, and
`patched.dtb` to `/data/local/tmp`. This use of `/data/local/tmp` is only the
stock Android kexec launcher staging area.

## Ubuntu Rootfs Notes

The direct-root Ubuntu path is intentionally minimal. `src/boot_ubuntu_rootfs.c`
moves the existing `/proc`, `/sys`, `/dev`, `/config`, and cgroup mounts into
the Ubuntu rootfs, then execs `/sbin/init`.

Systemd starts split kexec services for:

```text
watchdog feeder
panic timer
vendor/vendor_dlkm mapping and mounts
Ubuntu USB ADB
USB/adbd sampler
optional Wi-Fi module bring-up
kexec-wpa-supplicant and systemd-networkd networking
OpenSSH server
```

Docker is usable in the Ubuntu rootfs with the Docker GKI fragment above. The
last validated path used `iptables-nft` on the kexec kernel:

```sh
update-alternatives --set iptables /usr/sbin/iptables-nft
update-alternatives --set ip6tables /usr/sbin/ip6tables-nft
iptables -t nat -L
nft list ruleset
systemctl start docker
docker run --rm hello-world
```

If booted into an older kernel without `CONFIG_NF_TABLES`, switch back to
legacy iptables instead:

```sh
update-alternatives --set iptables /usr/sbin/iptables-legacy
update-alternatives --set ip6tables /usr/sbin/ip6tables-legacy
```

For package maintenance in this kexec rootfs, keep the Ubuntu kernel packages
held unless you are deliberately testing Ubuntu-packaged kernels:

```sh
apt-mark hold linux-generic linux-headers-generic linux-image-generic
```

`flash-kernel` should also be disabled for this rootfs because boot images are
managed by the Android/kexec payload, not by Ubuntu:

```sh
mkdir -p /etc/flash-kernel
printf 'none\n' > /etc/flash-kernel/machine
```

When using host-side proxying for package operations, set up ADB reverse and
make sure loopback is up in Ubuntu:

```sh
adb.exe -s ubuntu012345678 reverse tcp:7890 tcp:7890
adb.exe -s ubuntu012345678 shell 'ip link set lo up'
```

Then run apt with explicit proxy variables, for example:

```sh
http_proxy=http://127.0.0.1:7890 \
https_proxy=http://127.0.0.1:7890 \
apt-get update
```

## Boot And Test

### MT6895 pre-kexec mm_infra cleanup

The stock launcher used by `scripts/host/kexec_adb_until_ubuntu.sh` runs this
step automatically before `kexec -l/-e`:

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

Ubuntu direct-root boot:

```bash
cd /home/in/work/kernels
ADB=adb.exe STOCK_SERIAL=U89PBYJBFQKNLZEY UBUNTU_WIFI=0 PANIC_AFTER=180 \
  bash scripts/host/kexec_adb_until_ubuntu.sh \
  work/output/combined_ramdisk_kexec_system_mbox.lz4 4
```

The kexec test scripts do not append extra debug memory parameters by default.
Use `KEXEC_EXTRA_CMDLINE='slub_debug=FZPU init_on_free=1'` only for an explicit
debug run; those options have exposed early userspace instability on this stack.

Success marker:

```text
*** UBUNTU ADB SHELL IS UP (serial ubuntu012345678) ***
```

Early-death retry policy:

- retry only when the last valid pstore kernel log line contains
  `mtk_scpsys_mt6895`;
- stop immediately for any other failure before the direct-root handoff.

## Runtime Logs

Persistent direct-root logs:

```text
/var/log/kexec-runtime/boot-rootfs.log
/var/log/kexec-runtime/ubuntu-runtime.log
/var/log/kexec-runtime/adbd.log
/var/log/kexec-runtime/wifi-bringup.log
/var/log/kexec-runtime/dmesg-wifi-before.log
/var/log/kexec-runtime/dmesg-wifi-after.log
```

In Ubuntu, systemd unit state is the primary runtime view:

```sh
systemctl status kexec-adbd.service kexec-wifi.service \
  kexec-wpa-supplicant.service systemd-networkd.service ssh.service
journalctl -u kexec-wifi.service -u kexec-wpa-supplicant.service -b --no-pager
```

For the user-space proxy and container stack:

```sh
systemctl status mihomo.service docker.service containerd.service
journalctl -u mihomo.service -u docker.service -b --no-pager
curl -I -x http://127.0.0.1:7890 https://www.google.com
docker info
```

Watchdog mode is controlled by `/etc/xaga-watchdog.conf` in the Ubuntu rootfs.
Both modes use the installed shell watchdog helper. Keep development sessions
in the default unconditional feed mode:

```sh
WATCHDOG_MODE=dev
WATCHDOG_DRY_RUN=1
```

For unattended burn-in, switch to gated dry-run first. This keeps kicking the
MTK hardware watchdog but records whether health checks would have stopped
feeding it:

```sh
WATCHDOG_MODE=unattended
WATCHDOG_DRY_RUN=1
WATCHDOG_HEALTH_URLS="https://your-health-endpoint.example/ping"
systemctl restart kexec-watchdog.service
cat /run/kexec-runtime/watchdog-health
journalctl -u kexec-watchdog.service -b --no-pager
```

Only after a clean 24-48 hour dry-run should `WATCHDOG_DRY_RUN=0` be used. In
that mode, repeated health-check failures make the watchdog service hold
`/dev/watchdog0` open and stop kicking it, leaving the hardware watchdog to
reset the device.

From stock Android after reboot:

```bash
adb.exe shell "su -c 'mkdir -p /mnt/linux_kexec; mount | grep -q \" /mnt/linux_kexec \" || mount -t ext4 -o rw,noatime /dev/block/by-name/linux /mnt/linux_kexec 2>/dev/null || mount -t ext4 -o rw,noatime /dev/block/sdc88 /mnt/linux_kexec; tail -120 /mnt/linux_kexec/var/log/kexec-runtime/boot-rootfs.log'"
```

Useful markers:

```text
kexec-system-init: prepare linux runtime begin
kexec-system-init: mounted linux root at /kexec, boot helper at /kexec/usr/local/libexec/kexec/boot_ubuntu_rootfs
kexec-system-init: prepare linux runtime ok
boot-ubuntu-rootfs: begin direct rootfs newroot=/kexec init=/sbin/init
boot-ubuntu-rootfs: early watchdog armed
boot-ubuntu-rootfs: moving mounts and switching root
```

## Wi-Fi

Module and firmware bring-up is handled by `scripts/device/wifi_bringup.sh`.
It is installed as `/usr/local/libexec/kexec/wifi_bringup.sh` and is run by
`kexec-wifi.service` unless `/etc/kexec-runtime/wifi_enabled` disables it.

The intended production network path is `wlan0` over Wi-Fi 6. USB is useful as
the rescue/control plane for ADB and low-rate package maintenance, but it is
USB 2.0 on this hardware and is not the target data plane for performance-heavy
services.

Current stability status:

```text
wlan0 can associate, get DHCP, and reach the internet.
Sustained package-download traffic has triggered a kernel Oops once in:
  skb_release_data -> __kfree_skb -> tcp_recvmsg -> inet6_recvmsg
The same pstore window contained repeated WLAN/MDDP messages:
  mddpw_drv_get_mddp_feature before MD ready
  qmLogDropFallBehind
```

Treat Wi-Fi as functional but not yet production-qualified until repeated
high-throughput IPv4/IPv6 tests pass without pstore crashes.

Run manually from Ubuntu:

```bash
adb.exe -s ubuntu012345678 shell \
  'WIFI_POWER_WAIT_SECS=420 /bin/sh /usr/local/libexec/kexec/wifi_bringup.sh'
```

Check progress:

```sh
cat /var/lib/kexec-runtime/wifi-status
tail -220 /var/log/kexec-runtime/wifi-bringup.log
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

After `wlan0` exists, Ubuntu uses the normal
`kexec-wpa-supplicant.service` plus `systemd-networkd` path. The installed
systemd network/link files set DHCP for `wlan0` and pin a stable MAC address
before association. Create the AP configuration once:

```sh
wpa_passphrase "SSID" "passphrase" > /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
chmod 600 /etc/wpa_supplicant/wpa_supplicant-wlan0.conf
systemctl restart kexec-wpa-supplicant.service systemd-networkd.service
```

`/etc/systemd/network/25-kexec-wlan0.network` enables DHCP for `wlan0`.
`systemd-resolved.service` is enabled and `/etc/resolv.conf` points to the
resolved stub, so DNS servers learned from DHCP are used automatically.
Check connection state with:

```sh
networkctl status wlan0
ip addr show wlan0
resolvectl status 2>/dev/null || cat /etc/resolv.conf
```

For stability testing, reduce variables before running high-throughput service
loads:

```sh
sysctl -w net.ipv6.conf.all.disable_ipv6=1
sysctl -w net.ipv6.conf.default.disable_ipv6=1
sysctl -w net.ipv6.conf.wlan0.disable_ipv6=1
ip link set wlan0 mtu 1400
apt-get -o Acquire::ForceIPv4=true update
```

If `ethtool` is available, test with offload paths disabled:

```sh
ethtool -K wlan0 gro off gso off tso off rx off tx off 2>/dev/null || true
```

Run stress tests one variable at a time and collect pstore immediately after any
return to stock Android.

## systemd Boot

The repository default is systemd as PID 1. The Ubuntu rootfs enters
`multi-user.target` and starts split kexec units for time keeping, watchdog
feeding, panic timeout, vendor partition mounts, USB ADB, Wi-Fi hardware
bring-up, and `kexec-wpa-supplicant` plus `systemd-networkd`
networking path.

The active Ubuntu boot path is intentionally single-path:

```text
boot_ubuntu_rootfs -> /sbin/init -> multi-user.target
```

The old phase-A PID 1 and `kexec-phase-a.service` have been removed. Split
systemd units execute `/usr/local/libexec/kexec/bin/kexec-*`. Use stock rescue
if Ubuntu systemd does not come up.

## Layout

```text
src/                        static ramdisk bootstrap and direct-root helper
scripts/host/               host-side build/install/boot/test helpers
scripts/device/bin/         per-service Ubuntu kexec helper entrypoints
scripts/device/lib/kexec/   shared helper libraries for the kexec units
scripts/device/             helpers installed into /usr/local/libexec/kexec
scripts/lib/                shared host-side shell configuration
patches/                    source patches kept outside repo-managed source trees
prebuilt/                   first-stage init, Ubuntu adbd, stock rescue tools
sources/                    AOSP/kernel/tool source trees
work/                       generated local state: logs, output, vendor, temp
old/                        archived boot images, old probes, experiments
```

## Remaining Work

```text
validate repeated systemd split-unit Ubuntu boots
add and validate production wlan0 AP credentials
qualify wlan0 as the production Wi-Fi 6 data plane under sustained TCP load
identify or disable the unstable WLAN/MDDP/skb path seen during package downloads
broaden Docker validation beyond hello-world to long-running bridge/NAT workloads
```
