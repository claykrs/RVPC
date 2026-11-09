"""Build execute_luau payloads that stage RVPC's Studio boot fixtures.

Emits JSON args files for the Studio MCP bridge:
  rvpc_fixtures_1.json .. n  (RvpcFixtures folder + BootBios/BootVga/BootIsoNN)
  rvpc_boot.json             (RvpcBoot machine factory)

Payload rule: the `code` string contains ZERO backslashes; all binary content
travels as base64 and is decoded by a pure-Luau decoder inside the payload.
"""
import base64
import json
import os

RVPC = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
OUT = os.path.dirname(os.path.abspath(__file__))
STUDIO = "1de8c2a0-c7c8-47e1-b7bc-f10038977f1d"

PRELUDE = '''local RS = game:GetService("ReplicatedStorage")
local SPS = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts")
local SSS = game:GetService("ServerScriptService")
local A2B = {}
do
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, #chars do
		A2B[string.sub(chars, i, i)] = i - 1
	end
end
local function b64(s)
	s = string.gsub(s, "=", "")
	local out = {}
	local acc, count = 0, 0
	for i = 1, #s do
		acc = acc * 64 + A2B[string.sub(s, i, i)]
		count += 1
		if count == 4 then
			out[#out + 1] = string.char(bit32.band(bit32.rshift(acc, 16), 255), bit32.band(bit32.rshift(acc, 8), 255), bit32.band(acc, 255))
			acc, count = 0, 0
		end
	end
	if count == 2 then
		out[#out + 1] = string.char(bit32.band(bit32.rshift(acc, 4), 255))
	elseif count == 3 then
		out[#out + 1] = string.char(bit32.band(bit32.rshift(acc, 10), 255), bit32.band(bit32.rshift(acc, 2), 255))
	end
	return table.concat(out)
end
local function upsert(parent, name, className)
	local child = parent:FindFirstChild(name)
	if not child or not child:IsA(className) then
		if child then child:Destroy() end
		child = Instance.new(className)
		child.Name = name
		child.Parent = parent
	end
	return child
end
local Q = string.char(34)
local RET = "return "'''

FACTORY = '''-- RvpcBoot -- builds the FreeDOS boot machine for the Studio shell.
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local function decode(s)
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	local lookup = {}
	for i = 1, #chars do
		lookup[string.sub(chars, i, i)] = i - 1
	end
	s = string.gsub(s, "=", "")
	local out = {}
	local acc, count = 0, 0
	for i = 1, #s do
		acc = acc * 64 + lookup[string.sub(s, i, i)]
		count += 1
		if count == 4 then
			out[#out + 1] = string.char(bit32.band(bit32.rshift(acc, 16), 255), bit32.band(bit32.rshift(acc, 8), 255), bit32.band(acc, 255))
			acc, count = 0, 0
		end
	end
	if count == 2 then
		out[#out + 1] = string.char(bit32.band(bit32.rshift(acc, 4), 255))
	elseif count == 3 then
		out[#out + 1] = string.char(bit32.band(bit32.rshift(acc, 10), 255), bit32.band(bit32.rshift(acc, 2), 255))
	end
	return table.concat(out)
end
local function collect(name, count)
	local parts = {}
	for i = 1, count do
		parts[i] = require(ReplicatedStorage.RvpcFixtures[name .. string.format("%02d", i)])
	end
	return decode(table.concat(parts))
end
return function(Rvpc, RvpcUi)
	local bios = collect("BootBios", {biosChunks})
	local vgaRom = collect("BootVga", {vgaChunks})
	local cdrom = collect("BootIso", {chunks})
	return Rvpc.Machine.new({
		Memory = Rvpc.Memory,
		Cpu = Rvpc.Cpu,
		Vga = Rvpc.Vga,
		Pic = Rvpc.Pic,
		Pit = Rvpc.Pit,
		Cmos = Rvpc.Cmos,
		FwCfg = Rvpc.FwCfg,
		Ide = Rvpc.Ide,
		Kbc = Rvpc.Kbc,
		Fpu = Rvpc.Fpu,
		Dma = Rvpc.Dma,
		Sb16 = Rvpc.Sb16,
		Fdc = Rvpc.Fdc,
		Ne2000 = Rvpc.Ne2000,
		Isp = Rvpc.Isp,
		Xms = Rvpc.Xms,
		Uart = Rvpc.Uart,
		Lpt = Rvpc.Lpt,
	}, {
		memorySize = 32 * 1024 * 1024,
		cpu = { cpuLevel = "486" },
		rom = buffer.fromstring(bios),
		vgaRom = buffer.fromstring(vgaRom),
		cdrom = buffer.fromstring(cdrom),
		-- Blank 32 MiB primary-master disk so the FreeDOS installer can
		-- partition; generated at boot, nothing embedded.
		hdd = buffer.create(32 * 1024 * 1024),
	})
end'''


def chunk_b64(data, size):
	enc = base64.b64encode(data).decode()
	return [enc[i:i + size] for i in range(0, len(enc), size)]


def payload(code):
	assert "\\" not in code, "payload contains a backslash"
	return {"code": code, "datamodel_type": "Edit", "studio_id": STUDIO}


def main():
	bios = open(os.path.join(RVPC, "roms", "bios-256k.bin"), "rb").read()
	vga = open(os.path.join(RVPC, "roms", "vgabios-stdvga.bin"), "rb").read()
	iso = open(os.path.join(RVPC, "media", "freedos-boot.iso"), "rb").read()
	iso_chunks = chunk_b64(iso, 131072)  # base64 chars per chunk
	n = len(iso_chunks)
	print(f"bios {len(bios)//1024}KB, vga {len(vga)//1024}KB, iso {len(iso)//1024}KB -> {n} chunks")

	# payload 1: fixtures folder + bios/vga chunks (Source caps at 200K chars)
	bios_chunks = chunk_b64(bios, 131072)
	vga_chunks = chunk_b64(vga, 131072)
	code = PRELUDE + "\n" + 'local fix = upsert(RS, "RvpcFixtures", "Folder")\n'
	for i, chunk in enumerate(bios_chunks):
		name = f"BootBios{i + 1:02d}"
		code += "local m = upsert(fix, " + json.dumps(name) + ", " + '"ModuleScript"' + ")\n"
		code += "m.Source = RET .. Q .. " + json.dumps(chunk) + " .. Q\n"
	for i, chunk in enumerate(vga_chunks):
		name = f"BootVga{i + 1:02d}"
		code += "local m = upsert(fix, " + json.dumps(name) + ", " + '"ModuleScript"' + ")\n"
		code += "m.Source = RET .. Q .. " + json.dumps(chunk) + " .. Q\n"
	code += 'return "fixtures1 ok"'
	json.dump(payload(code), open(os.path.join(OUT, "rvpc_fixtures_1.json"), "w"))

	# payloads 2..: iso chunks, 6 per payload
	per = 6
	for start in range(0, n, per):
		group = iso_chunks[start:start + per]
		code = PRELUDE + "\n" + 'local fix = upsert(RS, "RvpcFixtures", "Folder")\n'
		for i, chunk in enumerate(group):
			name = f"BootIso{start + i + 1:02d}"
			code += "local m = upsert(fix, " + json.dumps(name) + ", " + '"ModuleScript"' + ")\n"
			code += "m.Source = RET .. Q .. " + json.dumps(chunk) + " .. Q\n"
		code += f'return "iso {start + 1}..{start + len(group)} ok"'
		json.dump(payload(code), open(os.path.join(OUT, f"rvpc_fixtures_{start // per + 2}.json"), "w"))

	# final payload: RvpcBoot factory
	factory = (FACTORY
		.replace("{chunks}", str(n))
		.replace("{biosChunks}", str(len(bios_chunks)))
		.replace("{vgaChunks}", str(len(vga_chunks))))
	factory_b64 = base64.b64encode(factory.encode()).decode()
	code = PRELUDE + "\n" + 'local fix = upsert(RS, "RvpcFixtures", "Folder")\n'
	code += 'local m = upsert(RS, "RvpcBoot", "ModuleScript")\n'
	code += "m.Source = b64(" + json.dumps(factory_b64) + ")\n"
	code += 'return "boot ok"'
	json.dump(payload(code), open(os.path.join(OUT, "rvpc_boot.json"), "w"))
	print(f"wrote {2 + (n + per - 1) // per} payload files, {n} iso chunks")


def repr_b64(data):
	return json.dumps(base64.b64encode(data).decode())


if __name__ == "__main__":
	main()
