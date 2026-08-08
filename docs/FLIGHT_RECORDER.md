# Persistent Flight Recorder

The xaga Ubuntu runtime includes a bounded flight recorder for intermittent
failures that may present with different final symptoms. It preserves the
earliest high-signal event without logging every packet or every `skb`.

This is an evidence collector, not a fix. It does not identify a silent memory
writer until that corruption produces a detectable kernel or health event.

## Storage layers

The recorder uses three complementary stores:

| Store | Content | Persistence |
| --- | --- | --- |
| `console-ramoops` | kernel console, Oops and panic output | survives reset |
| `pmsg-ramoops` | selected `XFR1` boot, kernel and health events | survives reset |
| disk ring | five-minute health snapshots and all `XFR1` events | survives normal boots |

The disk ring is:

```text
/var/log/kexec-runtime/flight-recorder.log
/var/log/kexec-runtime/flight-recorder.log.1
...
/var/log/kexec-runtime/flight-recorder.log.8
```

The defaults retain up to eight 2 MiB rotated files. The persistent pmsg writer
has a hard 48 KiB per-boot budget. It does not emit periodic heartbeats to pmsg.
This keeps the writer below the end of the 64 KiB pmsg zone, whose final 16
bytes are reserved for the ARM64 kexec marker.

The budget state is under `/run/kexec-runtime/flight-recorder` and is preserved
across service restarts within one boot. It resets only with the boot.

## Event format

Every event is one bounded ASCII line:

```text
XFR1 seq=7 boot=BOOT-UUID mono=123.45 wall=2026-07-30T15:00:00Z level=warn event=kernel msg=...
```

Fields identify the boot, monotonic position, wall time, severity and event
class. Messages are single-line printable ASCII and are capped at 512 bytes.

The service emits:

- one persistent boot identity event with kernel and command-line hash;
- disk-only health snapshots every five minutes;
- the first occurrence of selected kernel Oops, memory-corruption, SMMU/IOMMU,
  DMA, lockup, firmware and `skb_release_data` signatures;
- the first watchdog health failure and the decision to stop feeding it;
- Wi-Fi bring-up success or failure;
- increases in failed systemd unit count.

Exact repeated kernel lines are de-duplicated within one boot. Full kernel
context remains in `console-ramoops`; the pmsg record is an index to the first
high-signal event, not a replacement for the console.

## Runtime

The installed unit is:

```text
kexec-flight-recorder.service
```

Useful checks in Ubuntu:

```bash
systemctl status kexec-flight-recorder.service
tail -100 /var/log/kexec-runtime/flight-recorder.log
cat /run/kexec-runtime/flight-recorder/pmsg-bytes
```

Other root services can add a bounded persistent event:

```bash
/usr/local/libexec/kexec/bin/kexec-flight-recorder \
  event warn component_name "short diagnostic message"
```

Configuration is preserved across runtime reinstalls:

```text
/etc/xaga-flight-recorder.conf
```

The repository defaults are in
`scripts/device/xaga-flight-recorder.conf`.

## Collection after a reset

Do not trigger another kexec before collection. From stock Android, preserve:

```text
/sys/fs/pstore/console-ramoops-0
/sys/fs/pstore/pmsg-ramoops-0
```

The current boot writes through `/dev/pmsg0`. Those bytes become the previous
boot's `pmsg-ramoops-0` only after the next kernel probes ramoops.

Decode a captured pmsg file on the host:

```bash
scripts/host/decode_flight_recorder.sh \
  work/logs/failure-YYYYMMDD-HHMMSS/pmsg-ramoops-0
```

`scripts/host/kexec_adb_until_ubuntu.sh` decodes pmsg automatically into:

```text
round_N_flight_recorder_pmsg.txt
```

After a return to stock, this file is always decoded from stock's current
`/sys/fs/pstore/pmsg-ramoops-0`. A possibly older copy that Ubuntu previously
archived on its filesystem is retained separately as
`round_N_pmsg_ubuntu_archive.bin`; it is never allowed to suppress collection
of the current pstore.

It also collects the disk ring as:

```text
round_N_flight_recorder_disk.txt
```

Stock-SSH recovery includes both the disk flight log and decoded `XFR1` records
in its failure directory.

## Interpretation

Treat the first event as a lead, not automatic root-cause proof:

```text
XFR1 IOMMU fault before unrelated Oops
    investigate a DMA writer or device reset state

XFR1 Wi-Fi firmware failure before skb corruption
    investigate the vendor Wi-Fi and GRO boundary

no XFR1 event, but complete console Oops
    the fatal path ran too quickly for the user-space monitor;
    use console evidence and add targeted kernel instrumentation
```

For per-`skb` producer tracing, add debug-only invariant checks in the Ubuntu
kernel as described in
[`incidents/2026-07-29-skb-panic.md`](incidents/2026-07-29-skb-panic.md).
The flight recorder supplies the common timeline around those targeted checks.
