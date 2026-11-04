--!nonstrict
-- IspTests.lua -- ARP, ICMP, DHCP and DNS over a synthetic NE2000 link.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift
const Isp = require("../core/Isp")
const Ne2000 = require("../core/Ne2000")

const TESTS = {}
const GUEST_MAC = { 0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC }
const GUEST_IP = { 10, 0, 2, 15 }

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function be16(buf, offset, value)
	buffer.writeu8(buf, offset, band(rshift(value, 8), 0xFF))
	buffer.writeu8(buf, offset + 1, band(value, 0xFF))
end

local function be32(buf, offset, value)
	buffer.writeu8(buf, offset, band(rshift(value, 24), 0xFF))
	buffer.writeu8(buf, offset + 1, band(rshift(value, 16), 0xFF))
	buffer.writeu8(buf, offset + 2, band(rshift(value, 8), 0xFF))
	buffer.writeu8(buf, offset + 3, band(value, 0xFF))
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

local function checksum(buf, offset, length)
	local sum = 0
	local index = 0
	while index + 1 < length do
		sum += read16(buf, offset + index)
		index += 2
	end
	if index < length then
		sum += lshift(buffer.readu8(buf, offset + index), 8)
	end
	while sum > 0xFFFF do
		sum = band(sum, 0xFFFF) + rshift(sum, 16)
	end
	return band(bit32.bnot(sum), 0xFFFF)
end

local function ethernet(dest, source, etherType, payload)
	const frame = buffer.create(14 + buffer.len(payload))
	putMac(frame, 0, dest)
	putMac(frame, 6, source)
	be16(frame, 12, etherType)
	buffer.copy(frame, 14, payload, 0, buffer.len(payload))
	return frame
end

local function ipv4(source, dest, protocol, payload)
	const packet = buffer.create(20 + buffer.len(payload))
	buffer.writeu8(packet, 0, 0x45)
	be16(packet, 2, 20 + buffer.len(payload))
	be16(packet, 4, 1)
	be16(packet, 6, 0x4000)
	buffer.writeu8(packet, 8, 64)
	buffer.writeu8(packet, 9, protocol)
	putIp(packet, 12, source)
	putIp(packet, 16, dest)
	be16(packet, 10, checksum(packet, 0, 20))
	buffer.copy(packet, 20, payload, 0, buffer.len(payload))
	return packet
end

local function udp(sourcePort, destPort, payload)
	const packet = buffer.create(8 + buffer.len(payload))
	be16(packet, 0, sourcePort)
	be16(packet, 2, destPort)
	be16(packet, 4, 8 + buffer.len(payload))
	be16(packet, 6, 0)
	buffer.copy(packet, 8, payload, 0, buffer.len(payload))
	return packet
end

local function fresh()
	const output = {}
	const isp = Isp.new({ mac = "52:54:00:12:34:56", ip = "10.0.2.2" })
	isp:attach({
		receive = function(_nic, frame)
			output[#output + 1] = frame
		end,
	})
	return isp, output
end

T("arp_request_reply", function(expect)
	const isp, output = fresh()
	const arp = buffer.create(28)
	be16(arp, 0, 1)
	be16(arp, 2, 0x0800)
	buffer.writeu8(arp, 4, 6)
	buffer.writeu8(arp, 5, 4)
	be16(arp, 6, 1)
	putMac(arp, 8, GUEST_MAC)
	putIp(arp, 14, GUEST_IP)
	putMac(arp, 18, { 0, 0, 0, 0, 0, 0 })
	putIp(arp, 24, { 10, 0, 2, 2 })
	const frame = ethernet({ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, GUEST_MAC, 0x0806, arp)
	isp:receive(frame)
	expect(#output == 1, "no ARP reply")
	if #output == 1 then
		const reply = output[1]
		expect(read16(reply, 14 + 6) == 2, "ARP op")
		expect(buffer.readu8(reply, 14 + 8) == 0x52, "sender MAC")
		expect(readIp(reply, 14 + 24)[1] == 10, "target IP")
	end
end)

T("icmp_echo_reply", function(expect)
	const isp, output = fresh()
	const icmp = buffer.create(12)
	buffer.writeu8(icmp, 0, 8)
	buffer.writeu8(icmp, 1, 0)
	be16(icmp, 4, 0x1234)
	be16(icmp, 6, 1)
	for index = 8, 11 do
		buffer.writeu8(icmp, index, index)
	end
	be16(icmp, 2, checksum(icmp, 0, buffer.len(icmp)))
	const packet = ipv4(GUEST_IP, { 10, 0, 2, 2 }, 1, icmp)
	isp:receive(ethernet({ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, GUEST_MAC, 0x0800, packet))
	expect(#output == 1, "no ICMP reply")
	if #output == 1 then
		const reply = output[1]
		expect(buffer.readu8(reply, 34) == 0, "ICMP type")
		expect(read16(reply, 38) == 0x1234, "ICMP id")
		expect(readIp(reply, 26)[1] == 10 and readIp(reply, 26)[2] == 0, "reply source")
	end
end)

T("dhcp_discover_offer", function(expect)
	const isp, output = fresh()
	const bootp = buffer.create(244)
	buffer.writeu8(bootp, 0, 1)
	buffer.writeu8(bootp, 1, 1)
	buffer.writeu8(bootp, 2, 6)
	be32(bootp, 4, 0x12345678)
	be16(bootp, 10, 0x8000)
	putMac(bootp, 28, GUEST_MAC)
	be32(bootp, 236, 0x63825363)
	buffer.writeu8(bootp, 240, 53)
	buffer.writeu8(bootp, 241, 1)
	buffer.writeu8(bootp, 242, 1)
	buffer.writeu8(bootp, 243, 0)
	const packet = ipv4({ 0, 0, 0, 0 }, { 255, 255, 255, 255 }, 17, udp(68, 67, bootp))
	isp:receive(ethernet({ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, GUEST_MAC, 0x0800, packet))
	expect(#output == 1, "no DHCP offer")
	if #output == 1 then
		const reply = output[1]
		expect(readIp(reply, 14 + 20 + 8 + 16)[4] == 15, "yiaddr")
		local found = 0
		local offset = 14 + 20 + 8 + 240
		while offset + 1 < buffer.len(reply) do
			const code = buffer.readu8(reply, offset)
			if code == 0 then
				break
			end
			const length = buffer.readu8(reply, offset + 1)
			if code == 53 and length >= 1 then
				found = buffer.readu8(reply, offset + 2)
			end
			offset += 2 + length
		end
		expect(found == 2, "DHCP message type=" .. found)
	end
end)

T("dns_query_returns_a_record", function(expect)
	const isp, output = fresh()
	const query = buffer.create(29)
	be16(query, 0, 0x4242)
	be16(query, 2, 0x0100)
	be16(query, 4, 1)
	local offset = 12
	for _, label in ipairs({ "rvpc", "local" }) do
		buffer.writeu8(query, offset, #label)
		for index = 1, #label do
			buffer.writeu8(query, offset + index, string.byte(label, index))
		end
		offset += 1 + #label
	end
	buffer.writeu8(query, offset, 0)
	offset += 1
	be16(query, offset, 1)
	be16(query, offset + 2, 1)
	const packet = ipv4(GUEST_IP, { 10, 0, 2, 3 }, 17, udp(1234, 53, query))
	isp:receive(ethernet({ 0x52, 0x54, 0, 0x12, 0x34, 0x56 }, GUEST_MAC, 0x0800, packet))
	expect(#output == 1, "no DNS reply")
	if #output == 1 then
		const reply = output[1]
		expect(read16(reply, 14 + 20 + 8) == 0x4242, "DNS id")
		const answerStart = offset + 4
		const answerIp = readIp(reply, 14 + 20 + 8 + answerStart + 12)
		expect(
			answerIp[1] == 10 and answerIp[2] == 0 and answerIp[3] == 2 and answerIp[4] == 80,
			"DNS A"
		)
	end
end)

T("ne2000_link_arp_round_trip", function(expect)
	const nic = Ne2000.new()
	const isp = Isp.new({ mac = "52:54:00:12:34:56", ip = "10.0.2.2" })
	isp:attach(nic)
	nic:out8(0x30F, 0x01) -- IMR RX
	const arp = buffer.create(28)
	be16(arp, 0, 1)
	be16(arp, 2, 0x0800)
	buffer.writeu8(arp, 4, 6)
	buffer.writeu8(arp, 5, 4)
	be16(arp, 6, 1)
	putMac(arp, 8, GUEST_MAC)
	putIp(arp, 14, GUEST_IP)
	putMac(arp, 18, { 0, 0, 0, 0, 0, 0 })
	putIp(arp, 24, { 10, 0, 2, 2 })
	const frame = ethernet({ 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }, GUEST_MAC, 0x0806, arp)
	buffer.copy(nic.mem, 0x4000, frame, 0, buffer.len(frame))
	nic:out8(0x304, 0x40) -- TPSR
	nic:out8(0x305, band(buffer.len(frame), 0xFF))
	nic:out8(0x306, band(rshift(buffer.len(frame), 8), 0xFF))
	nic:out8(0x300, 0x24) -- NODMA | TXP
	expect(buffer.readu8(nic.mem, 0x4600) == 0x01, "no ARP reply in ring")
	expect(buffer.readu16(nic.mem, 0x4600 + 2) == 42, "reply length")
	expect(nic:irqPending(), "RX IRQ not pending")
end)

return TESTS
