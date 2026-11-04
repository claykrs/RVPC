--!nonstrict
-- IdeTests.lua -- ATA PIO, MBR parsing and ATAPI PACKET/READ(10).

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift
const Ide = require("../core/Ide")

const TESTS = {}

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
	for index = 0, count - 1, 2 do
		buffer.writeu16(out, index, ide:in16(0x1F0))
	end
	return out
end

local function submitPacket(ide, packet)
	for index = 0, 11, 2 do
		ide:out16(0x1F0, bor(packet[index + 1] or 0, lshift(packet[index + 2] or 0, 8)))
	end
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
	submitPacket(ide, { 0x43, 0, 0, 0, 0, 0, 0, 0, 0x10, 0, 0, 0 })
	const toc = readBytes(ide, 20)
	expect(be16(toc, 0) == 20, "TOC length=" .. be16(toc, 0))
	expect(buffer.readu8(toc, 2) == 1 and buffer.readu8(toc, 3) == 1, "TOC tracks")
	expect(buffer.readu8(toc, 14) == 0xAA, "leadout track")
	expect(be32(toc, 16) == 32, "leadout LBA=" .. be32(toc, 16))
end)

return TESTS
