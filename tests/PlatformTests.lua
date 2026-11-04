--!nonstrict
-- PlatformTests.lua -- PCI PIIX3 config, PIRQ routing, ELCR and ROM BAR.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift
const Memory = require("../core/Memory")
const Cpu = require("../core/Cpu")
const Machine = require("../core/Machine")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function fresh()
	return Machine.new({ Memory = Memory, Cpu = Cpu }, {
		memorySize = 1024 * 1024,
		cpu = { cpuLevel = "486" },
	})
end

local function selectConfig(m, device, fn, offset)
	m.cpu.io.out32(0xCF8, bor(0x80000000, lshift(device, 11), lshift(fn, 8), band(offset, 0xFC)))
end

local function read32(m, device, fn, offset)
	selectConfig(m, device, fn, offset)
	return m.cpu.io.in32(0xCFC)
end

local function read8(m, device, fn, offset)
	selectConfig(m, device, fn, offset)
	return m.cpu.io.in8(0xCFC + band(offset, 3))
end

local function write32(m, device, fn, offset, value)
	selectConfig(m, device, fn, offset)
	m.cpu.io.out32(0xCFC, value)
end

local function write8(m, device, fn, offset, value)
	selectConfig(m, device, fn, offset)
	m.cpu.io.out8(0xCFC + band(offset, 3), value)
end

T("pci_ids_and_headers", function(expect)
	const m = fresh()
	expect(read32(m, 0, 0, 0x00) == 0x12378086, "host bridge ID")
	expect(read32(m, 1, 0, 0x00) == 0x70008086, "ISA bridge ID")
	expect(read32(m, 1, 1, 0x00) == 0x70108086, "IDE ID")
	expect(read32(m, 2, 0, 0x00) == 0x11111234, "VGA ID")
	expect(read32(m, 1, 0, 0x08) == 0x06010000, "ISA class")
	expect(read32(m, 1, 0, 0x0C) == 0x00800000, "ISA multifunction header")
	expect(read32(m, 1, 1, 0x08) == 0x01018000, "IDE class")
	expect(read32(m, 1, 1, 0x0C) == 0, "IDE single-function header")
	expect(read32(m, 2, 0, 0x08) == 0x03000001, "VGA class")
	expect(read32(m, 2, 0, 0x0C) == 0, "VGA header")
end)

T("pirq_defaults_and_byte_writes", function(expect)
	const m = fresh()
	for offset = 0x60, 0x63 do
		expect(read8(m, 1, 0, offset) == 0x80, string.format("PIRQ %02X default", offset))
	end
	write8(m, 1, 0, 0x60, 0x0A)
	write8(m, 1, 0, 0x61, 0x0A)
	write8(m, 1, 0, 0x62, 0x0B)
	write8(m, 1, 0, 0x63, 0x0B)
	expect(read8(m, 1, 0, 0x60) == 0x0A, "PIRQA byte")
	expect(read8(m, 1, 0, 0x61) == 0x0A, "PIRQB byte")
	expect(read8(m, 1, 0, 0x62) == 0x0B, "PIRQC byte")
	expect(read8(m, 1, 0, 0x63) == 0x0B, "PIRQD byte")
	expect(read32(m, 1, 0, 0x60) == 0x0B0B0A0A, "PIRQ dword")
	write8(m, 1, 0, 0x55, 0x12)
	write8(m, 1, 0, 0x56, 0x34)
	expect(read8(m, 1, 0, 0x55) == 0x12, "reg 0x55")
	expect(read8(m, 1, 0, 0x56) == 0x34, "reg 0x56")
end)

T("elcr_read_write", function(expect)
	const m = fresh()
	expect(m.cpu.io.in8(0x4D0) == 0, "ELCR master default")
	expect(m.cpu.io.in8(0x4D1) == 0, "ELCR slave default")
	m.cpu.io.out8(0x4D0, 0x00)
	m.cpu.io.out8(0x4D1, 0x0C)
	expect(m.cpu.io.in8(0x4D0) == 0x00, "ELCR master value")
	expect(m.cpu.io.in8(0x4D1) == 0x0C, "ELCR slave value")
end)

T("vga_config_polish", function(expect)
	const m = fresh()
	expect(read32(m, 2, 0, 0x10) == 0xE0000000, "VGA BAR0 default")
	expect(band(read32(m, 2, 0, 0x04), 0xFFFF) == 0x0007, "VGA command default")
	expect(band(rshift(read32(m, 2, 0, 0x04), 16), 0x10) == 0, "VGA capability bit")
	expect(band(read32(m, 2, 0, 0x3C), 0xFF) == 11, "VGA IRQ line")
	expect(band(rshift(read32(m, 2, 0, 0x3C), 8), 0xFF) == 3, "VGA IRQ pin")
	write32(m, 2, 0, 0x04, 0x00000003)
	expect(band(read32(m, 2, 0, 0x04), 0xFFFF) == 0x0003, "VGA command write")
	write32(m, 2, 0, 0x40, 0x20)
	expect(band(read32(m, 2, 0, 0x40), 0xFF) == 0x20, "VGA latency write")
	write32(m, 2, 0, 0x30, 0xFFFFFFFF)
	expect(read32(m, 2, 0, 0x30) == 0xFFFFF800, "VGA ROM BAR size")
	write32(m, 2, 0, 0x30, 0x000C0001)
	expect(read32(m, 2, 0, 0x30) == 0x000C0001, "VGA ROM BAR base")
	write32(m, 2, 0, 0x3C, 0x0000030B)
	expect(read32(m, 2, 0, 0x3C) == 0x0000030B, "VGA IRQ readback")
end)

T("isa_ide_and_status", function(expect)
	const m = fresh()
	expect(read32(m, 1, 0, 0x04) == 0x02000007, "ISA command/status default")
	expect(read32(m, 1, 1, 0x04) == 0x02800007, "IDE command/status default")
	expect(band(read32(m, 1, 1, 0x3C), 0xFF) == 14, "IDE IRQ line")
	expect(band(rshift(read32(m, 1, 1, 0x3C), 8), 0xFF) == 1, "IDE IRQ pin")
	expect(band(rshift(read32(m, 1, 0, 0x04), 16), 0x10) == 0, "ISA capability bit")
	expect(band(rshift(read32(m, 1, 1, 0x04), 16), 0x10) == 0, "IDE capability bit")
	write32(m, 1, 0, 0x04, 0x00000001)
	expect(band(read32(m, 1, 0, 0x04), 0xFFFF) == 0x0001, "ISA command write")
	write32(m, 1, 1, 0x04, 0x00000001)
	expect(band(read32(m, 1, 1, 0x04), 0xFFFF) == 0x0001, "IDE command write")
	write32(m, 1, 1, 0x40, 0x40)
	expect(band(read32(m, 1, 1, 0x40), 0xFF) == 0x40, "IDE latency write")
	expect(read32(m, 1, 1, 0x10) == 0x000001F1, "IDE BAR0 default")
	expect(read32(m, 1, 1, 0x14) == 0x000003F7, "IDE BAR1 default")
	expect(read32(m, 1, 1, 0x18) == 0x00000171, "IDE BAR2 default")
	expect(read32(m, 1, 1, 0x1C) == 0x00000377, "IDE BAR3 default")
	expect(read32(m, 1, 1, 0x20) == 0x0000C001, "IDE BAR4 default")
end)

return TESTS
