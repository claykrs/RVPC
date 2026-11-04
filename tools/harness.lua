--!nonstrict
-- harness.lua -- headless RVDM98 boot: load a real 256 KiB SeaBIOS (and the
-- SeaVGABIOS option ROM) and run until firmware text appears or it faults.
--
-- Usage: lune run tools/harness.lua [max-millions]
-- ROMs are not committed; place them in roms/ (see README).

const fs = require("@lune/fs")
const process = require("@lune/process")

const Memory = require("../core/Memory")
const Cpu = require("../core/Cpu")
const Vga = require("../core/Vga")
const Pic = require("../core/Pic")
const Pit = require("../core/Pit")
const Cmos = require("../core/Cmos")
const FwCfg = require("../core/FwCfg")
const Xms = require("../core/Xms")
const Uart = require("../core/Uart")
const Lpt = require("../core/Lpt")
const Machine = require("../core/Machine")

const BIOS_PATH = "roms/bios-256k.bin"
const VGA_ROM_PATH = "roms/vgabios-stdvga.bin"

if not fs.isFile(BIOS_PATH) then
	print("missing " .. BIOS_PATH)
	print("download a prebuilt QEMU/SeaBIOS 256 KiB image, e.g.")
	print("  https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/bios-256k.bin")
	error("SeaBIOS ROM not staged")
end

const bios = buffer.fromstring(fs.readFile(BIOS_PATH))
if buffer.len(bios) ~= 0x40000 then
	error(("expected a 256 KiB SeaBIOS image, got %d bytes"):format(buffer.len(bios)))
end

local vgaRom = nil
if fs.isFile(VGA_ROM_PATH) then
	vgaRom = buffer.fromstring(fs.readFile(VGA_ROM_PATH))
else
	print("warning: " .. VGA_ROM_PATH .. " not found; SeaBIOS has no INT 10h console")
	print("  https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/vgabios-stdvga.bin")
end

const machine = Machine.new({
	Memory = Memory,
	Cpu = Cpu,
	Vga = Vga,
	Pic = Pic,
	Pit = Pit,
	Cmos = Cmos,
	FwCfg = FwCfg,
	Xms = Xms,
	Uart = Uart,
	Lpt = Lpt,
}, {
	memorySize = 32 * 1024 * 1024,
	cpu = { cpuLevel = "486" },
	rom = bios,
	vgaRom = vgaRom,
})

print(
	("SeaBIOS %d bytes, RAM %d MiB"):format(
		buffer.len(bios),
		math.floor(machine.mem.size / (1024 * 1024))
	)
)
print("reset vector " .. machine:bootPc())
print(
	"reset bytes "
		.. string.format(
			"%02X %02X %02X %02X %02X",
			machine.mem:read8(0xFFFF0),
			machine.mem:read8(0xFFFF1),
			machine.mem:read8(0xFFFF2),
			machine.mem:read8(0xFFFF3),
			machine.mem:read8(0xFFFF4)
		)
)

local limitMillions = tonumber(process.args[1] or "") or 20
const budget = limitMillions * 1_000_000
const chunk = 2_000_000
local executed = 0
local lastScreen = ""
local lastPrint = 0

while executed < budget do
	const want = math.min(chunk, budget - executed)
	local ok, result = pcall(function()
		return machine:run(want)
	end)
	if not ok then
		print(
			("FAULT at %s after %d steps: %s"):format(machine:bootPc(), executed, tostring(result))
		)
		break
	end
	executed += result
	const screen = machine:outputText()
	if screen ~= lastScreen then
		lastScreen = screen
		if #screen > 0 then
			print(("-- screen at %s (%d steps)"):format(machine:bootPc(), executed))
			print(screen)
		end
	end
	if executed - lastPrint >= 10_000_000 then
		lastPrint = executed
		print(("... %dM steps at %s"):format(math.floor(executed / 1_000_000), machine:bootPc()))
	end
	if
		string.find(screen, "No bootable", 1, true)
		or string.find(screen, "Booting from", 1, true)
		or (string.find(screen, "SeaBIOS", 1, true) and executed >= 6_000_000)
	then
		break
	end
	if result == 0 then
		print(("stopped at %s (halted=%s)"):format(machine:bootPc(), tostring(machine.cpu.halted)))
		break
	end
end

const screen = machine:outputText()
const debug = machine:debugText()
print(("boot PC: %s"):format(machine:bootPc()))
print(
	("steps: %d  halted: %s  irqs: %d  page faults: %d"):format(
		executed,
		tostring(machine.cpu.halted),
		machine.irqCount,
		machine.cpu.pageFaults
	)
)
if #debug > 0 then
	print("---- firmware debug console (0x402) ----")
	print(debug)
end
print("---- screen ----")
print(screen)
print("---- end ----")
