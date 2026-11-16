#!/usr/bin/env python3
"""Disassemble the resident OTI probe at 028E:6C48 and dump table 636C."""
import struct
from capstone import Cs, CS_ARCH_X86, CS_MODE_16

data = open("media/dump_OAKCDROM.SYS", "rb").read()
SEG = 0x028E
FILE_DELTA = 0x200  # file offset = resident offset + 0x200
md = Cs(CS_ARCH_X86, CS_MODE_16)


def dump(start, end):
    print("\n=== %04X:%04X-%04X (file %05X) ===" % (SEG, start, end, start + FILE_DELTA))
    code = data[start + FILE_DELTA:end + FILE_DELTA]
    for insn in md.disasm(code, SEG * 16 + start):
        ip = insn.address - SEG * 16
        raw = " ".join("%02X" % b for b in insn.bytes)
        print("%04X: %-24s %-8s %s" % (ip, raw, insn.mnemonic, insn.op_str))


print("table at 028E:636C (file 0x656C):")
tbl = data[0x656C:0x656C + 0x100]
for row in range(0, len(tbl), 16):
    print("%04X:" % (0x636C + row), " ".join("%02X" % b for b in tbl[row:row + 16]))

dump(0x6C40, 0x6D50)
dump(0x6D50, 0x6E40)
dump(0x6E40, 0x6F30)
