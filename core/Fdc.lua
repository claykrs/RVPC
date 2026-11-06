--!strict
-- Fdc.lua -- Intel 82077AA-style floppy disk controller.
--
-- The controller exposes the classic PC/AT ports 0x3F0-0x3F5 and 0x3F7,
-- two 3.5" 1.44 MiB drives (80 cylinders, 2 heads, 18 sectors), IRQ6 and
-- 8237 DMA channel 2. Drive images are host-provided buffers; write-back and
-- persistence remain the caller's job through the optional dirty callback.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const Fdc = {}
Fdc.__index = Fdc

Fdc.BASE = 0x3F0
Fdc.IRQ = 6
Fdc.DMA_CHANNEL = 2
Fdc.CYLINDERS = 80
Fdc.HEADS = 2
Fdc.SECTORS = 18
Fdc.SECTOR_SIZE = 512
Fdc.DRIVE_SIZE = Fdc.CYLINDERS * Fdc.HEADS * Fdc.SECTORS * Fdc.SECTOR_SIZE

const REG_SRA = 0
const REG_SRB = 1
const REG_DOR = 2
const REG_TDR = 3
const REG_MSR = 4
const REG_FIFO = 5
const REG_DIR = 7

const DOR_DRIVE_MASK = 0x03
const DOR_RESET = 0x04
const DOR_DMA = 0x08
const DOR_MOTOR_A = 0x10
const DOR_MOTOR_B = 0x20

const CMD_READ_TRACK = 0x02
const CMD_SPECIFY = 0x03
const CMD_SENSE_DRIVE = 0x04
const CMD_WRITE = 0x05
const CMD_READ = 0x06
const CMD_RECALIBRATE = 0x07
const CMD_SENSE_INT = 0x08
const CMD_WRITE_DELETED = 0x09
const CMD_READ_ID = 0x0A
const CMD_READ_DELETED = 0x0C
const CMD_FORMAT_TRACK = 0x0D
const CMD_DUMPREG = 0x0E
const CMD_SEEK = 0x0F
const CMD_VERSION = 0x10
const CMD_SCAN_EQUAL = 0x11
const CMD_PERPENDICULAR = 0x12
const CMD_CONFIGURE = 0x13
const CMD_LOCK = 0x14
const CMD_VERIFY = 0x16
const CMD_POWERDOWN = 0x17
const CMD_UNLOCK = 0x18
const CMD_SCAN_LOW = 0x19
const CMD_SCAN_HIGH = 0x1D

const PARAM_COUNTS: { [number]: number } = {
	[CMD_READ_TRACK] = 8,
	[CMD_SPECIFY] = 2,
	[CMD_SENSE_DRIVE] = 1,
	[CMD_WRITE] = 8,
	[CMD_READ] = 8,
	[CMD_RECALIBRATE] = 1,
	[CMD_SENSE_INT] = 0,
	[CMD_WRITE_DELETED] = 8,
	[CMD_READ_ID] = 1,
	[CMD_READ_DELETED] = 8,
	[CMD_FORMAT_TRACK] = 5,
	[CMD_DUMPREG] = 0,
	[CMD_SEEK] = 2,
	[CMD_VERSION] = 0,
	[CMD_SCAN_EQUAL] = 8,
	[CMD_PERPENDICULAR] = 1,
	[CMD_CONFIGURE] = 3,
	[CMD_LOCK] = 0,
	[CMD_VERIFY] = 8,
	[CMD_POWERDOWN] = 0,
	[CMD_UNLOCK] = 0,
	[CMD_SCAN_LOW] = 8,
	[CMD_SCAN_HIGH] = 8,
}

const ST0_ABNTERM = 0x40
const ST0_INVCMD = 0x80
const ST0_RDYCHG = 0xC0
const ST1_MA = 0x01
const ST1_NW = 0x02

export type DirtyCallback = (drive: number, lba: number, count: number) -> ()

export type Config = {
	floppy: buffer?,
	floppy1: buffer?,
	writeProtected: boolean?,
	writeProtected1: boolean?,
	dirty: DirtyCallback?,
	dirty1: DirtyCallback?,
	dma: any?,
	irq: number?,
}

export type Drive = {
	index: number,
	image: buffer?,
	writeProtected: boolean,
	dirtyCallback: DirtyCallback?,
	track: number,
	head: number,
	sector: number,
	motor: boolean,
	mediaChanged: boolean,
	dirty: boolean,
	dirtyFirstSector: number?,
	dirtyLastSector: number?,
}

type SenseEntry = {
	st0: number,
	pcn: number,
}

type Pending = {
	kind: string,
	driveIndex: number,
	lba: number,
	count: number,
	track: number,
	head: number,
	sector: number,
	sectorSize: number,
	fill: number,
	formatSectors: number,
}

export type Fdc = typeof(setmetatable(
	{} :: {
		drives: { Drive },
		current: number,
		dor: number,
		tdr: number,
		dsr: number,
		phase: string,
		command: number,
		params: { number },
		paramIndex: number,
		paramCount: number,
		results: { number },
		resultIndex: number,
		dataBuffer: buffer?,
		dataPos: number,
		dataLength: number,
		irqPending: boolean,
		irq: number,
		dma: any?,
		dirty: boolean,
		lock: boolean,
		perpendicular: number,
		config: number,
		senseQueue: { SenseEntry },
		pending: Pending?,
		lastStatus: { number },
		reset: (self: Fdc) -> (),
		in8: (self: Fdc, port: number) -> number,
		out8: (self: Fdc, port: number, value: number) -> (),
		takeIrq: (self: Fdc) -> boolean,
		driveDirty: (self: Fdc, index: number) -> boolean,
		clearDriveDirty: (self: Fdc, index: number) -> (),
	},
	Fdc
))

local function newDrive(
	index: number,
	image: buffer?,
	writeProtected: boolean?,
	callback: DirtyCallback?
): Drive
	return {
		index = index,
		image = image,
		writeProtected = writeProtected == true,
		dirtyCallback = callback,
		track = 0,
		head = 0,
		sector = 1,
		motor = false,
		mediaChanged = image ~= nil,
		dirty = false,
		dirtyFirstSector = nil,
		dirtyLastSector = nil,
	}
end

function Fdc.new(config: Config?): Fdc
	const cfg: Config = config or {}
	local self = setmetatable({}, Fdc) :: any
	self.drives = {
		newDrive(0, cfg.floppy, cfg.writeProtected, cfg.dirty),
		newDrive(1, cfg.floppy1, cfg.writeProtected1, cfg.dirty1),
	}
	self.current = 0
	self.dor = bor(DOR_RESET, DOR_DMA)
	self.tdr = 0
	self.dsr = 0
	self.irq = cfg.irq or Fdc.IRQ
	self.dma = cfg.dma
	self.dirty = false
	self.lock = false
	self.perpendicular = 0
	self.config = 0
	self.phase = "command"
	self.command = 0
	self.params = {}
	self.paramIndex = 0
	self.paramCount = 0
	self.results = {}
	self.resultIndex = 0
	self.dataBuffer = nil
	self.dataPos = 0
	self.dataLength = 0
	self.irqPending = false
	self.senseQueue = {}
	self.pending = nil
	self.lastStatus = { 0, 0, 0 }
	self:reset()
	return self
end

local function clearPending(self: Fdc)
	self.command = 0
	self.params = {}
	self.paramIndex = 0
	self.paramCount = 0
	self.results = {}
	self.resultIndex = 0
	self.dataBuffer = nil
	self.dataPos = 0
	self.dataLength = 0
	self.pending = nil
end

local function toCommand(self: Fdc)
	clearPending(self)
	self.phase = "command"
end

function Fdc.reset(self: Fdc)
	self.phase = "command"
	self.irqPending = false
	self.senseQueue = {}
	self.lastStatus = { 0, 0, 0 }
	self.lock = false
	self.perpendicular = 0
	self.config = 0
	self.tdr = 0
	self.current = 0
	self.dor = bor(DOR_RESET, DOR_DMA)
	for _, drive in ipairs(self.drives) do
		drive.track = 0
		drive.head = 0
		drive.sector = 1
		drive.motor = false
		drive.mediaChanged = drive.image ~= nil
	end
	clearPending(self)
end

local function activeDrive(self: Fdc): Drive
	return self.drives[self.current + 1]
end

local function msrValue(self: Fdc): number
	local value = 0x80 -- RQM
	if self.phase == "command" then
		value = bor(value, 0x20) -- NDMA
	elseif self.phase == "result" or self.phase == "read" then
		value = bor(value, 0x40, 0x20, 0x10)
	elseif self.phase == "write" then
		value = bor(value, 0x20, 0x10)
	end
	if self.phase ~= "command" then
		value = bor(value, lshift(1, self.current))
	end
	return value
end

local function statusA(self: Fdc): number
	local value = if self.irqPending then 0x80 else 0
	if not self.drives[2].image then
		value = bor(value, 0x40)
	end
	const drive = activeDrive(self)
	if drive.track == 0 then
		value = bor(value, 0x10)
	end
	if drive.head == 1 then
		value = bor(value, 0x08)
	end
	if drive.writeProtected then
		value = bor(value, 0x02)
	end
	return value
end

local function statusB(self: Fdc): number
	local value = 0xC0
	for index = 1, 2 do
		if self.drives[index].motor then
			value = bor(value, lshift(1, index - 1))
		end
	end
	if self.current == 0 then
		value = bor(value, 0x20)
	end
	return value
end

local function dirValue(self: Fdc): number
	const drive = activeDrive(self)
	return if drive.mediaChanged then 0x80 else 0x00
end

local function queueSense(self: Fdc, st0: number, pcn: number)
	self.senseQueue[#self.senseQueue + 1] = { st0 = st0, pcn = pcn }
end

local function raiseIrq(self: Fdc)
	self.irqPending = true
end

local function finishResult(self: Fdc, results: { number }, irq: boolean)
	self.results = results
	self.resultIndex = 0
	self.phase = "result"
	if irq then
		raiseIrq(self)
	end
end

local function failTransfer(self: Fdc, drive: Drive, st1: number)
	self.lastStatus = { 0, st1, 0 }
	finishResult(self, {
		bor(ST0_ABNTERM, band(drive.index, 0x03), if drive.head == 1 then 0x04 else 0),
		st1,
		0,
		drive.track,
		drive.head,
		drive.sector,
		2,
	}, true)
end

local function successTransfer(self: Fdc, drive: Drive)
	self.lastStatus = { 0, 0, 0 }
	finishResult(self, {
		bor(band(drive.index, 0x03), if drive.head == 1 then 0x04 else 0),
		0,
		0,
		drive.track,
		drive.head,
		drive.sector,
		2,
	}, true)
end

local function chsToLba(track: number, head: number, sector: number): number
	return ((track * Fdc.HEADS) + head) * Fdc.SECTORS + (sector - 1)
end

local function sectorCount(drive: Drive): number
	const image = drive.image
	if not image then
		return 0
	end
	return math.floor(buffer.len(image) / Fdc.SECTOR_SIZE)
end

local function readSector(drive: Drive, lba: number): buffer
	const out = buffer.create(Fdc.SECTOR_SIZE)
	const image = drive.image
	if image and lba >= 0 and (lba + 1) * Fdc.SECTOR_SIZE <= buffer.len(image) then
		buffer.copy(out, 0, image, lba * Fdc.SECTOR_SIZE, Fdc.SECTOR_SIZE)
	end
	return out
end

local function writeSector(drive: Drive, lba: number, data: buffer)
	const image = drive.image
	if not image or lba < 0 or (lba + 1) * Fdc.SECTOR_SIZE > buffer.len(image) then
		return false
	end
	buffer.copy(image, lba * Fdc.SECTOR_SIZE, data, 0, Fdc.SECTOR_SIZE)
	return true
end

local function markDirty(self: Fdc, drive: Drive, lba: number, count: number)
	drive.dirty = true
	self.dirty = true
	const last = lba + count - 1
	if not drive.dirtyFirstSector or lba < drive.dirtyFirstSector then
		drive.dirtyFirstSector = lba
	end
	if not drive.dirtyLastSector or last > drive.dirtyLastSector then
		drive.dirtyLastSector = last
	end
	if drive.dirtyCallback then
		drive.dirtyCallback(drive.index, lba, count)
	end
end

local function useDma(self: Fdc): boolean
	return band(self.dor, DOR_DMA) ~= 0 and self.dma ~= nil
end

local function dmaToMemory(self: Fdc, data: buffer): boolean
	if not self.dma then
		return false
	end
	self.dma:request(Fdc.DMA_CHANNEL, true)
	const written = self.dma:write(Fdc.DMA_CHANNEL, data)
	self.dma:request(Fdc.DMA_CHANNEL, false)
	return written == buffer.len(data)
end

local function dmaFromMemory(self: Fdc, length: number): buffer?
	if not self.dma then
		return nil
	end
	self.dma:request(Fdc.DMA_CHANNEL, true)
	const data = self.dma:read(Fdc.DMA_CHANNEL, length)
	self.dma:request(Fdc.DMA_CHANNEL, false)
	if not data or buffer.len(data) ~= length then
		return nil
	end
	return data
end

local function advancePosition(
	drive: Drive,
	track: number,
	head: number,
	sector: number,
	count: number
)
	local r = sector
	local h = head
	local c = track
	for _ = 1, count do
		r += 1
		if r > Fdc.SECTORS then
			r = 1
			h += 1
			if h >= Fdc.HEADS then
				h = 0
				c += 1
			end
		end
	end
	drive.track = c
	drive.head = h
	drive.sector = r
end

local function startReadWrite(self: Fdc, write: boolean)
	const driveIndex = band(self.params[1], 0x03)
	const head = band(rshift(self.params[1], 2), 0x01)
	const track = band(self.params[2], 0xFF)
	const sector = band(self.params[4], 0xFF)
	const eot = band(self.params[6], 0xFF)
	if driveIndex > 1 then
		failTransfer(self, activeDrive(self), ST1_MA)
		return
	end
	const drive = self.drives[driveIndex + 1]
	if not drive.image then
		failTransfer(self, drive, ST1_MA)
		return
	end
	if track >= Fdc.CYLINDERS or head >= Fdc.HEADS or sector < 1 or sector > Fdc.SECTORS then
		failTransfer(self, drive, ST1_MA)
		return
	end
	if write and drive.writeProtected then
		failTransfer(self, drive, ST1_NW)
		return
	end
	local count = eot - sector + 1
	if count < 1 then
		count = 1
	end
	const total = sectorCount(drive)
	const lba = chsToLba(track, head, sector)
	if lba < 0 or lba + count > total then
		failTransfer(self, drive, ST1_MA)
		return
	end
	const length = count * Fdc.SECTOR_SIZE
	drive.track = track
	drive.head = head
	drive.sector = sector
	if write then
		if useDma(self) then
			const data = dmaFromMemory(self, length)
			if not data then
				failTransfer(self, drive, ST1_MA)
				return
			end
			local offset = 0
			for index = 0, count - 1 do
				const piece = buffer.create(Fdc.SECTOR_SIZE)
				buffer.copy(piece, 0, data, offset, Fdc.SECTOR_SIZE)
				writeSector(drive, lba + index, piece)
				offset += Fdc.SECTOR_SIZE
			end
			markDirty(self, drive, lba, count)
			advancePosition(drive, track, head, sector, count)
			successTransfer(self, drive)
		else
			self.pending = {
				kind = "write",
				driveIndex = driveIndex,
				lba = lba,
				count = count,
				track = track,
				head = head,
				sector = sector,
				sectorSize = Fdc.SECTOR_SIZE,
				fill = 0,
				formatSectors = 0,
			}
			self.dataBuffer = buffer.create(length)
			self.dataPos = 0
			self.dataLength = length
			self.phase = "write"
		end
	else
		const data = buffer.create(length)
		for index = 0, count - 1 do
			const piece = readSector(drive, lba + index)
			buffer.copy(data, index * Fdc.SECTOR_SIZE, piece, 0, Fdc.SECTOR_SIZE)
		end
		advancePosition(drive, track, head, sector, count)
		if useDma(self) then
			if dmaToMemory(self, data) then
				successTransfer(self, drive)
			else
				failTransfer(self, drive, ST1_MA)
			end
		else
			self.dataBuffer = data
			self.dataPos = 0
			self.dataLength = length
			self.phase = "read"
		end
	end
end

local function completePendingWrite(self: Fdc)
	const pending = self.pending
	const data = self.dataBuffer
	if not pending or not data then
		toCommand(self)
		return
	end
	const drive = self.drives[pending.driveIndex + 1]
	if pending.kind == "format" then
		local offset = 0
		const fill = buffer.create(Fdc.SECTOR_SIZE)
		buffer.fill(fill, 0, pending.fill, Fdc.SECTOR_SIZE)
		for _ = 0, pending.formatSectors - 1 do
			const c = buffer.readu8(data, offset)
			const h = buffer.readu8(data, offset + 1)
			const r = buffer.readu8(data, offset + 2)
			offset += 4
			if c < Fdc.CYLINDERS and h < Fdc.HEADS and r >= 1 and r <= Fdc.SECTORS then
				const lba = chsToLba(c, h, r)
				writeSector(drive, lba, fill)
				markDirty(self, drive, lba, 1)
			end
		end
	else
		local offset = 0
		for index = 0, pending.count - 1 do
			const piece = buffer.create(Fdc.SECTOR_SIZE)
			buffer.copy(piece, 0, data, offset, Fdc.SECTOR_SIZE)
			writeSector(drive, pending.lba + index, piece)
			offset += Fdc.SECTOR_SIZE
		end
		markDirty(self, drive, pending.lba, pending.count)
		advancePosition(drive, pending.track, pending.head, pending.sector, pending.count)
	end
	self.pending = nil
	successTransfer(self, drive)
end

local function startFormat(self: Fdc)
	const driveIndex = band(self.params[1], 0x03)
	const head = band(rshift(self.params[1], 2), 0x01)
	const sectors = band(self.params[3], 0xFF)
	const fill = band(self.params[5], 0xFF)
	if driveIndex > 1 then
		failTransfer(self, activeDrive(self), ST1_MA)
		return
	end
	const drive = self.drives[driveIndex + 1]
	if not drive.image then
		failTransfer(self, drive, ST1_MA)
		return
	end
	if drive.writeProtected then
		failTransfer(self, drive, ST1_NW)
		return
	end
	const length = sectors * 4
	self.pending = {
		kind = "format",
		driveIndex = driveIndex,
		lba = 0,
		count = 0,
		track = drive.track,
		head = head,
		sector = 1,
		sectorSize = Fdc.SECTOR_SIZE,
		fill = fill,
		formatSectors = sectors,
	}
	if length == 0 then
		self.pending = nil
		successTransfer(self, drive)
		return
	end
	if useDma(self) then
		const data = dmaFromMemory(self, length)
		if not data then
			failTransfer(self, drive, ST1_MA)
			return
		end
		self.dataBuffer = data
		completePendingWrite(self)
	else
		self.dataBuffer = buffer.create(length)
		self.dataPos = 0
		self.dataLength = length
		self.phase = "write"
	end
end

local function executeCommand(self: Fdc)
	const op = band(self.command, 0x1F)
	if op == CMD_VERSION then
		finishResult(self, { 0x90 }, false)
	elseif op == CMD_SPECIFY or op == CMD_CONFIGURE or op == CMD_PERPENDICULAR then
		if op == CMD_CONFIGURE then
			self.config = self.params[1] or 0
		elseif op == CMD_PERPENDICULAR then
			self.perpendicular = self.params[1] or 0
		end
		toCommand(self)
	elseif op == CMD_LOCK then
		self.lock = true
		toCommand(self)
	elseif op == CMD_UNLOCK or op == CMD_POWERDOWN then
		self.lock = false
		toCommand(self)
	elseif op == CMD_SENSE_INT then
		const entry = table.remove(self.senseQueue, 1)
		if entry then
			finishResult(self, { entry.st0, entry.pcn }, false)
		else
			finishResult(self, { 0x80, 0 }, false)
		end
	elseif op == CMD_SENSE_DRIVE then
		const driveIndex = band(self.params[1], 0x03)
		const head = band(rshift(self.params[1], 2), 0x01)
		if driveIndex > 1 then
			finishResult(self, { 0 }, false)
			return
		end
		const drive = self.drives[driveIndex + 1]
		local st3 = band(driveIndex, 0x03)
		if head == 1 then
			st3 = bor(st3, 0x04)
		end
		if drive.image then
			st3 = bor(st3, 0x08, 0x20) -- two-sided, ready
		end
		if drive.track == 0 then
			st3 = bor(st3, 0x10)
		end
		if drive.writeProtected then
			st3 = bor(st3, 0x40)
		end
		finishResult(self, { st3 }, false)
	elseif op == CMD_RECALIBRATE then
		const driveIndex = band(self.params[1], 0x03)
		const drive = self.drives[math.min(driveIndex, 1) + 1]
		drive.track = 0
		drive.head = 0
		drive.sector = 1
		drive.mediaChanged = false
		queueSense(self, bor(0x20, band(driveIndex, 0x03)), 0)
		raiseIrq(self)
		toCommand(self)
	elseif op == CMD_SEEK then
		const driveIndex = band(self.params[1], 0x03)
		const head = band(rshift(self.params[1], 2), 0x01)
		const track = band(self.params[2], 0xFF)
		const drive = self.drives[math.min(driveIndex, 1) + 1]
		drive.track = track
		drive.head = head
		drive.sector = 1
		drive.mediaChanged = false
		queueSense(self, bor(0x20, band(driveIndex, 0x03), if head == 1 then 0x04 else 0), track)
		raiseIrq(self)
		toCommand(self)
	elseif op == CMD_READ_ID then
		const driveIndex = band(self.params[1], 0x03)
		const head = band(rshift(self.params[1], 2), 0x01)
		if driveIndex > 1 then
			failTransfer(self, activeDrive(self), ST1_MA)
			return
		end
		const drive = self.drives[driveIndex + 1]
		if not drive.image then
			failTransfer(self, drive, ST1_MA)
			return
		end
		drive.head = head
		finishResult(self, {
			bor(band(driveIndex, 0x03), if head == 1 then 0x04 else 0),
			0,
			0,
			drive.track,
			head,
			drive.sector,
			2,
		}, true)
	elseif op == CMD_READ or op == CMD_READ_DELETED or op == CMD_READ_TRACK then
		startReadWrite(self, false)
	elseif op == CMD_WRITE or op == CMD_WRITE_DELETED then
		startReadWrite(self, true)
	elseif op == CMD_FORMAT_TRACK then
		startFormat(self)
	elseif op == CMD_DUMPREG then
		finishResult(self, {
			self.drives[1].track,
			self.drives[2].track,
			self.params[1] or 0,
			self.params[2] or 0,
			0,
			if self.lock then 0x80 else 0,
			self.perpendicular,
			self.config,
			self.dor,
			self.dsr,
		}, false)
	elseif op == CMD_VERIFY then
		toCommand(self)
	else
		finishResult(self, { ST0_INVCMD }, false)
	end
end

function Fdc.in8(self: Fdc, port: number): number
	const offset = band(port - Fdc.BASE, 0x07)
	if offset == REG_SRA then
		return statusA(self)
	elseif offset == REG_SRB then
		return statusB(self)
	elseif offset == REG_DOR then
		return bor(self.dor, band(self.current, 0x03))
	elseif offset == REG_TDR then
		return self.tdr
	elseif offset == REG_MSR then
		return msrValue(self)
	elseif offset == REG_FIFO then
		if self.phase == "result" then
			if self.resultIndex < #self.results then
				const value = self.results[self.resultIndex + 1]
				self.resultIndex += 1
				if self.resultIndex >= #self.results then
					toCommand(self)
				end
				return band(value, 0xFF)
			end
			toCommand(self)
			return 0xFF
		elseif self.phase == "read" and self.dataBuffer then
			if self.dataPos < self.dataLength then
				const value = buffer.readu8(self.dataBuffer, self.dataPos)
				self.dataPos += 1
				if self.dataPos >= self.dataLength then
					successTransfer(self, activeDrive(self))
				end
				return value
			end
			return 0xFF
		end
		return 0xFF
	elseif offset == REG_DIR then
		return dirValue(self)
	end
	return 0xFF
end

function Fdc.out8(self: Fdc, port: number, value: number)
	value = band(value, 0xFF)
	const offset = band(port - Fdc.BASE, 0x07)
	if offset == REG_DOR then
		const wasReset = band(self.dor, DOR_RESET) == 0
		self.dor = value
		self.current = band(value, DOR_DRIVE_MASK)
		self.drives[1].motor = band(value, DOR_MOTOR_A) ~= 0
		self.drives[2].motor = band(value, DOR_MOTOR_B) ~= 0
		if band(value, DOR_RESET) == 0 then
			self.phase = "command"
			self.irqPending = false
		elseif wasReset then
			clearPending(self)
			self.phase = "command"
			self.irqPending = false
			self.senseQueue = {}
			for _, drive in ipairs(self.drives) do
				drive.track = 0
				drive.head = 0
				drive.sector = 1
				drive.mediaChanged = drive.image ~= nil
			end
			for _ = 1, 4 do
				queueSense(self, ST0_RDYCHG, 0)
			end
			raiseIrq(self)
		end
	elseif offset == REG_TDR then
		self.tdr = band(value, 0x0C)
	elseif offset == REG_MSR then
		self.dsr = value
		if band(value, 0x80) ~= 0 then
			clearPending(self)
			self.phase = "command"
			self.irqPending = false
		end
	elseif offset == REG_FIFO then
		if self.phase == "command" then
			if self.paramIndex == 0 and self.command == 0 then
				self.command = value
				self.params = {}
				self.paramIndex = 0
				self.paramCount = PARAM_COUNTS[band(value, 0x1F)] or 0
				if self.paramCount == 0 then
					executeCommand(self)
				end
			else
				self.params[#self.params + 1] = value
				self.paramIndex += 1
				if self.paramIndex >= self.paramCount then
					executeCommand(self)
				end
			end
		elseif self.phase == "write" and self.dataBuffer then
			if self.dataPos < self.dataLength then
				buffer.writeu8(self.dataBuffer, self.dataPos, value)
				self.dataPos += 1
				if self.dataPos >= self.dataLength then
					completePendingWrite(self)
				end
			end
		end
	elseif offset == REG_DIR then
		self.dsr = band(self.dsr, 0xFC)
		self.dsr = bor(self.dsr, band(value, 0x03))
	end
end

function Fdc.takeIrq(self: Fdc): boolean
	if not self.irqPending then
		return false
	end
	self.irqPending = false
	return true
end

function Fdc.driveDirty(self: Fdc, index: number): boolean
	const drive = self.drives[index + 1]
	return drive ~= nil and drive.dirty
end

function Fdc.clearDriveDirty(self: Fdc, index: number)
	const drive = self.drives[index + 1]
	if drive then
		drive.dirty = false
		drive.dirtyFirstSector = nil
		drive.dirtyLastSector = nil
	end
end

return Fdc
