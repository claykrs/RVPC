--!strict
-- Cmos.lua -- MC146818 RTC and the PC's battery-backed CMOS RAM.
--
-- The clock starts at 2026-01-01 12:00:00 (Thursday) and advances one second
-- per 1,193,182 emulated Machine.run steps, i.e. one second per PIT input
-- count. Time never comes from the host. Date rollover uses the real month
-- lengths and Gregorian leap years. Time/date/alarm registers are formatted
-- from status B (BCD/binary, 12/24-hour) and may be written by the guest.
--
-- Status A rate bits select the periodic interrupt rate from the 32.768 kHz
-- divider. The divider bits are stored but the emulated time base is always
-- 32.768 kHz (the PC board's crystal). Status C PF/AF/UF are set by events and
-- IRQF is asserted when the matching status B enable is set; reading status C
-- clears all four. The update-in-progress bit is asserted for the last 244 us
-- of each second.

const band, bor, bnot, rshift = bit32.band, bit32.bor, bit32.bnot, bit32.rshift

const Cmos = {}
Cmos.__index = Cmos

const PIT_INPUT_HZ = 1193182
const RTC_INPUT_HZ = 32768
const UIP_STEPS = 291 -- 244 us at the 1.193182 MHz PIT input

const STATUS_B_24H = 0x02
const STATUS_B_DM = 0x04
const STATUS_B_UIE = 0x10
const STATUS_B_AIE = 0x20
const STATUS_B_PIE = 0x40
const STATUS_B_SET = 0x80
const STATUS_C_UF = 0x10
const STATUS_C_AF = 0x20
const STATUS_C_PF = 0x40
const STATUS_C_IRQF = 0x80
const ENABLE_MASK = bor(STATUS_B_UIE, STATUS_B_AIE, STATUS_B_PIE)
const ALARM_IGNORE = 0xC0

export type RtcState = {
	regA: number,
	regB: number,
	regC: number,
	regD: number,
	period: number,
	phase: number,
	clockTicks: number,
	second: number,
	minute: number,
	hour: number,
	dayOfWeek: number,
	day: number,
	month: number,
	year: number,
	century: number,
	alarmSecond: number,
	alarmMinute: number,
	alarmHour: number,
}

export type Config = {
	memorySize: number?,
	floppyType: number?,
}

export type Cmos = typeof(setmetatable(
	{} :: {
		index: number,
		nmiMasked: boolean,
		memorySize: number,
		floppyType: number,
		ram: { [number]: number },
		shutdown: number,
		rtc: RtcState,
		stepsPerSecond: number,
		uipSteps: number,
		lastReadIndex: number,
		lastReadValue: number,
		readCount: number,
		trace: { string },
		in8: (self: Cmos, port: number) -> number,
		out8: (self: Cmos, port: number, value: number) -> boolean,
		advance: (self: Cmos, steps: number) -> boolean,
		advanceSeconds: (self: Cmos, seconds: number) -> boolean,
		irqPending: (self: Cmos) -> boolean,
		setShutdown: (self: Cmos, value: number) -> (),
	},
	Cmos
))

local function toBcd(value: number): number
	return band(math.floor(value / 10), 0x0F) * 16 + value % 10
end

local function fromBcd(value: number): number?
	const high = band(rshift(value, 4), 0x0F)
	const low = band(value, 0x0F)
	if high > 9 or low > 9 then
		return nil
	end
	return high * 10 + low
end

local function isLeapYear(year: number): boolean
	return year % 4 == 0 and (year % 100 ~= 0 or year % 400 == 0)
end

const MONTH_DAYS = { 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 }

local function daysInMonth(year: number, month: number): number
	if month == 2 and isLeapYear(year) then
		return 29
	end
	return MONTH_DAYS[month] or 31
end

local function rtcPeriod(regA: number): number
	const rate = band(regA, 0x0F)
	if rate == 0 then
		return 0
	end
	const frequency = rshift(RTC_INPUT_HZ, rate - 1)
	if frequency == 0 then
		return 0
	end
	return math.max(1, math.floor(PIT_INPUT_HZ / frequency + 0.5))
end

local function newRtcState(): RtcState
	const regA = 0x26
	return {
		regA = regA,
		regB = 0x02,
		regC = 0,
		regD = 0x80,
		period = rtcPeriod(regA),
		phase = 0,
		clockTicks = 0,
		second = 0,
		minute = 0,
		hour = 12,
		dayOfWeek = 5, -- 2026-01-01 is a Thursday (Sunday = 1)
		day = 1,
		month = 1,
		year = 26,
		century = 20,
		alarmSecond = 0,
		alarmMinute = 0,
		alarmHour = 0,
	}
end

local function formatValue(self: Cmos, value: number): number
	if band(self.rtc.regB, STATUS_B_DM) ~= 0 then
		return band(value, 0xFF)
	end
	return toBcd(value)
end

local function formatHour(self: Cmos): number
	const rtc = self.rtc
	const binary = band(rtc.regB, STATUS_B_DM) ~= 0
	if band(rtc.regB, STATUS_B_24H) ~= 0 then
		return if binary then rtc.hour else toBcd(rtc.hour)
	end
	const pm = rtc.hour >= 12
	local hour12 = rtc.hour % 12
	if hour12 == 0 then
		hour12 = 12
	end
	const value = if binary then hour12 else toBcd(hour12)
	return if pm then bor(value, 0x80) else value
end

local function statusA(self: Cmos): number
	const rtc = self.rtc
	local value = band(rtc.regA, 0x7F)
	if
		band(rtc.regB, STATUS_B_SET) == 0
		and rtc.clockTicks >= self.stepsPerSecond - self.uipSteps
	then
		value = bor(value, 0x80)
	end
	return value
end

local function alarmFieldMatches(raw: number, current: number, bcd: boolean): boolean
	if band(raw, ALARM_IGNORE) == ALARM_IGNORE then
		return true
	end
	const value = if bcd then fromBcd(band(raw, 0x3F)) else band(raw, 0x3F)
	return value == current
end

local function alarmHourMatches(rtc: RtcState): boolean
	const raw = rtc.alarmHour
	if band(raw, ALARM_IGNORE) == ALARM_IGNORE then
		return true
	end
	const bcd = band(rtc.regB, STATUS_B_DM) == 0
	if band(rtc.regB, STATUS_B_24H) ~= 0 then
		const value = if bcd then fromBcd(band(raw, 0x7F)) else band(raw, 0x7F)
		return value == rtc.hour
	end
	const pm = band(raw, 0x80) ~= 0
	const hour12 = if bcd then fromBcd(band(raw, 0x7F)) else band(raw, 0x7F)
	if hour12 == nil or hour12 < 1 or hour12 > 12 then
		return false
	end
	local hour = hour12 % 12
	if pm then
		hour += 12
	end
	return hour == rtc.hour
end

local function alarmMatches(self: Cmos): boolean
	const rtc = self.rtc
	const bcd = band(rtc.regB, STATUS_B_DM) == 0
	return alarmFieldMatches(rtc.alarmSecond, rtc.second, bcd)
		and alarmFieldMatches(rtc.alarmMinute, rtc.minute, bcd)
		and alarmHourMatches(rtc)
end

local function advanceDay(self: Cmos)
	const rtc = self.rtc
	rtc.dayOfWeek = (rtc.dayOfWeek % 7) + 1
	if rtc.month < 1 or rtc.month > 12 then
		rtc.month = 1
	end
	if rtc.day < 1 then
		rtc.day = 1
	end
	rtc.day += 1
	const fullYear = rtc.century * 100 + rtc.year
	if rtc.day > daysInMonth(fullYear, rtc.month) then
		rtc.day = 1
		rtc.month += 1
		if rtc.month > 12 then
			rtc.month = 1
			rtc.year += 1
			if rtc.year > 99 then
				rtc.year = 0
				rtc.century = (rtc.century + 1) % 100
			end
		end
	end
end

local function recordUpdate(self: Cmos, events: number): boolean
	const rtc = self.rtc
	const before = rtc.regC
	const newEvents = band(events, bnot(before))
	rtc.regC = bor(before, events)
	if band(newEvents, band(rtc.regB, ENABLE_MASK)) ~= 0 and band(before, STATUS_C_IRQF) == 0 then
		rtc.regC = bor(rtc.regC, STATUS_C_IRQF)
		return true
	end
	return false
end

local function stepSecond(self: Cmos): boolean
	const rtc = self.rtc
	rtc.second += 1
	if rtc.second >= 60 then
		rtc.second = 0
		rtc.minute += 1
		if rtc.minute >= 60 then
			rtc.minute = 0
			rtc.hour += 1
			if rtc.hour >= 24 then
				rtc.hour = 0
				advanceDay(self)
			end
		end
	end
	local events = STATUS_C_UF
	if alarmMatches(self) then
		events = bor(events, STATUS_C_AF)
	end
	return recordUpdate(self, events)
end

local function advanceWholeSeconds(self: Cmos, seconds: number): boolean
	local remaining = math.floor(seconds)
	if remaining <= 0 then
		return false
	end
	local irq = false
	if remaining >= 86400 then
		const days = math.floor(remaining / 86400)
		remaining = remaining % 86400
		for _ = 1, days do
			advanceDay(self)
		end
		local events = STATUS_C_UF
		if alarmMatches(self) then
			events = bor(events, STATUS_C_AF)
		end
		irq = recordUpdate(self, events)
	end
	for _ = 1, remaining do
		if stepSecond(self) then
			irq = true
		end
	end
	return irq
end

local function readStatusC(self: Cmos): number
	const value = self.rtc.regC
	self.rtc.regC = 0
	return value
end

local function decodeField(self: Cmos, value: number, low: number, high: number): number?
	const raw = band(value, 0xFF)
	const decoded = if band(self.rtc.regB, STATUS_B_DM) ~= 0 then raw else fromBcd(raw)
	if decoded == nil or decoded < low or decoded > high then
		return nil
	end
	return decoded
end

local function writeHour(self: Cmos, value: number)
	const rtc = self.rtc
	const bcd = band(rtc.regB, STATUS_B_DM) == 0
	if band(rtc.regB, STATUS_B_24H) ~= 0 then
		const hour = if bcd then fromBcd(band(value, 0x7F)) else band(value, 0x7F)
		if hour ~= nil and hour <= 23 then
			rtc.hour = hour
		end
		return
	end
	const pm = band(value, 0x80) ~= 0
	const hour12 = if bcd then fromBcd(band(value, 0x7F)) else band(value, 0x7F)
	if hour12 == nil or hour12 < 1 or hour12 > 12 then
		return
	end
	local hour = hour12 % 12
	if pm then
		hour += 12
	end
	rtc.hour = hour
end

local function syncIrq(self: Cmos): boolean
	const rtc = self.rtc
	const was = band(rtc.regC, STATUS_C_IRQF) ~= 0
	if band(rtc.regC, band(rtc.regB, ENABLE_MASK)) ~= 0 then
		rtc.regC = bor(rtc.regC, STATUS_C_IRQF)
	else
		rtc.regC = band(rtc.regC, bnot(STATUS_C_IRQF))
	end
	return not was and band(rtc.regC, STATUS_C_IRQF) ~= 0
end

local function writeRegister(self: Cmos, index: number, value: number): boolean
	const rtc = self.rtc
	if index == 0x0A then
		const oldRate = band(rtc.regA, 0x0F)
		rtc.regA = band(value, 0x7F) -- UIP is read-only
		rtc.period = rtcPeriod(rtc.regA)
		if band(rtc.regA, 0x0F) ~= oldRate or rtc.period == 0 then
			rtc.phase = 0
		end
		return false
	elseif index == 0x0B then
		const wasSet = band(rtc.regB, STATUS_B_SET) ~= 0
		const wasPie = band(rtc.regB, STATUS_B_PIE) ~= 0
		rtc.regB = band(value, 0xFF)
		if (band(rtc.regB, STATUS_B_SET) ~= 0) ~= wasSet then
			rtc.clockTicks = 0
		end
		if (band(rtc.regB, STATUS_B_PIE) ~= 0) ~= wasPie then
			rtc.phase = 0
		end
		return syncIrq(self)
	elseif index == 0x0C or index == 0x0D then
		return false
	elseif index == 0x00 then
		const decoded = decodeField(self, value, 0, 59)
		if decoded then
			rtc.second = decoded
		end
		return false
	elseif index == 0x01 then
		rtc.alarmSecond = band(value, 0xFF)
		return false
	elseif index == 0x02 then
		const decoded = decodeField(self, value, 0, 59)
		if decoded then
			rtc.minute = decoded
		end
		return false
	elseif index == 0x03 then
		rtc.alarmMinute = band(value, 0xFF)
		return false
	elseif index == 0x04 then
		writeHour(self, value)
		return false
	elseif index == 0x05 then
		rtc.alarmHour = band(value, 0xFF)
		return false
	elseif index == 0x06 then
		const decoded = decodeField(self, value, 1, 7)
		if decoded then
			rtc.dayOfWeek = decoded
		end
		return false
	elseif index == 0x07 then
		const decoded = decodeField(self, value, 1, 31)
		if decoded then
			rtc.day = decoded
		end
		return false
	elseif index == 0x08 then
		const decoded = decodeField(self, value, 1, 12)
		if decoded then
			rtc.month = decoded
		end
		return false
	elseif index == 0x09 then
		const decoded = decodeField(self, value, 0, 99)
		if decoded then
			rtc.year = decoded
		end
		return false
	elseif index == 0x32 then
		const decoded = decodeField(self, value, 0, 99)
		if decoded then
			rtc.century = decoded
		end
		return false
	end
	self.ram[index] = band(value, 0xFF)
	return false
end

local function extendedKB(self: Cmos): number
	return math.min(0xFFFF, math.floor((self.memorySize - 0x100000) / 1024))
end

local function readRegister(self: Cmos, index: number): number
	const rtc = self.rtc
	if index == 0x00 then
		return formatValue(self, rtc.second)
	elseif index == 0x01 then
		return band(rtc.alarmSecond, 0xFF)
	elseif index == 0x02 then
		return formatValue(self, rtc.minute)
	elseif index == 0x03 then
		return band(rtc.alarmMinute, 0xFF)
	elseif index == 0x04 then
		return formatHour(self)
	elseif index == 0x05 then
		return band(rtc.alarmHour, 0xFF)
	elseif index == 0x06 then
		return formatValue(self, rtc.dayOfWeek)
	elseif index == 0x07 then
		return formatValue(self, rtc.day)
	elseif index == 0x08 then
		return formatValue(self, rtc.month)
	elseif index == 0x09 then
		return formatValue(self, rtc.year)
	elseif index == 0x0A then
		return statusA(self)
	elseif index == 0x0B then
		return rtc.regB
	elseif index == 0x0C then
		return readStatusC(self)
	elseif index == 0x0D then
		return rtc.regD
	elseif index == 0x0E then
		return 0x00
	elseif index == 0x0F then
		return self.shutdown
	elseif index == 0x10 then
		return self.floppyType -- high nibble drive A, low nibble drive B
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
		return formatValue(self, rtc.century)
	elseif index == 0x34 or index == 0x35 then
		return 0x00
	end
	return self.ram[index] or 0x00
end

function Cmos.new(config: Config?): Cmos
	const cfg = (config or {}) :: Config
	local self = setmetatable({}, Cmos) :: any
	self.index = 0
	self.nmiMasked = false
	self.memorySize = cfg.memorySize or (16 * 1024 * 1024)
	self.floppyType = cfg.floppyType or 0
	self.ram = {}
	self.shutdown = 0
	self.rtc = newRtcState()
	self.stepsPerSecond = PIT_INPUT_HZ
	self.uipSteps = UIP_STEPS
	self.lastReadIndex = 0
	self.lastReadValue = 0
	self.readCount = 0
	self.trace = {}
	-- SeaBIOS reads the QEMU boot-order words from CMOS 0x38/0x3D before it
	-- looks at fw_cfg bootorder. Nibbles low-to-high are boot priority 101..:
	-- 3 = CD, 2 = HD, 1 = floppy. This puts the ATAPI CD first and stops the
	-- always-present floppy fallback from winning the first attempt.
	self.ram[0x38] = 0x10
	self.ram[0x3D] = 0x23
	return self
end

function Cmos.out8(self: Cmos, port: number, value: number): boolean
	value = band(value, 0xFF)
	if port == 0x70 then
		self.index = band(value, 0x7F)
		self.nmiMasked = band(value, 0x80) ~= 0
		return false
	end
	if port == 0x71 then
		if #self.trace < 40 then
			self.trace[#self.trace + 1] = ("W%02X=%02X"):format(self.index, value)
		end
		if self.index == 0x0F then
			self.shutdown = value
			return false
		end
		return writeRegister(self, self.index, value)
	end
	return false
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

-- Advance the clock and periodic divider by `steps` emulated PIT input counts.
-- Returns true only when a newly asserted status C flag toggles IRQF from 0 to
-- 1, so Machine raises IRQ8 exactly once per interrupt edge.
function Cmos.advance(self: Cmos, steps: number): boolean
	const wholeSteps = math.floor(steps)
	if wholeSteps <= 0 then
		return false
	end
	const rtc = self.rtc
	if band(rtc.regB, STATUS_B_SET) ~= 0 then
		rtc.clockTicks = 0
		rtc.phase = 0
		return false
	end
	local irq = false
	if rtc.period > 0 and band(rtc.regB, STATUS_B_PIE) ~= 0 then
		const total = rtc.phase + wholeSteps
		if total >= rtc.period then
			rtc.phase = total % rtc.period
			irq = recordUpdate(self, STATUS_C_PF) or irq
		else
			rtc.phase = total
		end
	else
		rtc.phase = 0
	end
	const total = rtc.clockTicks + wholeSteps
	if total >= self.stepsPerSecond then
		const seconds = math.floor(total / self.stepsPerSecond)
		rtc.clockTicks = total % self.stepsPerSecond
		irq = advanceWholeSeconds(self, seconds) or irq
	else
		rtc.clockTicks = total
	end
	return irq
end

-- Advance exactly whole calendar seconds. Intended for tests, host time
-- injection and callers that do not need sub-second RTC phase. Resets the
-- sub-second counter so the next `advance` starts a fresh second.
function Cmos.advanceSeconds(self: Cmos, seconds: number): boolean
	const whole = math.floor(seconds)
	self.rtc.clockTicks = 0
	if whole <= 0 or band(self.rtc.regB, STATUS_B_SET) ~= 0 then
		return false
	end
	return advanceWholeSeconds(self, whole)
end

function Cmos.irqPending(self: Cmos): boolean
	return band(self.rtc.regC, STATUS_C_IRQF) ~= 0
end

function Cmos.setShutdown(self: Cmos, value: number)
	self.shutdown = band(value, 0xFF)
end

return Cmos
