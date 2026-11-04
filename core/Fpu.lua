--!strict
-- Fpu.lua -- practical 486 x87 subset.
--
-- Registers are held as Lua doubles, not true 80-bit extended values. That is
-- enough for the 32/64-bit code paths used by the 486-era DOS/Windows software
-- this machine targets. Pending exceptions are reported through the x87 status
-- word but are not raised as CPU exceptions. Deliberate gaps: 80-bit memory
-- operands, FLDENV/FSTENV/FNSAVE/FRSTOR, FISTTP/FBLD/FBSTP, exact 66-bit
-- trigonometric argument reduction, and underflow/precision tracking. Stack,
-- invalid-op and divide-by-zero status still update so software can detect
-- unsupported operations.

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
const LN2 = math.log(2)
const TWO32 = 4294967296
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
		lastOpcode: number,
		reset: (self: Fpu) -> (),
		st: (self: Fpu, index: number) -> number,
		tagWord: (self: Fpu) -> number,
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

local function raiseException(self: Fpu, bits: number)
	self.status = bor(self.status, bits, ES)
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
	return math.exp(value * LN2)
end

local function log2(value: number): number
	return math.log(value) / LN2
end

local function arithmetic(self: Fpu, a: number, b: number, op: number): number
	local result: number
	const finiteOperands = isFinite(a) and isFinite(b)
	if op == 0 then -- add
		result = a + b
	elseif op == 1 then -- subtract
		result = a - b
	elseif op == 2 then -- multiply
		result = a * b
	else -- divide
		if b == 0 and a ~= 0 and not isNan(a) then
			raiseException(self, ZE)
		end
		result = a / b
	end
	if isNan(result) then
		invalid(self)
	elseif finiteOperands and isInf(result) then
		raiseException(self, OE)
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
	for index = 0, 7 do
		self.regs[index] = 0
		self.tags[index] = TAG_EMPTY
	end
	syncTop(self)
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
	elseif group == 1 then -- D9: m32 load/store, control word
		if reg == 0 then
			doFld(self, readM32(cpu, e))
		elseif reg == 2 then
			doFst(self, cpu, e, 32, false)
		elseif reg == 3 then
			doFst(self, cpu, e, 32, true)
		elseif reg == 5 then
			self.control = cpu:read16(memoryAddress(cpu, e, 2))
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
	elseif group == 3 then -- DB: m32 integer load/store
		if reg == 0 then
			push(self, readSigned32(cpu, e))
		elseif reg == 2 then
			storeInteger(self, cpu, e, 32, false)
		elseif reg == 3 then
			storeInteger(self, cpu, e, 32, true)
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
	elseif group == 5 then -- DD: m64 load/store, status word
		if reg == 0 then
			doFld(self, readM64(cpu, e))
		elseif reg == 2 then
			doFst(self, cpu, e, 64, false)
		elseif reg == 3 then
			doFst(self, cpu, e, 64, true)
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
	else -- DF: m16/m64 integer load/store
		if reg == 0 then
			push(self, readSigned16(cpu, e))
		elseif reg == 2 then
			storeInteger(self, cpu, e, 16, false)
		elseif reg == 3 then
			storeInteger(self, cpu, e, 16, true)
		elseif reg == 5 then
			push(self, readSigned64(cpu, e))
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
						setTop(self, math.sqrt(value))
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

function Fpu.execute(self: Fpu, cpu: any, opcode: number, e: any)
	self.lastOpcode = opcode
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
	self.lastOpcode = 0
	for index = 0, 7 do
		self.regs[index] = 0
		self.tags[index] = TAG_EMPTY
	end
	syncTop(self)
	return self
end

return Fpu
