--!nonstrict
-- harness.lua -- headless RVPC boot: load a real 256 KiB SeaBIOS (and the
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
const Ide = require("../core/Ide")
const Kbc = require("../core/Kbc")
const Fpu = require("../core/Fpu")
const Xms = require("../core/Xms")
const Uart = require("../core/Uart")
const Lpt = require("../core/Lpt")
const Machine = require("../core/Machine")

const BIOS_PATH = "roms/bios-256k.bin"
const VGA_ROM_PATH = "roms/vgabios-stdvga.bin"
const CDROM_PATH = if fs.isFile("media/freedos-boot.iso")
	then "media/freedos-boot.iso"
	else "media/FD13LIVE.iso"
const HDD_PATH = "media/hdd.img"

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

local hdd = nil
if fs.isFile(HDD_PATH) then
	hdd = buffer.fromstring(fs.readFile(HDD_PATH))
end

local cdrom = nil
if fs.isFile(CDROM_PATH) then
	cdrom = buffer.fromstring(fs.readFile(CDROM_PATH))
else
	print("warning: " .. CDROM_PATH .. " not found; only the blank HDD is attached")
end

const machine = Machine.new({
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
	rom = bios,
	vgaRom = vgaRom,
	hdd = hdd,
	cdrom = cdrom,
})

print(
	("SeaBIOS %d bytes, RAM %d MiB"):format(
		buffer.len(bios),
		math.floor(machine.mem.size / (1024 * 1024))
	)
)
machine.cpu.traceEnabled = true
print(
	("IDE: HDD %s, CD %s"):format(
		if hdd then ("%d KiB"):format(math.floor(buffer.len(hdd) / 1024)) else "absent",
		if cdrom then ("%d KiB"):format(math.floor(buffer.len(cdrom) / 1024)) else "absent"
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

local limitMillions = tonumber(process.args[1] or "") or 40
const budget = limitMillions * 1_000_000
const chunk = 2_000_000
local executed = 0
local lastScreen = ""
local lastPrint = 0
local menuSelected = false
local menuDebug = 0

while executed < budget do
	const want = math.min(chunk, budget - executed)
	local ok, result = pcall(function()
		return machine:run(want)
	end)
	if not ok then
		print(
			("FAULT at %s after %d steps: %s"):format(machine:bootPc(), executed, tostring(result))
		)
		local irq = machine.cpu.lastIrq
		if irq then
			print(
				("last IRQ0 before: cs=%04X ip=%04X flags=%04X ss=%04X sp=%04X"):format(
					irq.cs,
					irq.ip,
					irq.flags,
					irq.ss,
					irq.sp
				)
			)
			print(("  stack: %04X %04X %04X %04X"):format(irq.s0, irq.s1, irq.s2, irq.s3))
			if machine.cpu.lastIrqTrace then
				print("  IRQ0 entry trace:")
				for index, pc in machine.cpu.lastIrqTrace do
					print("    " .. pc)
					if index >= 40 then
						break
					end
				end
			end
		end
		if machine.cpu.badCsTrace then
			print("first 0202:0 entry trace:")
			for _, pc in machine.cpu.badCsTrace do
				print("  " .. pc)
			end
		end
		local sw = machine.cpu.lastSwInt
		if sw then
			print(
				("last INT10: from %04X:%04X flags=%04X ss=%04X sp=%04X"):format(
					sw.cs,
					sw.ip,
					sw.flags,
					sw.ss,
					sw.sp
				)
			)
			print(
				("  int10 stack: %04X %04X %04X %04X %04X %04X %04X %04X"):format(
					sw.s0,
					sw.s1,
					sw.s2,
					sw.s3,
					sw.s4,
					sw.s5,
					sw.s6,
					sw.s7
				)
			)
		end
		local extra = {}
		for index = 0, 127 do
			extra[#extra + 1] = string.format("%04X", machine.mem:read16(0xE9600 + index * 2))
		end
		print("VGA extra stack:" .. table.concat(extra, " "))
		local far = machine.cpu.lastFarCall
		if far then
			print(
				("last far CALL: %04X:%04X -> %04X:%04X ss=%04X sp=%04X"):format(
					far.fromCs,
					far.fromIp,
					far.toCs,
					far.toIp,
					far.ss,
					far.sp
				)
			)
		end
		local retf = machine.cpu.lastRetf
		if retf then
			print(
				("last RETF: %04X:%04X -> %04X:%04X ss=%04X sp=%04X after=%04X"):format(
					retf.fromCs,
					retf.fromIp,
					retf.cs,
					retf.ip,
					retf.ss,
					retf.sp,
					retf.afterSp
				)
			)
			print(
				("  retf stack: %04X %04X %04X %04X %04X %04X"):format(
					retf.s0,
					retf.s1,
					retf.s2,
					retf.s3,
					retf.s4,
					retf.s5
				)
			)
		end
		local iret = machine.cpu.lastIret
		if iret then
			print(
				("last IRET: ip=%04X cs=%04X flags=%04X ss=%04X sp=%04X"):format(
					iret.ip,
					iret.cs,
					iret.flags,
					iret.ss,
					iret.sp
				)
			)
			print(("  stack: %04X %04X %04X %04X"):format(iret.s0, iret.s1, iret.s2, iret.s3))
		end
		print("trace:")
		const trace = machine.cpu:traceDump(4096)
		local first = nil
		for index, pc in trace do
			if string.find(pc, "0202:", 1, true) then
				first = index
				break
			end
		end
		if first then
			for index = math.max(1, first - 80), math.min(#trace, first + 16) do
				print("  " .. trace[index])
			end
		else
			for _, pc in machine.cpu:traceDump(48) do
				print("  " .. pc)
			end
		end
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
	if not menuSelected and string.find(screen, "Select boot device", 1, true) then
		print(
			("selecting boot entry 1 (CD); bda head=%04X tail=%04X start=%04X end=%04X"):format(
				machine.mem:read16(0x41A),
				machine.mem:read16(0x41C),
				machine.mem:read16(0x480),
				machine.mem:read16(0x482)
			)
		)
		if machine:injectBdaKey(0x02, string.byte("1")) then
			menuSelected = true
			print(
				("injected; bda head=%04X tail=%04X"):format(
					machine.mem:read16(0x41A),
					machine.mem:read16(0x41C)
				)
			)
		end
	end
	if menuSelected then
		menuDebug += 1
		if menuDebug % 8 == 0 then
			print(
				("menu wait: bda head=%04X tail=%04X pc=%s"):format(
					machine.mem:read16(0x41A),
					machine.mem:read16(0x41C),
					machine:bootPc()
				)
			)
		end
	end
	if
		string.find(screen, "FreeCom", 1, true)
		or string.find(screen, "KERNEL", 1, true)
		or string.find(screen, "A:\\>", 1, true)
		or string.find(screen, "C:\\>", 1, true)
		or string.find(screen, "No bootable", 1, true)
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
print(
	("INT counts: 08=%d 09=%d 21=%d 74=%d"):format(
		machine.cpu.intCounts[0x08] or 0,
		machine.cpu.intCounts[0x09] or 0,
		machine.cpu.intCounts[0x21] or 0,
		machine.cpu.intCounts[0x74] or 0
	)
)
print(
	("IVT21=%04X:%04X IVT09=%04X:%04X"):format(
		machine.mem:read16(0x21 * 4 + 2),
		machine.mem:read16(0x21 * 4),
		machine.mem:read16(0x09 * 4 + 2),
		machine.mem:read16(0x09 * 4)
	)
)
print(
	("csBase=%08X cs=%04X ssBase=%08X"):format(
		machine.cpu.segBase.cs,
		machine.cpu.cs,
		machine.cpu.segBase.ss
	)
)
print(
	("PAM58=%08X locked=%s"):format(
		machine.hostConfig[0x58] or 0,
		tostring(machine.mem.lowRomLocked)
	)
)
if machine.pic then
	print(
		("PIC: master imr=%02X isr=%02X irr=%02X slave imr=%02X isr=%02X irr=%02X"):format(
			machine.pic.master.imr,
			machine.pic.master.isr,
			machine.pic.master.irr,
			machine.pic.slave.imr,
			machine.pic.slave.isr,
			machine.pic.slave.irr
		)
	)
end
if machine.kbc then
	print(
		("KBC: queue=%d config=%02X irq1=%s irq12=%s"):format(
			#machine.kbc.queue,
			machine.kbc.config,
			tostring(machine.kbc:takeIrq1()),
			tostring(machine.kbc:takeIrq12())
		)
	)
	print("KBC trace: " .. table.concat(machine.kbc.trace, " "))
end
if machine.ide then
	print(
		("IDE: commands=%d last=%02X identify=%d packet=%d selected=%d"):format(
			machine.ide.commandCount,
			machine.ide.lastCommand,
			machine.ide.identifyCount,
			machine.ide.packetCount,
			machine.ide.selectedIndex
		)
	)
end
if #debug > 0 then
	print("---- firmware debug console (0x402) ----")
	print(debug)
end
if machine.vga and not machine.vga:isTextMode() then
	const width = machine.vga:width()
	const height = machine.vga:height()
	const pixels = machine.vga:snapshotRGBA()
	local rows = { ("P6\n%d %d\n255\n"):format(width, height) }
	for y = 0, height - 1 do
		const row = table.create(width * 3)
		for x = 0, width - 1 do
			const source = (y * width + x) * 4
			row[x * 3 + 1] = string.char(buffer.readu8(pixels, source))
			row[x * 3 + 2] = string.char(buffer.readu8(pixels, source + 1))
			row[x * 3 + 3] = string.char(buffer.readu8(pixels, source + 2))
		end
		rows[#rows + 1] = table.concat(row)
	end
	fs.writeFile("tools/out/screen.ppm", table.concat(rows))
	print(("graphics screen: %dx%d -> tools/out/screen.ppm"):format(width, height))
end
print("---- screen ----")
print(screen)
print("---- end ----")
