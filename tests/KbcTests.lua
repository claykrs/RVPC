--!nonstrict
-- KbcTests.lua -- 8042 keyboard/mouse queues, set-1 codes and IRQ lines.

const band = bit32.band
const Kbc = require("../core/Kbc")

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

return TESTS
