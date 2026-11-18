import struct, sys

path = sys.argv[1] if len(sys.argv) > 1 else "media/win30/staged/KERNEL.EXE"
d = open(path, "rb").read()


def u8(o): return d[o]
def u16(o): return struct.unpack_from("<H", d, o)[0]
def u32(o): return struct.unpack_from("<I", d, o)[0]

assert d[:2] == b"MZ"
ne = u32(0x3C)
assert d[ne:ne+2] == b"NE", d[ne:ne+2]
cseg = u16(ne + 0x1C)
segtab = ne + u16(ne + 0x22)
restab = ne + u16(ne + 0x24)
shift = u16(ne + 0x32)

pat = bytes.fromhex("9affff00008bf4")
for i in range(cseg):
    e = segtab + i * 8
    sector = u16(e)
    length = u16(e + 2)
    flags = u16(e + 4)
    off = sector << shift
    seg = d[off:off + length]
    print(f"seg {i+1}: file {off:#x} len {length:#x} flags {flags:#06x} shift {shift} hdr {d[off:off+2].hex()}")
    idx = seg.find(pat)
    if idx >= 0:
        print(f"   found lcall placeholder at seg offset {idx:#x}")
        if flags & 0x100:
            ro = off + length
            count = u16(ro)
            print(f"   relocations: {count}")
            for r in range(count):
                rec = ro + 2 + r * 8
                at, rt, fo, t1, t2 = struct.unpack_from("<BBHHH", d, rec)
                if idx - 8 <= fo <= idx + 8:
                    print(f"     rec {r}: addrType={at:#x} type={rt:#x} off={fo:#x} t1={t1:#x} t2={t2:#x}")
        else:
            print("   no reloc info (flags & 0x100 clear)")
