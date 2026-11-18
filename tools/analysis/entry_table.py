import struct
d = open(r'media/win30/staged/KERNEL.EXE', 'rb').read()
ne = struct.unpack('<I', d[0x3C:0x40])[0]
def u8(o): return d[ne+o]
def u16(o): return struct.unpack('<H', d[ne+o:ne+o+2])[0]
enttab, cbenttab = u16(4), u16(6)
print('etab', enttab, 'len', cbenttab)
p = 0
ordinal = 0
while p < cbenttab:
    count = u8(p)
    if count == 0:
        print('terminator at', p); break
    segidx = u8(p+1)
    p += 2
    kind = 'movable' if segidx == 0xFF else ('const' if segidx == 0xFE else 'fixed seg%d' % segidx)
    print('bundle: %d entries, %s' % (count, kind))
    for i in range(count):
        ordinal += 1
        if ordinal in (44, 45, 46, 72, 121):
            if segidx == 0xFF:
                flags, skip, seg, off = u8(p), u16(p+1), u8(p+3), u16(p+4)
                print('  ord%d: MOVABLE flags=%#x seg=%d off=%#x' % (ordinal, flags, seg, off))
            else:
                flags, off = u8(p), u16(p+1)
                print('  ord%d: FIXED flags=%#x seg=%d off=%#x' % (ordinal, flags, segidx, off))
        if segidx == 0xFF: p += 6
        else: p += 3
print('total ordinals:', ordinal)
