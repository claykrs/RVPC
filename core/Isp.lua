--!strict
-- Isp.lua -- small host-side ISP for the NE2000 link.
--
-- The ISP terminates Ethernet/ARP, IPv4, ICMP echo, DHCP and DNS for a private
-- 10.0.2.0/24 network. It has no Roblox or host socket dependency: attach() a
-- NE2000 and it consumes transmitted frames and injects replies.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const Isp = {}
Isp.__index = Isp

const ETH_ARP = 0x0806
const ETH_IPV4 = 0x0800
const IP_ICMP = 1
const IP_UDP = 17
const IP_TCP = 6

export type Config = {
	mac: string?,
	ip: string?,
	netmask: string?,
	dns: string?,
	clientIp: string?,
	hostname: string?,
}

type Ip = { number }
type Mac = { number }

export type Isp = typeof(setmetatable(
	{} :: {
		mac: Mac,
		ip: Ip,
		netmask: Ip,
		dns: Ip,
		clientIp: Ip,
		hostname: string,
		nic: any,
		arp: { [string]: Mac },
		nextId: number,
		new: (config: Config?) -> Isp,
		attach: (self: Isp, nic: any) -> (),
		receive: (self: Isp, frame: buffer) -> (),
		macString: (self: Isp) -> string,
		ipString: (self: Isp) -> string,
	},
	Isp
))

local function parseMac(text: string?): Mac
	const source = text or "52:54:00:12:34:56"
	const out: Mac = { 0x52, 0x54, 0, 0x12, 0x34, 0x56 }
	local index = 0
	for part in string.gmatch(source, "[^:%-]+") do
		if index < 6 then
			out[index + 1] = band(tonumber(part, 16) or 0, 0xFF)
			index += 1
		end
	end
	return out
end

local function macString(mac: Mac): string
	return string.format(
		"%02X:%02X:%02X:%02X:%02X:%02X",
		mac[1],
		mac[2],
		mac[3],
		mac[4],
		mac[5],
		mac[6]
	)
end

local function parseIp(text: string?): Ip
	const source = text or "10.0.2.2"
	const out: Ip = { 10, 0, 2, 2 }
	local index = 0
	for part in string.gmatch(source, "%d+") do
		if index < 4 then
			out[index + 1] = band(tonumber(part) or 0, 0xFF)
			index += 1
		end
	end
	return out
end

local function ipString(ip: Ip): string
	return ("%d.%d.%d.%d"):format(ip[1], ip[2], ip[3], ip[4])
end

local function sameIp(a: Ip, b: Ip): boolean
	return a[1] == b[1] and a[2] == b[2] and a[3] == b[3] and a[4] == b[4]
end

local function sameMac(a: Mac, b: Mac): boolean
	for index = 1, 6 do
		if a[index] ~= b[index] then
			return false
		end
	end
	return true
end

local function readMac(buf: buffer, offset: number): Mac
	return {
		buffer.readu8(buf, offset),
		buffer.readu8(buf, offset + 1),
		buffer.readu8(buf, offset + 2),
		buffer.readu8(buf, offset + 3),
		buffer.readu8(buf, offset + 4),
		buffer.readu8(buf, offset + 5),
	}
end

local function writeMac(buf: buffer, offset: number, mac: Mac)
	for index = 1, 6 do
		buffer.writeu8(buf, offset + index - 1, mac[index])
	end
end

local function readIp(buf: buffer, offset: number): Ip
	return {
		buffer.readu8(buf, offset),
		buffer.readu8(buf, offset + 1),
		buffer.readu8(buf, offset + 2),
		buffer.readu8(buf, offset + 3),
	}
end

local function writeIp(buf: buffer, offset: number, ip: Ip)
	for index = 1, 4 do
		buffer.writeu8(buf, offset + index - 1, ip[index])
	end
end

local function readBE16(buf: buffer, offset: number): number
	return bor(lshift(buffer.readu8(buf, offset), 8), buffer.readu8(buf, offset + 1))
end

local function writeBE16(buf: buffer, offset: number, value: number)
	buffer.writeu8(buf, offset, band(rshift(value, 8), 0xFF))
	buffer.writeu8(buf, offset + 1, band(value, 0xFF))
end

local function readBE32(buf: buffer, offset: number): number
	return bor(
		lshift(buffer.readu8(buf, offset), 24),
		lshift(buffer.readu8(buf, offset + 1), 16),
		lshift(buffer.readu8(buf, offset + 2), 8),
		buffer.readu8(buf, offset + 3)
	)
end

local function writeBE32(buf: buffer, offset: number, value: number)
	buffer.writeu8(buf, offset, band(rshift(value, 24), 0xFF))
	buffer.writeu8(buf, offset + 1, band(rshift(value, 16), 0xFF))
	buffer.writeu8(buf, offset + 2, band(rshift(value, 8), 0xFF))
	buffer.writeu8(buf, offset + 3, band(value, 0xFF))
end

local function checksum(buf: buffer, offset: number, length: number): number
	local sum = 0
	local index = 0
	while index + 1 < length do
		sum += readBE16(buf, offset + index)
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

local function broadcastMac(): Mac
	return { 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF }
end

function Isp.new(config: Config?): Isp
	const cfg: Config = config or {}
	const self = setmetatable({}, Isp) :: any
	self.mac = parseMac(cfg.mac)
	self.ip = parseIp(cfg.ip)
	self.netmask = parseIp(cfg.netmask or "255.255.255.0")
	self.dns = parseIp(cfg.dns or "10.0.2.3")
	self.clientIp = parseIp(cfg.clientIp or "10.0.2.15")
	self.hostname = cfg.hostname or "rvpc.local"
	self.nic = nil
	self.arp = {
		[ipString(self.ip)] = self.mac,
		[ipString(self.dns)] = self.mac,
		["10.0.2.80"] = self.mac,
	}
	self.nextId = 1
	return self
end

function Isp.macString(self: Isp): string
	return macString(self.mac)
end

function Isp.ipString(self: Isp): string
	return ipString(self.ip)
end

-- Attach a device with `receive(frame)` (NE2000) and consume its transmit
-- callback. The callback signature is device.transmit(frame).
function Isp.attach(self: Isp, nic: any)
	self.nic = nic
	nic.transmit = function(frame: buffer)
		self:receive(frame)
	end
end

local function sendEther(self: Isp, dest: Mac, etherType: number, payload: buffer)
	if not self.nic then
		return
	end
	const frame = buffer.create(14 + buffer.len(payload))
	writeMac(frame, 0, dest)
	writeMac(frame, 6, self.mac)
	writeBE16(frame, 12, etherType)
	buffer.copy(frame, 14, payload, 0, buffer.len(payload))
	self.nic:receive(frame)
end

local function sendIpv4(self: Isp, destMac: Mac, destIp: Ip, protocol: number, payload: buffer)
	const total = 20 + buffer.len(payload)
	const packet = buffer.create(total)
	buffer.writeu8(packet, 0, 0x45)
	buffer.writeu8(packet, 1, 0)
	writeBE16(packet, 2, total)
	writeBE16(packet, 4, self.nextId)
	self.nextId = band(self.nextId + 1, 0xFFFF)
	writeBE16(packet, 6, 0x4000)
	buffer.writeu8(packet, 8, 64)
	buffer.writeu8(packet, 9, protocol)
	writeIp(packet, 12, self.ip)
	writeIp(packet, 16, destIp)
	writeBE16(packet, 10, 0)
	writeBE16(packet, 10, checksum(packet, 0, 20))
	buffer.copy(packet, 20, payload, 0, buffer.len(payload))
	sendEther(self, destMac, ETH_IPV4, packet)
end

local function sendUdp(
	self: Isp,
	destMac: Mac,
	destIp: Ip,
	srcPort: number,
	dstPort: number,
	payload: buffer
)
	const udp = buffer.create(8 + buffer.len(payload))
	writeBE16(udp, 0, srcPort)
	writeBE16(udp, 2, dstPort)
	writeBE16(udp, 4, 8 + buffer.len(payload))
	writeBE16(udp, 6, 0)
	buffer.copy(udp, 8, payload, 0, buffer.len(payload))
	sendIpv4(self, destMac, destIp, IP_UDP, udp)
end

local function handleArp(self: Isp, frame: buffer)
	if buffer.len(frame) < 42 then
		return
	end
	const payload = 14
	const op = readBE16(frame, payload + 6)
	const senderMac = readMac(frame, payload + 8)
	const senderIp = readIp(frame, payload + 14)
	const targetIp = readIp(frame, payload + 24)
	self.arp[ipString(senderIp)] = senderMac
	if op ~= 1 or not sameIp(targetIp, self.ip) then
		return
	end
	const reply = buffer.create(28)
	writeBE16(reply, 0, 1)
	writeBE16(reply, 2, ETH_IPV4)
	buffer.writeu8(reply, 4, 6)
	buffer.writeu8(reply, 5, 4)
	writeBE16(reply, 6, 2)
	writeMac(reply, 8, self.mac)
	writeIp(reply, 14, self.ip)
	writeMac(reply, 18, senderMac)
	writeIp(reply, 24, senderIp)
	sendEther(self, senderMac, ETH_ARP, reply)
end

local function handleIcmp(self: Isp, srcMac: Mac, srcIp: Ip, payload: buffer)
	if buffer.len(payload) < 8 or buffer.readu8(payload, 0) ~= 8 then
		return
	end
	const reply = buffer.create(buffer.len(payload))
	buffer.copy(reply, 0, payload, 0, buffer.len(payload))
	buffer.writeu8(reply, 0, 0)
	buffer.writeu8(reply, 1, 0)
	writeBE16(reply, 2, 0)
	writeBE16(reply, 2, checksum(reply, 0, buffer.len(reply)))
	sendIpv4(self, srcMac, srcIp, IP_ICMP, reply)
end

local function dhcpReply(self: Isp, srcMac: Mac, payload: buffer, messageType: number)
	if buffer.len(payload) < 240 then
		return
	end
	const xid = readBE32(payload, 4)
	const flags = readBE16(payload, 10)
	const clientMac = readMac(payload, 28)
	const reply = buffer.create(300)
	buffer.writeu8(reply, 0, 2)
	buffer.writeu8(reply, 1, 1)
	buffer.writeu8(reply, 2, 6)
	buffer.writeu8(reply, 3, 0)
	writeBE32(reply, 4, xid)
	writeBE16(reply, 8, 0)
	writeBE16(reply, 10, flags)
	writeIp(reply, 12, { 0, 0, 0, 0 })
	writeIp(reply, 16, self.clientIp)
	writeIp(reply, 20, self.ip)
	writeIp(reply, 24, { 0, 0, 0, 0 })
	writeMac(reply, 28, clientMac)
	writeBE32(reply, 236, 0x63825363)
	local offset = 240
	local function option(code: number, value: string)
		buffer.writeu8(reply, offset, code)
		buffer.writeu8(reply, offset + 1, #value)
		for index = 1, #value do
			buffer.writeu8(reply, offset + 1 + index, string.byte(value, index) :: number)
		end
		offset += 2 + #value
	end
	option(53, string.char(messageType))
	option(54, string.char(self.ip[1], self.ip[2], self.ip[3], self.ip[4]))
	option(51, string.char(0, 0, 0x0E, 0x10))
	option(1, string.char(self.netmask[1], self.netmask[2], self.netmask[3], self.netmask[4]))
	option(3, string.char(self.ip[1], self.ip[2], self.ip[3], self.ip[4]))
	option(6, string.char(self.dns[1], self.dns[2], self.dns[3], self.dns[4]))
	option(15, self.hostname)
	buffer.writeu8(reply, offset, 0)
	offset += 1
	const out = buffer.create(offset)
	buffer.copy(out, 0, reply, 0, offset)
	sendUdp(self, srcMac, { 255, 255, 255, 255 }, 67, 68, out)
end

local function handleDhcp(self: Isp, srcMac: Mac, payload: buffer)
	if buffer.len(payload) < 240 or buffer.readu8(payload, 0) ~= 1 then
		return
	end
	local messageType = 0
	local offset = 240
	while offset < buffer.len(payload) do
		const code = buffer.readu8(payload, offset)
		if code == 0 then
			break
		end
		const length = buffer.readu8(payload, offset + 1)
		if code == 53 and length >= 1 then
			messageType = buffer.readu8(payload, offset + 2)
			break
		end
		offset += 2 + length
	end
	if messageType == 1 then
		dhcpReply(self, srcMac, payload, 2) -- OFFER
	elseif messageType == 3 then
		dhcpReply(self, srcMac, payload, 5) -- ACK
	end
end

local function readDnsName(buf: buffer, offset: number): (string, number)
	local labels: { string } = {}
	local cursor = offset
	while cursor < buffer.len(buf) do
		const length = buffer.readu8(buf, cursor)
		if length == 0 then
			cursor += 1
			break
		end
		if band(length, 0xC0) == 0xC0 then
			cursor += 2
			break
		end
		if cursor + 1 + length > buffer.len(buf) then
			break
		end
		local label = ""
		for index = 1, length do
			label ..= string.char(buffer.readu8(buf, cursor + index))
		end
		labels[#labels + 1] = label
		cursor += 1 + length
	end
	return table.concat(labels, "."), cursor
end

local function handleDns(self: Isp, srcMac: Mac, srcIp: Ip, srcPort: number, payload: buffer)
	if buffer.len(payload) < 12 then
		return
	end
	const question, questionEnd = readDnsName(payload, 12)
	if question == "" or questionEnd + 4 > buffer.len(payload) then
		return
	end
	const qtype = readBE16(payload, questionEnd)
	if qtype ~= 1 then
		return
	end
	const answerStart = questionEnd + 4
	const answer = buffer.create(answerStart + 16)
	buffer.copy(answer, 0, payload, 0, answerStart)
	writeBE16(answer, 2, 0x8180)
	writeBE16(answer, 4, 1)
	writeBE16(answer, 6, 1)
	writeBE16(answer, 8, 0)
	writeBE16(answer, 10, 0)
	buffer.writeu8(answer, answerStart, 0xC0)
	buffer.writeu8(answer, answerStart + 1, 0x0C)
	writeBE16(answer, answerStart + 2, 1)
	writeBE16(answer, answerStart + 4, 1)
	writeBE32(answer, answerStart + 6, 60)
	writeBE16(answer, answerStart + 10, 4)
	writeIp(answer, answerStart + 12, { 10, 0, 2, 80 })
	sendUdp(self, srcMac, srcIp, 53, srcPort, answer)
end

local function handleIpv4(self: Isp, frame: buffer)
	if buffer.len(frame) < 34 then
		return
	end
	const offset = 14
	const version = band(buffer.readu8(frame, offset), 0xF0)
	if version ~= 0x40 then
		return
	end
	const headerLength = band(buffer.readu8(frame, offset), 0x0F) * 4
	if headerLength < 20 or 14 + headerLength > buffer.len(frame) then
		return
	end
	if checksum(frame, offset, headerLength) ~= 0 then
		return
	end
	const totalLength = readBE16(frame, offset + 2)
	if totalLength < headerLength or 14 + totalLength > buffer.len(frame) then
		return
	end
	const protocol = buffer.readu8(frame, offset + 9)
	const srcIp = readIp(frame, offset + 12)
	const srcMac = readMac(frame, 6)
	const payload = buffer.create(totalLength - headerLength)
	buffer.copy(payload, 0, frame, offset + headerLength, totalLength - headerLength)
	if protocol == IP_ICMP then
		handleIcmp(self, srcMac, srcIp, payload)
	elseif protocol == IP_UDP then
		if buffer.len(payload) < 8 then
			return
		end
		const srcPort = readBE16(payload, 0)
		const dstPort = readBE16(payload, 2)
		const body = buffer.create(buffer.len(payload) - 8)
		buffer.copy(body, 0, payload, 8, buffer.len(body))
		if dstPort == 67 then
			handleDhcp(self, srcMac, body)
		elseif dstPort == 53 then
			handleDns(self, srcMac, srcIp, srcPort, body)
		end
	elseif protocol == IP_TCP then
		-- TCP is deliberately left to the next network pass.
	end
end

function Isp.receive(self: Isp, frame: buffer)
	if buffer.len(frame) < 14 then
		return
	end
	const dest = readMac(frame, 0)
	if not sameMac(dest, self.mac) and not sameMac(dest, broadcastMac()) then
		return
	end
	const etherType = readBE16(frame, 12)
	if etherType == ETH_ARP then
		handleArp(self, frame)
	elseif etherType == ETH_IPV4 then
		handleIpv4(self, frame)
	end
end

return Isp
