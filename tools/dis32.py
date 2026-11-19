"""Disassemble 32-bit code from a win98_run checkpoint: dis32.py SNAP LINEAR LEN (hex)."""
import os, subprocess, sys
import capstone
snap, addr, n = sys.argv[1], int(sys.argv[2], 16), int(sys.argv[3], 16)
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
res = subprocess.run([os.path.join(root, "tools", "bin", "lune.exe"), "run", "tools/win98_run.lua", "--load", snap, "--dump", hex(addr), "--dump-len", hex(n)], capture_output=True, text=True, cwd=root)
data = bytearray()
for line in res.stdout.splitlines():
    if ":" in line and not line.startswith("loaded"):
        data += bytes(int(x, 16) for x in line.split(":")[1].split())
md = capstone.Cs(capstone.CS_ARCH_X86, capstone.CS_MODE_32)
for i in md.disasm(bytes(data), addr):
    print("%08X" % i.address, i.bytes.hex(" "), i.mnemonic, i.op_str)
