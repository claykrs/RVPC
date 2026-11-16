#!/usr/bin/env python3
"""Disassemble the live 0B5B overlay (file offset base 0x8ED0)."""
import struct
from capstone import Cs, CS_ARCH_X86, CS_MODE_16

data = open("media/dump_OAKCDROM.SYS", "rb").read()
BASE_FILE = 0x8ED0
SEG = 0x0B5B
md = Cs(CS_ARCH_X86, CS_MODE_16)


def dump(start, end):
    print("\n=== %04X:%04X-%04X (file %05X) ===" % (SEG, start, end, BASE_FILE + start))
    code = data[BASE_FILE + start:BASE_FILE + end]
    for insn in md.disasm(code, SEG * 16 + start):
        ip = insn.address - SEG * 16
        raw = " ".join("%02X" % b for b in insn.bytes)
        print("%04X: %-22s %-8s %s" % (ip, raw, insn.mnemonic, insn.op_str))


dump(0x0400, 0x0540)
dump(0x0540, 0x05B0)
