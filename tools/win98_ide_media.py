#!/usr/bin/env python3
"""Create media/win98se-ide.iso with an IDE-only CONFIG.SYS.

The El Torito 1.44 MiB floppy image starts at ISO LBA 21 (catalog at LBA 20).
Both [SETUP_CD] and [CD] are reduced to HIMEM + OAKCDROM. All other sections,
AUTOEXEC.BAT and the original ISO are left untouched.
"""
import shutil
import struct
import sys

SRC = "media/win98se.iso"
DST = "media/win98se-ide.iso"
BOOT_LBA = 21
BOOT_BYTES = 2880 * 512


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def fat12(img):
    bps = u16(img, 11)
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
        "root_off": root_off,
        "root_entries": root_entries,
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


def patch_config(text):
    lines = text.replace("\r\n", "\n").split("\n")
    out = []
    section = ""
    target = {"[SETUP_CD]", "[CD]"}
    inserted = set()
    for line in lines:
        stripped = line.strip()
        if stripped.startswith("[") and stripped.endswith("]"):
            if section in target and out and out[-1] != "":
                out.append("")
            section = stripped.upper()
            out.append(line)
            if section in target:
                out.append("device=himem.sys /testmem:off")
                out.append("device=oakcdrom.sys /D:oemcd001")
                inserted.add(section)
            continue
        if section in target:
            # Drop the original section body; it is replaced on the header.
            continue
        out.append(line)
    if inserted != target:
        raise SystemExit("missing sections: %s" % (target - inserted))
    # Collapse the blank line that preceded each replacement's next section
    # only if it would create a duplicate blank.
    cleaned = []
    for line in out:
        if line == "" and cleaned and cleaned[-1] == "":
            continue
        cleaned.append(line)
    return ("\r\n".join(cleaned)).encode("ascii")


def main():
    if SRC == DST:
        raise SystemExit("refusing to overwrite the source ISO")
    shutil.copyfile(SRC, DST)
    with open(DST, "r+b") as f:
        f.seek(BOOT_LBA * 2048)
        img = bytearray(f.read(BOOT_BYTES))
        info = fat12(img)

        cfg_off, cfg_entry = find_root_entry(img, info, "CONFIG.SYS")
        cfg_first = u16(cfg_entry, 26)
        cfg_size = u32(cfg_entry, 28)
        cfg_clusters = chain(info, cfg_first)
        cfg_capacity = len(cfg_clusters) * info["bps"]
        old = read_file(img, info, cfg_first, cfg_size).decode("ascii")
        new = patch_config(old)
        if len(new) > cfg_capacity:
            raise SystemExit("patched CONFIG.SYS exceeds existing cluster chain")

        # Verify AUTOEXEC is untouched from the original before writing.
        ae_off, ae_entry = find_root_entry(img, info, "AUTOEXEC.BAT")
        ae_before = read_file(img, info, u16(ae_entry, 26), u32(ae_entry, 28))

        pos = 0
        for cluster in cfg_clusters:
            coff = cluster_offset(info, cluster)
            chunk = new[pos:pos + info["bps"]]
            img[coff:coff + info["bps"]] = chunk + bytes(info["bps"] - len(chunk))
            pos += info["bps"]
        struct.pack_into("<I", img, cfg_off + 28, len(new))
        f.seek(BOOT_LBA * 2048)
        f.write(img)

    # Re-read the copy and verify the resulting files.
    with open(DST, "rb") as f:
        f.seek(BOOT_LBA * 2048)
        check = bytearray(f.read(BOOT_BYTES))
    info = fat12(check)
    cfg_off, cfg_entry = find_root_entry(check, info, "CONFIG.SYS")
    cfg = read_file(check, info, u16(cfg_entry, 26), u32(cfg_entry, 28))
    ae_off, ae_entry = find_root_entry(check, info, "AUTOEXEC.BAT")
    ae = read_file(check, info, u16(ae_entry, 26), u32(ae_entry, 28))
    assert ae == ae_before, "AUTOEXEC.BAT changed"
    assert cfg.count(b"device=oakcdrom.sys /D:oemcd001") == 2
    assert cfg.count(b"device=himem.sys /testmem:off") >= 3  # two CD sections + NOCD
    for removed in (
        b"btdosm.sys",
        b"flashpt.sys",
        b"btcdrom.sys",
        b"aspi2dos.sys",
        b"aspi8dos.sys",
        b"aspi4dos.sys",
        b"aspi8u2.sys",
        b"aspicd.sys",
    ):
        assert removed not in cfg, "still present: " + removed.decode()
    print("boot image:", BOOT_BYTES, "bytes at ISO LBA", BOOT_LBA)
    print("CONFIG.SYS cluster chain:", cfg_clusters, "old", len(old), "new", len(cfg))
    print("AUTOEXEC.BAT unchanged:", len(ae), "bytes")
    print("---- patched CONFIG.SYS ----")
    print(cfg.decode("ascii"))
    print("---- AUTOEXEC.BAT (unchanged) ----")
    print(ae.decode("ascii"))


if __name__ == "__main__":
    main()
