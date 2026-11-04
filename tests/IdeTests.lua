--!nonstrict
-- IdeTests.lua -- ATA PIO, MBR parsing and ATAPI PACKET/READ(10).

const fs = require("@lune/fs")
const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift
const Ide = require("../core/Ide")

const TESTS = {}

-- The live ISO is copyrighted media and is not present in CI. Real-media
-- checks register only when the file exists locally.
local function loadRealIso()
	const path = "media/FD13LIVE.iso"
	local existsOk, exists = pcall(fs.isFile, path)
	if not existsOk or not exists then
		return nil
	end
	local readOk, contents = pcall(fs.readFile, path)
	if not readOk then
		return nil
	end
	return buffer.fromstring(contents)
end

const realIso = loadRealIso()

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function be32(buf, offset)
	return bor(
		lshift(buffer.readu8(buf, offset), 24),
		lshift(buffer.readu8(buf, offset + 1), 16),
		lshift(buffer.readu8(buf, offset + 2), 8),
		buffer.readu8(buf, offset + 3)
	)
end

local function be16(buf, offset)
	return bor(lshift(buffer.readu8(buf, offset), 8), buffer.readu8(buf, offset + 1))
end

local function le16(buf, offset)
	return bor(buffer.readu8(buf, offset), lshift(buffer.readu8(buf, offset + 1), 8))
end

local function le32(buf, offset)
	return bor(
		buffer.readu8(buf, offset),
		lshift(buffer.readu8(buf, offset + 1), 8),
		lshift(buffer.readu8(buf, offset + 2), 16),
		lshift(buffer.readu8(buf, offset + 3), 24)
	)
end

local function expectAscii(expect, buf, offset, text)
	for index = 1, #text do
		const got = buffer.readu8(buf, offset + index - 1)
		const want = string.byte(text, index)
		expect(
			got == want,
			string.format("ASCII at %d: got %02X want %02X", offset + index - 1, got, want)
		)
	end
end

local function compareBytes(expect, label, got, gotOffset, want, wantOffset, count)
	local mismatches = 0
	for index = 0, count - 1 do
		if buffer.readu8(got, gotOffset + index) ~= buffer.readu8(want, wantOffset + index) then
			mismatches += 1
		end
	end
	expect(mismatches == 0, label .. " mismatches=" .. mismatches)
end

local function selectDrive(ide, slave)
	ide:out8(0x1F6, if slave then 0xF0 else 0xE0)
end

local function readWords(ide, count)
	const words = {}
	for index = 1, count do
		words[index] = ide:in16(0x1F0)
	end
	return words
end

local function readBytes(ide, count)
	local out = buffer.create(count)
	local index = 0
	while index + 1 < count do
		buffer.writeu16(out, index, ide:in16(0x1F0))
		index += 2
	end
	if index < count then
		buffer.writeu8(out, index, ide:in8(0x1F0))
	end
	return out
end

local function submitPacket(ide, packet, length)
	for index = 0, (length or 12) - 1, 2 do
		ide:out16(0x1F0, bor(packet[index + 1] or 0, lshift(packet[index + 2] or 0, 8)))
	end
end

local function sendPacket(ide, packet, length)
	selectDrive(ide, true)
	ide:out8(0x1F7, 0xA0)
	submitPacket(ide, packet, length)
	return ide:in8(0x1F7)
end

local function requestSense(ide)
	const status = sendPacket(ide, { 0x03, 0, 0, 0, 18, 0, 0, 0, 0, 0, 0, 0 })
	return status, readBytes(ide, 18)
end

local function readLba(ide, lba, count, opcode)
	local packet = { opcode or 0x28 }
	if opcode == 0x88 then
		for index = 1, 16 do
			packet[index] = 0
		end
		packet[1] = 0x88
		packet[3] = band(rshift(lba, 56), 0xFF)
		packet[4] = band(rshift(lba, 48), 0xFF)
		packet[5] = band(rshift(lba, 40), 0xFF)
		packet[6] = band(rshift(lba, 32), 0xFF)
		packet[7] = band(rshift(lba, 24), 0xFF)
		packet[8] = band(rshift(lba, 16), 0xFF)
		packet[9] = band(rshift(lba, 8), 0xFF)
		packet[10] = band(lba, 0xFF)
		packet[11] = band(rshift(count, 24), 0xFF)
		packet[12] = band(rshift(count, 16), 0xFF)
		packet[13] = band(rshift(count, 8), 0xFF)
		packet[14] = band(count, 0xFF)
		const status = sendPacket(ide, packet, 16)
		return status, readBytes(ide, count * 2048)
	elseif opcode == 0xA8 then
		for index = 1, 12 do
			packet[index] = 0
		end
		packet[1] = 0xA8
		packet[3] = band(rshift(lba, 24), 0xFF)
		packet[4] = band(rshift(lba, 16), 0xFF)
		packet[5] = band(rshift(lba, 8), 0xFF)
		packet[6] = band(lba, 0xFF)
		packet[7] = band(rshift(count, 16), 0xFF)
		packet[8] = band(rshift(count, 8), 0xFF)
		packet[9] = band(count, 0xFF)
		const status = sendPacket(ide, packet)
		return status, readBytes(ide, count * 2048)
	end
	for index = 1, 12 do
		packet[index] = 0
	end
	packet[1] = 0x28
	packet[3] = band(rshift(lba, 24), 0xFF)
	packet[4] = band(rshift(lba, 16), 0xFF)
	packet[5] = band(rshift(lba, 8), 0xFF)
	packet[6] = band(lba, 0xFF)
	packet[8] = band(rshift(count, 8), 0xFF)
	packet[9] = band(count, 0xFF)
	const status = sendPacket(ide, packet)
	return status, readBytes(ide, count * 2048)
end

local function makeHdd()
	local hdd = buffer.create(1024 * 1024)
	buffer.writeu8(hdd, 446, 0x80) -- bootable
	buffer.writeu8(hdd, 446 + 4, 0x06) -- FAT16
	buffer.writeu32(hdd, 446 + 8, 63)
	buffer.writeu32(hdd, 446 + 12, 100)
	buffer.writeu16(hdd, 510, 0xAA55)
	for index = 0, 15 do
		buffer.writeu8(hdd, 63 * 512 + index, 0xA0 + index)
	end
	return hdd
end

local function makeIso()
	local iso = buffer.create(64 * 1024)
	for index = 0, 2047 do
		buffer.writeu8(iso, index, index % 251)
	end
	buffer.writeu8(iso, 0, 0x46) -- 'F'
	buffer.writeu8(iso, 1, 0x52) -- 'R'
	buffer.writeu8(iso, 2, 0x45) -- 'E'
	buffer.writeu8(iso, 3, 0x45) -- 'E'
	return iso
end

T("ata_identify_and_read", function(expect)
	const hdd = makeHdd()
	const ide = Ide.new({ hdd = hdd })
	selectDrive(ide, false)
	ide:out8(0x1F7, 0xEC)
	expect(band(ide:in8(0x1F7), 0x08) ~= 0, "IDENTIFY did not assert DRQ")
	const words = readWords(ide, 256)
	expect(words[1] == 0x0040, string.format("word0=%04X", words[1]))
	expect(words[62] == 0, string.format("LBA high=%04X", words[62]))
	expect(words[61] == 2048, string.format("LBA low=%04X", words[61]))
	expect(words[28] == 0x5256, string.format("model word RV=%04X", words[28]))
	expect(ide:takeIrq(), "IRQ14 not raised")
	selectDrive(ide, false)
	ide:out8(0x1F2, 1)
	ide:out8(0x1F3, 63)
	ide:out8(0x1F4, 0)
	ide:out8(0x1F5, 0)
	ide:out8(0x1F7, 0x20)
	const sector = readBytes(ide, 512)
	expect(buffer.readu8(sector, 0) == 0xA0, "sector marker")
	expect(buffer.readu8(sector, 15) == 0xAF, "sector tail")
end)

T("ata_write_and_flush", function(expect)
	const hdd = makeHdd()
	const ide = Ide.new({ hdd = hdd })
	selectDrive(ide, false)
	ide:out8(0x1F2, 1)
	ide:out8(0x1F3, 100)
	ide:out8(0x1F4, 0)
	ide:out8(0x1F5, 0)
	ide:out8(0x1F7, 0x30)
	for index = 0, 255 do
		ide:out16(0x1F0, 0x5A00 + index)
	end
	expect(buffer.readu16(hdd, 100 * 512) == 0x5A00, "first word")
	expect(buffer.readu16(hdd, 100 * 512 + 510) == 0x5AFF, "last word")
	ide:out8(0x1F7, 0xE7)
	expect(band(ide:in8(0x1F7), 0x40) ~= 0, "not ready after flush")
end)

local function writeSectors(ide, lba, count, firstWord)
	selectDrive(ide, false)
	ide:out8(0x1F2, band(count, 0xFF))
	ide:out8(0x1F3, band(lba, 0xFF))
	ide:out8(0x1F4, band(rshift(lba, 8), 0xFF))
	ide:out8(0x1F5, band(rshift(lba, 16), 0xFF))
	ide:out8(0x1F6, 0xE0)
	ide:out8(0x1F7, 0x30)
	for index = 0, count * 256 - 1 do
		ide:out16(0x1F0, firstWord + index)
	end
end

T("ata_write_dirty_tracking", function(expect)
	const hdd = makeHdd()
	const ide = Ide.new({ hdd = hdd })
	expect(not ide:diskDirty(), "fresh image marked dirty")
	local first, last = ide:dirtySectorRange()
	expect(first == nil and last == nil, "fresh image has a dirty range")

	writeSectors(ide, 100, 1, 0x5A00)
	expect(ide:diskDirty(), "write did not mark the image dirty")
	first, last = ide:dirtySectorRange()
	expect(
		first == 100 and last == 100,
		string.format("range=%s..%s", tostring(first), tostring(last))
	)
	ide:out8(0x1F7, 0xE7)
	expect(ide:diskDirty(), "ATA FLUSH cleared host dirty state")

	writeSectors(ide, 150, 2, 0x6B00)
	first, last = ide:dirtySectorRange()
	expect(
		first == 100 and last == 151,
		string.format("merged range=%s..%s", tostring(first), tostring(last))
	)

	ide:clearDiskDirty()
	expect(not ide:diskDirty(), "clearDiskDirty left the dirty flag set")
	first, last = ide:dirtySectorRange()
	expect(first == nil and last == nil, "clearDiskDirty left a range behind")

	writeSectors(ide, 200, 1, 0x7C00)
	ide:reset()
	expect(ide:diskDirty(), "reset dropped unsaved dirty state")
end)

T("ata_write_rejects_cdrom", function(expect)
	const iso = makeIso()
	const ide = Ide.new({ cdrom = iso })
	const before = buffer.readu8(iso, 0)
	selectDrive(ide, true)
	ide:out8(0x1F2, 1)
	ide:out8(0x1F3, 0)
	ide:out8(0x1F4, 0)
	ide:out8(0x1F5, 0)
	ide:out8(0x1F7, 0x30)
	expect(band(ide:in8(0x1F7), 0x01) ~= 0, "ATA WRITE to CD did not fail")
	expect(not ide:diskDirty(), "CD write marked the disk dirty")
	expect(buffer.readu8(iso, 0) == before, "CD image was mutated by ATA WRITE")
end)

T("ata_identify_32m_geometry", function(expect)
	const hdd = buffer.create(32 * 1024 * 1024)
	const ide = Ide.new({ hdd = hdd })
	selectDrive(ide, false)
	ide:out8(0x1F7, 0xEC)
	expect(band(ide:in8(0x1F7), 0x08) ~= 0, "IDENTIFY did not assert DRQ")
	const words = readWords(ide, 256)
	expect(words[61] == 0 and words[62] == 1, "LBA28 capacity words are not 65536")
	expect(words[2] == 65, "cylinders=" .. words[2])
	expect(words[4] == 16, "heads=" .. words[4])
	expect(words[7] == 63, "sectors/track=" .. words[7])

	-- Last sector of the 32 MiB image exercises the LBA28 register path.
	writeSectors(ide, 65535, 1, 0xBEE0)
	expect(buffer.readu16(hdd, 65535 * 512) == 0xBEE0, "last-sector write")
	local first, last = ide:dirtySectorRange()
	expect(first == 65535 and last == 65535, "last-sector dirty range")

	-- DRIVE_HEAD bit 6 carries LBA27..24. Check the register latch directly;
	-- a 32 MiB image cannot reach those sectors.
	ide:out8(0x1F3, 0)
	ide:out8(0x1F4, 0)
	ide:out8(0x1F5, 0)
	ide:out8(0x1F6, 0xE1)
	expect(ide.lba == 0x01000000, string.format("LBA high nibble=%08X", ide.lba))
	ide:out8(0x1F6, 0xE0)
	expect(ide.lba == 0, string.format("LBA high nibble clear=%08X", ide.lba))
end)

T("ata_lba_high_nibble", function(expect)
	const ide = Ide.new({ hdd = makeHdd() })
	selectDrive(ide, false)
	ide:out8(0x1F6, 0xE1) -- stale high LBA nibble
	ide:out8(0x1F6, 0xE0) -- must clear it before the next command
	ide:out8(0x1F2, 1)
	ide:out8(0x1F3, 63)
	ide:out8(0x1F4, 0)
	ide:out8(0x1F5, 0)
	ide:out8(0x1F7, 0x20)
	expect(band(ide:in8(0x1F7), 0x01) == 0, "read failed with stale LBA high nibble")
	const sector = readBytes(ide, 512)
	expect(buffer.readu8(sector, 0) == 0xA0, "sector marker after high nibble reset")
end)

T("mbr_parser", function(expect)
	const hdd = makeHdd()
	const parts = Ide.parseMbr(hdd)
	expect(#parts == 1, "partition count=" .. #parts)
	if #parts == 1 then
		expect(parts[1].status == 0x80, "status")
		expect(parts[1].kind == 0x06, "type")
		expect(parts[1].lba == 63, "lba")
		expect(parts[1].sectors == 100, "sectors")
	end
end)

T("atapi_identify_and_read10", function(expect)
	const iso = makeIso()
	const ide = Ide.new({ hdd = makeHdd(), cdrom = iso })
	selectDrive(ide, true)
	ide:out8(0x1F7, 0xA1)
	expect(band(ide:in8(0x1F7), 0x08) ~= 0, "IDENTIFY PACKET did not assert DRQ")
	const id = readWords(ide, 256)
	expect(id[1] == 0x85C0, string.format("ATAPI word0=%04X", id[1]))
	-- READ(10): LBA 0, one 2048-byte block.
	ide:out8(0x1F7, 0xA0)
	submitPacket(ide, { 0x28, 0, 0, 0, 0, 0, 0, 0, 1, 0, 0, 0 })
	expect(band(ide:in8(0x1F7), 0x08) ~= 0, "READ(10) did not assert DRQ")
	const data = readBytes(ide, 2048)
	expect(buffer.readu8(data, 0) == 0x46 and buffer.readu8(data, 3) == 0x45, "ISO marker")
	expect(buffer.readu8(data, 17) == 17, "ISO body")
end)

T("atapi_capacity_and_toc", function(expect)
	const iso = makeIso()
	const ide = Ide.new({ cdrom = iso })
	selectDrive(ide, true)
	ide:out8(0x1F7, 0xA0)
	submitPacket(ide, { 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
	const cap = readBytes(ide, 8)
	expect(be32(cap, 0) == 31, "last LBA=" .. be32(cap, 0))
	expect(be32(cap, 4) == 2048, "block size=" .. be32(cap, 4))

	ide:out8(0x1F7, 0xA0)
	submitPacket(ide, { 0x43, 0, 0, 0, 0, 0, 0, 0x00, 0xFF, 0, 0, 0 })
	const toc = readBytes(ide, 20)
	expect(be16(toc, 0) == 18, "TOC length=" .. be16(toc, 0))
	expect(buffer.readu8(toc, 2) == 1 and buffer.readu8(toc, 3) == 1, "TOC tracks")
	expect(buffer.readu8(toc, 14) == 0xAA, "leadout track")
	expect(be32(toc, 16) == 32, "leadout LBA=" .. be32(toc, 16))
end)

T("atapi_read12_read16_verify", function(expect)
	const iso = makeIso()
	const ide = Ide.new({ cdrom = iso })
	for _, spec in ipairs({ { 0x28, 0, 2 }, { 0xA8, 3, 2 }, { 0x88, 5, 2 } }) do
		const status, data = readLba(ide, spec[2], spec[3], spec[1])
		expect(band(status, 0x08) ~= 0, string.format("opcode %02X did not assert DRQ", spec[1]))
		expect(band(status, 0x01) == 0, string.format("opcode %02X error", spec[1]))
		compareBytes(
			expect,
			string.format("opcode %02X data", spec[1]),
			data,
			0,
			iso,
			spec[2] * 2048,
			spec[3] * 2048
		)
		expect(band(ide:in8(0x1F7), 0x08) == 0, string.format("opcode %02X left DRQ set", spec[1]))
	end

	local status = sendPacket(ide, { 0x2F, 0, 0, 0, 0, 1, 0, 0, 1, 0, 0, 0 })
	expect(band(status, 0x41) == 0x40, string.format("VERIFY(10) status=%02X", status))
	status = sendPacket(ide, { 0x2F, 0, 0, 0, 0, 31, 0, 0, 2, 0, 0, 0 })
	expect(band(status, 0x01) ~= 0, "VERIFY(10) out of range did not fail")
	const _, sense = requestSense(ide)
	expect(buffer.readu8(sense, 2) == 0x05, "VERIFY sense key")
	expect(buffer.readu8(sense, 12) == 0x21, "VERIFY sense ASC")
end)

T("atapi_error_sense", function(expect)
	const ide = Ide.new({ cdrom = makeIso() })
	local status = sendPacket(ide, { 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
	expect(status == 0x50, string.format("TEST UNIT READY status=%02X", status))

	status = sendPacket(ide, { 0x28, 0, 0, 0, 0, 32, 0, 0, 1, 0, 0, 0 })
	expect(band(status, 0x01) ~= 0, "out-of-range READ(10) did not fail")
	expect(ide:in8(0x1F1) == 0x04, string.format("ATAPI error reg=%02X", ide:in8(0x1F1)))
	local senseStatus, sense = requestSense(ide)
	expect(band(senseStatus, 0x08) ~= 0, "REQUEST SENSE did not assert DRQ")
	expect(buffer.readu8(sense, 0) == 0xF0, "sense response code")
	expect(buffer.readu8(sense, 2) == 0x05, "sense key")
	expect(buffer.readu8(sense, 7) == 10, "sense additional length")
	expect(buffer.readu8(sense, 12) == 0x21, "sense ASC")
	expect(buffer.readu8(sense, 13) == 0, "sense ASCQ")

	local _, cleared = requestSense(ide)
	expect(buffer.readu8(cleared, 2) == 0, "sense not cleared")
	expect(buffer.readu8(cleared, 12) == 0, "sense ASC not cleared")

	status = sendPacket(ide, { 0xDE, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
	expect(band(status, 0x01) ~= 0, "unknown opcode did not fail")
	const _, opcodeSense = requestSense(ide)
	expect(buffer.readu8(opcodeSense, 2) == 0x05, "opcode sense key")
	expect(buffer.readu8(opcodeSense, 12) == 0x20, "opcode sense ASC")

	status = sendPacket(ide, { 0x28, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
	expect(status == 0x50, string.format("zero-length READ(10) status=%02X", status))
end)

T("atapi_inquiry_mode_sense_configuration", function(expect)
	const ide = Ide.new({ cdrom = makeIso() })

	local status = sendPacket(ide, { 0x12, 0, 0, 0, 36, 0, 0, 0, 0, 0, 0, 0 })
	expect(band(status, 0x08) ~= 0, "INQUIRY did not assert DRQ")
	const inquiry = readBytes(ide, 36)
	expect(buffer.readu8(inquiry, 0) == 0x05, "INQUIRY device type")
	expect(buffer.readu8(inquiry, 1) == 0x80, "INQUIRY removable")
	expectAscii(expect, inquiry, 8, "RVPC")
	expectAscii(expect, inquiry, 16, "VIRTUAL CD")

	status = sendPacket(ide, { 0x12, 1, 0, 0, 36, 0, 0, 0, 0, 0, 0, 0 })
	expect(band(status, 0x08) ~= 0, "INQUIRY EVPD did not assert DRQ")
	const vpd = readBytes(ide, 5)
	expect(buffer.readu8(vpd, 0) == 0x05, "EVPD device type")
	expect(buffer.readu8(vpd, 1) == 0, "EVPD page")
	expect(buffer.readu8(vpd, 3) == 1 and buffer.readu8(vpd, 4) == 0, "EVPD page list")

	status = sendPacket(ide, { 0x5A, 0, 0x2A, 0, 0, 0, 0, 0, 64, 0, 0, 0 })
	expect(band(status, 0x08) ~= 0, "MODE SENSE(10) did not assert DRQ")
	const mode10 = readBytes(ide, 30)
	expect(be16(mode10, 0) == 28, "MODE SENSE(10) length=" .. be16(mode10, 0))
	expect(buffer.readu8(mode10, 8) == 0x2A, "MODE SENSE(10) page")
	expect(buffer.readu8(mode10, 9) == 0x14, "MODE SENSE(10) page length")

	status = sendPacket(ide, { 0x1A, 0, 0x3F, 0, 64, 0, 0, 0, 0, 0, 0, 0 })
	expect(band(status, 0x08) ~= 0, "MODE SENSE(6) did not assert DRQ")
	const mode6 = readBytes(ide, 50)
	expect(buffer.readu8(mode6, 0) == 49, "MODE SENSE(6) length=" .. buffer.readu8(mode6, 0))
	expect(buffer.readu8(mode6, 4) == 0x01, "MODE SENSE(6) first page")
	expect(buffer.readu8(mode6, 28) == 0x2A, "MODE SENSE(6) capabilities page")

	status = sendPacket(ide, { 0x46, 0, 0, 0, 0, 0, 0, 0, 64, 0, 0, 0 })
	expect(band(status, 0x08) ~= 0, "GET CONFIGURATION did not assert DRQ")
	const config = readBytes(ide, 16)
	expect(be32(config, 0) == 12, "GET CONFIGURATION data length")
	expect(be16(config, 6) == 0x0008, "GET CONFIGURATION current profile")
	expect(be16(config, 8) == 0, "GET CONFIGURATION feature code")
	expect(buffer.readu8(config, 10) == 0x03, "GET CONFIGURATION feature flags")
	expect(buffer.readu8(config, 11) == 4, "GET CONFIGURATION feature length")
	expect(be16(config, 12) == 0x0008, "GET CONFIGURATION profile")
	expect(buffer.readu8(config, 14) == 1, "GET CONFIGURATION current flag")
end)

T("atapi_toc_formats_and_read_header", function(expect)
	const ide = Ide.new({ cdrom = makeIso() })
	local function tocPacket(format, msf, startTrack, allocation, legacy)
		local packet = { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 }
		packet[1] = 0x43
		packet[2] = if msf then 0x02 else 0
		packet[3] = if legacy then 0 else format
		packet[7] = startTrack
		packet[8] = band(rshift(allocation, 8), 0xFF)
		packet[9] = band(allocation, 0xFF)
		packet[10] = band(lshift(if legacy then format else 0, 6), 0xFF)
		return packet
	end

	local status = sendPacket(ide, tocPacket(0, false, 0, 255, false))
	expect(band(status, 0x08) ~= 0, "READ TOC did not assert DRQ")
	local toc = readBytes(ide, 20)
	expect(be16(toc, 0) == 18, "READ TOC length=" .. be16(toc, 0))
	expect(buffer.readu8(toc, 2) == 1 and buffer.readu8(toc, 3) == 1, "READ TOC tracks")
	expect(buffer.readu8(toc, 5) == 0x14, "track 1 control")
	expect(buffer.readu8(toc, 6) == 1, "track 1 number")
	expect(be32(toc, 8) == 0, "track 1 LBA")
	expect(buffer.readu8(toc, 14) == 0xAA, "leadout track")
	expect(be32(toc, 16) == 32, "leadout LBA")

	status = sendPacket(ide, tocPacket(0, true, 0, 255, false))
	expect(band(status, 0x08) ~= 0, "MSF READ TOC did not assert DRQ")
	toc = readBytes(ide, 20)
	expect(buffer.readu8(toc, 8) == 0 and buffer.readu8(toc, 9) == 0, "track 1 MSF high")
	expect(buffer.readu8(toc, 10) == 2 and buffer.readu8(toc, 11) == 0, "track 1 MSF")
	expect(buffer.readu8(toc, 16) == 0 and buffer.readu8(toc, 17) == 0, "leadout MSF high")
	expect(buffer.readu8(toc, 18) == 2 and buffer.readu8(toc, 19) == 32, "leadout MSF")

	status = sendPacket(ide, tocPacket(1, false, 0, 255, false))
	expect(band(status, 0x08) ~= 0, "multi-session TOC did not assert DRQ")
	local multi = readBytes(ide, 12)
	expect(be16(multi, 0) == 10, "multi-session length")
	expect(buffer.readu8(multi, 2) == 1 and buffer.readu8(multi, 3) == 1, "session numbers")
	expect(buffer.readu8(multi, 5) == 0x14 and buffer.readu8(multi, 6) == 1, "last session track")

	status = sendPacket(ide, tocPacket(2, false, 0, 255, false))
	expect(band(status, 0x08) ~= 0, "full TOC did not assert DRQ")
	local full = readBytes(ide, 48)
	expect(be16(full, 0) == 46, "full TOC length=" .. be16(full, 0))
	expect(buffer.readu8(full, 7) == 0xA0, "full TOC A0")
	expect(buffer.readu8(full, 18) == 0xA1, "full TOC A1")
	expect(buffer.readu8(full, 29) == 0xA2, "full TOC A2")
	expect(
		buffer.readu8(full, 34) == 0
			and buffer.readu8(full, 35) == 2
			and buffer.readu8(full, 36) == 32,
		"full TOC leadout"
	)
	expect(buffer.readu8(full, 40) == 0x01, "full TOC track 1")

	status = sendPacket(ide, tocPacket(2, false, 0, 255, true))
	expect(band(status, 0x08) ~= 0, "legacy full TOC did not assert DRQ")
	full = readBytes(ide, 48)
	expect(buffer.readu8(full, 7) == 0xA0, "legacy full TOC A0")

	status = sendPacket(ide, tocPacket(3, false, 0, 255, false))
	expect(band(status, 0x08) ~= 0, "PMA did not assert DRQ")
	const pma = readBytes(ide, 4)
	expect(be16(pma, 0) == 0, "PMA length")

	status = sendPacket(ide, tocPacket(4, false, 0, 255, false))
	expect(band(status, 0x08) ~= 0, "ATIP did not assert DRQ")
	const atip = readBytes(ide, 4)
	expect(be16(atip, 0) == 0, "ATIP length")

	status = sendPacket(ide, { 0x44, 0, 0, 0, 0, 5, 0, 0, 8, 0, 0, 0 })
	expect(band(status, 0x08) ~= 0, "READ HEADER did not assert DRQ")
	local header = readBytes(ide, 8)
	expect(buffer.readu8(header, 0) == 0x01, "READ HEADER mode")
	expect(be32(header, 4) == 5, "READ HEADER LBA=" .. be32(header, 4))

	status = sendPacket(ide, { 0x44, 2, 0, 0, 0, 5, 0, 0, 8, 0, 0, 0 })
	expect(band(status, 0x08) ~= 0, "MSF READ HEADER did not assert DRQ")
	header = readBytes(ide, 8)
	expect(buffer.readu8(header, 5) == 0 and buffer.readu8(header, 6) == 2, "READ HEADER MSF")
	expect(buffer.readu8(header, 7) == 5, "READ HEADER MSF frame")

	status = sendPacket(ide, { 0x44, 0, 0, 0, 0, 32, 0, 0, 8, 0, 0, 0 })
	expect(band(status, 0x01) ~= 0, "out-of-range READ HEADER did not fail")
end)

T("atapi_start_stop_and_prevent_allow", function(expect)
	const ide = Ide.new({ cdrom = makeIso() })
	local status = sendPacket(ide, { 0x1E, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 })
	expect(status == 0x50, string.format("PREVENT status=%02X", status))
	status = sendPacket(ide, { 0x1B, 0, 0, 0, 0x02, 0, 0, 0, 0, 0, 0, 0 })
	expect(band(status, 0x01) ~= 0, "locked eject did not fail")
	local _, sense = requestSense(ide)
	expect(buffer.readu8(sense, 2) == 0x02, "eject sense key")
	expect(buffer.readu8(sense, 12) == 0x53, "eject sense ASC")

	status = sendPacket(ide, { 0x1B, 0, 0, 0, 0x03, 0, 0, 0, 0, 0, 0, 0 })
	expect(status == 0x50, string.format("START STOP load status=%02X", status))
	status = sendPacket(ide, { 0x1E, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
	expect(status == 0x50, string.format("ALLOW status=%02X", status))
	status = sendPacket(ide, { 0x1B, 0, 0, 0, 0x02, 0, 0, 0, 0, 0, 0, 0 })
	expect(status == 0x50, string.format("unlocked eject status=%02X", status))
	status = sendPacket(ide, { 0xBB, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
	expect(status == 0x50, string.format("SET SPEED status=%02X", status))
end)

T("ata_mbr_boot_partition", function(expect)
	const hdd = makeHdd()
	const boot = Ide.findBootPartition(hdd)
	expect(boot ~= nil, "no boot partition found")
	if boot then
		expect(boot.status == 0x80, "boot status")
		expect(boot.kind == 0x06, "boot type")
		expect(boot.lba == 63, "boot LBA")
	end
	buffer.writeu8(hdd, 446, 0)
	expect(Ide.findBootPartition(hdd) == nil, "inactive MBR returned a boot partition")
end)

if realIso then
	T("atapi_real_iso_eltorito", function(expect)
		const totalSectors = math.floor(buffer.len(realIso) / 2048)
		expect(totalSectors == 204870, "ISO sectors=" .. totalSectors)
		const ide = Ide.new({ cdrom = realIso })

		-- scsi_is_ready() runs TEST UNIT READY before cdrom_boot().
		local status = sendPacket(ide, { 0x00, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
		expect(status == 0x50, string.format("TUR status=%02X", status))

		-- SeaBIOS cdrom_media_info() reads the PVD and boot record.
		local _, pvd = readLba(ide, 16, 1)
		expectAscii(expect, pvd, 40, "FD13-LiveCD")
		local bootRecord
		status, bootRecord = readLba(ide, 17, 1)
		expect(band(status, 0x08) ~= 0, "LBA 17 did not assert DRQ")
		compareBytes(expect, "boot record", bootRecord, 0, realIso, 17 * 2048, 2048)
		expect(buffer.readu8(bootRecord, 0) == 0, "boot record descriptor type")
		expectAscii(expect, bootRecord, 1, "CD001")
		expectAscii(expect, bootRecord, 7, "EL TORITO SPECIFICATION")
		const catalogLba = le32(bootRecord, 0x47)
		expect(catalogLba == 403, "boot catalog LBA=" .. catalogLba)

		-- El Torito boot catalog validation entry and initial entry.
		const catalogStatus, catalog = readLba(ide, catalogLba, 1)
		expect(band(catalogStatus, 0x08) ~= 0, "boot catalog did not assert DRQ")
		compareBytes(expect, "boot catalog", catalog, 0, realIso, catalogLba * 2048, 2048)
		expect(buffer.readu8(catalog, 0) == 0x01, "validation header id")
		expect(buffer.readu8(catalog, 1) == 0x00, "validation platform")
		expect(
			buffer.readu8(catalog, 30) == 0x55 and buffer.readu8(catalog, 31) == 0xAA,
			"validation key"
		)
		expect(buffer.readu8(catalog, 32) == 0x88, "initial entry bootable")
		expect(buffer.readu8(catalog, 33) == 0x00, "initial entry no-emulation")
		expect(le16(catalog, 34) == 0, "initial entry load segment=" .. le16(catalog, 34))
		const imageSectors = le16(catalog, 38)
		const imageLba = le32(catalog, 40)
		expect(imageSectors == 4, "initial entry sector count=" .. imageSectors)
		expect(imageLba == 404, "initial entry load RBA=" .. imageLba)

		-- The same image through READ(10), READ(12) and READ(16).
		local firstImage
		for _, opcode in ipairs({ 0x28, 0xA8, 0x88 }) do
			const imageStatus, image = readLba(ide, imageLba, imageSectors, opcode)
			expect(
				band(imageStatus, 0x08) ~= 0,
				string.format("image opcode %02X did not assert DRQ", opcode)
			)
			compareBytes(
				expect,
				string.format("image opcode %02X", opcode),
				image,
				0,
				realIso,
				imageLba * 2048,
				imageSectors * 2048
			)
			firstImage = firstImage or image
		end
		expect(
			buffer.readu8(firstImage, 0) == 0xFA
				and buffer.readu8(firstImage, 1) == 0xEA
				and buffer.readu8(firstImage, 2) == 0x6C
				and buffer.readu8(firstImage, 3) == 0x7C,
			"El Torito boot signature"
		)
		expect(band(ide:in8(0x1F7), 0x08) == 0, "image transfer left DRQ set")

		-- READ CAPACITY and READ TOC report the same media size.
		status = sendPacket(ide, { 0x25, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
		expect(band(status, 0x08) ~= 0, "READ CAPACITY did not assert DRQ")
		const capacity = readBytes(ide, 8)
		expect(be32(capacity, 0) == totalSectors - 1, "capacity last LBA=" .. be32(capacity, 0))
		expect(be32(capacity, 4) == 2048, "capacity block size")

		status = sendPacket(ide, { 0x43, 0, 0, 0, 0, 0, 0, 0x00, 0xFF, 0, 0, 0 })
		expect(band(status, 0x08) ~= 0, "READ TOC did not assert DRQ")
		const toc = readBytes(ide, 20)
		expect(be16(toc, 0) == 18, "real ISO TOC length=" .. be16(toc, 0))
		expect(buffer.readu8(toc, 14) == 0xAA, "real ISO leadout track")
		expect(be32(toc, 16) == totalSectors, "real ISO leadout LBA=" .. be32(toc, 16))
	end)
end

return TESTS
