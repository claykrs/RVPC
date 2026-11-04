--!nonstrict
-- UartTests.lua -- 8250 COM1 register, loopback and IRQ behaviour.

const band = bit32.band
const Uart = require("../core/Uart")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

T("divisor_latch_and_scratch", function(expect)
	const uart = Uart.new(Uart.loopbackBackend())
	uart:out8(0x3FB, 0x80) -- DLAB
	uart:out8(0x3F8, 0x01)
	uart:out8(0x3F9, 0x00)
	expect(uart:in8(0x3F8) == 0x01, "DLL")
	expect(uart:in8(0x3F9) == 0x00, "DLM")
	uart:out8(0x3FB, 0x03)
	uart:out8(0x3FF, 0xA5)
	expect(uart:in8(0x3FF) == 0xA5, "scratch")
end)

T("loopback_tx_rx", function(expect)
	const uart = Uart.new(Uart.loopbackBackend())
	uart:out8(0x3F8, string.byte("R"))
	uart:out8(0x3F8, string.byte("V"))
	uart:poll()
	expect(uart:rxAvailable(), "RX not available")
	expect(uart:readByte() == string.byte("R"), "first byte")
	expect(uart:readByte() == string.byte("V"), "second byte")
	expect(not uart:rxAvailable(), "RX queue not drained")
end)

T("rx_irq_and_iir", function(expect)
	const uart = Uart.new(Uart.loopbackBackend())
	uart:out8(0x3FC, 0x0B) -- DTR, RTS, OUT2
	uart:out8(0x3F9, 0x01) -- received-data interrupt
	uart:pushByte(0x5A)
	expect(uart:irqPending(), "IRQ not pending")
	expect(band(uart:in8(0x3FA), 0x0E) == 0x04, "IIR source")
	expect(uart:readByte() == 0x5A, "RX byte")
	expect(not uart:irqPending(), "IRQ still pending after drain")
end)

T("modem_loopback", function(expect)
	const uart = Uart.new(Uart.loopbackBackend())
	uart:out8(0x3FC, 0x1B) -- loopback + RTS + DTR + OUT2
	expect(uart:modemStatus() == 0xB0, "modem loopback bits")
end)

return TESTS
