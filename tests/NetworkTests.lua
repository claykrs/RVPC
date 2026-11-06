--!nonstrict
-- NetworkTests.lua -- Machine-level NE2000 + Isp wiring (ports, IRQ10, ARP).

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift
const Memory = require("../core/Memory")
const Cpu = require("../core/Cpu")
const Pic = require("../core/Pic")
const Ne2000 = require("../core/Ne2000")
const Isp = require("../core/Isp")
const Machine = require("../core/Machine")

const TESTS = {}
const GUEST_MAC = { 0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC }
const ISP_MAC = { 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 }
const GUEST_IP = { 10, 0, 2, 15 }
const ISP_IP = { 10, 0, 2, 2 }

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function fresh()
	return Machine.new({
		Memory = Memory,
		Cpu = Cpu,
		Pic = Pic,
		Ne2000 = Ne2000,
		Isp = Isp,
	}, {
		memorySize = 16 * 1024 * 1024,
		cpu = { cpuLevel = "486" },
		network = {
			mac = "52:54:00:AA:BB:CC",
			ispMac = "52:54:00:12:34:56",
			ip = "10.0.2.2",
		},
	})
end

local function ioIn8(m, port)
	return m.cpu.io.in8(port)
end

local function ioOut8(m, port, value)
	m.cpu.io.out8(port, value)
end

local function be16(buf, offset, value)
	buffer.writeu8(buf, offset, band(rshift(value, 8), 0xFF))
	buffer.writeu8(buf, offset + 1, band(value, 0xFF))
end

local function read16(buf, offset)
	return bor(lshift(buffer.readu8(buf, offset), 8), buffer.readu8(buf, offset + 1))
end

local function putMac(buf, offset, mac)
	for index = 1, 6 do
		buffer.writeu8(buf, offset + index - 1, mac[index])
	end
end

local function putIp(buf, offset, ip)
	for index = 1, 4 do
		buffer.writeu8(buf, offset + index - 1, ip[index])
	end
end

local function readIp(buf, offset)
	return {
		buffer.readu8(buf, offset),
		buffer.readu8(buf, offset + 1),
		buffer.readu8(buf, offset + 2),
		buffer.readu8(buf, offset + 3),
	}
end

local function ethernet(dest, source, etherType, payload)
	const frame = buffer.create(14 + buffer.len(payload))
	putMac(frame, 0, dest)
	putMac(frame, 6, source)
	be16(frame, 12, etherType)
	buffer.copy(frame, 14, payload, 0, buffer.len(payload))
	return frame
end

local function remoteWrite(m, address, bytes)
	const length = buffer.len(bytes)
	ioOut8(m, 0x308, band(address, 0xFF))
	ioOut8(m, 0x309, band(rshift(address, 8), 0xFF))
	ioOut8(m, 0x30A, band(length, 0xFF))
	ioOut8(m, 0x30B, band(rshift(length, 8), 0xFF))
	ioOut8(m, 0x300, 0x30) -- NODMA | RWRITE
	for index = 0, length - 1 do
		ioOut8(m, 0x310, buffer.readu8(bytes, index))
	end
end

local function remoteRead(m, address, count)
	ioOut8(m, 0x308, band(address, 0xFF))
	ioOut8(m, 0x309, band(rshift(address, 8), 0xFF))
	ioOut8(m, 0x30A, band(count, 0xFF))
	ioOut8(m, 0x30B, band(rshift(count, 8), 0xFF))
	ioOut8(m, 0x300, 0x28) -- NODMA | RREAD
	const out = buffer.create(count)
	for index = 0, count - 1 do
		buffer.writeu8(out, index, ioIn8(m, 0x310))
	end
	return out
end

local function arpRequestFrame()
	const arp = buffer.create(28)
	be16(arp, 0, 1)
	be16(arp, 2, 0x0800)
	buffer.writeu8(arp, 4, 6)
	buffer.writeu8(arp, 5, 4)
	be16(arp, 6, 1)
	putMac(arp, 8, GUEST_MAC)
	putIp(arp, 14, GUEST_IP)
	putMac(arp, 18, { 0, 0, 0, 0, 0, 0 })
	putIp(arp, 24, ISP_IP)
	return ethernet({ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, GUEST_MAC, 0x0806, arp)
end

T("machine_ne2000_attach_and_par", function(expect)
	const m = fresh()
	expect(m.ne2000 ~= nil, "machine.ne2000 missing")
	expect(m.isp ~= nil, "machine.isp missing")
	if not m.ne2000 or not m.isp then
		return
	end
	expect(m.ne2000.base == 0x300, ("base=%04X"):format(m.ne2000.base))
	expect(m.ne2000.irq == 10, ("irq=%d"):format(m.ne2000.irq))
	expect(m.ne2000:macString() == "52:54:00:AA:BB:CC", "MAC=" .. m.ne2000:macString())
	expect(m.isp:ipString() == "10.0.2.2", "ISP IP=" .. m.isp:ipString())
	expect(m.isp:macString() == "52:54:00:12:34:56", "ISP MAC=" .. m.isp:macString())
	expect(m.isp.nic == m.ne2000, "ISP not attached to machine NIC")

	ioOut8(m, 0x300, 0x40) -- page 1
	const par = {
		ioIn8(m, 0x301),
		ioIn8(m, 0x302),
		ioIn8(m, 0x303),
		ioIn8(m, 0x304),
		ioIn8(m, 0x305),
		ioIn8(m, 0x306),
	}
	expect(
		par[1] == 0x52 and par[2] == 0x54 and par[3] == 0x00 and par[6] == 0xCC,
		table.concat(par, ":")
	)
end)

T("machine_irq10_pic_and_isr_clear", function(expect)
	const m = fresh()
	expect(m.ne2000 ~= nil and m.pic ~= nil, "network/PIC missing")
	if not m.ne2000 or not m.pic then
		return
	end
	ioOut8(m, 0x30F, 0x01) -- IMR: RX
	const frame = buffer.create(60)
	for index = 0, 59 do
		buffer.writeu8(frame, index, index + 1)
	end
	expect(m.ne2000:receive(frame), "receive rejected")
	expect(m.ne2000:irqPending(), "RX IRQ not pending")

	-- Unmask the cascade and IRQ10 so the PIC can deliver vector 0x72.
	m.pic.master.imr = 0
	m.pic.slave.imr = 0
	m.cpu.halted = true
	m.cpu.flags = bor(band(m.cpu.flags, 0xFFFF), 0x202)
	m.cpu.ss = 0
	m.cpu:setSP(0x7000)
	m:run(1)

	expect(m.irqCount == 1, "irqCount=" .. m.irqCount)
	expect(band(m.pic.slave.isr, 0x04) ~= 0, "IRQ10 not in service")
	expect(band(m.pic.master.isr, 0x04) ~= 0, "cascade not in service")

	ioOut8(m, 0x307, 0x01) -- clear NIC RX ISR
	expect(not m.ne2000:irqPending(), "NIC ISR did not clear")
	expect(not m.ne2000:takeIrq(), "NIC IRQ line still asserted")
	ioOut8(m, 0xA0, 0x20) -- slave EOI
	ioOut8(m, 0x20, 0x20) -- master EOI
	expect(m.pic.slave.isr == 0 and m.pic.master.isr == 0, "PIC ISR did not clear")
end)

T("machine_arp_round_trip_through_ports", function(expect)
	const m = fresh()
	if not m.ne2000 or not m.isp then
		expect(false, "network missing")
		return
	end
	ioOut8(m, 0x30F, 0x01) -- IMR: RX

	const request = arpRequestFrame()
	remoteWrite(m, 0x4000, request)
	ioOut8(m, 0x304, 0x40) -- TPSR
	ioOut8(m, 0x305, band(buffer.len(request), 0xFF))
	ioOut8(m, 0x306, band(rshift(buffer.len(request), 8), 0xFF))
	ioOut8(m, 0x300, 0x24) -- NODMA | TXP; Isp receives and queues the reply

	expect(m.ne2000:irqPending(), "ARP reply did not raise RX IRQ")
	const header = remoteRead(m, 0x4600, 4)
	expect(buffer.readu8(header, 0) == 0x01, "RX status=" .. buffer.readu8(header, 0))
	const length = buffer.readu8(header, 2) + buffer.readu8(header, 3) * 256
	expect(length == 42, "ARP reply length=" .. length)
	const reply = remoteRead(m, 0x4604, 42)
	expect(read16(reply, 12) == 0x0806, "reply ethertype")
	expect(read16(reply, 14 + 6) == 2, "ARP op")
	expect(buffer.readu8(reply, 14 + 8) == ISP_MAC[1], "ARP sender MAC")
	expect(readIp(reply, 14 + 24)[4] == GUEST_IP[4], "ARP target IP")
end)

T("machine_network_can_be_disabled", function(expect)
	const m = Machine.new({
		Memory = Memory,
		Cpu = Cpu,
		Ne2000 = Ne2000,
		Isp = Isp,
	}, {
		memorySize = 16 * 1024 * 1024,
		cpu = { cpuLevel = "486" },
		network = { enabled = false },
	})
	expect(m.ne2000 == nil, "disabled network created a NIC")
	expect(m.isp == nil, "disabled network created an ISP")
end)

return TESTS
