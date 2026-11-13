--!nonstrict
-- _boothdd.lua -- boot the pre-installed FreeDOS HDD image headlessly.
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
	hdd = buffer.fromstring(fs.readFile("media/_test_hdd.img")),
})
local done = 0
local hitAt = nil
local last = ""
while done < 300_000_000 do
	local ok, n = pcall(function()
		return m:run(200_000)
	end)
	if not ok then
		print("FAULT at", done, n)
		break
	end
	if n == 0 then
		break
	end
	done += n
	local screen = m:outputText()
	if string.find(screen, "C:\\>", 1, true) or string.find(screen, "C>", 1, true) then
		hitAt = done
		break
	end
	if done % 5_000_000 < 200_000 then
		local flat = (screen:gsub("[^%g\n]+", " "))
		if flat ~= last then
			last = flat
			print("at", done, "screen tail:", flat:sub(-120):gsub("\n", " "))
		end
	end
end
print("boot done:", done, "promptAt:", hitAt)
print(string.sub((m:outputText():gsub("[^%g\n]+", " ")), 1, 800))
