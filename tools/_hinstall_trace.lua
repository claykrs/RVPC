--!nonstrict
-- _hinstall_trace.lua -- replay the headless FreeDOS install with logging:
--  * every ATA data-phase WRITE payload (per command: LBA, count, words)
--  * every ATA data-phase READ payload on both controllers (per command:
--    LBA, count, words read back), so CD-served file data can be compared
--    against the ISO bytes
-- Dump the logs and the C: image at the "Set active boot partition" point.
-- The key/settle/repress flow is byte-identical to tools/_hinstall.lua.
local fs = require("@lune/fs")
local Memory = require("../core/Memory")
local Cpu = require("../core/Cpu")
local Vga = require("../core/Vga")
local Pic = require("../core/Pic")
local Pit = require("../core/Pit")
local Cmos = require("../core/Cmos")
local FwCfg = require("../core/FwCfg")
local Ide = require("../core/Ide")
local Kbc = require("../core/Kbc")
local Fpu = require("../core/Fpu")
local Xms = require("../core/Xms")
local Uart = require("../core/Uart")
local Lpt = require("../core/Lpt")
local Machine = require("../core/Machine")

local m = Machine.new({
	Memory = Memory,
	Cpu = Cpu,
	Vga = Vga,
	Pic = Pic,
	Pit = Pit,
	Cmos = Cmos,
	FwCfg = FwCfg,
	Ide = Ide,
	Kbc = Kbc,
	Fpu = Fpu,
	Xms = Xms,
	Uart = Uart,
	Lpt = Lpt,
}, {
	memorySize = 32 * 1024 * 1024,
	cpu = { cpuLevel = "486" },
	rom = buffer.fromstring(fs.readFile("roms/bios-256k.bin")),
	vgaRom = buffer.fromstring(fs.readFile("roms/vgabios-stdvga.bin")),
	cdrom = buffer.fromstring(fs.readFile("media/freedos-boot.iso")),
	hdd = buffer.create(32 * 1024 * 1024),
	floppy = { image = buffer.fromstring(fs.readFile("media/x86DSK01.img")) },
})

---------------------------------------------------------------- hooks
local events = {} -- serialized per-command records
local CAP = 400000 -- cap stored words per command (safety)

local function newHook(ide, name: string, dataPort: number, cmdPort: number)
	local cur = nil
	local origOut8 = ide.out8
	ide.out8 = function(self, port, value)
		if port == cmdPort then
			if cur then
				events[#events + 1] = cur
				cur = nil
			end
			if value == 0x30 or value == 0x31 then
				cur =
					{ kind = "W", bus = name, lba = self.lba, count = self.sectorCount, words = {} }
			elseif value == 0x20 or value == 0x21 or value == 0x24 or value == 0x25 then
				cur =
					{ kind = "R", bus = name, lba = self.lba, count = self.sectorCount, words = {} }
			end
		end
		return origOut8(self, port, value)
	end
	local origOut16 = ide.out16
	ide.out16 = function(self, port, value)
		if cur and cur.kind == "W" and port == dataPort and #cur.words < CAP then
			cur.words[#cur.words + 1] = value
		end
		return origOut16(self, port, value)
	end
	local origIn16 = ide.in16
	ide.in16 = function(self, port)
		local v = origIn16(self, port)
		if cur and cur.kind == "R" and port == dataPort and #cur.words < CAP then
			cur.words[#cur.words + 1] = v
		end
		return v
	end
end
newHook(m.ide, "pri", 0x1F0, 0x1F7)
newHook(m.ide2, "sec", 0x170, 0x177)

---------------------------------------------------------------- install flow
local function flat(s)
	return (s:gsub("[^%g\n]+", " "))
end
local function pumpUntil(limit, needle)
	local done = 0
	while done < limit do
		local ok, n = pcall(function()
			return m:run(500_000)
		end)
		if not ok then
			return "FAULT:" .. tostring(n)
		end
		if n == 0 then
			break
		end
		done += n
		if needle and string.find(m:outputText(), needle, 1, true) then
			return "hit"
		end
	end
	return "timeout"
end
local function press(code)
	m:pressKey(code)
	m:releaseKey(code)
end
local function answerKey(code, sig)
	for _ = 1, 4 do
		press(code)
		pumpUntil(12_000_000, nil)
		if flat(m:outputText()) ~= sig then
			return true
		end
	end
	return flat(m:outputText()) ~= sig
end

pumpUntil(30_000_000, "select your language")
local sig = flat(m:outputText())
answerKey(0x1C, sig)

local target = "Set active boot partition"
local done = false
for round = 1, 30 do
	local screen = m:outputText()
	if string.find(screen, target, 1, true) then
		print("reached sys-transfer at round", round)
		done = true
		break
	end
	if string.find(screen, "Insert diskette", 1, true) then
		print("reached diskette phase at round", round)
		done = true
		break
	end
	sig = flat(screen)
	local code = 0x15 -- Y
	if not answerKey(code, sig) then
		answerKey(0x1C, sig)
	end
	print("r" .. round, "answered; screen:", flat(m:outputText()):sub(-90))
end
print("done:", done)

---------------------------------------------------------------- dump logs
local summary = {}
local payloadChunks = {}
for i, e in ipairs(events) do
	summary[#summary + 1] = string.format(
		"%d %s %s lba=%d count=%d words=%d",
		i,
		e.kind,
		e.bus,
		e.lba,
		e.count,
		#e.words
	)
	local t = {}
	local n = math.min(#e.words, 600)
	for k = 1, n do
		t[#t + 1] = string.format("%04X", e.words[k])
	end
	payloadChunks[#payloadChunks + 1] = ("@%d %s %s lba=%d count=%d\n"):format(
		i,
		e.kind,
		e.bus,
		e.lba,
		e.count
	) .. table.concat(t, " ")
end
fs.writeFile("media/_trace_ata_summary.txt", table.concat(summary, "\n"))
fs.writeFile("media/_trace_ata_payload.txt", table.concat(payloadChunks, "\n"))

local out = m.ide.master.image
fs.writeFile("media/_trace_c.img", buffer.tostring(out))
print("ata commands:", #events)
