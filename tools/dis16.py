"""Disassemble 16-bit code from a win98_run checkpoint: dis16.py SNAP SEG START LEN (hex)."""
import os
import subprocess
import sys

import capstone

snap, seg, start, n = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16), int(sys.argv[4], 16)
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
lune = os.path.join(root, "tools", "bin", "lune.exe")
addr = seg * 16 + start
res = subprocess.run(
    [lune, "run", "tools/win98_run.lua", "--load", snap, "--dump", hex(addr), "--dump-len", hex(n)],
    capture_output=True,
    text=True,
    cwd=root,
)
data = bytearray()
for line in res.stdout.splitlines():
    if ":" in line and not line.startswith("loaded"):
        data += bytes(int(x, 16) for x in line.split(":")[1].split())
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_16)
for i in md.disasm(bytes(data), start):
    print("%04X" % i.address, i.bytes.hex(" "), i.mnemonic, i.op_str)
