#!/usr/bin/env python3
"""Build media/win98se-ide-nohimem.iso: the IDE-only ISO with a boot image
CONFIG.SYS that does not load HIMEM.SYS or use DOS=HIGH/UMB.

This is a diagnostic media variant for isolating the Setup CAB-copy failure.
"""
import shutil
import struct

SRC = "media/win98se-ide.iso"
DST = "media/win98se-ide-nohimem.iso"
BOOT_LBA = 21
BOOT_BYTES = 2880 * 512

CONFIG = """[menu]\r
menuitem=SETUP_CD, Start Windows 98 Setup from CD-ROM.\r
menuitem=CD, Start computer with CD-ROM support.\r
menuitem=NOCD, Start computer without CD-ROM support.\r
menudefault=SETUP_CD,30\r
menucolor=7,0\r
\r
[SETUP_CD]\r
device=oakcdrom.sys /D:oemcd001\r
\r
[CD]\r
device=oakcdrom.sys /D:oemcd001\r
\r
[NOCD]\r
\r
[COMMON]\r
files=60\r
buffers=20\r
stacks=9,256\r
lastdrive=z\r
""".encode("ascii")


def u16(b, o):
    return struct.unpack_from("<H", b, o)[0]


def u32(b, o):
    return struct.unpack_from("<I", b, o)[0]


def find_config(img):
    bps = u16(img, 11)
    reserved = u16(img, 14)
    fats = img[16]
    root_entries = u16(img, 17)
    fat_sectors = u16(img, 22)
    root_off = (reserved + fats * fat_sectors) * bps
    data_off = root_off + root_entries * 32
    for off in range(root_off, root_off + root_entries * 32, 32):
        entry = img[off:off + 32]
        if entry[0] in (0, 0xE5):
            continue
        base = entry[0:8].decode("ascii", "replace").rstrip(" ")
        ext = entry[8:11].decode("ascii", "replace").rstrip(" ")
        if base + ("." + ext if ext else "") == "CONFIG.SYS":
            return off, u16(entry, 26), u32(entry, 28), data_off, bps
    raise SystemExit("CONFIG.SYS not found in boot image")


def main():
    shutil.copyfile(SRC, DST)
    iso = bytearray(open(DST, "rb").read())
    img = bytearray(iso[BOOT_LBA * 2048:BOOT_LBA * 2048 + BOOT_BYTES])
    root_off, cluster, size, data_off, bps = find_config(img)
    assert len(CONFIG) <= 512, len(CONFIG)
    off = data_off + (cluster - 2) * bps
    img[off:off + bps] = CONFIG + b"\0" * (bps - len(CONFIG))
    struct.pack_into("<I", img, root_off + 28, len(CONFIG))
    iso[BOOT_LBA * 2048:BOOT_LBA * 2048 + BOOT_BYTES] = img
    open(DST, "wb").write(iso)
    print("wrote %s (CONFIG.SYS %d bytes at cluster %d)" % (DST, len(CONFIG), cluster))


if __name__ == "__main__":
    main()
