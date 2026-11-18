--!nonstrict
-- Ne2000Tests.lua -- DP8390 registers, remote DMA, transmit and receive ring.

const band = bit32.band
const Ne2000 = require("../core/Ne2000")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function writeReg(n, offset, value)
	n:out8(0x300 + offset, value)
end

local function readReg(n, offset)
	return n:in8(0x300 + offset)
end

local function remoteWrite(n, address, bytes)
	writeReg(n, 8, band(address, 0xFF))
	writeReg(n, 9, band(bit32.rshift(address, 8), 0xFF))
	writeReg(n, 10, band(#bytes, 0xFF))
	writeReg(n, 11, band(bit32.rshift(#bytes, 8), 0xFF))
	writeReg(n, 0, 0x30) -- NODMA | RWRITE
	for index = 1, #bytes do
		n:out8(0x310, bytes[index])
	end
end

local function remoteRead(n, address, count)
	writeReg(n, 8, band(address, 0xFF))
	writeReg(n, 9, band(bit32.rshift(address, 8), 0xFF))
	writeReg(n, 10, band(count, 0xFF))
	writeReg(n, 11, band(bit32.rshift(count, 8), 0xFF))
	writeReg(n, 0, 0x28) -- NODMA | RREAD
	const out = {}
	for index = 1, count do
		out[index] = n:in8(0x310)
	end
	return out
end

T("reset_mac_and_registers", function(expect)
	const n = Ne2000.new({ mac = "52:54:00:AA:BB:CC" })
	expect(n:macString() == "52:54:00:AA:BB:CC", "mac")
	expect(band(readReg(n, 7), 0x80) ~= 0, "reset ISR")
	writeReg(n, 7, 0x80)
	expect(readReg(n, 7) == 0, "ISR clear")
	writeReg(n, 0, 0x40) -- page 1
	expect(readReg(n, 1) == 0x52 and readReg(n, 2) == 0x54, "PAR0/1")
	expect(readReg(n, 3) == 0x00 and readReg(n, 6) == 0xCC, "PAR2..5")
end)

T("remote_dma_write_read", function(expect)
	const n = Ne2000.new()
	remoteWrite(n, 0x4000, { 0x11, 0x22, 0x33, 0x44 })
	const got = remoteRead(n, 0x4000, 4)
	expect(
		got[1] == 0x11 and got[2] == 0x22 and got[3] == 0x33 and got[4] == 0x44,
		table.concat(got, ",")
	)
	expect(band(readReg(n, 7), 0x40) ~= 0, "RDC not set")
end)

T("transmit_frame_and_interrupt", function(expect)
	local sent = nil
	const n = Ne2000.new({
		transmit = function(frame)
			sent = frame
		end,
	})
	const frame = {}
	for index = 1, 60 do
		frame[index] = index
	end
	remoteWrite(n, 0x4000, frame)
	writeReg(n, 4, 0x40) -- TPSR
	writeReg(n, 5, 60)
	writeReg(n, 6, 0)
	writeReg(n, 15, 0x02) -- IMR: TX
	writeReg(n, 0, 0x24) -- NODMA | TXP
	expect(sent ~= nil and buffer.len(sent) == 60, "frame not transmitted")
	expect(band(readReg(n, 4), 0x01) ~= 0, "PTX not set")
	expect(n:irqPending(), "TX IRQ not pending")
	writeReg(n, 7, 0x02)
	expect(not n:irqPending(), "TX IRQ did not clear")
end)

T("receive_ring_header_and_irq", function(expect)
	const n = Ne2000.new()
	writeReg(n, 15, 0x01) -- IMR: RX
	const frame = buffer.create(60)
	for index = 0, 59 do
		buffer.writeu8(frame, index, index + 1)
	end
	expect(n:receive(frame), "receive rejected")
	expect(n:irqPending(), "RX IRQ not pending")
	const header = remoteRead(n, 0x4600, 4)
	expect(header[1] == 0x01, "RX status")
	expect(header[2] == 0x47, "next page")
	expect(header[3] == 60 and header[4] == 0, "length")
	const body = remoteRead(n, 0x4604, 4)
	expect(body[1] == 1 and body[4] == 4, "body")
	expect(n:takeIrq(), "takeIrq")
	expect(not n:takeIrq(), "takeIrq repeated without ack")
	writeReg(n, 7, 0x01)
	expect(not n:irqPending(), "RX IRQ did not clear")
end)

T("receive_rejects_bad_frames", function(expect)
	const n = Ne2000.new()
	expect(not n:receive(buffer.create(10)), "short frame accepted")
	expect(not n:receive(buffer.create(2000)), "oversize frame accepted")
end)

return TESTS
