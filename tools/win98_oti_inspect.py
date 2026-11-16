#!/usr/bin/env python3
"""Inspect the Win98 SE El Torito boot image and FAT12 root (read-only)."""
import struct
import sys

ISO = "media/win98se.iso"


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def iso_read(f, lba, count):
    f.seek(lba * 2048)
    return f.read(count * 2048)


def fat_name(entry):
    base = entry[0:8].decode("ascii", "replace").rstrip(" ")
    ext = entry[8:11].decode("ascii", "replace").rstrip(" ")
    return base + ("." + ext if ext else "")


def fat_entries(fat, root, cluster_size=1):
    entries = []
    for off in range(0, len(root), 32):
        e = root[off:off + 32]
        if len(e) < 32 or e[0] == 0:
            break
        if e[0] == 0xE5:
            continue
        attr = e[11]
        first = u16(e, 26)
        size = u32(e, 28)
        entries.append((fat_name(e), attr, first, size))
    return entries


def read_chain(fat, image, first, size):
    out = bytearray()
    cluster = first
    seen = set()
    while cluster and cluster < 0xFF8 and cluster not in seen:
        seen.add(cluster)
        off = (cluster + 31) * 512
        out += image[off:off + 512]
        nxt = fat[cluster]
        cluster = nxt
        if len(out) >= size:
            break
    return bytes(out[:size])


with open(ISO, "rb") as f:
    pvd = iso_read(f, 16, 1)
    print("PVD id", pvd[1:6], "vol", pvd[40:72].decode("ascii", "replace").rstrip())
    print("root record", pvd[156:190].hex())
    root_lba = u32(pvd, 156 + 2)
    root_size = u32(pvd, 156 + 10)
    print("root lba/size", root_lba, root_size)

    for lba in range(17, 32):
        vd = iso_read(f, lba, 1)
        if vd[1:6] in (b"CD001", b"CD00X"):
            print("VD", lba, "type", vd[0], "id", vd[1:6])
            if vd[0] == 0:
                cat_lba = u32(vd, 0x47)
                print("boot catalog lba", cat_lba)
                cat = iso_read(f, cat_lba, 1)
                print("catalog validation", cat[0:32].hex())
                for i in range(1, 8):
                    e = cat[i * 32:i * 32 + 32]
                    if len(e) < 32 or e[0] not in (0x88, 0x00):
                        print("catalog entry", i, e.hex())
                        continue
                    media = e[1]
                    sectors = u16(e, 6)
                    rba = u32(e, 8)
                    print(
                        "catalog entry", i, "boot=%02X media=%d sectors=%d rba=%d"
                        % (e[0], media, sectors, rba)
                    )

    # User-guided extraction.
    boot_lba = 21
    f.seek(boot_lba * 2048)
    boot = f.read(1474560)
    print("boot image", len(boot), "sig", boot[510:512].hex())
    bps = u16(boot, 11)
    spc = boot[13]
    reserved = u16(boot, 14)
    fats = boot[16]
    root_entries = u16(boot, 17)
    total_sectors = u16(boot, 19)
    fat_sectors = u16(boot, 22)
    print(
        "BPB bps=%d spc=%d reserved=%d fats=%d root_entries=%d total=%d fat_sectors=%d"
        % (bps, spc, reserved, fats, root_entries, total_sectors, fat_sectors)
    )
    fat_off = reserved * bps
    root_off = fat_off + fats * fat_sectors * bps
    data_off = root_off + root_entries * 32
    fat_raw = boot[fat_off:fat_off + fat_sectors * bps]
    fat = []
    for i in range(0, len(fat_raw), 3):
        if i + 2 >= len(fat_raw):
            break
        a, b, c = fat_raw[i], fat_raw[i + 1], fat_raw[i + 2]
        fat.append(a | ((b & 0x0F) << 8))
        fat.append((b >> 4) | (c << 4))
    root = boot[root_off:data_off]
    entries = fat_entries(fat, root)
    for name, attr, first, size in entries:
        print("%-14s attr=%02X cluster=%d size=%d" % (name, attr, first, size))
    for name, attr, first, size in entries:
        if name in ("CONFIG.SYS", "OAKCDROM.SYS", "OAKCDROM.SY_", "HIMEM.SYS", "EMM386.EXE"):
            data = read_chain(fat, boot, first, size)
            out = "media/dump_" + name
            with open(out, "wb") as g:
                g.write(data)
            print("wrote", out, len(data), "head", data[:32].hex())
