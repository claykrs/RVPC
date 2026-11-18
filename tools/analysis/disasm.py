import sys
from capstone import Cs, CS_ARCH_X86, CS_MODE_16

data = open("tools/memdump.bin", "rb").read()
seg = int(sys.argv[1], 16)
start = int(sys.argv[2], 16)
end = int(sys.argv[3], 16)
base = (seg << 4) & 0xFFFFF
md = Cs(CS_ARCH_X86, CS_MODE_16)
for ins in md.disasm(data[base + start:base + end], start):
    print("%04X:%04X  %-20s %s %s" % (seg, ins.address, ins.bytes.hex(), ins.mnemonic, ins.op_str))
