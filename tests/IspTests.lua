--!nonstrict
-- IspTests.lua -- ARP, ICMP, DHCP and DNS over a synthetic NE2000 link.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift
const Isp = require("../core/Isp")
const Ne2000 = require("../core/Ne2000")

const TESTS = {}
const GUEST_MAC = { 0x52, 0x54, 0x00, 0xAA, 0xBB, 0xCC }
const GUEST_IP = { 10, 0, 2, 15 }
const SERVER_IP = { 10, 0, 2, 2 }
const ISP_MAC = { 0x52, 0x54, 0x00, 0x12, 0x34, 0x56 }
const TCP_FIN = 0x01
const TCP_SYN = 0x02
const TCP_RST = 0x04
const TCP_PSH = 0x08
const TCP_ACK = 0x10

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

local function fresh(config)
	const output = {}
	const isp = Isp.new(config or { mac = "52:54:00:12:34:56", ip = "10.0.2.2" })
	isp:attach({
		receive = function(_nic, frame)
			output[#output + 1] = frame
		end,
	})
	return isp, output
end

local function read32(buf, offset)
	return bor(
		lshift(buffer.readu8(buf, offset), 24),
		lshift(buffer.readu8(buf, offset + 1), 16),
		lshift(buffer.readu8(buf, offset + 2), 8),
		buffer.readu8(buf, offset + 3)
	)
end

local function bufferString(buf)
	local chars = table.create(buffer.len(buf))
	for index = 1, buffer.len(buf) do
		chars[index] = string.char(buffer.readu8(buf, index - 1))
	end
	return table.concat(chars)
end

local function tcpChecksum(srcIp, dstIp, segment)
	const pseudo = buffer.create(12 + buffer.len(segment))
	putIp(pseudo, 0, srcIp)
	putIp(pseudo, 4, dstIp)
	buffer.writeu8(pseudo, 8, 0)
	buffer.writeu8(pseudo, 9, 6)
	be16(pseudo, 10, buffer.len(segment))
	buffer.copy(pseudo, 12, segment, 0, buffer.len(segment))
	return checksum(pseudo, 0, buffer.len(pseudo))
end

local function tcpSegment(srcPort, dstPort, seq, ack, flags, payload, window)
	const segment = buffer.create(20 + buffer.len(payload or buffer.create(0)))
	be16(segment, 0, srcPort)
	be16(segment, 2, dstPort)
	be32(segment, 4, seq)
	be32(segment, 8, ack)
	buffer.writeu8(segment, 12, 0x50)
	buffer.writeu8(segment, 13, flags)
	be16(segment, 14, window or 0xFFFF)
	be16(segment, 16, 0)
	be16(segment, 18, 0)
	if payload then
		buffer.copy(segment, 20, payload, 0, buffer.len(payload))
	end
	return segment
end

local function sendTcp(isp, srcPort, dstPort, seq, ack, flags, payload)
	const segment = tcpSegment(srcPort, dstPort, seq, ack, flags, payload, 0xFFFF)
	be16(segment, 16, tcpChecksum(GUEST_IP, SERVER_IP, segment))
	const packet = ipv4(GUEST_IP, SERVER_IP, 6, segment)
	isp:receive(ethernet(ISP_MAC, GUEST_MAC, 0x0800, packet))
end

local function parseTcp(frame)
	const ipOffset = 14
	const headerLength = band(buffer.readu8(frame, ipOffset), 0x0F) * 4
	const tcpOffset = ipOffset + headerLength
	const totalLength = read16(frame, ipOffset + 2)
	const dataOffset = rshift(buffer.readu8(frame, tcpOffset + 12), 4) * 4
	const payloadLength = totalLength - headerLength - dataOffset
	const payload = buffer.create(payloadLength)
	if payloadLength > 0 then
		buffer.copy(payload, 0, frame, tcpOffset + dataOffset, payloadLength)
	end
	const segment = buffer.create(totalLength - headerLength)
	buffer.copy(segment, 0, frame, tcpOffset, totalLength - headerLength)
	return {
		srcPort = read16(frame, tcpOffset),
		dstPort = read16(frame, tcpOffset + 2),
		seq = read32(frame, tcpOffset + 4),
		ack = read32(frame, tcpOffset + 8),
		flags = buffer.readu8(frame, tcpOffset + 13),
		window = read16(frame, tcpOffset + 14),
		payload = payload,
		text = bufferString(payload),
		checksumOk = tcpChecksum(SERVER_IP, GUEST_IP, segment) == 0,
	}
end

local function tcpKey(guestPort, serverPort)
	return ("10.0.2.15:%d->10.0.2.2:%d"):format(guestPort, serverPort or 80)
end

local function handshake(isp, output, guestPort)
	sendTcp(isp, guestPort, 80, 0x1000, 0, TCP_SYN, nil)
	const synAck = parseTcp(output[#output])
	const serverSeq = synAck.seq
	const guestNext = synAck.ack
	sendTcp(isp, guestPort, 80, guestNext, serverSeq + 1, TCP_ACK, nil)
	return {
		guestPort = guestPort,
		serverSeq = serverSeq,
		guestNext = guestNext,
		serverNext = serverSeq + 1,
	}
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

T("tcp_checksum_round_trip", function(expect)
	const segment =
		tcpSegment(1234, 80, 0x11223344, 0x55667788, TCP_ACK, buffer.fromstring("hello"), 8192)
	const sum = tcpChecksum(GUEST_IP, SERVER_IP, segment)
	expect(sum ~= 0, "checksum was zero")
	be16(segment, 16, sum)
	expect(tcpChecksum(GUEST_IP, SERVER_IP, segment) == 0, "checksum did not validate")
end)

T("tcp_syn_synack_ack_handshake", function(expect)
	const isp, output = fresh()
	sendTcp(isp, 40000, 80, 0x1000, 0, TCP_SYN, nil)
	expect(#output == 1, "no SYN-ACK")
	const synAck = parseTcp(output[1])
	expect(band(synAck.flags, TCP_SYN) ~= 0 and band(synAck.flags, TCP_ACK) ~= 0, "SYN-ACK flags")
	expect(synAck.srcPort == 80 and synAck.dstPort == 40000, "SYN-ACK ports")
	expect(synAck.ack == 0x1001, string.format("SYN-ACK ack=%X", synAck.ack))
	expect(synAck.checksumOk, "SYN-ACK checksum")
	const conn = isp.tcp[tcpKey(40000)]
	expect(conn ~= nil and conn.state == "syn_received", "connection not SYN_RECEIVED")
	expect(conn.rcvNxt == 0x1001, string.format("rcvNxt=%X", conn.rcvNxt))
	expect(conn.sndNxt == synAck.seq + 1, "server sequence after SYN")

	sendTcp(isp, 40000, 80, 0x1001, synAck.seq + 1, TCP_ACK, nil)
	expect(#output == 1, "ACK produced an unexpected response")
	expect(conn.state == "established", "connection not ESTABLISHED")
	expect(conn.sndUna == synAck.seq + 1, "sndUna did not advance")
end)

T("http_get_root_and_fin", function(expect)
	const isp, output = fresh({
		mac = "52:54:00:12:34:56",
		ip = "10.0.2.2",
		httpBody = "<html>TCP OK</html>",
	})
	const hs = handshake(isp, output, 40100)
	const request = "GET / HTTP/1.0\r\nHost: rvpc.local\r\n\r\n"
	const base = #output
	sendTcp(
		isp,
		40100,
		80,
		hs.guestNext,
		hs.serverNext,
		bor(TCP_ACK, TCP_PSH),
		buffer.fromstring(request)
	)
	expect(#output == base + 2, "expected response and FIN, got " .. (#output - base))
	const response = parseTcp(output[base + 1])
	const fin = parseTcp(output[base + 2])
	expect(band(response.flags, TCP_ACK) ~= 0, "response missing ACK")
	expect(band(response.flags, TCP_PSH) ~= 0, "response missing PSH")
	expect(response.checksumOk, "response checksum")
	const divider = string.find(response.text, "\r\n\r\n", 1, true)
	expect(divider ~= nil, "response missing header divider")
	const body = if divider then string.sub(response.text, divider + 4) else ""
	expect(string.find(response.text, "HTTP/1.0 200 OK", 1, true) ~= nil, "response status")
	expect(
		string.find(response.text, "Content-Length: " .. #body, 1, true) ~= nil,
		"Content-Length"
	)
	expect(string.find(response.text, "Connection: close", 1, true) ~= nil, "Connection header")
	expect(body == "<html>TCP OK</html>", "response body=" .. body)
	expect(band(fin.flags, TCP_FIN) ~= 0 and band(fin.flags, TCP_ACK) ~= 0, "FIN flags")
	expect(fin.checksumOk, "FIN checksum")
	expect(fin.seq == response.seq + buffer.len(response.payload), "FIN sequence")
	expect(fin.ack == hs.guestNext + #request, "FIN ack")
	const conn = isp.tcp[tcpKey(40100)]
	expect(conn.state == "fin_wait", "server did not enter FIN_WAIT")

	const outputCount = #output
	sendTcp(isp, 40100, 80, hs.guestNext + #request, fin.seq + 1, TCP_ACK, nil)
	expect(conn.state == "time_wait", "server did not enter TIME_WAIT")
	expect(#output == outputCount, "TIME_WAIT ACK produced output")
end)

T("http_get_missing_returns_404", function(expect)
	const isp, output = fresh()
	const hs = handshake(isp, output, 40101)
	const base = #output
	sendTcp(
		isp,
		40101,
		80,
		hs.guestNext,
		hs.serverNext,
		bor(TCP_ACK, TCP_PSH),
		buffer.fromstring("GET /missing HTTP/1.0\r\n\r\n")
	)
	expect(#output == base + 2, "missing response/FIN count")
	const response = parseTcp(output[base + 1])
	expect(string.find(response.text, "HTTP/1.0 404 Not Found", 1, true) ~= nil, "404 status")
	expect(string.sub(response.text, -9) == "Not Found", "404 body")
	expect(band(parseTcp(output[base + 2]).flags, TCP_FIN) ~= 0, "404 FIN")
end)

T("http_custom_handler", function(expect)
	const isp, output = fresh()
	isp:setHttpHandler(function(request)
		return { status = 200, body = "handler:" .. request.path, contentType = "text/plain" }
	end)
	const hs = handshake(isp, output, 40102)
	const base = #output
	sendTcp(
		isp,
		40102,
		80,
		hs.guestNext,
		hs.serverNext,
		bor(TCP_ACK, TCP_PSH),
		buffer.fromstring("GET /custom HTTP/1.0\r\n\r\n")
	)
	const response = parseTcp(output[base + 1])
	expect(string.find(response.text, "200 OK", 1, true) ~= nil, "custom status")
	expect(
		string.sub(response.text, -15) == "handler:/custom",
		"custom body=" .. string.sub(response.text, -15)
	)
	expect(
		string.find(response.text, "Content-Type: text/plain", 1, true) ~= nil,
		"custom content type"
	)
end)

T("tcp_sequence_wrap", function(expect)
	const isp, output = fresh({
		mac = "52:54:00:12:34:56",
		ip = "10.0.2.2",
		httpBody = "wrap",
	})
	sendTcp(isp, 40105, 80, 0xFFFFFFF0, 0, TCP_SYN, nil)
	const synAck = parseTcp(output[#output])
	expect(synAck.ack == 0xFFFFFFF1, string.format("wrap SYN-ACK ack=%X", synAck.ack))
	sendTcp(isp, 40105, 80, 0xFFFFFFF1, synAck.seq + 1, TCP_ACK, nil)
	const request = "GET / HTTP/1.0\r\n\r\n"
	const base = #output
	sendTcp(
		isp,
		40105,
		80,
		0xFFFFFFF1,
		synAck.seq + 1,
		bor(TCP_ACK, TCP_PSH),
		buffer.fromstring(request)
	)
	expect(#output == base + 2, "wrap response/FIN count")
	const response = parseTcp(output[base + 1])
	expect(
		response.ack == band(0xFFFFFFF1 + #request, 0xFFFFFFFF),
		string.format("wrap response ack=%X", response.ack)
	)
	expect(string.sub(response.text, -4) == "wrap", "wrap body")
end)

T("tcp_client_fin_handshake", function(expect)
	const isp, output = fresh()
	const hs = handshake(isp, output, 40106)
	const conn = isp.tcp[tcpKey(40106)]
	const base = #output
	sendTcp(isp, 40106, 80, hs.guestNext, hs.serverNext, bor(TCP_ACK, TCP_FIN), nil)
	expect(#output == base + 2, "client FIN did not produce ACK and FIN")
	const ack = parseTcp(output[base + 1])
	const fin = parseTcp(output[base + 2])
	expect(band(ack.flags, TCP_ACK) ~= 0 and buffer.len(ack.payload) == 0, "FIN ACK")
	expect(band(fin.flags, TCP_FIN) ~= 0, "server FIN missing")
	expect(fin.ack == hs.guestNext + 1, string.format("server FIN ack=%X", fin.ack))
	expect(conn.state == "last_ack", "connection not LAST_ACK")
	sendTcp(isp, 40106, 80, hs.guestNext + 1, fin.seq + 1, TCP_ACK, nil)
	expect(conn.state == "closed", "connection not CLOSED")
end)

T("tcp_unknown_port_syn_gets_rst", function(expect)
	const isp, output = fresh()
	sendTcp(isp, 40103, 81, 0x2000, 0, TCP_SYN, nil)
	expect(#output == 1, "no RST for unknown port")
	const rst = parseTcp(output[1])
	expect(band(rst.flags, TCP_RST) ~= 0, "RST flag missing")
	expect(band(rst.flags, TCP_ACK) ~= 0, "RST missing ACK")
	expect(rst.ack == 0x2001, string.format("RST ack=%X", rst.ack))
	expect(next(isp.tcp) == nil, "unknown-port SYN created a connection")
end)

T("tcp_data_ack_duplicate_and_out_of_order", function(expect)
	const isp, output = fresh({
		mac = "52:54:00:12:34:56",
		ip = "10.0.2.2",
		httpBody = "ordered",
	})
	const hs = handshake(isp, output, 40104)
	const key = tcpKey(40104)
	const conn = isp.tcp[key]
	const first = "GET / HTTP/1.0\r\nHost: "
	const rest = "rvpc.local\r\n\r\n"
	const base = #output

	sendTcp(
		isp,
		40104,
		80,
		hs.guestNext,
		hs.serverNext,
		bor(TCP_ACK, TCP_PSH),
		buffer.fromstring(first)
	)
	expect(#output == base + 1, "first data segment not ACKed")
	const firstAck = parseTcp(output[base + 1])
	expect(firstAck.ack == hs.guestNext + #first, string.format("first ACK=%X", firstAck.ack))
	expect(conn.requestText == first, "first segment not buffered")

	sendTcp(
		isp,
		40104,
		80,
		hs.guestNext,
		hs.serverNext,
		bor(TCP_ACK, TCP_PSH),
		buffer.fromstring(first)
	)
	expect(#output == base + 2, "duplicate segment not ACKed")
	const duplicateAck = parseTcp(output[base + 2])
	expect(duplicateAck.ack == hs.guestNext + #first, "duplicate ACK advanced")
	expect(conn.requestText == first, "duplicate segment corrupted request")

	sendTcp(
		isp,
		40104,
		80,
		hs.guestNext + #first + 5,
		hs.serverNext,
		bor(TCP_ACK, TCP_PSH),
		buffer.fromstring(rest)
	)
	expect(#output == base + 3, "out-of-order segment not ACKed")
	const outOfOrderAck = parseTcp(output[base + 3])
	expect(outOfOrderAck.ack == hs.guestNext + #first, "out-of-order ACK advanced")
	expect(conn.requestText == first, "out-of-order segment corrupted request")

	sendTcp(
		isp,
		40104,
		80,
		hs.guestNext + #first,
		hs.serverNext,
		bor(TCP_ACK, TCP_PSH),
		buffer.fromstring(rest)
	)
	expect(#output == base + 5, "completed request did not produce response/FIN")
	const response = parseTcp(output[base + 4])
	expect(
		string.sub(response.text, -7) == "ordered",
		"ordered body=" .. string.sub(response.text, -7)
	)
	expect(conn.rcvNxt == hs.guestNext + #first + #rest, "rcvNxt did not advance")
end)

return TESTS
