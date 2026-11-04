--!strict
-- Cmos.lua -- MC146818 RTC and the PC's battery-backed CMOS RAM.
--
-- SeaBIOS reads the shutdown byte (0x0F), the extended-memory size words
-- (0x30/0x31) and the RTC status registers during POST. The clock is frozen at a
-- valid BCD time; this machine has no wall-clock source and no requirement that
-- the guest's date match the host.

const band, rshift = bit32.band, bit32.rshift

const Cmos = {}
Cmos.__index = Cmos

export type Config = {
	memorySize: number?,
}

export type Cmos = typeof(setmetatable(
	{} :: {
		index: number,
		nmiMasked: boolean,
		memorySize: number,
		ram: { [number]: number },
		shutdown: number,
		lastReadIndex: number,
		lastReadValue: number,
		readCount: number,
		trace: { string },
		in8: (self: Cmos, port: number) -> number,
		out8: (self: Cmos, port: number, value: number) -> (),
		setShutdown: (self: Cmos, value: number) -> (),
	},
	Cmos
))

local function toBcd(value: number): number
	return band(math.floor(value / 10), 0x0F) * 16 + value % 10
end

function Cmos.new(config: Config?): Cmos
	const cfg = (config or {}) :: Config
	local self = setmetatable({}, Cmos) :: any
	self.index = 0
	self.nmiMasked = false
	self.memorySize = cfg.memorySize or (16 * 1024 * 1024)
	self.ram = {}
	self.shutdown = 0
	self.lastReadIndex = 0
	self.lastReadValue = 0
	self.readCount = 0
	self.trace = {}
	return self
end

local function extendedKB(self: Cmos): number
	return math.min(0xFFFF, math.floor((self.memorySize - 0x100000) / 1024))
end

local function readRegister(self: Cmos, index: number): number
	if index == 0x00 then
		return 0x00 -- seconds
	elseif index == 0x01 then
		return 0x00
	elseif index == 0x02 then
		return 0x00 -- minutes
	elseif index == 0x03 then
		return 0x00
	elseif index == 0x04 then
		return 0x12 -- hours
	elseif index == 0x05 then
		return 0x00
	elseif index == 0x06 then
		return 0x01 -- day of week
	elseif index == 0x07 then
		return 0x01 -- day
	elseif index == 0x08 then
		return 0x01 -- month
	elseif index == 0x09 then
		return toBcd(26)
	elseif index == 0x0A then
		return 0x26 -- divider, 32.768 kHz, no update-in-progress
	elseif index == 0x0B then
		return 0x02 -- BCD, 24-hour, daylight saving disabled
	elseif index == 0x0C then
		return 0x00 -- no pending flag
	elseif index == 0x0D then
		return 0x80 -- battery good
	elseif index == 0x0E then
		return 0x00
	elseif index == 0x0F then
		return self.shutdown
	elseif index == 0x10 then
		return 0x00 -- no floppy drives
	elseif index == 0x12 then
		return 0x00 -- no fixed disk types
	elseif index == 0x14 then
		return 0x02 -- FPU present, no equipment bits
	elseif index == 0x15 or index == 0x16 then
		return if index == 0x15 then 0x80 else 0x02 -- 640 KiB base memory
	elseif index == 0x17 or index == 0x18 then
		const kb = extendedKB(self)
		return if index == 0x17 then band(kb, 0xFF) else band(rshift(kb, 8), 0xFF)
	elseif index == 0x30 or index == 0x31 then
		const kb = extendedKB(self)
		return if index == 0x30 then band(kb, 0xFF) else band(rshift(kb, 8), 0xFF)
	elseif index == 0x32 then
		return 0x20 -- century
	elseif index == 0x34 or index == 0x35 then
		return 0x00
	end
	return self.ram[index] or 0x00
end

function Cmos.out8(self: Cmos, port: number, value: number)
	value = band(value, 0xFF)
	if port == 0x70 then
		self.index = band(value, 0x7F)
		self.nmiMasked = band(value, 0x80) ~= 0
		return
	end
	if port == 0x71 then
		if #self.trace < 40 then
			self.trace[#self.trace + 1] = ("W%02X=%02X"):format(self.index, value)
		end
		if self.index == 0x0F then
			self.shutdown = value
		else
			self.ram[self.index] = value
		end
	end
end

function Cmos.in8(self: Cmos, port: number): number
	if port == 0x70 then
		return self.index
	elseif port == 0x71 then
		const value = readRegister(self, self.index)
		self.lastReadIndex = self.index
		self.lastReadValue = value
		self.readCount += 1
		if #self.trace < 40 then
			self.trace[#self.trace + 1] = ("R%02X=%02X"):format(self.index, value)
		end
		return value
	end
	return 0xFF
end

function Cmos.setShutdown(self: Cmos, value: number)
	self.shutdown = band(value, 0xFF)
end

return Cmos
