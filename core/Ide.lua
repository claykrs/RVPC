--!strict
-- Ide.lua -- primary IDE channel: ATA-2 PIO hard disk + ATAPI CD-ROM.
--
-- The controller exposes the classic task-file ports (0x1F0-0x1F7, 0x3F6)
-- with a master HDD and slave CD-ROM. Commands complete synchronously; PIO
-- data sits in a one-command buffer and IRQ14 is raised when DRQ/DRDY is ready.
-- The drive images are host-supplied buffers (core never touches the
-- filesystem).

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const Ide = {}
Ide.__index = Ide

const DATA = 0x1F0
const ALT_STATUS = 0x3F6
const IRQ = 14
const IRQ_SECONDARY = 15
const BM_CMD_START = 0x01
const BM_CMD_MEMWRITE = 0x08
const BM_STATUS_ACTIVE = 0x01
const BM_STATUS_ERROR = 0x02
const BM_STATUS_INT = 0x04
const BM_STATUS_DMA_CAP = 0x20

const ST_ERR = 0x01
const ST_DRQ = 0x08
const ST_DSC = 0x10
const ST_DRDY = 0x40
const ST_BSY = 0x80

const ATA_IDENTIFY = 0xEC
const ATA_READ = 0x20
const ATA_WRITE = 0x30
const ATA_READ_DMA = 0xC8
const ATA_WRITE_DMA = 0xCA
const ATA_READ_DMA_EXT = 0x25
const ATA_WRITE_DMA_EXT = 0x35
const ATA_FLUSH = 0xE7
const ATA_SET_FEATURES = 0xEF
const ATA_IDENTIFY_PACKET = 0xA1
const ATA_DEVICE_RESET = 0x08
const ATA_PACKET = 0xA0
const ATA_DIAGNOSTIC = 0x90
const ATA_INIT_PARAMS = 0x91
const ATA_NOP = 0x00

const SENSE_NOT_READY = 0x02
const SENSE_ILLEGAL_REQUEST = 0x05
const ASC_INVALID_OPCODE = 0x20
const ASC_LBA_OUT_OF_RANGE = 0x21
const ASC_INVALID_FIELD = 0x24
const ASC_MEDIUM_NOT_PRESENT = 0x3A
const ASC_MEDIA_REMOVAL_PREVENTED = 0x53
const MAX_ATAPI_SECTORS = 2048

-- A real device stays busy for a short period after the host hands over the
-- last word of a PIO write (committing the sector) before signalling
-- completion with DRDY + INTRQ. Guests drive the whole channel state machine
-- off that interrupt, so completing the write instantly at the last data
-- write makes the completion observable through the status register BEFORE
-- the interrupt and double-signals the event. The delay is counted in
-- advance() cycles (machine steps).
const WRITE_COMPLETION_DELAY = 200

export type Partition = {
	index: number,
	status: number,
	kind: number,
	lba: number,
	sectors: number,
}

export type Drive = {
	present: boolean,
	kind: string, -- "hdd" | "cdrom"
	image: buffer?,
	status: number,
	error: number,
	model: string,
	-- True while the task file still holds the power-on signature (ATAPI
	-- 0x14/0xEB in the cylinder registers); DOS ATAPI drivers detect the CD
	-- by reading it. Any register write or command hands the file to the guest.
	sig: boolean,
}

export type Transfer = {
	buffer: buffer,
	pos: number,
	length: number,
	write: boolean,
	lba: number,
}

export type Config = {
	hdd: buffer?,
	cdrom: buffer?,
	base: number?,
	altBase: number?,
	irq: number?,
	bmBase: number?,
	mem: any?,
}

export type Ide = typeof(setmetatable(
	{} :: {
		master: Drive,
		slave: Drive,
		selected: Drive,
		selectedIndex: number,
		base: number,
		altBase: number,
		irq: number,
		bmBase: number,
		mem: any?,
		bmCmd: number,
		bmStatus: number,
		bmPrdt: number,
		lba: number,
		sectorCount: number,
		driveHead: number,
		deviceControl: number,
		transfer: Transfer?,
		packet: buffer,
		packetPos: number,
		pktCdb: boolean,
		pktData: boolean,
		-- ATAPI interrupt-reason phase: 1 = CDB accept (CoD=1), 2 = data
		-- transfer (I/O=1), 3 = command completed (CoD=1, I/O=1). 0 = idle.
		packetPhase: number,
		features: number,
		atapiDma: boolean,
		irqPending: boolean,
		lastError: number,
		senseKey: number,
		senseAsc: number,
		senseAscq: number,
		mediaLocked: boolean,
		commandCount: number,
		lastCommand: number,
		identifyCount: number,
		packetCount: number,
		dirty: boolean,
		dirtyFirstSector: number?,
		dirtyLastSector: number?,
		-- Cycles left before a pending PIO write completion goes DRDY.
		writeDoneCycles: number,
		diskDirty: (self: Ide) -> boolean,
		clearDiskDirty: (self: Ide) -> (),
		dirtySectorRange: (self: Ide) -> (number?, number?),
		in8: (self: Ide, port: number) -> number,
		out8: (self: Ide, port: number, value: number) -> (),
		in16: (self: Ide, port: number) -> number,
		out16: (self: Ide, port: number, value: number) -> (),
		bmIn8: (self: Ide, port: number) -> number,
		bmOut8: (self: Ide, port: number, value: number) -> (),
		bmIn16: (self: Ide, port: number) -> number,
		bmOut16: (self: Ide, port: number, value: number) -> (),
		bmIn32: (self: Ide, port: number) -> number,
		bmOut32: (self: Ide, port: number, value: number) -> (),
		advance: (self: Ide) -> (),
		takeIrq: (self: Ide) -> boolean,
		reset: (self: Ide) -> (),
	},
	Ide
))

local function newDrive(kind: string, image: buffer?, present: boolean): Drive
	return {
		present = present,
		kind = kind,
		image = image,
		status = if present then bor(ST_DRDY, ST_DSC) else 0,
		error = 0,
		model = if kind == "hdd" then "RVPC VIRTUAL HDD" else "RVPC VIRTUAL CD",
		sig = true,
	}
end

-- Task-file signature bytes a device reports after reset: sector count 0x01,
-- sector number 0x01, cylinder low/high 0x14/0xEB for ATAPI, 0x00/0x00 for ATA.
local function sigRegister(drive: Drive, offset: number): number
	if drive.kind == "cdrom" then
		if offset == 4 then
			return 0x14
		elseif offset == 5 then
			return 0xEB
		end
	end
	if offset == 2 or offset == 3 then
		return 0x01
	end
	return 0x00
end

function Ide.new(config: Config?): Ide
	const cfg = (config or {}) :: Config
	local self = setmetatable({}, Ide) :: any
	self.master = newDrive("hdd", cfg.hdd, cfg.hdd ~= nil)
	self.slave = newDrive("cdrom", cfg.cdrom, cfg.cdrom ~= nil)
	self.selected = self.master
	self.selectedIndex = 0
	self.base = cfg.base or DATA
	self.altBase = cfg.altBase or ALT_STATUS
	self.irq = cfg.irq or IRQ
	self.bmBase = cfg.bmBase or 0xC000
	self.mem = cfg.mem
	self.bmCmd = 0
	self.bmStatus = BM_STATUS_DMA_CAP
	self.bmPrdt = 0
	self.lba = 0
	self.sectorCount = 0
	self.driveHead = 0
	self.deviceControl = 0
	self.transfer = nil
	self.packet = buffer.create(16)
	self.packetPos = 0
	self.pktCdb = false
	self.pktData = false
	self.packetPhase = 0
	self.features = 0
	self.atapiDma = false
	self.irqPending = false
	self.lastError = 0
	self.senseKey = 0
	self.senseAsc = 0
	self.senseAscq = 0
	self.mediaLocked = false
	self.commandCount = 0
	self.lastCommand = 0
	self.identifyCount = 0
	self.packetCount = 0
	self.dirty = false
	self.dirtyFirstSector = nil
	self.dirtyLastSector = nil
	self.writeDoneCycles = 0
	return self
end

-- ATA SRST (device control bit 2) resets both devices on the channel. The
-- host's drive-select register and the nIEN bit are not part of the device
-- reset, so the selected drive and deviceControl are preserved by this helper.
local function softReset(self: Ide)
	self.transfer = nil
	self.packetPos = 0
	self.pktCdb = false
	self.pktData = false
	self.packetPhase = 0
	self.features = 0
	self.atapiDma = false
	self.irqPending = false
	self.writeDoneCycles = 0
	self.master.status = if self.master.present then bor(ST_DRDY, ST_DSC) else 0
	self.slave.status = if self.slave.present then bor(ST_DRDY, ST_DSC) else 0
	self.master.error = 0
	self.slave.error = 0
	self.master.sig = true
	self.slave.sig = true
	self.senseKey = 0
	self.senseAsc = 0
	self.senseAscq = 0
	self.mediaLocked = false
end

function Ide.reset(self: Ide)
	self.selected = self.master
	self.selectedIndex = 0
	self.deviceControl = 0
	self.writeDoneCycles = 0
	softReset(self)
	self.bmCmd = 0
	self.bmStatus = BM_STATUS_DMA_CAP
	self.bmPrdt = 0
end

local function putWord(buf: buffer, index: number, value: number)
	buffer.writeu16(buf, index * 2, band(value, 0xFFFF))
end

local function putScsiString(buf: buffer, byteOffset: number, text: string, length: number)
	for index = 0, length - 1 do
		const byte = if index < #text then string.byte(text, index + 1) :: number else 32
		buffer.writeu8(buf, byteOffset + index, byte)
	end
end

-- ATA IDENTIFY stores the first character of each pair in the high byte of
-- the word; SCSI INQUIRY uses plain byte order.
local function putAtaString(buf: buffer, byteOffset: number, text: string, length: number)
	for index = 0, length - 1 do
		const byte = if index < #text then string.byte(text, index + 1) :: number else 32
		const wordOffset = byteOffset + math.floor(index / 2) * 2
		buffer.writeu8(buf, wordOffset + (if index % 2 == 0 then 1 else 0), byte)
	end
end

local function capacitySectors(drive: Drive, blockSize: number): number
	const image = drive.image
	if not image then
		return 0
	end
	return math.floor(buffer.len(image) / blockSize)
end

local function finalizeIdentify(out: buffer)
	-- Word 255 is the two's-complement checksum of words 0..254. Some OS
	-- drivers (including Windows 9x) validate it before trusting the rest.
	local sum = 0
	for index = 0, 254 do
		sum += buffer.readu16(out, index * 2)
	end
	putWord(out, 255, band(0x10000 - band(sum, 0xFFFF), 0xFFFF))
end

local function identify(drive: Drive): buffer
	const out = buffer.create(512)
	if drive.kind == "cdrom" then
		putWord(out, 0, 0x85C0) -- ATAPI packet device
		putWord(out, 1, 0)
		putWord(out, 49, 0x0300) -- DMA + LBA supported
		putWord(out, 53, 0x0002) -- words 54-58 (model) valid
		putWord(out, 63, 0x0007) -- multiword DMA modes 0-2
		putWord(out, 80, 0x0004) -- ATA/ATAPI-2
		putWord(out, 82, 0x0100) -- DMA
		putAtaString(out, 54, "RVPC VIRTUAL CD", 40)
		finalizeIdentify(out)
		return out
	end
	putWord(out, 0, 0x0040)
	const total = capacitySectors(drive, 512)
	-- Report a CHS geometry that matches the image size instead of the old
	-- fixed 16383/16/63 (which described an 8 GiB disk on every image). LBA28
	-- remains authoritative; CHS is only the INT13 fallback geometry.
	const heads = 16
	const sectorsPerTrack = 63
	const cylinders = math.max(1, math.min(16383, math.floor(total / (heads * sectorsPerTrack))))
	putWord(out, 1, cylinders) -- cylinders
	putWord(out, 3, heads) -- heads
	putWord(out, 6, sectorsPerTrack) -- sectors/track
	putWord(out, 49, 0x0300) -- DMA + LBA
	putWord(out, 53, 0x0006) -- words 54-58 and 64-70 are valid
	putWord(out, 60, band(total, 0xFFFF))
	putWord(out, 61, band(rshift(total, 16), 0xFFFF))
	putWord(out, 63, 0x0007) -- multiword DMA modes 0-2
	putWord(out, 64, 0x0003) -- advanced PIO modes 3 and 4
	putWord(out, 65, 0x0078) -- 120 ns minimum multiword DMA cycle
	putWord(out, 66, 0x0078)
	putWord(out, 67, 0x0078) -- 120 ns minimum PIO cycle without flow control
	putWord(out, 68, 0x0078)
	putWord(out, 80, 0x0004) -- ATA-2
	putWord(out, 82, 0x4100) -- DMA + LBA
	putAtaString(out, 54, "RVPC VIRTUAL HDD", 40)
	finalizeIdentify(out)
	return out
end

local function finish(self: Ide, status: number)
	self.selected.status = status
	self.transfer = nil
	self.pktCdb = false
	self.pktData = false
	if self.packetPhase ~= 0 then
		self.packetPhase = 3
	end
	self.irqPending = true
end

local dmaFinish: (self: Ide, ok: boolean) -> ()
local dmaBufferToGuest: (self: Ide, data: buffer) -> boolean

local function beginRead(self: Ide, data: buffer)
	const length = buffer.len(data)
	if length == 0 then
		finish(self, bor(ST_DRDY, ST_DSC))
		return
	end
	if self.atapiDma then
		self.atapiDma = false
		self.bmStatus = bor(
			band(self.bmStatus, bit32.bnot(bor(BM_STATUS_ERROR, BM_STATUS_INT))),
			BM_STATUS_ACTIVE
		)
		dmaFinish(self, dmaBufferToGuest(self, data))
		return
	end
	self.transfer = {
		buffer = data,
		pos = 0,
		length = length,
		write = false,
		lba = self.lba,
	}
	self.selected.status = bor(ST_DRDY, ST_DSC, ST_DRQ)
end

local function beginWrite(self: Ide, lba: number, length: number)
	self.transfer = {
		buffer = buffer.create(length),
		pos = 0,
		length = length,
		write = true,
		lba = lba,
	}
	self.selected.status = bor(ST_DRDY, ST_DSC, ST_DRQ)
end

-- Track guest writes so a host harness can decide whether the backing image
-- needs to be persisted. The range is a conservative union: non-contiguous
-- writes are reported as one span from the first to the last touched sector.
local function markDiskDirty(self: Ide, lba: number, sectors: number)
	if sectors <= 0 then
		return
	end
	self.dirty = true
	const last = lba + sectors - 1
	if not self.dirtyFirstSector or lba < self.dirtyFirstSector then
		self.dirtyFirstSector = lba
	end
	if not self.dirtyLastSector or last > self.dirtyLastSector then
		self.dirtyLastSector = last
	end
end

local function completeWrite(self: Ide, transfer: Transfer)
	const drive = self.selected
	if drive.kind == "hdd" and drive.image then
		buffer.copy(drive.image, transfer.lba * 512, transfer.buffer, 0, transfer.length)
		markDiskDirty(self, transfer.lba, math.floor(transfer.length / 512))
	end
	-- The device received all sector data; hold BSY for the media-commit
	-- period before signalling completion (see WRITE_COMPLETION_DELAY).
	self.transfer = nil
	self.pktCdb = false
	self.pktData = false
	self.writeDoneCycles = WRITE_COMPLETION_DELAY
	self.selected.status = ST_BSY
end

function Ide.diskDirty(self: Ide): boolean
	return self.dirty
end

function Ide.clearDiskDirty(self: Ide)
	self.dirty = false
	self.dirtyFirstSector = nil
	self.dirtyLastSector = nil
end

-- Inclusive sector range touched since the last clearDiskDirty(), or nil when
-- the image is clean.
function Ide.dirtySectorRange(self: Ide): (number?, number?)
	return self.dirtyFirstSector, self.dirtyLastSector
end

-- BDMA helpers. The bus-master engine walks the guest's PRDT in physical
-- memory and moves whole ATA sectors. Memory access is injected through the
-- host-owned Memory object; the IDE core never touches a filesystem.
local function memRead32(mem: any, addr: number): number
	return mem:read32(addr)
end

local function memCopyTo(mem: any, addr: number, length: number): buffer
	return mem:copyTo(addr, length)
end

local function memCopyFrom(mem: any, addr: number, data: buffer)
	mem:copyFrom(addr, data)
end

local function dmaReady(self: Ide, read: boolean): boolean
	if not self.mem or self.bmPrdt == 0 or band(self.bmCmd, BM_CMD_START) == 0 then
		return false
	end
	return (band(self.bmCmd, BM_CMD_MEMWRITE) ~= 0) == read
end

function dmaBufferToGuest(self: Ide, data: buffer): boolean
	const mem = self.mem
	if not mem then
		return false
	end
	local address = self.bmPrdt
	local offset = 0
	const total = buffer.len(data)
	local entries = 0
	while offset < total and entries < 4096 do
		const bufferAddress = memRead32(mem, address)
		const sizeWord = memRead32(mem, address + 4)
		local count = band(sizeWord, 0xFFFE)
		if count == 0 then
			count = 0x10000
		end
		const last = band(sizeWord, 0x80000000) ~= 0
		const chunk = math.min(count, total - offset)
		if chunk > 0 then
			const piece = buffer.create(chunk)
			buffer.copy(piece, 0, data, offset, chunk)
			memCopyFrom(mem, bufferAddress, piece)
			offset += chunk
		end
		address += 8
		entries += 1
		if last then
			break
		end
	end
	return offset == total
end

local function dmaGuestToBuffer(self: Ide, data: buffer): boolean
	const mem = self.mem
	if not mem then
		return false
	end
	local address = self.bmPrdt
	local offset = 0
	const total = buffer.len(data)
	local entries = 0
	while offset < total and entries < 4096 do
		const bufferAddress = memRead32(mem, address)
		const sizeWord = memRead32(mem, address + 4)
		local count = band(sizeWord, 0xFFFE)
		if count == 0 then
			count = 0x10000
		end
		const last = band(sizeWord, 0x80000000) ~= 0
		const chunk = math.min(count, total - offset)
		if chunk > 0 then
			const piece = memCopyTo(mem, bufferAddress, chunk)
			buffer.copy(data, offset, piece, 0, chunk)
			offset += chunk
		end
		address += 8
		entries += 1
		if last then
			break
		end
	end
	return offset == total
end

function dmaFinish(self: Ide, ok: boolean)
	if ok then
		self.selected.status = bor(ST_DRDY, ST_DSC)
		self.bmStatus = bor(
			band(self.bmStatus, bit32.bnot(bor(BM_STATUS_ACTIVE, BM_STATUS_ERROR))),
			BM_STATUS_INT
		)
	else
		self.selected.error = 0x04
		self.lastError = 0x04
		self.selected.status = bor(ST_DRDY, ST_ERR)
		self.bmStatus =
			bor(band(self.bmStatus, bit32.bnot(BM_STATUS_ACTIVE)), BM_STATUS_ERROR, BM_STATUS_INT)
	end
	self.transfer = nil
	if self.packetPhase ~= 0 then
		self.packetPhase = 3
	end
	self.irqPending = true
end

local function dmaRead(self: Ide, drive: Drive, lba: number, count: number)
	const image = drive.image
	if not image then
		dmaFinish(self, false)
		return
	end
	self.bmStatus =
		bor(band(self.bmStatus, bit32.bnot(bor(BM_STATUS_ERROR, BM_STATUS_INT))), BM_STATUS_ACTIVE)
	const data = buffer.create(count * 512)
	buffer.copy(data, 0, image, lba * 512, count * 512)
	dmaFinish(self, dmaBufferToGuest(self, data))
end

local function dmaWrite(self: Ide, drive: Drive, lba: number, count: number)
	const image = drive.image
	if not image then
		dmaFinish(self, false)
		return
	end
	self.bmStatus =
		bor(band(self.bmStatus, bit32.bnot(bor(BM_STATUS_ERROR, BM_STATUS_INT))), BM_STATUS_ACTIVE)
	const data = buffer.create(count * 512)
	if not dmaGuestToBuffer(self, data) then
		dmaFinish(self, false)
		return
	end
	buffer.copy(image, lba * 512, data, 0, count * 512)
	markDiskDirty(self, lba, count)
	dmaFinish(self, true)
end

local function failCommand(self: Ide, errorCode: number)
	self.selected.error = errorCode
	self.lastError = errorCode
	self.selected.status = bor(ST_DRDY, ST_ERR)
	self.transfer = nil
	self.pktCdb = false
	self.pktData = false
	if self.packetPhase ~= 0 then
		self.packetPhase = 3
	end
	self.irqPending = true
end

local function readBE32(buf: buffer, offset: number): number
	return bor(
		lshift(buffer.readu8(buf, offset), 24),
		lshift(buffer.readu8(buf, offset + 1), 16),
		lshift(buffer.readu8(buf, offset + 2), 8),
		buffer.readu8(buf, offset + 3)
	)
end

local function readBE16(buf: buffer, offset: number): number
	return bor(lshift(buffer.readu8(buf, offset), 8), buffer.readu8(buf, offset + 1))
end

local function putBE32(buf: buffer, offset: number, value: number)
	buffer.writeu8(buf, offset, band(rshift(value, 24), 0xFF))
	buffer.writeu8(buf, offset + 1, band(rshift(value, 16), 0xFF))
	buffer.writeu8(buf, offset + 2, band(rshift(value, 8), 0xFF))
	buffer.writeu8(buf, offset + 3, band(value, 0xFF))
end

local function putBE16(buf: buffer, offset: number, value: number)
	buffer.writeu8(buf, offset, band(rshift(value, 8), 0xFF))
	buffer.writeu8(buf, offset + 1, band(value, 0xFF))
end

local function failAtapi(self: Ide, senseKey: number, asc: number, ascq: number?)
	self.senseKey = senseKey
	self.senseAsc = asc
	self.senseAscq = ascq or 0
	failCommand(self, 0x04)
end

local function atapiReply(self: Ide, data: buffer, allocation: number)
	const length = math.max(0, math.min(buffer.len(data), allocation))
	if length < buffer.len(data) then
		const sliced = buffer.create(length)
		if length > 0 then
			buffer.copy(sliced, 0, data, 0, length)
		end
		beginRead(self, sliced)
	else
		beginRead(self, data)
	end
	if self.transfer ~= nil then
		self.packetPhase = 2
	end
	self.irqPending = true
end

local function atapiRange(self: Ide, lba: number, count: number): boolean
	const drive = self.selected
	if not drive.image then
		failAtapi(self, SENSE_NOT_READY, ASC_MEDIUM_NOT_PRESENT)
		return false
	end
	const total = capacitySectors(drive, 2048)
	if lba < 0 or count > MAX_ATAPI_SECTORS or lba >= total or lba + count > total then
		failAtapi(self, SENSE_ILLEGAL_REQUEST, ASC_LBA_OUT_OF_RANGE)
		return false
	end
	return true
end

local function atapiRead(self: Ide, lba: number, count: number)
	const drive = self.selected
	const image = drive.image
	if count == 0 then
		finish(self, bor(ST_DRDY, ST_DSC))
		return
	end
	if not image or not atapiRange(self, lba, count) then
		return
	end
	const data = buffer.create(count * 2048)
	buffer.copy(data, 0, image, lba * 2048, count * 2048)
	beginRead(self, data)
	if self.transfer ~= nil then
		self.packetPhase = 2
	end
	self.irqPending = true
end

local function atapiVerify(self: Ide, lba: number, count: number)
	if count == 0 or atapiRange(self, lba, count) then
		finish(self, bor(ST_DRDY, ST_DSC))
	end
end

local function msfParts(lba: number): (number, number, number)
	const frames = lba + 150
	return math.floor(frames / 75 / 60), math.floor(frames / 75) % 60, frames % 75
end

local function putMsf3(buf: buffer, offset: number, lba: number)
	const minute, second, frame = msfParts(lba)
	buffer.writeu8(buf, offset, minute)
	buffer.writeu8(buf, offset + 1, second)
	buffer.writeu8(buf, offset + 2, frame)
end

local function putTocEntry(
	buf: buffer,
	offset: number,
	control: number,
	track: number,
	lba: number,
	msf: boolean
)
	buffer.writeu8(buf, offset, 0)
	buffer.writeu8(buf, offset + 1, control)
	buffer.writeu8(buf, offset + 2, track)
	buffer.writeu8(buf, offset + 3, 0)
	if msf then
		buffer.writeu8(buf, offset + 4, 0)
		putMsf3(buf, offset + 5, lba)
	else
		putBE32(buf, offset + 4, lba)
	end
end

local function putFullTocEntry(
	buf: buffer,
	offset: number,
	point: number,
	pmin: number,
	psec: number,
	pframe: number
)
	buffer.writeu8(buf, offset, 1) -- session number
	buffer.writeu8(buf, offset + 1, 0x14) -- ADR=1, data track
	buffer.writeu8(buf, offset + 2, 0) -- TNO
	buffer.writeu8(buf, offset + 3, point)
	-- min/sec/frame of the POINT itself are zero for a single session.
	buffer.writeu8(buf, offset + 7, 0)
	buffer.writeu8(buf, offset + 8, pmin)
	buffer.writeu8(buf, offset + 9, psec)
	buffer.writeu8(buf, offset + 10, pframe)
end

local function atapiReadToc(self: Ide, allocation: number)
	const msf = band(buffer.readu8(self.packet, 1), 0x02) ~= 0
	local format = band(buffer.readu8(self.packet, 2), 0x0F)
	if format == 0 then
		-- Legacy ATAPI put the format in the top two bits of byte 9.
		format = rshift(buffer.readu8(self.packet, 9), 6)
	end
	const startTrack = buffer.readu8(self.packet, 6)
	const total = capacitySectors(self.selected, 2048)
	if format == 0 then
		const tracks: { number } = {}
		if startTrack <= 1 then
			tracks[#tracks + 1] = 1
		end
		tracks[#tracks + 1] = 0xAA
		const data = buffer.create(4 + 8 * #tracks)
		putBE16(data, 0, 2 + 8 * #tracks)
		buffer.writeu8(data, 2, 1)
		buffer.writeu8(data, 3, 1)
		for index, track in ipairs(tracks) do
			putTocEntry(
				data,
				4 + (index - 1) * 8,
				0x14,
				track,
				if track == 0xAA then total else 0,
				msf
			)
		end
		atapiReply(self, data, allocation)
	elseif format == 1 then
		const data = buffer.create(12)
		putBE16(data, 0, 10)
		buffer.writeu8(data, 2, 1) -- first complete session
		buffer.writeu8(data, 3, 1) -- last complete session
		buffer.writeu8(data, 5, 0x14) -- ADR=1, data track
		buffer.writeu8(data, 6, 1) -- first track in last session
		atapiReply(self, data, allocation)
	elseif format == 2 then
		const data = buffer.create(4 + 11 * 4)
		putBE16(data, 0, 2 + 11 * 4)
		buffer.writeu8(data, 2, 1)
		buffer.writeu8(data, 3, 1)
		putFullTocEntry(data, 4, 0xA0, 1, 0, 0)
		putFullTocEntry(data, 15, 0xA1, 1, 0, 0)
		const minute, second, frame = msfParts(total)
		putFullTocEntry(data, 26, 0xA2, minute, second, frame)
		putFullTocEntry(data, 37, 0x01, 0, 2, 0)
		atapiReply(self, data, allocation)
	else
		-- PMA/ATIP are not populated; return a valid empty response.
		const data = buffer.create(4)
		putBE16(data, 0, 0)
		atapiReply(self, data, allocation)
	end
end

local function makeModePage(code: number, values: { number }): buffer
	const data = buffer.create(2 + #values)
	buffer.writeu8(data, 0, code)
	buffer.writeu8(data, 1, #values)
	for index, value in ipairs(values) do
		buffer.writeu8(data, 1 + index, value)
	end
	return data
end

local function concatPages(pages: { buffer }): buffer
	local total = 0
	for _, page in ipairs(pages) do
		total += buffer.len(page)
	end
	const data = buffer.create(total)
	local offset = 0
	for _, page in ipairs(pages) do
		buffer.copy(data, offset, page, 0, buffer.len(page))
		offset += buffer.len(page)
	end
	return data
end

local function modeSensePages(code: number): buffer?
	if code == 0x3F then
		return concatPages({
			makeModePage(0x01, { 0x00, 0x05, 0x00, 0x00, 0x00, 0x00 }),
			makeModePage(0x0E, {
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
			}),
			makeModePage(0x2A, {
				0x3B,
				0x00,
				0x71,
				0x60,
				0x29,
				0x00,
				0x02,
				0xC0,
				0x00,
				0x02,
				0x02,
				0x00,
				0x02,
				0xC0,
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
				0x00,
			}),
		})
	elseif code == 0x01 then
		return makeModePage(0x01, { 0x00, 0x05, 0x00, 0x00, 0x00, 0x00 })
	elseif code == 0x0E then
		return makeModePage(0x0E, { 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0 })
	elseif code == 0x2A then
		return makeModePage(0x2A, {
			0x3B,
			0x00,
			0x71,
			0x60,
			0x29,
			0x00,
			0x02,
			0xC0,
			0x00,
			0x02,
			0x02,
			0x00,
			0x02,
			0xC0,
			0x00,
			0x00,
			0x00,
			0x00,
			0x00,
			0x00,
		})
	end
	return nil
end

local function atapiModeSense(self: Ide, ten: boolean, allocation: number)
	const action = rshift(buffer.readu8(self.packet, 2), 6)
	if action ~= 0 then
		failAtapi(self, SENSE_ILLEGAL_REQUEST, ASC_INVALID_FIELD)
		return
	end
	const code = band(buffer.readu8(self.packet, 2), 0x3F)
	const pages = modeSensePages(code)
	if not pages then
		failAtapi(self, SENSE_ILLEGAL_REQUEST, ASC_INVALID_FIELD)
		return
	end
	const header = if ten then 8 else 4
	const data = buffer.create(header + buffer.len(pages))
	if ten then
		putBE16(data, 0, buffer.len(data) - 2)
	else
		buffer.writeu8(data, 0, buffer.len(data) - 1)
	end
	buffer.copy(data, header, pages, 0, buffer.len(pages))
	atapiReply(self, data, allocation)
end

local function atapiGetConfiguration(self: Ide, allocation: number)
	const startFeature = readBE16(self.packet, 2)
	if startFeature ~= 0 then
		failAtapi(self, SENSE_ILLEGAL_REQUEST, ASC_INVALID_FIELD)
		return
	end
	const data = buffer.create(16)
	putBE32(data, 0, 12)
	putBE16(data, 6, 0x0008) -- current profile: CD-ROM
	putBE16(data, 8, 0x0000) -- profile list feature
	buffer.writeu8(data, 10, 0x03) -- current + persistent
	buffer.writeu8(data, 11, 4)
	putBE16(data, 12, 0x0008)
	buffer.writeu8(data, 14, 0x01) -- profile is current
	atapiReply(self, data, allocation)
end

local function atapiInquiry(self: Ide, allocation: number)
	if band(buffer.readu8(self.packet, 1), 0x01) ~= 0 then
		const page = buffer.readu8(self.packet, 2)
		if page == 0 then
			const data = buffer.create(5)
			buffer.writeu8(data, 0, 0x05)
			buffer.writeu8(data, 3, 1)
			atapiReply(self, data, allocation)
		else
			failAtapi(self, SENSE_ILLEGAL_REQUEST, ASC_INVALID_FIELD)
		end
		return
	end
	const data = buffer.create(36)
	buffer.writeu8(data, 0, 0x05) -- CD-ROM
	buffer.writeu8(data, 1, 0x80) -- removable
	buffer.writeu8(data, 3, 0x21) -- ATAPI-2
	buffer.writeu8(data, 4, 31)
	putScsiString(data, 8, "RVPC", 8)
	putScsiString(data, 16, "VIRTUAL CD", 16)
	putScsiString(data, 32, "1.0", 4)
	atapiReply(self, data, allocation)
end

local function atapiReadHeader(self: Ide, allocation: number)
	const lba = readBE32(self.packet, 2)
	if not atapiRange(self, lba, 1) then
		return
	end
	const data = buffer.create(8)
	buffer.writeu8(data, 0, 0x01) -- CD-ROM mode 1
	if band(buffer.readu8(self.packet, 1), 0x02) ~= 0 then
		putMsf3(data, 5, lba)
	else
		putBE32(data, 4, lba)
	end
	atapiReply(self, data, allocation)
end

local function atapiPacket(self: Ide)
	const drive = self.selected
	self.pktCdb = false
	self.pktData = true
	if drive.kind ~= "cdrom" then
		failAtapi(self, SENSE_ILLEGAL_REQUEST, ASC_INVALID_OPCODE)
		return
	end
	const savedKey = self.senseKey
	const savedAsc = self.senseAsc
	const savedAscq = self.senseAscq
	self.senseKey = 0
	self.senseAsc = 0
	self.senseAscq = 0
	const op = buffer.readu8(self.packet, 0)
	if op == 0x03 then -- REQUEST SENSE
		const allocation = buffer.readu8(self.packet, 4)
		const data = buffer.create(18)
		buffer.writeu8(data, 0, 0xF0)
		buffer.writeu8(data, 2, band(savedKey, 0x0F))
		buffer.writeu8(data, 7, 10)
		buffer.writeu8(data, 12, savedAsc)
		buffer.writeu8(data, 13, savedAscq)
		atapiReply(self, data, allocation)
		return
	end
	if not drive.image then
		failAtapi(self, SENSE_NOT_READY, ASC_MEDIUM_NOT_PRESENT)
		return
	end
	if op == 0x00 or op == 0xBB then -- TEST UNIT READY / SET CD SPEED
		finish(self, bor(ST_DRDY, ST_DSC))
	elseif op == 0x12 then -- INQUIRY
		atapiInquiry(self, buffer.readu8(self.packet, 4))
	elseif op == 0x1A then -- MODE SENSE(6)
		atapiModeSense(self, false, buffer.readu8(self.packet, 4))
	elseif op == 0x5A then -- MODE SENSE(10)
		atapiModeSense(self, true, readBE16(self.packet, 7))
	elseif op == 0x1B then -- START STOP UNIT
		const start = band(buffer.readu8(self.packet, 4), 0x01) ~= 0
		const loej = band(buffer.readu8(self.packet, 4), 0x02) ~= 0
		const powerCondition = band(buffer.readu8(self.packet, 4), 0xF0)
		if powerCondition == 0 and loej and not start and self.mediaLocked then
			failAtapi(self, SENSE_NOT_READY, ASC_MEDIA_REMOVAL_PREVENTED)
		else
			finish(self, bor(ST_DRDY, ST_DSC))
		end
	elseif op == 0x1E then -- PREVENT/ALLOW MEDIUM REMOVAL
		self.mediaLocked = band(buffer.readu8(self.packet, 4), 0x01) ~= 0
		finish(self, bor(ST_DRDY, ST_DSC))
	elseif op == 0x25 then -- READ CAPACITY(10)
		const total = capacitySectors(drive, 2048)
		const data = buffer.create(8)
		putBE32(data, 0, math.max(0, total - 1))
		putBE32(data, 4, 2048)
		atapiReply(self, data, 8)
	elseif op == 0x28 then -- READ(10)
		atapiRead(self, readBE32(self.packet, 2), readBE16(self.packet, 7))
	elseif op == 0xA8 then -- READ(12)
		const count = bor(
			lshift(buffer.readu8(self.packet, 6), 16),
			lshift(buffer.readu8(self.packet, 7), 8),
			buffer.readu8(self.packet, 8)
		)
		atapiRead(self, readBE32(self.packet, 2), count)
	elseif op == 0x88 then -- READ(16)
		const high = readBE32(self.packet, 2)
		const low = readBE32(self.packet, 6)
		const count = readBE32(self.packet, 10)
		if high ~= 0 then
			failAtapi(self, SENSE_ILLEGAL_REQUEST, ASC_LBA_OUT_OF_RANGE)
		else
			atapiRead(self, low, count)
		end
	elseif op == 0x2F then -- VERIFY(10)
		atapiVerify(self, readBE32(self.packet, 2), readBE16(self.packet, 7))
	elseif op == 0x2B then -- SEEK(10)
		const lba = readBE32(self.packet, 2)
		if atapiRange(self, lba, 1) then
			finish(self, bor(ST_DRDY, ST_DSC))
		end
	elseif op == 0x43 then -- READ TOC/PMA/ATIP
		atapiReadToc(self, readBE16(self.packet, 7))
	elseif op == 0x44 then -- READ HEADER
		atapiReadHeader(self, readBE16(self.packet, 7))
	elseif op == 0x46 then -- GET CONFIGURATION
		atapiGetConfiguration(self, readBE16(self.packet, 7))
	elseif op == 0x51 then -- READ DISC INFORMATION
		const allocation = readBE16(self.packet, 7)
		const data = buffer.create(34)
		buffer.writeu8(data, 1, 32)
		buffer.writeu8(data, 2, 0x0E)
		buffer.writeu8(data, 3, 1)
		buffer.writeu8(data, 4, 1)
		buffer.writeu8(data, 5, 1)
		buffer.writeu8(data, 6, 1)
		buffer.writeu8(data, 7, 0x20)
		atapiReply(self, data, allocation)
	else
		failAtapi(self, SENSE_ILLEGAL_REQUEST, ASC_INVALID_OPCODE)
	end
end

-- ATAPI PACKET normally carries 12-byte CDBs; READ(16) is the one command
-- that needs the 16-byte packet form.
local function packetReady(self: Ide): boolean
	if self.packetPos >= 16 then
		return true
	end
	return self.packetPos == 12 and buffer.readu8(self.packet, 0) ~= 0x88
end

local function command(self: Ide, cmd: number)
	-- A guest should not issue commands while the device is busy committing a
	-- write; if it does, the commit completes immediately first.
	if self.writeDoneCycles > 0 then
		self.writeDoneCycles = 0
		finish(self, bor(ST_DRDY, ST_DSC))
	end
	self.commandCount += 1
	self.lastCommand = cmd
	self.packetPhase = 0
	const drive = self.selected
	if not drive.present then
		-- Unreachable through Ide.out8 (empty positions swallow command
		-- writes), but keep the position inert if a command ever lands here:
		-- no device means no status change, no error register and no IRQ.
		self.transfer = nil
		self.irqPending = false
		return
	end
	self.transfer = nil
	self.atapiDma = false
	drive.error = 0
	drive.sig = false
	self.lastError = 0
	if cmd == ATA_IDENTIFY then
		self.identifyCount += 1
		if drive.kind ~= "hdd" then
			failCommand(self, 0x04)
			-- ATAPI devices keep the reset signature (0x14/0xEB in the
			-- cylinder registers) after an aborted IDENTIFY DEVICE. DOS
			-- ATAPI probes use ABRT + this signature pair to distinguish a
			-- CD-ROM from an ATA disk.
			if drive.kind == "cdrom" then
				drive.sig = true
			end
			return
		end
		beginRead(self, identify(drive))
		self.irqPending = true
	elseif cmd == ATA_IDENTIFY_PACKET then
		self.identifyCount += 1
		if drive.kind ~= "cdrom" then
			failCommand(self, 0x04)
			return
		end
		beginRead(self, identify(drive))
		self.irqPending = true
	elseif cmd == ATA_READ or cmd == ATA_READ_DMA or cmd == ATA_READ_DMA_EXT then
		const count = if self.sectorCount == 0 then 256 else self.sectorCount
		const image = drive.image
		const total = capacitySectors(drive, 512)
		if not image or self.lba >= total or self.lba + count > total then
			failCommand(self, 0x04)
			return
		end
		const isDma = cmd == ATA_READ_DMA or cmd == ATA_READ_DMA_EXT
		if isDma then
			-- BMIDE only applies to the DMA commands. A plain ATA READ must
			-- stay PIO even if the bus-master engine happens to be armed.
			if drive.kind ~= "hdd" or not dmaReady(self, true) then
				failCommand(self, 0x04)
				return
			end
			dmaRead(self, drive, self.lba, count)
			return
		end
		if drive.kind ~= "hdd" then
			failCommand(self, 0x04)
			return
		end
		const data = buffer.create(count * 512)
		buffer.copy(data, 0, image, self.lba * 512, count * 512)
		beginRead(self, data)
		self.irqPending = true
	elseif cmd == ATA_WRITE or cmd == ATA_WRITE_DMA or cmd == ATA_WRITE_DMA_EXT then
		if drive.kind ~= "hdd" then
			failCommand(self, 0x04)
			return
		end
		const count = if self.sectorCount == 0 then 256 else self.sectorCount
		const image = drive.image
		const total = capacitySectors(drive, 512)
		if not image or self.lba >= total or self.lba + count > total then
			failCommand(self, 0x04)
			return
		end
		const isDma = cmd == ATA_WRITE_DMA or cmd == ATA_WRITE_DMA_EXT
		if isDma then
			-- As above: a plain ATA WRITE is PIO and must not consume the
			-- PRDT merely because the bus-master command register is armed.
			if not dmaReady(self, false) then
				failCommand(self, 0x04)
				return
			end
			dmaWrite(self, drive, self.lba, count)
			return
		end
		beginWrite(self, self.lba, count * 512)
		self.irqPending = true
	elseif cmd == ATA_PACKET then
		self.packetCount += 1
		if drive.kind ~= "cdrom" then
			failCommand(self, 0x04)
			return
		end
		self.packetPos = 0
		self.pktCdb = true
		self.pktData = false
		self.packetPhase = 1
		self.atapiDma = band(self.features, 0x01) ~= 0 and dmaReady(self, true)
		drive.status = bor(ST_DRDY, ST_DSC, ST_DRQ)
	elseif
		cmd == ATA_FLUSH
		or cmd == ATA_SET_FEATURES
		or cmd == ATA_INIT_PARAMS
		or cmd == ATA_NOP
	then
		finish(self, bor(ST_DRDY, ST_DSC))
	elseif cmd == ATA_DIAGNOSTIC then
		self.master.error = 0
		self.slave.error = 0
		finish(self, bor(ST_DRDY, ST_DSC))
	elseif cmd == ATA_DEVICE_RESET then
		-- DEVICE RESET reloads the selected device's power-on signature into
		-- the task file. ATAPI detection in DOS drivers reads 0x14/0xEB out of
		-- the cylinder registers right after issuing it.
		drive.sig = true
		drive.error = 0
		finish(self, bor(ST_DRDY, ST_DSC))
		-- DEVICE RESET asserts INTRQ when the device is ready again.
		self.irqPending = true
	else
		failCommand(self, 0x04)
	end
end

local function readDataByte(self: Ide): number
	const transfer = self.transfer
	if not transfer or transfer.write or transfer.pos >= transfer.length then
		return 0xFF
	end
	const value = buffer.readu8(transfer.buffer, transfer.pos)
	transfer.pos += 1
	if transfer.pos >= transfer.length then
		finish(self, bor(ST_DRDY, ST_DSC))
	end
	return value
end

local function readDataWord(self: Ide): number
	const transfer = self.transfer
	if not transfer or transfer.write or transfer.pos + 1 >= transfer.length then
		return 0xFFFF
	end
	const value = buffer.readu16(transfer.buffer, transfer.pos)
	transfer.pos += 2
	if transfer.pos >= transfer.length then
		finish(self, bor(ST_DRDY, ST_DSC))
	end
	return value
end

local function writeDataByte(self: Ide, value: number)
	const transfer = self.transfer
	if not transfer or not transfer.write or transfer.pos >= transfer.length then
		return
	end
	buffer.writeu8(transfer.buffer, transfer.pos, band(value, 0xFF))
	transfer.pos += 1
	if transfer.pos >= transfer.length then
		completeWrite(self, transfer)
	end
end

local function writeDataWord(self: Ide, value: number)
	const transfer = self.transfer
	if not transfer or not transfer.write or transfer.pos + 1 >= transfer.length then
		return
	end
	buffer.writeu16(transfer.buffer, transfer.pos, band(value, 0xFFFF))
	transfer.pos += 2
	if transfer.pos >= transfer.length then
		completeWrite(self, transfer)
	end
end

function Ide.out8(self: Ide, port: number, value: number)
	value = band(value, 0xFF)
	const offset = port - self.base
	if port == self.altBase then
		-- SRST is level-sensitive but the device reset occurs on the 0->1
		-- transition. Clear any stale ERR/DRQ and reload both signatures;
		-- the host's selected drive and nIEN bit survive the reset.
		if band(value, 0x04) ~= 0 and band(self.deviceControl, 0x04) == 0 then
			softReset(self)
		end
		self.deviceControl = value
		return
	end
	if offset == 6 then
		self.driveHead = value
		self.selectedIndex = if band(value, 0x10) ~= 0 then 1 else 0
		self.selected = if self.selectedIndex == 0 then self.master else self.slave
		if band(value, 0x40) ~= 0 then
			self.lba = bor(band(self.lba, 0x00FFFFFF), lshift(band(value, 0x0F), 24))
		end
		return
	end
	-- The remaining task-file registers live in the selected device. With no
	-- device at that position the writes are lost on the floating bus: nothing
	-- latches, no signature is disturbed, no command runs and no IRQ is
	-- raised. Answering as a live controller that rejects commands makes
	-- drivers probe phantom devices on empty channels.
	if not self.selected.present then
		return
	end
	if offset == 0 then
		if self.transfer and self.transfer.write then
			writeDataByte(self, value)
		elseif
			not self.transfer
			and self.packetPos < 16
			and band(self.selected.status, ST_DRQ) ~= 0
		then
			buffer.writeu8(self.packet, self.packetPos, value)
			self.packetPos += 1
			if packetReady(self) then
				atapiPacket(self)
			end
		end
	elseif offset == 1 then
		self.features = value
		self.selected.sig = false
	elseif offset == 2 then
		self.sectorCount = value
		self.selected.sig = false
	elseif offset == 3 then
		self.lba = bor(band(self.lba, 0xFFFFF00), value)
		self.selected.sig = false
	elseif offset == 4 then
		self.lba = bor(band(self.lba, 0xFFFF00FF), lshift(value, 8))
		self.selected.sig = false
	elseif offset == 5 then
		self.lba = bor(band(self.lba, 0xFF00FFFF), lshift(value, 16))
		self.selected.sig = false
	elseif offset == 7 then
		command(self, value)
	end
end

function Ide.in8(self: Ide, port: number): number
	-- An unpopulated device position leaves the task file floating: the whole
	-- register file (status, error, interrupt reason, signatures, data) reads
	-- as 0xFF, the way an empty ISA/PCI IDE bus does. Drivers treat any 0xFF
	-- status as "nothing here" and skip the position; answering with a live
	-- controller's 0x00/0x41 makes them probe phantom devices.
	if not self.selected.present then
		return 0xFF
	end
	const offset = port - self.base
	if offset == 0 then
		return readDataByte(self)
	elseif offset == 1 then
		return self.selected.error
	elseif offset == 2 then
		if self.selected.sig then
			return sigRegister(self.selected, 2)
		end
		-- During packet transfers the sector-count register is the interrupt
		-- reason: REL bit 2, I/O bit 1, CoD bit 0. CDB delivery is CoD=1,
		-- data-to-host is I/O=1, and command completion is CoD=1 with I/O=1.
		if self.pktCdb then
			return 0x01
		end
		if self.pktData and self.transfer ~= nil then
			return if self.transfer.write then 0x00 else 0x02
		end
		if self.packetPhase == 3 then
			return 0x03
		end
		return self.sectorCount
	elseif offset == 3 then
		if self.selected.sig then
			return sigRegister(self.selected, 3)
		end
		return band(self.lba, 0xFF)
	elseif offset == 4 then
		if self.selected.sig then
			return sigRegister(self.selected, 4)
		end
		-- Packet phases report the byte count of the current burst in the
		-- cylinder registers; the CDB burst is 12 bytes.
		if self.pktCdb then
			return 0x0C
		end
		if self.pktData and self.transfer ~= nil then
			return band(self.transfer.length - self.transfer.pos, 0xFF)
		end
		return band(rshift(self.lba, 8), 0xFF)
	elseif offset == 5 then
		if self.selected.sig then
			return sigRegister(self.selected, 5)
		end
		if self.pktCdb then
			return 0x00
		end
		if self.pktData and self.transfer ~= nil then
			return band(rshift(self.transfer.length - self.transfer.pos, 8), 0xFF)
		end
		return band(rshift(self.lba, 16), 0xFF)
	elseif offset == 6 then
		return self.driveHead
	elseif offset == 7 or port == self.altBase then
		return self.selected.status
	end
	return 0xFF
end

function Ide.in16(self: Ide, port: number): number
	if port == self.base then
		return readDataWord(self)
	end
	return bor(self:in8(port), lshift(self:in8(port + 1), 8))
end

function Ide.out16(self: Ide, port: number, value: number)
	if port == self.base then
		if self.transfer and self.transfer.write then
			writeDataWord(self, value)
		elseif
			not self.transfer
			and self.packetPos + 1 < 16
			and band(self.selected.status, ST_DRQ) ~= 0
		then
			buffer.writeu16(self.packet, self.packetPos, band(value, 0xFFFF))
			self.packetPos += 2
			if packetReady(self) then
				atapiPacket(self)
			end
		end
		return
	end
	self:out8(port, band(value, 0xFF))
	self:out8(port + 1, band(rshift(value, 8), 0xFF))
end

function Ide.bmIn8(self: Ide, port: number): number
	const offset = port - self.bmBase
	if offset == 0 then
		return self.bmCmd
	elseif offset == 2 then
		return self.bmStatus
	elseif offset >= 4 and offset <= 7 then
		return band(rshift(self.bmPrdt, (offset - 4) * 8), 0xFF)
	end
	return 0
end

function Ide.bmOut8(self: Ide, port: number, value: number)
	value = band(value, 0xFF)
	const offset = port - self.bmBase
	if offset == 0 then
		self.bmCmd = band(value, 0x09)
		if band(value, BM_CMD_START) == 0 then
			self.bmStatus = band(self.bmStatus, bit32.bnot(BM_STATUS_ACTIVE))
		end
	elseif offset == 1 then
		-- Reserved.
	elseif offset == 2 then
		-- Writing 1 clears interrupt/error; command/capability bits survive.
		self.bmStatus = band(self.bmStatus, bit32.bnot(band(value, 0x06)))
	elseif offset >= 4 and offset <= 7 then
		const shift = (offset - 4) * 8
		const mask = lshift(0xFF, shift)
		self.bmPrdt =
			band(bor(band(self.bmPrdt, bit32.bnot(mask)), lshift(value, shift)), 0xFFFFFFFC)
	end
end

function Ide.bmIn16(self: Ide, port: number): number
	const offset = port - self.bmBase
	if offset == 0 then
		return self.bmCmd
	elseif offset == 2 then
		return self.bmStatus
	elseif offset >= 4 and offset <= 7 then
		return bor(self:bmIn8(port), lshift(self:bmIn8(port + 1), 8))
	end
	return 0xFFFF
end

function Ide.bmOut16(self: Ide, port: number, value: number)
	const offset = port - self.bmBase
	if offset == 0 then
		self:bmOut8(port, band(value, 0xFF))
		self:bmOut8(port + 2, band(rshift(value, 16), 0xFF))
		return
	end
	self:bmOut8(port, band(value, 0xFF))
	self:bmOut8(port + 1, band(rshift(value, 8), 0xFF))
end

function Ide.bmIn32(self: Ide, port: number): number
	const offset = port - self.bmBase
	if offset == 0 then
		return bor(self.bmCmd, lshift(self.bmStatus, 16))
	elseif offset == 4 then
		return self.bmPrdt
	end
	return 0xFFFFFFFF
end

function Ide.bmOut32(self: Ide, port: number, value: number)
	const offset = port - self.bmBase
	if offset == 0 then
		self:bmOut8(port, band(value, 0xFF))
		self:bmOut8(port + 2, band(rshift(value, 16), 0xFF))
	elseif offset == 4 then
		self.bmPrdt = band(value, 0xFFFFFFFC)
	end
end

-- One machine step: retires the pending PIO write completion when its media
-- commit period has elapsed. The host sees BSY until then and DRDY + INTRQ
-- after, matching the timing real drivers sequence their state machine on.
function Ide.advance(self: Ide)
	if self.writeDoneCycles > 0 then
		self.writeDoneCycles -= 1
		if self.writeDoneCycles == 0 then
			finish(self, bor(ST_DRDY, ST_DSC))
		end
	end
end

function Ide.takeIrq(self: Ide): boolean
	if not self.irqPending then
		return false
	end
	if band(self.deviceControl, 0x02) ~= 0 then
		return false
	end
	self.irqPending = false
	return true
end

-- Parse the four primary MBR partition entries. SeaBIOS normally does this
-- itself; the helper is also used by tests and the host disk UI.
function Ide.parseMbr(image: buffer): { Partition }
	local partitions: { Partition } = {}
	if buffer.len(image) < 512 or buffer.readu16(image, 510) ~= 0xAA55 then
		return partitions
	end
	for index = 0, 3 do
		const offset = 446 + index * 16
		const kind = buffer.readu8(image, offset + 4)
		const lba = buffer.readu32(image, offset + 8)
		const sectors = buffer.readu32(image, offset + 12)
		if kind ~= 0 and sectors ~= 0 then
			partitions[#partitions + 1] = {
				index = index,
				status = buffer.readu8(image, offset),
				kind = kind,
				lba = lba,
				sectors = sectors,
			}
		end
	end
	return partitions
end

-- Return the active (status 0x80) primary partition, or nil when the MBR has
-- no boot flag. SeaBIOS does its own MBR scan; this mirrors it for tests and
-- the host disk UI.
function Ide.findBootPartition(image: buffer): Partition?
	for _, partition in ipairs(Ide.parseMbr(image)) do
		if partition.status == 0x80 then
			return partition
		end
	end
	return nil
end

Ide.IRQ = IRQ
Ide.IRQ_SECONDARY = IRQ_SECONDARY

return Ide
