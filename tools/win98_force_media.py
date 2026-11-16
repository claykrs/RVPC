#!/usr/bin/env python3
"""Copy the Win98 SE ISO and patch OAKCDROM.SYS switches in the El Torito
1.44 MiB boot image. Never modifies the source ISO.

Usage:
  python tools/win98_force_media.py media/win98se.iso media/win98se-force.iso "/S:1F0,14,1"
  python tools/win98_force_media.py --show media/win98se-force.iso
"""
import re
import shutil
import struct
import sys

BOOT_LBA = 21
BOOT_BYTES = 2880 * 512


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def fat12(img):
    bps = u16(img, 11)
    spc = img[13]
    reserved = u16(img, 14)
    fats = img[16]
    root_entries = u16(img, 17)
    fat_sectors = u16(img, 22)
    fat_off = reserved * bps
    root_off = fat_off + fats * fat_sectors * bps
    data_off = root_off + root_entries * 32
    raw = img[fat_off:fat_off + fat_sectors * bps]
    fat = []
    for i in range(0, len(raw), 3):
        if i + 2 >= len(raw):
            break
        a, b, c = raw[i], raw[i + 1], raw[i + 2]
        fat.append(a | ((b & 0x0F) << 8))
        fat.append((b >> 4) | (c << 4))
    return {
        "bps": bps,
        "spc": spc,
        "reserved": reserved,
        "fats": fats,
        "root_entries": root_entries,
        "fat_sectors": fat_sectors,
        "fat_off": fat_off,
        "root_off": root_off,
        "data_off": data_off,
        "fat": fat,
    }


def cluster_offset(info, cluster):
    return info["data_off"] + (cluster - 2) * info["bps"]


def chain(info, first):
    out = []
    n = first
    while 2 <= n < 0xFF8 and n not in out:
        out.append(n)
        n = info["fat"][n]
    return out


def read_file(img, info, first, size):
    out = bytearray()
    for cluster in chain(info, first):
        off = cluster_offset(info, cluster)
        out += img[off:off + info["bps"]]
    return bytes(out[:size])


def find_root_entry(img, info, name):
    name = name.upper()
    for off in range(info["root_off"], info["root_off"] + info["root_entries"] * 32, 32):
        entry = img[off:off + 32]
        if entry[0] in (0, 0xE5):
            continue
        base = entry[0:8].decode("ascii", "replace").rstrip(" ")
        ext = entry[8:11].decode("ascii", "replace").rstrip(" ")
        full = base + ("." + ext if ext else "")
        if full.upper() == name:
            return off, entry
    raise SystemExit("root entry not found: " + name)


def show(img):
    info = fat12(img)
    off, entry = find_root_entry(img, info, "CONFIG.SYS")
    size = u32(entry, 28)
    first = u16(entry, 26)
    data = read_file(img, info, first, size)
    print("CONFIG.SYS cluster=%d size=%d chain=%s" % (first, size, chain(info, first)))
    print(data.decode("ascii", "replace"))


def main():
    if len(sys.argv) >= 3 and sys.argv[1] == "--show":
        with open(sys.argv[2], "rb") as f:
            f.seek(BOOT_LBA * 2048)
            img = bytearray(f.read(BOOT_BYTES))
        show(img)
        return
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    src, dst, switches = sys.argv[1], sys.argv[2], sys.argv[3]
    if src == dst:
        raise SystemExit("refusing to overwrite the source ISO")
    shutil.copyfile(src, dst)
    with open(dst, "r+b") as f:
        f.seek(BOOT_LBA * 2048)
        img = bytearray(f.read(BOOT_BYTES))
        info = fat12(img)
        off, entry = find_root_entry(img, info, "CONFIG.SYS")
        size = u32(entry, 28)
        first = u16(entry, 26)
        clusters = chain(info, first)
        capacity = len(clusters) * info["bps"]
        text = read_file(img, info, first, size).decode("ascii")
        pattern = re.compile(r"(?im)^(device\s*=\s*oakcdrom\.sys)\s+/D:oemcd001\b")
        matches = pattern.findall(text)
        if not matches:
            raise SystemExit("no device=oakcdrom.sys /D:oemcd001 line found")
        new_text = pattern.sub(lambda m: "%s %s /D:oemcd001" % (m.group(1), switches), text)
        new_data = new_text.encode("ascii")
        if len(new_data) > capacity:
            raise SystemExit(
                "patched CONFIG.SYS %d bytes exceeds existing chain capacity %d"
                % (len(new_data), capacity)
            )
        print("patched lines:", len(matches))
        print("old size %d new size %d" % (size, len(new_data)))
        for line in new_text.splitlines():
            if "oakcdrom" in line.lower():
                print("  " + line)
        # Rewrite the file in its existing cluster chain.
        pos = 0
        for cluster in clusters:
            coff = cluster_offset(info, cluster)
            chunk = new_data[pos:pos + info["bps"]]
            img[coff:coff + info["bps"]] = chunk + bytes(info["bps"] - len(chunk))
            pos += info["bps"]
            if pos >= len(new_data):
                continue
        # Update the directory entry size.
        struct.pack_into("<I", img, off + 28, len(new_data))
        f.seek(BOOT_LBA * 2048)
        f.write(img)
    # Verify the copy.
    with open(dst, "rb") as f:
        f.seek(BOOT_LBA * 2048)
        check = bytearray(f.read(BOOT_BYTES))
    info = fat12(check)
    off, entry = find_root_entry(check, info, "CONFIG.SYS")
    data = read_file(check, info, u16(entry, 26), u32(entry, 28))
    assert b"/S:1F0,14,1" in data or switches.encode() in data
    print("verified CONFIG.SYS size", len(data))
    print(data.decode("ascii", "replace"))


if __name__ == "__main__":
    main()
