#!/usr/bin/env python3
import argparse
import os
import struct
import subprocess
import sys


GEOMETRY_MAGIC = 0x616C4467
HEADER_MAGIC = 0x414C5030
GEOMETRY_OFFSETS = (4096, 8192)
SECTOR_SIZE = 512


def read_at(path, offset, size):
    with open(path, "rb", buffering=0) as f:
        f.seek(offset)
        return f.read(size)


def cstr(raw):
    return raw.split(b"\0", 1)[0].decode("ascii", "ignore")


def find_super_device():
    ensure_block_nodes()

    by_partname = find_partition_by_name("super")
    if by_partname:
        return by_partname

    candidates = [
        "/dev/block/by-name/super",
        "/dev/block/sdc77",
        "/dev/block/sdc81",
        "/dev/block/sda",
        "/dev/block/sdb",
        "/dev/block/sdc",
    ]
    for path in candidates:
        if os.path.exists(path):
            return path
    raise RuntimeError("super block device not found")


def ensure_block_nodes():
    os.makedirs("/dev/block", exist_ok=True)
    sys_block = "/sys/block"
    if not os.path.isdir(sys_block):
        return

    for ent in os.listdir(sys_block):
        make_block_node_from_sys(os.path.join(sys_block, ent))
        base = os.path.join(sys_block, ent)
        if not os.path.isdir(base):
            continue
        for child in os.listdir(base):
            if child.startswith(ent):
                make_block_node_from_sys(os.path.join(base, child))


def make_block_node_from_sys(sys_path):
    dev_path = os.path.join(sys_path, "dev")
    if not os.path.exists(dev_path):
        return
    name = os.path.basename(sys_path)
    node = f"/dev/block/{name}"
    if os.path.exists(node):
        return
    with open(dev_path) as f:
        maj, minor = [int(x) for x in f.read().strip().split(":", 1)]
    os.mknod(node, 0o600 | stat_block(), os.makedev(maj, minor))


def find_partition_by_name(partname):
    sys_block = "/sys/block"
    if not os.path.isdir(sys_block):
        return None
    for disk in os.listdir(sys_block):
        base = os.path.join(sys_block, disk)
        if not os.path.isdir(base):
            continue
        for child in os.listdir(base):
            uevent = os.path.join(base, child, "uevent")
            if not os.path.exists(uevent):
                continue
            with open(uevent) as f:
                vals = dict(
                    line.strip().split("=", 1)
                    for line in f
                    if "=" in line
                )
            if vals.get("PARTNAME") == partname:
                devname = vals.get("DEVNAME", child)
                node = f"/dev/block/{devname}"
                if not os.path.exists(node):
                    make_block_node_from_sys(os.path.join(base, child))
                return node
    return None


def parse_geometry(superdev):
    for off in GEOMETRY_OFFSETS:
        data = read_at(superdev, off, 4096)
        if len(data) < 52:
            continue
        magic, struct_size = struct.unpack_from("<II", data, 0)
        if magic == GEOMETRY_MAGIC and struct_size >= 52:
            metadata_max_size, metadata_slot_count, logical_block_size = struct.unpack_from("<III", data, 40)
            return {
                "offset": off,
                "metadata_max_size": metadata_max_size,
                "metadata_slot_count": metadata_slot_count,
                "logical_block_size": logical_block_size,
            }
    raise RuntimeError("liblp geometry not found")


def table_desc(header, offset):
    table_offset, num_entries, entry_size = struct.unpack_from("<III", header, offset)
    return table_offset, num_entries, entry_size


def parse_metadata(superdev, geom, slot):
    # liblp keeps two geometry blocks first, then metadata slots.
    metadata_base = 4096 + 4096 + 4096
    metadata_offset = metadata_base + slot * geom["metadata_max_size"]
    header = read_at(superdev, metadata_offset, 4096)
    if len(header) < 128:
        raise RuntimeError("metadata header too short")
    magic = struct.unpack_from("<I", header, 0)[0]
    if magic != HEADER_MAGIC:
        # Some images omit the reserved first block before geometry.
        metadata_base = 4096 + 4096
        metadata_offset = metadata_base + slot * geom["metadata_max_size"]
        header = read_at(superdev, metadata_offset, 4096)
        magic = struct.unpack_from("<I", header, 0)[0]
        if magic != HEADER_MAGIC:
            raise RuntimeError("liblp metadata header not found")

    header_size = struct.unpack_from("<I", header, 8)[0]
    tables_size = struct.unpack_from("<I", header, 44)[0]
    tables = read_at(superdev, metadata_offset + header_size, tables_size)

    part_desc = table_desc(header, 80)
    extent_desc = table_desc(header, 92)
    block_desc = table_desc(header, 116)

    partitions = {}
    poff, pnum, psz = part_desc
    for i in range(pnum):
        entry = tables[poff + i * psz: poff + (i + 1) * psz]
        if len(entry) < 52:
            continue
        name = cstr(entry[:36])
        attrs, first_extent, num_extents, group = struct.unpack_from("<IIII", entry, 36)
        partitions[name] = {
            "name": name,
            "attrs": attrs,
            "first_extent": first_extent,
            "num_extents": num_extents,
            "group": group,
        }

    extents = []
    eoff, enum, esz = extent_desc
    for i in range(enum):
        entry = tables[eoff + i * esz: eoff + (i + 1) * esz]
        if len(entry) < 24:
            continue
        num_sectors, target_type, target_data, target_source = struct.unpack_from("<QIQL", entry, 0)
        extents.append({
            "num_sectors": num_sectors,
            "target_type": target_type,
            "target_data": target_data,
            "target_source": target_source,
        })

    block_devices = []
    boff, bnum, bsz = block_desc
    for i in range(bnum):
        entry = tables[boff + i * bsz: boff + (i + 1) * bsz]
        if len(entry) < 64:
            continue
        first_logical_sector = struct.unpack_from("<Q", entry, 0)[0]
        size = struct.unpack_from("<Q", entry, 16)[0]
        name = cstr(entry[24:60])
        block_devices.append({
            "first_logical_sector": first_logical_sector,
            "size": size,
            "name": name,
        })

    return partitions, extents, block_devices


def run(cmd, input_text=None):
    return subprocess.run(
        cmd,
        input=input_text,
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        check=False,
    )


def dm_node_by_name(name):
    sys_block = "/sys/block"
    if not os.path.isdir(sys_block):
        return None
    for ent in os.listdir(sys_block):
        if not ent.startswith("dm-"):
            continue
        name_path = os.path.join(sys_block, ent, "dm", "name")
        try:
            with open(name_path) as f:
                if f.read().strip() != name:
                    continue
            dev_path = os.path.join(sys_block, ent, "dev")
            with open(dev_path) as f:
                maj, minor = [int(x) for x in f.read().strip().split(":", 1)]
            os.makedirs("/dev/block", exist_ok=True)
            os.makedirs("/dev/mapper", exist_ok=True)
            node = f"/dev/block/{ent}"
            if not os.path.exists(node):
                os.mknod(node, 0o600 | stat_block(), os.makedev(maj, minor))
            mapper = f"/dev/mapper/{name}"
            if not os.path.exists(mapper):
                try:
                    os.symlink(node, mapper)
                except FileExistsError:
                    pass
            return node
        except OSError:
            continue
    return None


def stat_block():
    import stat
    return stat.S_IFBLK


def create_dm(name, table):
    existing = dm_node_by_name(name)
    if existing:
        print(f"{name}: already mapped at {existing}")
        return existing

    proc = run(["dmsetup", "create", name], input_text=table)
    if proc.returncode != 0:
        proc = run(["/system/bin/dmctl", "create", name], input_text=table)
    if proc.returncode != 0:
        raise RuntimeError(f"failed to create {name}: {proc.stderr.strip() or proc.stdout.strip()}")

    node = dm_node_by_name(name)
    print(f"{name}: mapped at {node or '<unknown>'}")
    return node


def mount_path(name, node):
    target = None
    if name.startswith("vendor_dlkm"):
        target = "/vendor_dlkm"
    elif name.startswith("vendor"):
        target = "/vendor"
    if not target or not node:
        return
    os.makedirs(target, exist_ok=True)
    with open("/proc/mounts") as f:
        if any(f" {target} " in line for line in f):
            print(f"{target}: already mounted")
            return
    proc = run(["mount", "-t", "erofs", "-o", "ro", node, target])
    if proc.returncode != 0:
        proc = run(["mount", "-o", "ro", node, target])
    if proc.returncode != 0:
        raise RuntimeError(f"failed to mount {node} on {target}: {proc.stderr.strip() or proc.stdout.strip()}")
    print(f"{target}: mounted from {node}")


def build_table(partition, extents, block_devices, superdev):
    rows = []
    logical = 0
    for idx in range(partition["first_extent"], partition["first_extent"] + partition["num_extents"]):
        extent = extents[idx]
        if extent["target_type"] != 0:
            raise RuntimeError(f"{partition['name']}: unsupported extent target type {extent['target_type']}")
        source = extent["target_source"]
        physical = extent["target_data"]
        rows.append(f"{logical} {extent['num_sectors']} linear {superdev} {physical}")
        logical += extent["num_sectors"]
    return "\n".join(rows) + "\n"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--super", default=None)
    ap.add_argument("--slot", default="_a")
    ap.add_argument("--partition", action="append", default=[])
    ap.add_argument("--mount", action="store_true")
    args = ap.parse_args()

    superdev = args.super or find_super_device()
    slot = 0 if args.slot in ("_a", "a", "0") else 1
    geom = parse_geometry(superdev)
    partitions, extents, block_devices = parse_metadata(superdev, geom, slot)

    wanted = args.partition or [f"vendor{args.slot}", f"vendor_dlkm{args.slot}"]
    for name in wanted:
        if name not in partitions:
            raise RuntimeError(f"partition not found in super metadata: {name}")
        table = build_table(partitions[name], extents, block_devices, superdev)
        node = create_dm(name, table)
        if args.mount:
            mount_path(name, node)


if __name__ == "__main__":
    try:
        main()
    except Exception as exc:
        print(f"map_super_partitions.py: {exc}", file=sys.stderr)
        sys.exit(1)
