--!strict
-- Fpu.lua -- practical 486 x87 subset.
--
-- Registers are held as Lua doubles, not true 80-bit extended values. That is
-- enough for the 32/64-bit code paths used by the 486-era DOS/Windows software
-- this machine targets. Unmasked exceptions set a deferred #MF condition that
-- is observed by WAIT/FWAIT or the next non-waiting x87 instruction, matching
-- the 486 native route. Deliberate gaps: exact 80-bit exception mantissas,
-- exact 66-bit trigonometric argument reduction, FISTTP, and full 80-bit
-- mantissa precision (extended values round-trip through a host double).
-- Underflow/denormal/precision tracking is approximate.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const TOP_MASK = 0x3800
const C0 = 0x0100
const C1 = 0x0200
const C2 = 0x0400
const C3 = 0x4000
const COND_MASK = bor(C0, C1, C2, C3)
const IE = 0x0001
const DE = 0x0002
const ZE = 0x0004
const OE = 0x0008
const UE = 0x0010
const PE = 0x0020
const SF = 0x0040
const ES = 0x0080
const EXCEPTION_MASK = bor(IE, DE, ZE, OE, UE, PE, SF, ES)
const DEFAULT_CONTROL = 0x037F

const TAG_VALID = 0
const TAG_ZERO = 1
const TAG_SPECIAL = 2
const TAG_EMPTY = 3

const NAN = 0 / 0
const INF = math.huge
const DBL_MIN = 2.2250738585072014e-308
const LN2 = math.log(2)
const TWO32 = 4294967296
const TWO63 = 9223372036854775808
const TWO64 = 18446744073709551616

const Fpu = {}
Fpu.__index = Fpu

export type Fpu = typeof(setmetatable(
	{} :: {
		regs: { number },
		tags: { number },
		top: number,
		control: number,
		status: number,
		invalidCount: number,
		stackFaultCount: number,
		pendingMf: boolean,
		lastOpcode: number,
		instIP: number,
		instCS: number,
		dataIP: number,
		dataDS: number,
		fop: number,
		reset: (self: Fpu) -> (),
		st: (self: Fpu, index: number) -> number,
		tagWord: (self: Fpu) -> number,
		wait: (self: Fpu, cpu: any) -> (),
		execute: (self: Fpu, cpu: any, opcode: number, e: any) -> (),
	},
	Fpu
))

local function isNan(value: number): boolean
	return value ~= value
end

local function isInf(value: number): boolean
	return value == INF or value == -INF
end

local function isFinite(value: number): boolean
	return not isNan(value) and not isInf(value)
end

local function isDenormal(value: number): boolean
	return value ~= 0 and isFinite(value) and math.abs(value) < DBL_MIN
end

local function tagFor(value: number): number
	if isNan(value) or isInf(value) then
		return TAG_SPECIAL
	elseif value == 0 then
		return TAG_ZERO
	end
	return TAG_VALID
end

local function syncTop(self: Fpu)
	self.status = bor(band(self.status, bit32.bnot(TOP_MASK)), lshift(self.top, 11))
end

local function exceptionUnmasked(self: Fpu, bits: number): boolean
	const exceptions = band(bits, 0x3F)
	return exceptions ~= 0 and band(exceptions, bit32.bnot(self.control)) ~= 0
end

local function refreshPending(self: Fpu)
	self.pendingMf = exceptionUnmasked(self, self.status)
end

local function raiseException(self: Fpu, bits: number)
	self.status = bor(self.status, bits)
	if exceptionUnmasked(self, bits) then
		self.status = bor(self.status, ES)
		self.pendingMf = true
	end
end

local function invalid(self: Fpu)
	self.invalidCount += 1
	raiseException(self, IE)
end

local function stackFault(self: Fpu)
	self.stackFaultCount += 1
	raiseException(self, bor(IE, SF))
end

local function setCondition(self: Fpu, c0: boolean, c1: boolean, c2: boolean, c3: boolean)
	local status = band(self.status, bit32.bnot(COND_MASK))
	if c0 then
		status = bor(status, C0)
	end
	if c1 then
		status = bor(status, C1)
	end
	if c2 then
		status = bor(status, C2)
	end
	if c3 then
		status = bor(status, C3)
	end
	self.status = status
end

local function setRegister(self: Fpu, physical: number, value: number)
	self.regs[physical] = value
	self.tags[physical] = tagFor(value)
end

local function getSt(self: Fpu, index: number): number
	return self.regs[(self.top + index) % 8]
end

local function setSt(self: Fpu, index: number, value: number)
	setRegister(self, (self.top + index) % 8, value)
end

local function stackTag(self: Fpu, index: number): number
	return self.tags[(self.top + index) % 8]
end

local function ensureStack(self: Fpu, count: number): boolean
	for index = 0, count - 1 do
		if stackTag(self, index) == TAG_EMPTY then
			stackFault(self)
			return false
		end
	end
	return true
end

local function canPush(self: Fpu): boolean
	return self.tags[(self.top + 7) % 8] == TAG_EMPTY
end

local function push(self: Fpu, value: number): boolean
	if not canPush(self) then
		stackFault(self)
		return false
	end
	self.top = (self.top + 7) % 8
	setRegister(self, self.top, value)
	syncTop(self)
	return true
end

local function pop(self: Fpu)
	self.tags[self.top] = TAG_EMPTY
	self.regs[self.top] = 0
	self.top = (self.top + 1) % 8
	syncTop(self)
end

local function setTop(self: Fpu, value: number)
	setRegister(self, self.top, value)
end

local function roundInteger(self: Fpu, value: number): number
	if not isFinite(value) then
		return value
	end
	const mode = band(rshift(self.control, 10), 3)
	if mode == 1 then
		return math.floor(value)
	elseif mode == 2 then
		return math.ceil(value)
	elseif mode == 3 then
		return if value < 0 then math.ceil(value) else math.floor(value)
	end
	const lower = math.floor(value)
	const fraction = value - lower
	if fraction > 0.5 then
		return lower + 1
	elseif fraction < 0.5 then
		return lower
	end
	return if lower % 2 == 0 then lower else lower + 1
end

local function truncate(value: number): number
	if value < 0 then
		return math.ceil(value)
	end
	return math.floor(value)
end

local function exp2(value: number): number
	return 2 ^ value
end

local function log2(value: number): number
	return math.log(value) / LN2
end

local function arithmetic(self: Fpu, a: number, b: number, op: number): number
	local result: number
	const finiteOperands = isFinite(a) and isFinite(b)
	local zeroDivide = false
	if isDenormal(a) or isDenormal(b) then
		raiseException(self, DE)
	end
	if op == 0 then -- add
		result = a + b
	elseif op == 1 then -- subtract
		result = a - b
	elseif op == 2 then -- multiply
		result = a * b
	else -- divide
		if b == 0 and a ~= 0 and not isNan(a) then
			raiseException(self, ZE)
			zeroDivide = true
		end
		result = a / b
	end
	if isNan(result) then
		invalid(self)
	else
		if isDenormal(result) then
			raiseException(self, DE)
		end
		if isDenormal(result) or ((op == 2 or op == 3) and result == 0 and a ~= 0 and b ~= 0) then
			raiseException(self, UE)
		end
		if not zeroDivide and finiteOperands and isInf(result) then
			raiseException(self, OE)
		end
		if op == 3 and b ~= 0 and isFinite(result) and result * b ~= a then
			raiseException(self, PE)
		end
	end
	return result
end

-- Relation: 0 greater, 1 less, 2 equal, 3 unordered.
local function compareValues(self: Fpu, a: number, b: number, quiet: boolean): number
	local relation
	if isNan(a) or isNan(b) then
		relation = 3
		if not quiet then
			invalid(self)
		end
	elseif a > b then
		relation = 0
	elseif a < b then
		relation = 1
	else
		relation = 2
	end
	setCondition(
		self,
		relation == 1 or relation == 3,
		false,
		relation == 3,
		relation == 2 or relation == 3
	)
	return relation
end

local function setCompareFlags(cpu: any, relation: number)
	const mask = bor(0x0001, 0x0004, 0x0040) -- CF | PF | ZF
	local flags = band(cpu.flags, bit32.bnot(mask))
	if relation == 1 then
		flags = bor(flags, 0x0001)
	elseif relation == 2 then
		flags = bor(flags, 0x0040)
	elseif relation == 3 then
		flags = bor(flags, 0x0001, 0x0004, 0x0040)
	end
	cpu.flags = flags
end

local function memoryAddress(cpu: any, e: any, size: number): number
	return cpu:linear(e.seg or "ds", e.off or 0, size)
end

local function readM32(cpu: any, e: any): number
	const bytes = buffer.create(4)
	buffer.writeu32(bytes, 0, cpu:read32(memoryAddress(cpu, e, 4)))
	return buffer.readf32(bytes, 0)
end

local function writeM32(cpu: any, e: any, value: number)
	const bytes = buffer.create(4)
	buffer.writef32(bytes, 0, value)
	cpu:write32(memoryAddress(cpu, e, 4), buffer.readu32(bytes, 0))
end

local function readM64(cpu: any, e: any): number
	const bytes = buffer.create(8)
	const address = memoryAddress(cpu, e, 8)
	buffer.writeu32(bytes, 0, cpu:read32(address))
	buffer.writeu32(bytes, 4, cpu:read32(address + 4))
	return buffer.readf64(bytes, 0)
end

local function writeM64(cpu: any, e: any, value: number)
	const bytes = buffer.create(8)
	buffer.writef64(bytes, 0, value)
	const address = memoryAddress(cpu, e, 8)
	cpu:write32(address, buffer.readu32(bytes, 0))
	cpu:write32(address + 4, buffer.readu32(bytes, 4))
end

-- 80-bit extended values are stored as a 64-bit explicit significand followed
-- by a sign/exponent word. The host value is a Lua double, so the low bits of
-- the significand are lost on store; normal values still round-trip through
-- this representation with double precision.
local function readM80At(cpu: any, address: number): number
	const low = cpu:read32(address)
	const high = cpu:read32(address + 4)
	const signExponent = cpu:read16(address + 8)
	const negative = band(signExponent, 0x8000) ~= 0
	const exponent = band(signExponent, 0x7FFF)
	const significand = high * TWO32 + low
	if exponent == 0x7FFF then
		if significand == 0x8000000000000000 then
			return if negative then -INF else INF
		end
		return NAN
	elseif exponent == 0 and significand == 0 then
		return if negative then -0.0 else 0.0
	end
	const unbiased = if exponent == 0 then 1 - 16383 - 63 else exponent - 16383 - 63
	const value = significand * exp2(unbiased)
	return if negative then -value else value
end

local function writeM80At(cpu: any, address: number, value: number)
	local sign = 0
	local exponent = 0
	local high = 0
	local low = 0
	if isNan(value) then
		exponent = 0x7FFF
		high = 0xC0000000
	elseif isInf(value) then
		exponent = 0x7FFF
		high = 0x80000000
	elseif value == 0 then
		if 1 / value < 0 then
			sign = 0x8000
		end
	else
		if value < 0 then
			sign = 0x8000
			value = -value
		end
		local binaryExponent = math.floor(log2(value))
		local significand = value / exp2(binaryExponent)
		if significand >= 2 then
			binaryExponent += 1
			significand /= 2
		elseif significand < 1 then
			binaryExponent -= 1
			significand *= 2
		end
		exponent = binaryExponent + 16383
		local scaled = significand * TWO63
		if scaled >= TWO64 then
			scaled /= 2
			exponent += 1
		end
		high = math.floor(scaled / TWO32)
		low = math.floor(scaled % TWO32)
	end
	cpu:write32(address, low)
	cpu:write32(address + 4, high)
	cpu:write16(address + 8, bor(sign, band(exponent, 0x7FFF)))
end

local function readM80(cpu: any, e: any): number
	return readM80At(cpu, memoryAddress(cpu, e, 10))
end

local function writeM80(cpu: any, e: any, value: number)
	writeM80At(cpu, memoryAddress(cpu, e, 10), value)
end

-- Packed BCD: nine bytes, least-significant digit first, then a sign byte.
local function readBcd(cpu: any, e: any): number
	const address = memoryAddress(cpu, e, 10)
	local value = 0
	for index = 8, 0, -1 do
		const byte = cpu:read8(address + index)
		value = value * 100 + rshift(byte, 4) * 10 + band(byte, 0x0F)
	end
	if band(cpu:read8(address + 9), 0x80) ~= 0 then
		value = -value
	end
	return value
end

local function writeBcd(self: Fpu, cpu: any, e: any)
	if not ensureStack(self, 1) then
		return
	end
	const address = memoryAddress(cpu, e, 10)
	local value = roundInteger(self, getSt(self, 0))
	const negative = value < 0
	value = math.abs(value)
	if not isFinite(value) or value >= 1e18 then
		invalid(self)
		for index = 0, 8 do
			cpu:write8(address + index, 0xFF)
		end
		cpu:write8(address + 9, 0xFF)
	else
		local remaining = math.floor(value)
		for index = 0, 8 do
			const digit0 = remaining % 10
			remaining = math.floor(remaining / 10)
			const digit1 = remaining % 10
			remaining = math.floor(remaining / 10)
			cpu:write8(address + index, bor(digit0, lshift(digit1, 4)))
		end
		cpu:write8(address + 9, if negative then 0x80 else 0x00)
	end
	pop(self)
end

local function readSigned16(cpu: any, e: any): number
	const value = cpu:read16(memoryAddress(cpu, e, 2))
	return if value >= 0x8000 then value - 0x10000 else value
end

local function readSigned32(cpu: any, e: any): number
	const value = cpu:read32(memoryAddress(cpu, e, 4))
	return if value >= 0x80000000 then value - TWO32 else value
end

local function readSigned64(cpu: any, e: any): number
	const address = memoryAddress(cpu, e, 8)
	const low = cpu:read32(address)
	const high = cpu:read32(address + 4)
	local value = high * TWO32 + low
	if high >= 0x80000000 then
		value -= TWO64
	end
	return value
end

local function writeSigned(cpu: any, e: any, size: number, value: number)
	const address = memoryAddress(cpu, e, size / 8)
	if size == 16 then
		cpu:write16(address, math.floor(value) % 0x10000)
	elseif size == 32 then
		cpu:write32(address, math.floor(value) % TWO32)
	else
		const unsigned = math.floor(value) % TWO64
		cpu:write32(address, unsigned % TWO32)
		cpu:write32(address + 4, math.floor(unsigned / TWO32))
	end
end

local function storeInteger(self: Fpu, cpu: any, e: any, size: number, popAfter: boolean)
	if not ensureStack(self, 1) then
		return
	end
	local value = roundInteger(self, getSt(self, 0))
	local min, max
	if size == 16 then
		min, max = -32768, 32768
	elseif size == 32 then
		min, max = -2147483648, 2147483648
	else
		min, max = -TWO64 / 2, TWO64 / 2
	end
	if not isFinite(value) or value < min or value >= max then
		invalid(self)
		if size == 16 then
			value = -32768
		elseif size == 32 then
			value = -2147483648
		else
			value = -9223372036854775808
		end
	end
	writeSigned(cpu, e, size, value)
	if popAfter then
		pop(self)
	end
end

local function integerArithmetic(self: Fpu, value: number, op: number)
	if not ensureStack(self, 1) then
		return
	end
	setTop(self, arithmetic(self, getSt(self, 0), value, op))
end

local function compareInteger(self: Fpu, value: number, popAfter: boolean)
	if not ensureStack(self, 1) then
		return
	end
	compareValues(self, getSt(self, 0), value, false)
	if popAfter then
		pop(self)
	end
end

local function doFld(self: Fpu, value: number)
	push(self, value)
end

local function doFst(self: Fpu, cpu: any, e: any, size: number, popAfter: boolean)
	if not ensureStack(self, 1) then
		return
	end
	const value = getSt(self, 0)
	if size == 32 then
		writeM32(cpu, e, value)
	else
		writeM64(cpu, e, value)
	end
	if popAfter then
		pop(self)
	end
end

local function doFcom(self: Fpu, value: number, popAfter: boolean, quiet: boolean)
	if not ensureStack(self, 1) then
		return
	end
	compareValues(self, getSt(self, 0), value, quiet)
	if popAfter then
		pop(self)
	end
end

local function fcomRegister(self: Fpu, index: number, popAfter: boolean, quiet: boolean)
	if not ensureStack(self, 1) or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	compareValues(self, getSt(self, 0), getSt(self, index), quiet)
	if popAfter then
		pop(self)
	end
end

local function fxch(self: Fpu, index: number)
	if index == 0 then
		return
	end
	if stackTag(self, 0) == TAG_EMPTY or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	const physical0 = self.top
	const physical1 = (self.top + index) % 8
	const value = self.regs[physical0]
	self.regs[physical0], self.regs[physical1] = self.regs[physical1], value
	const tag = self.tags[physical0]
	self.tags[physical0], self.tags[physical1] = self.tags[physical1], tag
end

local function fadd(self: Fpu, index: number, popAfter: boolean)
	if not ensureStack(self, 1) or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	const result = arithmetic(self, getSt(self, index), getSt(self, 0), 0)
	setSt(self, index, result)
	if popAfter then
		pop(self)
	end
end

local function fsub(self: Fpu, index: number, popAfter: boolean)
	if not ensureStack(self, 1) or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	if not ensureStack(self, 2) then
		return
	end
	const result = arithmetic(self, getSt(self, index), getSt(self, 0), 1)
	setSt(self, index, result)
	if popAfter then
		pop(self)
	end
end

local function fsubr(self: Fpu, index: number, popAfter: boolean)
	if not ensureStack(self, 1) or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	if not ensureStack(self, 2) then
		return
	end
	const result = arithmetic(self, getSt(self, 0), getSt(self, index), 1)
	setSt(self, index, result)
	if popAfter then
		pop(self)
	end
end

local function fmul(self: Fpu, index: number, popAfter: boolean)
	if not ensureStack(self, 1) or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	const result = arithmetic(self, getSt(self, index), getSt(self, 0), 2)
	setSt(self, index, result)
	if popAfter then
		pop(self)
	end
end

local function fdiv(self: Fpu, index: number, popAfter: boolean)
	if not ensureStack(self, 1) or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	if not ensureStack(self, 2) then
		return
	end
	const result = arithmetic(self, getSt(self, index), getSt(self, 0), 3)
	setSt(self, index, result)
	if popAfter then
		pop(self)
	end
end

local function fdivr(self: Fpu, index: number, popAfter: boolean)
	if not ensureStack(self, 1) or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	if not ensureStack(self, 2) then
		return
	end
	const result = arithmetic(self, getSt(self, 0), getSt(self, index), 3)
	setSt(self, index, result)
	if popAfter then
		pop(self)
	end
end

local function binaryTop(self: Fpu, value: number, op: number)
	if not ensureStack(self, 1) then
		return
	end
	setTop(self, arithmetic(self, getSt(self, 0), value, op))
end

local function topArithmetic(self: Fpu, index: number, op: number, reverse: boolean)
	if not ensureStack(self, 1) then
		return
	end
	if index ~= 0 and stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	local left, right = getSt(self, 0), getSt(self, index)
	if reverse then
		left, right = right, left
	end
	setTop(self, arithmetic(self, left, right, op))
end

local function ftst(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	compareValues(self, getSt(self, 0), 0, false)
end

local function fxam(self: Fpu)
	const tag = stackTag(self, 0)
	if tag == TAG_EMPTY then
		setCondition(self, true, false, false, true) -- empty
		return
	end
	const value = getSt(self, 0)
	const negative = value < 0 or (value == 0 and 1 / value < 0)
	if isNan(value) then
		setCondition(self, true, negative, false, false)
	elseif isInf(value) then
		setCondition(self, true, negative, true, false)
	elseif value == 0 then
		setCondition(self, false, negative, false, true)
	elseif math.abs(value) < 2.2250738585072014e-308 then
		setCondition(self, false, negative, true, true)
	else
		setCondition(self, false, negative, true, false)
	end
end

local function f2xm1(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	const value = getSt(self, 0)
	if not isFinite(value) or value < -1 or value > 1 then
		invalid(self)
		setTop(self, NAN)
		return
	end
	setTop(self, exp2(value) - 1)
end

local function fyl2x(self: Fpu)
	if not ensureStack(self, 2) then
		return
	end
	const x = getSt(self, 0)
	const y = getSt(self, 1)
	if isNan(x) or isNan(y) or x < 0 then
		invalid(self)
		setSt(self, 1, NAN)
	else
		if x == 0 then
			raiseException(self, ZE)
		end
		setSt(self, 1, y * log2(x))
	end
	pop(self)
end

local function fyl2xp1(self: Fpu)
	if not ensureStack(self, 2) then
		return
	end
	const x = getSt(self, 0)
	const y = getSt(self, 1)
	if isNan(x) or isNan(y) or x <= -1 then
		invalid(self)
		setSt(self, 1, NAN)
	else
		setSt(self, 1, y * log2(1 + x))
	end
	pop(self)
end

local function fsin(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	const value = getSt(self, 0)
	if not isFinite(value) then
		invalid(self)
		setTop(self, NAN)
		return
	end
	setTop(self, math.sin(value))
end

local function fcos(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	const value = getSt(self, 0)
	if not isFinite(value) then
		invalid(self)
		setTop(self, NAN)
		return
	end
	setTop(self, math.cos(value))
end

local function fsincos(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	if not canPush(self) then
		stackFault(self)
		return
	end
	const value = getSt(self, 0)
	if not isFinite(value) then
		invalid(self)
		setTop(self, NAN)
		return
	end
	const sine = math.sin(value)
	const cosine = math.cos(value)
	setTop(self, cosine)
	push(self, sine)
end

local function fptan(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	if not canPush(self) then
		stackFault(self)
		return
	end
	const value = getSt(self, 0)
	if not isFinite(value) then
		invalid(self)
		setTop(self, NAN)
		return
	end
	setTop(self, math.tan(value))
	push(self, 1.0)
end

local function fpatan(self: Fpu)
	if not ensureStack(self, 2) then
		return
	end
	const x = getSt(self, 0)
	const y = getSt(self, 1)
	if isNan(x) or isNan(y) then
		invalid(self)
		setSt(self, 1, NAN)
	else
		setSt(self, 1, math.atan2(y, x))
	end
	pop(self)
end

local function fprem(self: Fpu, roundNearest: boolean)
	if not ensureStack(self, 2) then
		return
	end
	const dividend = getSt(self, 0)
	const divisor = getSt(self, 1)
	if isNan(dividend) or isNan(divisor) or isInf(dividend) or divisor == 0 then
		invalid(self)
		setTop(self, NAN)
		setCondition(self, false, false, false, false)
		return
	end
	const quotient = if roundNearest
		then roundInteger(self, dividend / divisor)
		else truncate(dividend / divisor)
	if not isFinite(quotient) then
		invalid(self)
		setTop(self, NAN)
		setCondition(self, false, false, false, false)
		return
	end
	setTop(self, dividend - quotient * divisor)
	setCondition(self, quotient % 2 ~= 0, quotient < 0, false, false)
end

local function fxtract(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	if not canPush(self) then
		stackFault(self)
		return
	end
	const value = getSt(self, 0)
	if isNan(value) then
		invalid(self)
		setTop(self, NAN)
		push(self, NAN)
	elseif value == 0 then
		setTop(self, value)
		push(self, -INF)
	elseif isInf(value) then
		setTop(self, value)
		push(self, INF)
	else
		local exponent = math.floor(log2(math.abs(value)))
		local significand = value / exp2(exponent)
		if math.abs(significand) >= 2 then
			exponent += 1
			significand /= 2
		elseif math.abs(significand) < 1 then
			exponent -= 1
			significand *= 2
		end
		setTop(self, significand)
		push(self, exponent)
	end
end

local function fscale(self: Fpu)
	if not ensureStack(self, 2) then
		return
	end
	const value = getSt(self, 0)
	const scale = getSt(self, 1)
	if isNan(value) or isNan(scale) or isInf(scale) then
		invalid(self)
		setTop(self, NAN)
		return
	end
	const result = value * exp2(truncate(scale))
	if isNan(result) then
		invalid(self)
	elseif isFinite(value) and isInf(result) then
		raiseException(self, OE)
	end
	setTop(self, result)
end

local function frndint(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	setTop(self, roundInteger(self, getSt(self, 0)))
end

local function fcmov(self: Fpu, index: number, condition: boolean)
	if not ensureStack(self, 1) or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	if condition then
		setTop(self, getSt(self, index))
	end
end

local function fninit(self: Fpu)
	self.top = 0
	self.control = DEFAULT_CONTROL
	self.status = 0
	self.pendingMf = false
	self.instIP = 0
	self.instCS = 0
	self.dataIP = 0
	self.dataDS = 0
	self.fop = 0
	for index = 0, 7 do
		self.regs[index] = 0
		self.tags[index] = TAG_EMPTY
	end
	syncTop(self)
end

local function environmentSize(cpu: any): number
	if cpu.operand32 and not cpu:isV86() then
		return 28
	end
	return 14
end

local function writeEnvironment(self: Fpu, cpu: any, e: any): number
	const size = environmentSize(cpu)
	const address = memoryAddress(cpu, e, size)
	const status = bor(band(self.status, bit32.bnot(TOP_MASK)), lshift(self.top, 11))
	const tag = self:tagWord()
	if size == 28 then
		cpu:write32(address, band(self.control, 0xFFFF))
		cpu:write32(address + 4, band(status, 0xFFFF))
		cpu:write32(address + 8, band(tag, 0xFFFF))
		cpu:write32(address + 12, band(self.instIP, 0xFFFFFFFF))
		cpu:write32(address + 16, bor(band(self.instCS, 0xFFFF), lshift(band(self.fop, 0x7FF), 16)))
		cpu:write32(address + 20, band(self.dataIP, 0xFFFFFFFF))
		cpu:write32(address + 24, band(self.dataDS, 0xFFFF))
	else
		cpu:write16(address, band(self.control, 0xFFFF))
		cpu:write16(address + 2, band(status, 0xFFFF))
		cpu:write16(address + 4, band(tag, 0xFFFF))
		cpu:write16(address + 6, band(self.instIP, 0xFFFF))
		cpu:write16(address + 8, band(self.instCS, 0xFFFF))
		cpu:write16(address + 10, band(self.dataIP, 0xFFFF))
		cpu:write16(address + 12, band(self.dataDS, 0xFFFF))
	end
	-- FSTENV/FNSTENV/FNSAVE mask all exceptions after writing the image.
	self.control = bor(self.control, 0x3F)
	refreshPending(self)
	return size
end

local function readEnvironment(self: Fpu, cpu: any, e: any): number
	const size = environmentSize(cpu)
	const address = memoryAddress(cpu, e, size)
	local control, status, tag
	if size == 28 then
		control = cpu:read16(address)
		status = cpu:read16(address + 4)
		tag = cpu:read16(address + 8)
		self.instIP = cpu:read32(address + 12)
		const selectorOpcode = cpu:read32(address + 16)
		self.instCS = band(selectorOpcode, 0xFFFF)
		self.fop = band(rshift(selectorOpcode, 16), 0x7FF)
		self.dataIP = cpu:read32(address + 20)
		self.dataDS = band(cpu:read32(address + 24), 0xFFFF)
	else
		control = cpu:read16(address)
		status = cpu:read16(address + 2)
		tag = cpu:read16(address + 4)
		self.instIP = cpu:read16(address + 6)
		self.instCS = cpu:read16(address + 8)
		self.dataIP = cpu:read16(address + 10)
		self.dataDS = cpu:read16(address + 12)
		self.fop = 0
	end
	self.control = band(control, 0xFFFF)
	self.top = band(rshift(status, 11), 7)
	self.status = band(status, bit32.bnot(TOP_MASK))
	syncTop(self)
	for index = 0, 7 do
		self.tags[index] = band(rshift(tag, index * 2), 3)
	end
	refreshPending(self)
	return size
end

local function fstenv(self: Fpu, cpu: any, e: any)
	writeEnvironment(self, cpu, e)
end

local function fldenv(self: Fpu, cpu: any, e: any)
	readEnvironment(self, cpu, e)
end

local function fnsave(self: Fpu, cpu: any, e: any)
	const size = writeEnvironment(self, cpu, e)
	const address = memoryAddress(cpu, e, size) + size
	for index = 0, 7 do
		writeM80At(cpu, address + index * 10, getSt(self, index))
	end
	fninit(self)
end

local function frstor(self: Fpu, cpu: any, e: any)
	const size = readEnvironment(self, cpu, e)
	const address = memoryAddress(cpu, e, size) + size
	for index = 0, 7 do
		self.regs[(self.top + index) % 8] = readM80At(cpu, address + index * 10)
	end
end

local function fld80(self: Fpu, cpu: any, e: any)
	push(self, readM80(cpu, e))
end

local function fstp80(self: Fpu, cpu: any, e: any)
	if not ensureStack(self, 1) then
		return
	end
	writeM80(cpu, e, getSt(self, 0))
	pop(self)
end

local function fbld(self: Fpu, cpu: any, e: any)
	push(self, readBcd(cpu, e))
end

local function fbstp(self: Fpu, cpu: any, e: any)
	writeBcd(self, cpu, e)
end

local function executeMemory(self: Fpu, cpu: any, opcode: number, e: any)
	const group = opcode - 0xD8
	const reg = e.reg
	if group == 0 then -- D8: m32 arithmetic
		if reg == 0 then
			binaryTop(self, readM32(cpu, e), 0)
		elseif reg == 1 then
			binaryTop(self, readM32(cpu, e), 2)
		elseif reg == 2 then
			doFcom(self, readM32(cpu, e), false, false)
		elseif reg == 3 then
			doFcom(self, readM32(cpu, e), true, false)
		elseif reg == 4 then
			binaryTop(self, readM32(cpu, e), 1)
		elseif reg == 5 then
			if ensureStack(self, 1) then
				setTop(self, arithmetic(self, readM32(cpu, e), getSt(self, 0), 1))
			end
		elseif reg == 6 then
			binaryTop(self, readM32(cpu, e), 3)
		else
			if ensureStack(self, 1) then
				setTop(self, arithmetic(self, readM32(cpu, e), getSt(self, 0), 3))
			end
		end
	elseif group == 1 then -- D9: m32 load/store, environment, control word
		if reg == 0 then
			doFld(self, readM32(cpu, e))
		elseif reg == 2 then
			doFst(self, cpu, e, 32, false)
		elseif reg == 3 then
			doFst(self, cpu, e, 32, true)
		elseif reg == 4 then
			fldenv(self, cpu, e)
		elseif reg == 5 then
			self.control = cpu:read16(memoryAddress(cpu, e, 2))
			refreshPending(self)
		elseif reg == 6 then
			fstenv(self, cpu, e)
		elseif reg == 7 then
			cpu:write16(memoryAddress(cpu, e, 2), self.control)
		else
			invalid(self)
		end
	elseif group == 2 then -- DA: m32 integer arithmetic
		const value = readSigned32(cpu, e)
		if reg == 0 then
			integerArithmetic(self, value, 0)
		elseif reg == 1 then
			integerArithmetic(self, value, 2)
		elseif reg == 2 then
			compareInteger(self, value, false)
		elseif reg == 3 then
			compareInteger(self, value, true)
		elseif reg == 4 then
			integerArithmetic(self, value, 1)
		elseif reg == 5 then
			if ensureStack(self, 1) then
				setTop(self, arithmetic(self, value, getSt(self, 0), 1))
			end
		elseif reg == 6 then
			integerArithmetic(self, value, 3)
		else
			if ensureStack(self, 1) then
				setTop(self, arithmetic(self, value, getSt(self, 0), 3))
			end
		end
	elseif group == 3 then -- DB: m32 integer, m80 load/store
		if reg == 0 then
			push(self, readSigned32(cpu, e))
		elseif reg == 2 then
			storeInteger(self, cpu, e, 32, false)
		elseif reg == 3 then
			storeInteger(self, cpu, e, 32, true)
		elseif reg == 5 then
			fld80(self, cpu, e)
		elseif reg == 7 then
			fstp80(self, cpu, e)
		else
			invalid(self)
		end
	elseif group == 4 then -- DC: m64 arithmetic
		const value = readM64(cpu, e)
		if reg == 0 then
			binaryTop(self, value, 0)
		elseif reg == 1 then
			binaryTop(self, value, 2)
		elseif reg == 2 then
			doFcom(self, value, false, false)
		elseif reg == 3 then
			doFcom(self, value, true, false)
		elseif reg == 4 then
			binaryTop(self, value, 1)
		elseif reg == 5 then
			if ensureStack(self, 1) then
				setTop(self, arithmetic(self, value, getSt(self, 0), 1))
			end
		elseif reg == 6 then
			binaryTop(self, value, 3)
		else
			if ensureStack(self, 1) then
				setTop(self, arithmetic(self, value, getSt(self, 0), 3))
			end
		end
	elseif group == 5 then -- DD: m64 load/store, state, status word
		if reg == 0 then
			doFld(self, readM64(cpu, e))
		elseif reg == 2 then
			doFst(self, cpu, e, 64, false)
		elseif reg == 3 then
			doFst(self, cpu, e, 64, true)
		elseif reg == 4 then
			frstor(self, cpu, e)
		elseif reg == 6 then
			fnsave(self, cpu, e)
		elseif reg == 7 then
			cpu:write16(memoryAddress(cpu, e, 2), band(self.status, 0xFFFF))
		else
			invalid(self)
		end
	elseif group == 6 then -- DE: m16 integer arithmetic
		const value = readSigned16(cpu, e)
		if reg == 0 then
			integerArithmetic(self, value, 0)
		elseif reg == 1 then
			integerArithmetic(self, value, 2)
		elseif reg == 2 then
			compareInteger(self, value, false)
		elseif reg == 3 then
			compareInteger(self, value, true)
		elseif reg == 4 then
			integerArithmetic(self, value, 1)
		elseif reg == 5 then
			if ensureStack(self, 1) then
				setTop(self, arithmetic(self, value, getSt(self, 0), 1))
			end
		elseif reg == 6 then
			integerArithmetic(self, value, 3)
		else
			if ensureStack(self, 1) then
				setTop(self, arithmetic(self, value, getSt(self, 0), 3))
			end
		end
	else -- DF: m16/m64 integer, BCD load/store
		if reg == 0 then
			push(self, readSigned16(cpu, e))
		elseif reg == 2 then
			storeInteger(self, cpu, e, 16, false)
		elseif reg == 3 then
			storeInteger(self, cpu, e, 16, true)
		elseif reg == 4 then
			fbld(self, cpu, e)
		elseif reg == 5 then
			push(self, readSigned64(cpu, e))
		elseif reg == 6 then
			fbstp(self, cpu, e)
		elseif reg == 7 then
			storeInteger(self, cpu, e, 64, true)
		else
			invalid(self)
		end
	end
end

local function executeRegister(self: Fpu, cpu: any, opcode: number, e: any)
	const group = opcode - 0xD8
	const reg = e.reg
	const index = e.rm
	if group == 0 then -- D8: ST0,ST(i)
		if reg == 0 then
			topArithmetic(self, index, 0, false)
		elseif reg == 1 then
			topArithmetic(self, index, 2, false)
		elseif reg == 2 then
			fcomRegister(self, index, false, false)
		elseif reg == 3 then
			fcomRegister(self, index, true, false)
		elseif reg == 4 then
			topArithmetic(self, index, 1, false)
		elseif reg == 5 then
			topArithmetic(self, index, 1, true)
		elseif reg == 6 then
			topArithmetic(self, index, 3, false)
		else
			topArithmetic(self, index, 3, true)
		end
	elseif group == 1 then -- D9: register/transcendental opcodes
		if reg == 0 then
			if stackTag(self, index) == TAG_EMPTY then
				stackFault(self)
				return
			end
			push(self, getSt(self, index))
		elseif reg == 1 then
			fxch(self, index)
		elseif reg == 2 then
			if index ~= 0 then
				invalid(self)
			end
		elseif reg == 4 then
			if index == 0 then
				if ensureStack(self, 1) then
					setTop(self, -getSt(self, 0))
				end
			elseif index == 1 then
				if ensureStack(self, 1) then
					setTop(self, math.abs(getSt(self, 0)))
				end
			elseif index == 4 then
				ftst(self)
			elseif index == 5 then
				fxam(self)
			else
				invalid(self)
			end
		elseif reg == 5 then
			if index == 0 then
				push(self, 1.0)
			elseif index == 1 then
				push(self, log2(10))
			elseif index == 2 then
				push(self, 1 / LN2)
			elseif index == 3 then
				push(self, math.pi)
			elseif index == 4 then
				push(self, LN2 / math.log(10))
			elseif index == 5 then
				push(self, LN2)
			elseif index == 6 then
				push(self, 0.0)
			else
				invalid(self)
			end
		elseif reg == 6 then
			if index == 0 then
				f2xm1(self)
			elseif index == 1 then
				fyl2x(self)
			elseif index == 2 then
				fptan(self)
			elseif index == 3 then
				fpatan(self)
			elseif index == 4 then
				fxtract(self)
			elseif index == 5 then
				fprem(self, true)
			elseif index == 6 then
				self.top = (self.top + 7) % 8
				syncTop(self)
			elseif index == 7 then
				self.top = (self.top + 1) % 8
				syncTop(self)
			end
		elseif reg == 7 then
			if index == 0 then
				fprem(self, false)
			elseif index == 1 then
				fyl2xp1(self)
			elseif index == 2 then
				if ensureStack(self, 1) then
					const value = getSt(self, 0)
					if value < 0 then
						invalid(self)
						setTop(self, NAN)
					else
						const root = math.sqrt(value)
						if root * root ~= value then
							raiseException(self, PE)
						end
						setTop(self, root)
					end
				end
			elseif index == 3 then
				fsincos(self)
			elseif index == 4 then
				frndint(self)
			elseif index == 5 then
				fscale(self)
			elseif index == 6 then
				fsin(self)
			elseif index == 7 then
				fcos(self)
			end
		else
			invalid(self)
		end
	elseif group == 2 then -- DA: FCMOV / FUCOMPP
		if reg <= 3 then
			const condition = if reg == 0
				then band(cpu.flags, 0x0001) ~= 0
				elseif reg == 1 then band(cpu.flags, 0x0040) ~= 0
				elseif reg == 2 then band(cpu.flags, bor(0x0001, 0x0040)) ~= 0
				else band(cpu.flags, 0x0004) ~= 0
			fcmov(self, index, condition)
		elseif reg == 5 and index == 1 then
			if ensureStack(self, 2) then
				compareValues(self, getSt(self, 0), getSt(self, 1), true)
				pop(self)
				pop(self)
			end
		else
			invalid(self)
		end
	elseif group == 3 then -- DB: FNCLEX/FNINIT/FCOMI/FUCOMI
		if reg == 4 and index == 2 then
			self.status = band(self.status, bit32.bnot(EXCEPTION_MASK))
			self.pendingMf = false
		elseif reg == 4 and index == 3 then
			fninit(self)
		elseif reg == 5 then
			if ensureStack(self, 1) and stackTag(self, index) ~= TAG_EMPTY then
				const relation = compareValues(self, getSt(self, 0), getSt(self, index), true)
				setCompareFlags(cpu, relation)
			else
				stackFault(self)
			end
		elseif reg == 6 then
			if ensureStack(self, 1) and stackTag(self, index) ~= TAG_EMPTY then
				const relation = compareValues(self, getSt(self, 0), getSt(self, index), false)
				setCompareFlags(cpu, relation)
			else
				stackFault(self)
			end
		else
			invalid(self)
		end
	elseif group == 4 then -- DC: ST(i),ST0 arithmetic
		if reg == 0 then
			fadd(self, index, false)
		elseif reg == 1 then
			fmul(self, index, false)
		elseif reg == 2 then
			fcomRegister(self, index, false, false)
		elseif reg == 3 then
			fcomRegister(self, index, true, false)
		elseif reg == 4 then
			fsubr(self, index, false)
		elseif reg == 5 then
			fsub(self, index, false)
		elseif reg == 6 then
			fdivr(self, index, false)
		else
			fdiv(self, index, false)
		end
	elseif group == 5 then -- DD: stack/register move and unordered compare
		if reg == 0 then
			self.tags[(self.top + index) % 8] = TAG_EMPTY
			self.regs[(self.top + index) % 8] = 0
		elseif reg == 1 then
			fxch(self, index)
		elseif reg == 2 then
			if not ensureStack(self, 1) then
				return
			end
			setSt(self, index, getSt(self, 0))
		elseif reg == 3 then
			if not ensureStack(self, 1) then
				return
			end
			setSt(self, index, getSt(self, 0))
			pop(self)
		elseif reg == 4 then
			fcomRegister(self, index, false, true)
		elseif reg == 5 then
			fcomRegister(self, index, true, true)
		else
			invalid(self)
		end
	elseif group == 6 then -- DE: arithmetic with pop
		if reg == 0 then
			fadd(self, index, true)
		elseif reg == 1 then
			fmul(self, index, true)
		elseif reg == 2 then
			fcomRegister(self, index, true, false)
		elseif reg == 3 then
			if index == 1 then
				if ensureStack(self, 2) then
					compareValues(self, getSt(self, 0), getSt(self, 1), false)
					pop(self)
					pop(self)
				end
			else
				invalid(self)
			end
		elseif reg == 4 then
			fsubr(self, index, true)
		elseif reg == 5 then
			fsub(self, index, true)
		elseif reg == 6 then
			fdivr(self, index, true)
		else
			fdiv(self, index, true)
		end
	else -- DF: FNSTSW AX / FCOMI(P) / FUCOMI(P)
		if reg == 4 and index == 0 then
			cpu:wr(0, band(self.status, 0xFFFF))
		elseif reg == 5 then
			if ensureStack(self, 1) and stackTag(self, index) ~= TAG_EMPTY then
				const relation = compareValues(self, getSt(self, 0), getSt(self, index), true)
				setCompareFlags(cpu, relation)
				pop(self)
			else
				stackFault(self)
			end
		elseif reg == 6 then
			if ensureStack(self, 1) and stackTag(self, index) ~= TAG_EMPTY then
				const relation = compareValues(self, getSt(self, 0), getSt(self, index), false)
				setCompareFlags(cpu, relation)
				pop(self)
			else
				stackFault(self)
			end
		else
			invalid(self)
		end
	end
end

function Fpu.reset(self: Fpu)
	self.invalidCount = 0
	self.stackFaultCount = 0
	self.lastOpcode = 0
	fninit(self)
end

function Fpu.st(self: Fpu, index: number): number
	return getSt(self, index)
end

function Fpu.tagWord(self: Fpu): number
	local word = 0
	for index = 0, 7 do
		word = bor(word, lshift(band(self.tags[index], 3), index * 2))
	end
	return word
end

local function ignoresPending(opcode: number, e: any): boolean
	if opcode == 0xDB and e.reg == 4 then
		return e.rm == 2 or e.rm == 3 -- FNCLEX / FNINIT
	elseif opcode == 0xDF and e.reg == 4 and e.rm == 0 then
		return true -- FNSTSW AX
	elseif opcode == 0xD9 and (e.reg == 4 or e.reg == 6 or e.reg == 7) then
		return true -- FLDENV / FNSTENV / FNSTCW
	elseif opcode == 0xDD and (e.reg == 4 or e.reg == 6 or e.reg == 7) then
		return true -- FRSTOR / FNSAVE / FNSTSW m16
	end
	return false
end

function Fpu.wait(self: Fpu, cpu: any)
	if self.pendingMf then
		cpu:fault(16)
	end
end

function Fpu.execute(self: Fpu, cpu: any, opcode: number, e: any)
	self.lastOpcode = opcode
	if self.pendingMf and not ignoresPending(opcode, e) then
		cpu:fault(16)
		return
	end
	const environmentOp = (opcode == 0xD9 and (e.reg == 4 or e.reg == 6))
		or (opcode == 0xDD and (e.reg == 4 or e.reg == 6))
	if not environmentOp then
		self.instIP = cpu.opIP or cpu.ip
		self.instCS = cpu.cs
		self.fop = band(opcode, 0x7FF)
		if e.mod ~= 3 then
			self.dataIP = e.off or 0
			self.dataDS = cpu[e.seg or "ds"] or 0
		end
	end
	if e.mod == 3 then
		executeRegister(self, cpu, opcode, e)
	else
		executeMemory(self, cpu, opcode, e)
	end
end

function Fpu.new()
	local self = setmetatable({}, Fpu) :: any
	self.regs = {}
	self.tags = {}
	self.top = 0
	self.control = DEFAULT_CONTROL
	self.status = 0
	self.invalidCount = 0
	self.stackFaultCount = 0
	self.pendingMf = false
	self.lastOpcode = 0
	self.instIP = 0
	self.instCS = 0
	self.dataIP = 0
	self.dataDS = 0
	self.fop = 0
	for index = 0, 7 do
		self.regs[index] = 0
		self.tags[index] = TAG_EMPTY
	end
	syncTop(self)
	return self
end

return Fpu
