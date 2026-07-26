# Xaga Kexec Ubuntu

Boot Ubuntu directly on Xiaomi xaga through a stock-Android kexec handoff.
The project builds the kernel and initrd, installs the direct-root runtime on a
dedicated `linux` partition, and provides guarded boot and unattended test
flows.

## One public entry point

Use only the repository-root command:

```bash
./xaga help
```

The normal workflow is:

```bash
./xaga doctor
./xaga prepare
./xaga build all
./xaga status
./xaga install --serial <stock-adb-serial>
./xaga boot --serial <stock-adb-serial>
```

`doctor` is read-only. `prepare` explicitly uses the network and writes locked
source checkouts. `build all` builds kexec-tools, the patched AOSP prebuilts and
the GKI kernel. It does not create a rootfs unless an ISO is supplied.

Build the locked Ubuntu 26.04 minimal rootfs from a local official ISO:

```bash
sudo --preserve-env=ADB \
  ./xaga build rootfs \
    --iso /absolute/path/to/ubuntu-26.04-live-server-arm64.iso
```

Replacing the installed Ubuntu remains deliberately explicit:

```bash
./xaga install \
  --serial <stock-adb-serial> \
  --rootfs work/output/ubuntu-26.04-server-minimal-arm64.tar.gz \
  --sha256 <trusted-sha256> \
  --confirm-wipe-rootfs
```

## Device operations

Run one guarded boot:

```bash
./xaga boot --serial <stock-adb-serial> --panic-after 600
```

Run repeated unattended tests:

```bash
./xaga test --unattended \
  --serial <stock-adb-serial> \
  --rounds 10 \
  --panic-after 600
```

Back up the current Ubuntu while the phone is in rooted stock Android:

```bash
./xaga backup \
  --serial <stock-adb-serial> \
  --output-dir /safe/backup/location/ubuntu_$(date +%Y%m%d)
```

The backup command refuses a mounted Linux partition and creates an offline
tar+zstd archive with numeric owners, ACLs, xattrs, capabilities, device nodes
and sparse files preserved.

Partitioning is xaga-only and destructive. Always inspect first:

```bash
./xaga partition --plan
```

Writing the GPT and formatting userdata requires the explicit paired
confirmation:

```bash
./xaga partition --apply --confirm-destroy-userdata
```

## Scope

The supported baseline is:

```text
rooted stock xaga
  -> stock-side kexec launcher
  -> direct-root Ubuntu
  -> systemd
  -> bundled USB adbd
```

The official minimal rootfs does not include personal Wi-Fi credentials, SSH
keys, user data or the current phone's optional software.

For the complete clean-machine procedure, see
[Developer reproduction](docs/REPRODUCING.md). For call graphs, individual
implementation scripts, runtime layout and debugging, see
[Internal architecture](docs/INTERNALS.md).

Scripts under `scripts/` are internal implementation units. They remain
separately testable, but they are not the public command-line interface.
