--!nonstrict
-- _hinstall.lua -- headless FreeDOS install to the sys-transfer point, then
-- dump C: as the pre-installed image. Key insight: keys pressed right after
-- a prompt paints are eaten by the installer's keyboard purge; press, settle,
-- re-press until the screen moves.
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

-- press a key, then re-press after settles until the screen text changes
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

-- menus: language then keyboard layout (the proven double-Enter)
pumpUntil(30_000_000, "select your language")
local sig = flat(m:outputText())
answerKey(0x1C, sig)

-- the installer's proceed chain: answer every "proceed" and "format" prompt
-- until the sys-transfer marker appears
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
		-- sys-transfer completed; the diskette ask means C: core is written
		print("reached diskette phase at round", round)
		done = true
		break
	end
	sig = flat(screen)
	local code = 0x15 -- Y
	if not answerKey(code, sig) then
		-- maybe it wanted Enter instead
		answerKey(0x1C, sig)
	end
	print("r" .. round, "answered; screen:", flat(m:outputText()):sub(-90))
end
print("done:", done)
local out = m.ide.master.image
-- trim trailing zeros: find the last non-zero byte
local last = 0
local bytes = buffer.tostring(out)
for i = #bytes, 1, -4096 do
	local chunk = string.sub(bytes, i, math.min(i + 4095, #bytes))
	if chunk:find("[^%z]") then
		for j = #chunk, 1, -1 do
			if chunk:byte(j) ~= 0 then
				last = i + j - 1
				break
			end
		end
		if last > 0 then
			break
		end
	end
end
local size = math.max(last, 1048576)
size = math.floor((size + 65535) / 65536) * 65536 -- 64K align
fs.writeFile("media/fd13-c.img", string.sub(bytes, 1, size))
print("dumped C: bytes:", size)
