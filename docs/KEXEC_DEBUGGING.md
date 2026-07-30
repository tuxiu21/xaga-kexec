# Kexec Handoff Debugging

This is the durable runbook for classifying xaga stock-to-Ubuntu kexec
failures. It explains what the persistent ARM64 markers mean, how to preserve
evidence, and when a failure belongs to the old-kernel handoff rather than the
new Ubuntu kernel.

For the 2026-07-29 network panic investigation, see
[`incidents/2026-07-29-skb-panic.md`](incidents/2026-07-29-skb-panic.md).

## Do not diagnose from `Bye!` alone

`Bye!` is the last normal console message printed by the old kernel before it
calls `cpu_soft_restart()`. It does not prove that `machine_kexec()` stopped or
that relocation failed: execution continues in assembly with the MMU and
caches being disabled, so ordinary console output is no longer a reliable
observer.

Use the persistent marker and the resulting device identity instead:

- marker below `0x50`: investigate the old-kernel reset/relocation path;
- marker `0x50` or `0x51`: the new kernel was entered;
- marker `0x51` plus reachable Ubuntu userspace: the handoff succeeded;
- marker `0x50`/`0x51` plus a later panic: investigate the new kernel, not
  `machine_kexec()`.

Adding markers improves observability. It is not itself a fix for an
intermittent handoff failure.

## Persistent marker map

The trace uses one reserved 16-byte slot. Every new stage overwrites the prior
stage, so pstore contains the latest stage that was reached rather than a
history of every stage.

| Marker | Boundary |
| --- | --- |
| `0x10` | before `local_daif_mask()` |
| `0x11` | after `local_daif_mask()` |
| `0x20` | `__cpu_soft_restart` entry |
| `0x21` | before disabling the MMU and caches |
| `0x22` | after disabling the MMU and caches |
| `0x23` | before branching to relocation code |
| `0x30` | `arm64_relocate_new_kernel` entry |
| `0x31` | relocation complete |
| `0x32` | before branching to purgatory |
| `0x40` | purgatory entry |
| `0x41` | purgatory verification returned |
| `0x42` | before branching to the new kernel |
| `0x50` | new-kernel `primary_entry` |
| `0x51` | new kernel preserved its boot arguments |

The implementation is in the maintained stock kernel worktree:

```text
sources/android-kernel/common-stock/arch/arm64/kernel/machine_kexec.c
sources/android-kernel/common-stock/arch/arm64/kernel/cpu-reset.S
sources/android-kernel/common-stock/arch/arm64/kernel/relocate_kernel.S
sources/android-kernel/common-stock/arch/arm64/kernel/head.S
sources/android-kernel/common-stock/arch/arm64/include/asm/xaga_kexec_trace.h
```

The host-side decoder is:

```text
scripts/host/kexec_adb_until_ubuntu.sh:print_kexec_trace
```

Read pmsg with `adb exec-out`, not an ordinary interactive `adb shell`, so the
marker bytes are preserved exactly.

## Classification decision

```text
last marker < 0x50
    old-kernel handoff is still in scope
    inspect machine_kexec, CPU reset, MMU/cache, relocation, or purgatory

last marker is 0x50 or 0x51
    the new kernel was entered
    inspect new-kernel early boot, userspace, or a later runtime panic

last marker is 0x51 and Ubuntu systemd is reachable
    handoff succeeded
    do not attribute a later crash to machine_kexec
```

Also record both identities. A dropped SSH connection or disappearing stock
transport is not sufficient:

1. verify the Ubuntu identity disappears when reboot was requested;
2. verify the stock ADB serial appears;
3. verify `sys.boot_completed=1`;
4. read stock `ro.boot.bootreason` and `sys.boot.reason`.

## Evidence collection after a failure

Do not trigger another kexec after an unexpected return to stock. Ramoops uses
fixed names and the next boot cycle can overwrite the only useful evidence.

Collect at least:

- `ro.boot.bootreason`;
- `sys.boot.reason`;
- `/sys/fs/pstore/console-ramoops-0`;
- `/sys/fs/pstore/pmsg-ramoops-0`;
- attempt ID and host log directory;
- kernel, initrd, DTB and payload hashes;
- stock and Ubuntu serial/identity observations.

### Through stock USB ADB

```bash
ADB=/mnt/c/Users/Rin/AppData/Local/Android/Sdk/platform-tools/adb.exe
OUT=/home/in/work/kernels/work/logs/failure-YYYYMMDD-HHMMSS
mkdir -p "$OUT"

timeout 5 "$ADB" -s U89PBYJBFQKNLZEY shell getprop ro.boot.bootreason \
  > "$OUT/bootreason.txt"
timeout 5 "$ADB" -s U89PBYJBFQKNLZEY shell getprop sys.boot.reason \
  > "$OUT/sys-boot-reason.txt"
timeout 10 "$ADB" -s U89PBYJBFQKNLZEY exec-out su -c \
  'cat /sys/fs/pstore/console-ramoops-0' > "$OUT/console-ramoops-0"
timeout 10 "$ADB" -s U89PBYJBFQKNLZEY exec-out su -c \
  'cat /sys/fs/pstore/pmsg-ramoops-0' > "$OUT/pmsg-ramoops-0"
```

Every Windows ADB invocation from WSL needs its own short timeout. A stale
Windows/WSL transport has previously hung while reporting:

```text
UtilAcceptVsock:273: accept4 failed 110
```

That host failure can make a normal stock reboot look several minutes long.

### Through stock reverse SSH

```bash
stock_ssh() {
  ssh -J usjgw \
    -i /home/in/keys/xaga \
    -o IdentitiesOnly=yes \
    -o HostKeyAlias=xaga-stock-via-usjgw \
    -p 22023 root@127.0.0.1 "$@"
}

OUT=/home/in/work/kernels/work/logs/failure-YYYYMMDD-HHMMSS
mkdir -p "$OUT"

stock_ssh 'getprop ro.boot.bootreason; getprop sys.boot.reason' \
  > "$OUT/bootreason.txt"
stock_ssh 'cat /sys/fs/pstore/console-ramoops-0' \
  > "$OUT/console-ramoops-0"
stock_ssh 'cat /sys/fs/pstore/pmsg-ramoops-0' \
  > "$OUT/pmsg-ramoops-0"
```

Stock reverse SSH is the VPS loopback port `22023`; Ubuntu uses `22024`.
Authentication and device identity must be checked. A listening TCP port alone
is not evidence that the expected operating system is healthy.

## Repeated-test policy

Use bounded, explicit rounds. Each round must:

1. start from verified stock Android;
2. record payload hashes and an attempt ID;
3. trigger kexec exactly once;
4. wait for and verify Ubuntu identity and systemd;
5. hold the required runtime workload;
6. return to verified stock before the next round;
7. archive pstore immediately on any failure and stop.

Never automatically kexec again after a failure. That can destroy the marker
and panic evidence required to distinguish the handoff from a new-kernel
failure.

The current `./xaga test --unattended` retries failures and exits after its
first success. It is not a fixed-count success-cycle test. Do not use it to
claim that five or ten independent successful cycles were completed until a
dedicated fixed-round mode exists.

## Product-line safety

The marker-capable stock kernel and Ubuntu runtime kernel are different
products:

```text
sources/android-kernel/common-stock
sources/android-kernel/common-ubuntu
```

Keep their Git branches, worktrees, configurations, outputs and manifests
separate. In particular, do not enable Ubuntu/Docker configuration in a
stock-facing Image and do not flash an Ubuntu/Docker Image into stock boot.

## When to resume `Bye!` investigation

The 2026-07-29 controlled runs all reached `0x51`, so they did not reproduce an
old-kernel handoff failure. Keep the marker instrumentation installed and
resume active investigation only when a new failed run preserves one of these:

- marker below `0x50`;
- no marker despite a verified marker-capable stock kernel;
- reproducible loss before either the stock or Ubuntu identity becomes
  reachable.

At that point, preserve the failed run before changing code. The last marker
selects the assembly boundary to instrument next.
