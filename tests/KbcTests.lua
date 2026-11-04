--!nonstrict
-- KbcTests.lua -- 8042 keyboard/mouse queues, set-1 codes and IRQ lines.

const band, bor = bit32.band, bit32.bor
const Kbc = require("../core/Kbc")
const Pic = require("../core/Pic")
const Memory = require("../core/Memory")
const Cpu = require("../core/Cpu")
const Machine = require("../core/Machine")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

T("self_test_and_config", function(expect)
	const kbc = Kbc.new()
	kbc:out8(0x64, 0xAA)
	expect(kbc:in8(0x60) == 0x55, "self-test response")
	kbc:out8(0x64, 0x20)
	expect(kbc:in8(0x60) == 0x45, "default config")
	kbc:out8(0x64, 0x60)
	kbc:out8(0x60, 0x01)
	kbc:out8(0x64, 0x20)
	expect(kbc:in8(0x60) == 0x01, "config write")
end)

T("keyboard_set1_and_irq1", function(expect)
	const kbc = Kbc.new()
	kbc:out8(0x64, 0x60)
	kbc:out8(0x60, 0x01) -- keyboard IRQ on, mouse IRQ off
	kbc:pressKey(0x1E) -- 'A' make
	expect(band(kbc:in8(0x64), 0x01) ~= 0, "OBF not set")
	expect(kbc:takeIrq1(), "IRQ1 not pending")
	expect(kbc:in8(0x60) == 0x1E, "make code")
	expect(not kbc:takeIrq1(), "IRQ1 leaked after drain")
	kbc:releaseKey(0x1E)
	expect(kbc:in8(0x60) == 0x9E, "break code")
	expect(not kbc:takeIrq12(), "mouse IRQ with keyboard data")
end)

T("mouse_packet_and_irq12", function(expect)
	const kbc = Kbc.new()
	kbc:out8(0x64, 0x60)
	kbc:out8(0x60, 0x03) -- both IRQs on
	kbc:mouseMove(10, -5, 1)
	expect(kbc:takeIrq12(), "IRQ12 not pending")
	const flags = kbc:in8(0x60)
	const dx = kbc:in8(0x60)
	const dy = kbc:in8(0x60)
	expect(band(flags, 0x08) ~= 0, "PS/2 always-1 bit")
	expect(band(flags, 0x01) ~= 0, "left button")
	expect(band(flags, 0x20) ~= 0, "negative Y sign")
	expect(dx == 10, "dx=" .. dx)
	expect(dy == 0xFB, string.format("dy=%02X", dy))
	expect(not kbc:takeIrq12(), "IRQ12 leaked after drain")
end)

T("mouse_enable_command", function(expect)
	const kbc = Kbc.new()
	kbc:out8(0x64, 0xD4)
	kbc:out8(0x60, 0xF4)
	expect(kbc:in8(0x60) == 0xFA, "mouse ACK")
	expect(not kbc:takeIrq1(), "mouse ACK leaked to IRQ1")
end)

T("irq1_int9_reads_data_port", function(expect)
	const m = Machine.new({
		Memory = Memory,
		Cpu = Cpu,
		Pic = Pic,
		Kbc = Kbc,
	}, { memorySize = 1024 * 1024 })
	const cpu = m.cpu
	cpu:loadSeg("cs", 0x600)
	cpu:loadSeg("ds", 0x600)
	cpu:loadSeg("ss", 0x600)
	cpu.ip = 0x100
	cpu.r[5] = 0xFFFE
	cpu.flags = bor(cpu.flags, 0x200)
	cpu.halted = false
	-- Guest main loop: STI; HLT; JMP $
	const main = { 0xFB, 0xF4, 0xEB, 0xFE }
	for index, byte in ipairs(main) do
		m.mem:write8(0x6000 + 0x100 + index - 1, byte)
	end
	-- INT 09h: IN AL,60h; MOV [0300],AL; MOV AL,20h; OUT 20h,AL; IRET
	const handler = { 0xE4, 0x60, 0xA2, 0x00, 0x03, 0xB0, 0x20, 0xE6, 0x20, 0xCF }
	for index, byte in ipairs(handler) do
		m.mem:write8(0x6000 + 0x500 + index - 1, byte)
	end
	m.mem:write16(9 * 4, 0x0500)
	m.mem:write16(9 * 4 + 2, 0x0600)
	m.pic:out8(0x21, 0xFD) -- unmask IRQ1; default vector base is 08h
	m:pressKey(0x1E) -- 'A' make code
	m:run(40)
	expect(m.mem:read8(0x6300) == 0x1E, "INT 09 handler did not read 0x60")
	expect(#m.kbc.queue == 0, "KBC queue not drained")
end)

T("irq12_mouse_packet", function(expect)
	const m = Machine.new({
		Memory = Memory,
		Cpu = Cpu,
		Pic = Pic,
		Kbc = Kbc,
	}, { memorySize = 1024 * 1024 })
	const cpu = m.cpu
	cpu:loadSeg("cs", 0x600)
	cpu:loadSeg("ds", 0x600)
	cpu:loadSeg("ss", 0x600)
	cpu.ip = 0x100
	cpu.r[5] = 0xFFFE
	cpu.flags = bor(cpu.flags, 0x200)
	cpu.halted = false
	m.mem:write8(0x6000 + 0x100, 0xFB) -- STI
	m.mem:write8(0x6000 + 0x101, 0xF4) -- HLT
	m.mem:write8(0x6000 + 0x102, 0xEB)
	m.mem:write8(0x6000 + 0x103, 0xFE) -- JMP $
	-- INT 2Ch: read the three mouse bytes, EOI both PICs, IRET.
	const handler = {
		0xE4,
		0x60,
		0xA2,
		0x00,
		0x03,
		0xE4,
		0x60,
		0xA2,
		0x01,
		0x03,
		0xE4,
		0x60,
		0xA2,
		0x02,
		0x03,
		0xB0,
		0x20,
		0xE6,
		0xA0,
		0xE6,
		0x20,
		0xCF,
	}
	for index, byte in ipairs(handler) do
		m.mem:write8(0x6000 + 0x500 + index - 1, byte)
	end
	m.mem:write16(0x2C * 4, 0x0500)
	m.mem:write16(0x2C * 4 + 2, 0x0600)
	-- Remap/init both PICs: master 0x20 (+cascade), slave 0x28.
	for _, pair in ipairs({
		{ 0x20, 0x11 },
		{ 0x21, 0x20 },
		{ 0x21, 0x04 },
		{ 0x21, 0x01 },
		{ 0xA0, 0x11 },
		{ 0xA1, 0x28 },
		{ 0xA1, 0x02 },
		{ 0xA1, 0x01 },
	}) do
		m.pic:out8(pair[1], pair[2])
	end
	m.pic:out8(0x21, 0xFB) -- unmask cascade IRQ2
	m.pic:out8(0xA1, 0xEF) -- unmask slave IRQ4 (IRQ12)
	m.kbc:out8(0x64, 0x60)
	m.kbc:out8(0x60, 0x03) -- keyboard + mouse IRQs
	m:mouseMove(10, -5, 1)
	m:run(40)
	expect(m.mem:read8(0x6300) == 0x29, "mouse flags=" .. m.mem:read8(0x6300))
	expect(m.mem:read8(0x6301) == 10, "dx=" .. m.mem:read8(0x6301))
	expect(m.mem:read8(0x6302) == 0xFB, "dy=" .. m.mem:read8(0x6302))
	expect(#m.kbc.queue == 0, "mouse queue not drained")
end)

return TESTS
