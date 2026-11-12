--!nonstrict
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
	Memory = Memory, Cpu = Cpu, Vga = Vga, Pic = Pic, Pit = Pit, Cmos = Cmos,
	FwCfg = FwCfg, Ide = Ide, Kbc = Kbc, Fpu = Fpu, Xms = Xms, Uart = Uart, Lpt = Lpt,
}, {
	memorySize = 32 * 1024 * 1024,
	cpu = { cpuLevel = "486" },
	rom = buffer.fromstring(fs.readFile("roms/bios-256k.bin")),
	vgaRom = buffer.fromstring(fs.readFile("roms/vgabios-stdvga.bin")),
	hdd = buffer.fromstring(fs.readFile("media/_test_hdd.img")),
})
local done = 0
-- run coarse until the "Booting from Hard Disk" message, then fine-grain
local booted = false
while done < 40_000_000 do
	local ok, n = pcall(function()
		return m:run(100_000)
	end)
	if not ok then
		print("FAULT coarse at", done, n)
		break
	end
	done += n
	if not booted and string.find(m:outputText(), "FreeDOS kernel", 1, true) then
		booted = true
		print("kernel banner at", done)
		break
	end
end
-- fine-grain: step 1000 at a time, log cs:ip changes, catch the fault
local log = {}
local lastIp = nil
local faulterr = nil
local samples = {}
while done < 55_000_000 do
	local ok, err = pcall(function()
		return m:run(20)
	end)
	if not ok then
		faulterr = tostring(err)
		break
	end
	done += 20
	local cpu = m.cpu
	local key = string.format("%04X:%04X", cpu.cs, cpu.ip)
	if key ~= lastIp then
		log[#log + 1] = key
		if #log > 60 then
			table.remove(log, 1)
		end
		lastIp = key
	end
	if cpu.halted then
		break
	end
	if done % 2_000_000 < 20 then
		local d = m.ide.master
		samples[#samples + 1] = string.format("t=%dM pic m:irr=%02X isr=%02X imr=%02X s:irr=%02X isr=%02X imr=%02X pitPeriod=%s irq0=%s",
			done // 1_000_000, m.pic.master.irr, m.pic.master.isr, m.pic.master.imr,
			m.pic.slave.irr, m.pic.slave.isr, m.pic.slave.imr,
			tostring(m.pit and m.pit.period or "?"), tostring(m.pit and m.pit.irqPending or "?"))
	end
end
for _, s in samples do
	print(s)
end
print("fault:", faulterr or "none", "halted:", tostring(m.cpu.halted))
print("path tail:", table.concat(log, " "))
