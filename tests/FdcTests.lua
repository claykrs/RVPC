--!nonstrict
-- FdcTests.lua -- 82077AA register/command, DMA and IRQ behavior.

const band, rshift = bit32.band, bit32.rshift
const Fdc = require("../core/Fdc")
const Dma = require("../core/Dma")
const Memory = require("../core/Memory")
const Machine = require("../core/Machine")
const Cpu = require("../core/Cpu")
const Pic = require("../core/Pic")
const Cmos = require("../core/Cmos")

const TESTS = {}
const BASE = 0x3F0

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function makeImage()
	const image = buffer.create(Fdc.DRIVE_SIZE)
	for index = 0, 511 do
		buffer.writeu8(image, index, index % 251)
	end
	for index = 0, 511 do
		buffer.writeu8(image, 512 + index, (index * 3 + 7) % 256)
	end
	return image
end

local function newDma()
	const memory = Memory.new(1024 * 1024)
	const dma = Dma.new({
		read8 = function(address)
			return memory:read8(address)
		end,
		read16 = function(address)
			return memory:read16(address)
		end,
		write8 = function(address, value)
			memory:write8(address, value)
		end,
		write16 = function(address, value)
			memory:write16(address, value)
		end,
	})
	return dma, memory
end

local function fresh(config)
	const image = config and config.floppy
	const dma, memory = newDma()
	local captured = nil
	const fdc = Fdc.new({
		floppy = image,
		writeProtected = config and config.writeProtected,
		dma = dma,
		dirty = function(drive, lba, count)
			captured = { drive = drive, lba = lba, count = count }
		end,
	})
	return fdc, dma, memory, captured
end

local function wr(fdc, reg, value)
	fdc:out8(BASE + reg, value)
end

local function rd(fdc, reg)
	return fdc:in8(BASE + reg)
end

local function send(fdc, ...)
	const args = { ... }
	for _, value in ipairs(args) do
		local guard = 0
		while band(rd(fdc, 4), 0x80) == 0 and guard < 1000 do
			guard += 1
		end
		wr(fdc, 5, value)
	end
end

local function result(fdc, count)
	const out = {}
	for index = 1, count do
		local guard = 0
		while band(rd(fdc, 4), 0x80) == 0 and guard < 1000 do
			guard += 1
		end
		out[index] = rd(fdc, 5)
	end
	return out
end

local function resetController(fdc)
	wr(fdc, 2, 0x00)
	wr(fdc, 2, 0x0C)
	const irq = fdc:takeIrq()
	for _ = 1, 4 do
		send(fdc, 0x08)
		result(fdc, 2)
	end
	return irq
end

local function programChannel(dma, address, count, mode)
	dma:out8(0x0C, 0)
	dma:out8(0x04, band(address, 0xFF))
	dma:out8(0x04, band(rshift(address, 8), 0xFF))
	dma:out8(0x0C, 0)
	dma:out8(0x05, band(count - 1, 0xFF))
	dma:out8(0x05, band(rshift(count - 1, 8), 0xFF))
	dma:out8(0x81, band(rshift(address, 16), 0xFF))
	dma:out8(0x0B, mode)
	dma:out8(0x0A, 0x02) -- clear mask bit 2
end

T("reset_version_and_irq_latch", function(expect)
	const fdc = fresh({ floppy = makeImage() })
	expect(resetController(fdc), "reset did not raise IRQ6")
	expect(not fdc:takeIrq(), "IRQ latch did not clear")
	send(fdc, 0x10)
	const version = result(fdc, 1)
	expect(version[1] == 0x90, ("VERSION=%02X"):format(version[1]))
	expect(not fdc:takeIrq(), "VERSION raised IRQ")
end)

T("specify_recalibrate_seek_read_id", function(expect)
	const fdc = fresh({ floppy = makeImage() })
	resetController(fdc)

	send(fdc, 0x03, 0xAF, 0x02)
	expect(band(rd(fdc, 4), 0x80) ~= 0, "SPECIFY left controller not ready")
	expect(not fdc:takeIrq(), "SPECIFY raised IRQ")

	send(fdc, 0x07, 0x00)
	expect(fdc:takeIrq(), "RECALIBRATE did not raise IRQ")
	send(fdc, 0x08)
	local sense = result(fdc, 2)
	expect(band(sense[1], 0x20) ~= 0, ("RECAL ST0=%02X"):format(sense[1]))
	expect(sense[2] == 0, ("RECAL PCN=%02X"):format(sense[2]))

	send(fdc, 0x04, 0x00)
	const st3 = result(fdc, 1)
	expect(band(st3[1], 0x20) ~= 0, ("ST3 ready=%02X"):format(st3[1]))
	expect(band(st3[1], 0x08) ~= 0, "ST3 two-sided missing")

	send(fdc, 0x0A, 0x00)
	expect(fdc:takeIrq(), "READ ID did not raise IRQ")
	const id = result(fdc, 7)
	expect(band(id[1], 0xC0) == 0, ("READ ID ST0=%02X"):format(id[1]))
	expect(id[4] == 0 and id[5] == 0 and id[6] == 1 and id[7] == 2, "READ ID CHRN")

	send(fdc, 0x0F, 0x00, 0x0A)
	expect(fdc:takeIrq(), "SEEK did not raise IRQ")
	send(fdc, 0x08)
	sense = result(fdc, 2)
	expect(sense[2] == 10, ("SEEK PCN=%02X"):format(sense[2]))
end)

T("read_data_dma2", function(expect)
	const image = makeImage()
	const fdc, dma, memory = fresh({ floppy = image })
	resetController(fdc)
	wr(fdc, 2, 0x1C) -- motor A + IRQ/DMA + normal reset
	programChannel(dma, 0x1000, 512, 0x46) -- single, increment, memory write

	send(fdc, 0x06, 0x00, 0x00, 0x00, 0x01, 0x02, 0x01, 0x1B, 0xFF)
	expect(fdc:takeIrq(), "READ DATA did not raise IRQ")
	const status = result(fdc, 7)
	expect(band(status[1], 0xC0) == 0, ("READ ST0=%02X"):format(status[1]))
	expect(status[2] == 0 and status[3] == 0, "READ status")
	for index = 0, 511 do
		if memory:read8(0x1000 + index) ~= buffer.readu8(image, index) then
			expect(false, "DMA read differs at " .. index)
			return
		end
	end
	expect(true, "DMA read data")
	expect(not fdc:takeIrq(), "READ IRQ did not clear")
end)

T("write_data_dma2_and_dirty", function(expect)
	const image = makeImage()
	const fdc, dma, memory = fresh({ floppy = image })
	resetController(fdc)
	wr(fdc, 2, 0x1C)
	for index = 0, 511 do
		memory:write8(0x2000 + index, (index * 5 + 11) % 256)
	end
	programChannel(dma, 0x2000, 512, 0x4A) -- single, increment, memory read

	send(fdc, 0x05, 0x00, 0x00, 0x00, 0x02, 0x02, 0x02, 0x1B, 0xFF)
	expect(fdc:takeIrq(), "WRITE DATA did not raise IRQ")
	const status = result(fdc, 7)
	expect(band(status[1], 0xC0) == 0, ("WRITE ST0=%02X"):format(status[1]))
	for index = 0, 511 do
		if buffer.readu8(image, 512 + index) ~= memory:read8(0x2000 + index) then
			expect(false, "DMA write differs at " .. index)
			return
		end
	end
	expect(true, "DMA write data")
	expect(fdc:driveDirty(0), "write did not set dirty flag")
	expect(fdc.drives[1].dirtyFirstSector == 1, "dirty first sector")
end)

T("write_protect_and_missing_drive", function(expect)
	const image = makeImage()
	const wp = fresh({ floppy = image, writeProtected = true })
	resetController(wp)
	wr(wp, 2, 0x1C)
	send(wp, 0x05, 0x00, 0x00, 0x00, 0x02, 0x02, 0x02, 0x1B, 0xFF)
	expect(wp:takeIrq(), "write-protected WRITE did not raise IRQ")
	const wpStatus = result(wp, 7)
	expect(band(wpStatus[1], 0x40) ~= 0, ("WP ST0=%02X"):format(wpStatus[1]))
	expect(band(wpStatus[2], 0x02) ~= 0, ("WP ST1=%02X"):format(wpStatus[2]))
	expect(not wp:driveDirty(0), "write-protected write dirtied image")

	const none = fresh({})
	resetController(none)
	send(none, 0x0A, 0x00)
	expect(none:takeIrq(), "missing drive READ ID did not raise IRQ")
	const missing = result(none, 7)
	expect(band(missing[1], 0x40) ~= 0, ("missing ST0=%02X"):format(missing[1]))
	expect(band(missing[2], 0x01) ~= 0, ("missing ST1=%02X"):format(missing[2]))
	send(none, 0x04, 0x00)
	const missingSt3 = result(none, 1)
	expect(band(missingSt3[1], 0x20) == 0, "missing drive reported ready")
end)

T("configure_lock_dumpreg_invalid_format", function(expect)
	const image = makeImage()
	const fdc, dma, memory = fresh({ floppy = image })
	resetController(fdc)

	send(fdc, 0x13, 0x00, 0x0F, 0x00)
	send(fdc, 0x12, 0x00)
	send(fdc, 0x14)
	send(fdc, 0x18)
	expect(not fdc:takeIrq(), "configuration commands raised IRQ")
	send(fdc, 0x0E)
	const dump = result(fdc, 10)
	expect(dump[1] ~= nil and dump[10] ~= nil, "DUMPREG result length")

	send(fdc, 0xFF)
	const invalid = result(fdc, 1)
	expect(invalid[1] == 0x80, ("INVALID=%02X"):format(invalid[1]))

	wr(fdc, 2, 0x1C)
	for index = 0, 7 do
		memory:write8(0x3000 + index, index % 8)
	end
	-- C/H/R/N descriptors for sector 1 and 2
	memory:write8(0x3000, 0)
	memory:write8(0x3001, 0)
	memory:write8(0x3002, 1)
	memory:write8(0x3003, 2)
	memory:write8(0x3004, 0)
	memory:write8(0x3005, 0)
	memory:write8(0x3006, 2)
	memory:write8(0x3007, 2)
	programChannel(dma, 0x3000, 8, 0x4A)
	send(fdc, 0x0D, 0x00, 0x02, 0x02, 0x6C, 0xE5)
	expect(fdc:takeIrq(), "FORMAT TRACK did not raise IRQ")
	const formatStatus = result(fdc, 7)
	expect(band(formatStatus[1], 0xC0) == 0, ("FORMAT ST0=%02X"):format(formatStatus[1]))
	expect(buffer.readu8(image, 0) == 0xE5 and buffer.readu8(image, 512) == 0xE5, "FORMAT fill")
end)

T("machine_routes_fdc_and_irq6", function(expect)
	const image = makeImage()
	const m = Machine.new({
		Memory = Memory,
		Cpu = Cpu,
		Pic = Pic,
		Cmos = Cmos,
		Dma = Dma,
		Fdc = Fdc,
	}, {
		memorySize = 1024 * 1024,
		floppy = { image = image },
	})
	const cpu = m.cpu
	cpu:loadSeg("cs", 0x600)
	cpu.ip = 0x100
	cpu.halted = false
	const code = {
		0xBA,
		0xF2,
		0x03, -- MOV DX,0x3F2
		0xB0,
		0x00, -- MOV AL,0
		0xEE, -- OUT DX,AL   (enter reset)
		0xB0,
		0x0C, -- MOV AL,0x0C
		0xEE, -- OUT DX,AL   (leave reset, IRQ6)
		0xF4, -- HLT
	}
	for index, byte in ipairs(code) do
		m.mem:write8(0x6000 + 0x100 + index - 1, byte)
	end
	m:run(30)
	expect(m.fdc ~= nil, "machine did not create an FDC")
	expect(m.fdc.dor == 0x0C, ("FDC DOR=%02X"):format(m.fdc.dor))
	expect(m.fdc.drives[1].motor == false, "motor A unexpectedly on")
	expect(band(m.pic.master.irr, 0x40) ~= 0, "IRQ6 not raised through the PIC")
	expect(m.cmos.floppyType == 0x40, ("CMOS 0x10=%02X"):format(m.cmos.floppyType))
end)

return TESTS
