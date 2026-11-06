--!strict
-- Fpu.lua -- 486 x87 with true 80-bit extended precision.
--
-- Registers hold exact 80-bit extended values: a 15-bit biased exponent, a
-- sign bit and a 64-bit explicit-integer significand stored as two 32-bit
-- halves. Add/sub/mul/div/sqrt/prem/scale run in software on those integers
-- with guard and sticky bits, honoring the control word's precision control
-- (24/53/64) and all four rounding modes, with IE/DE/ZE/OE/UE/PE raised per
-- the masked/unmasked exception rules. Transcendental results (FSIN/FCOS/
-- FPTAN/F2XM1/FYL2X/FYL2XP1/FPATAN) are computed at double precision and
-- widened losslessly: accurate to 53 bits, not the full 64.

const band, bor = bit32.band, bit32.bor
const bxor, lshift, rshift = bit32.bxor, bit32.lshift, bit32.rshift

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

const TWO32 = 4294967296
const MIN_EXP = -16382
const MAX_EXP = 16383
const NAN_TOP_HI = 0xC0000000
const NAN_EXP = 0x7FFF
const INF_HI = 0x80000000

-- shared 8-byte buffer for double bit conversion
const cvt = buffer.create(8)

const Fpu = {}
Fpu.__index = Fpu

export type Fpu = typeof(setmetatable(
	{} :: {
		rSign: { number },
		rExp: { number },
		rHi: { number },
		rLo: { number },
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

---------------------------------------------------------------------
-- integer helpers (32-bit limbs; every value stays exact in doubles)
---------------------------------------------------------------------

local function clz32(v: number): number
	if v == 0 then
		return 32
	end
	local n = 0
	if band(v, 0xFFFF0000) == 0 then
		n += 16
		v = lshift(v, 16)
	end
	if band(v, 0xFF000000) == 0 then
		n += 8
		v = lshift(v, 8)
	end
	if band(v, 0xF0000000) == 0 then
		n += 4
		v = lshift(v, 4)
	end
	if band(v, 0xC0000000) == 0 then
		n += 2
		v = lshift(v, 2)
	end
	if band(v, 0x80000000) == 0 then
		n += 1
	end
	return n
end

local function clz64(hi: number, lo: number): number
	if hi ~= 0 then
		return clz32(hi)
	end
	return 32 + clz32(lo)
end

-- shift a 64-bit value right by n (n >= 1), extracting guard and sticky;
-- stIn merges into the resulting sticky
local function shr64gs(
	hi: number,
	lo: number,
	n: number,
	stIn: number
): (number, number, number, number)
	if n >= 64 then
		local any = if hi ~= 0 or lo ~= 0 then 1 else 0
		return 0, 0, 0, if any ~= 0 or stIn ~= 0 then 1 else 0
	end
	local guard, sticky
	if n == 32 then
		guard = math.floor(lo / 2 ^ 31) % 2
		sticky = if lo % 2 ^ 31 ~= 0 or stIn ~= 0 then 1 else 0
		return 0, hi, guard, sticky
	elseif n < 32 then
		local div = 2 ^ n
		guard = math.floor(lo / div * 2) % 2
		sticky = if lo % 2 ^ (n - 1) ~= 0 or stIn ~= 0 then 1 else 0
		local hiRem = hi % div
		local newLo = math.floor(lo / div) + hiRem * 2 ^ (32 - n)
		local newHi = math.floor(hi / div)
		return newHi % TWO32, newLo % TWO32, guard, sticky
	end
	local m = n - 32
	local div = 2 ^ m
	guard = math.floor(hi / div * 2) % 2
	sticky = if hi % 2 ^ (m - 1) ~= 0 or lo ~= 0 or stIn ~= 0 then 1 else 0
	lo = math.floor(hi / div)
	hi = 0
	return hi, lo, guard, sticky
end

-- shift a 64-bit value left by n (0..64); when the result exceeds 64 bits the
-- excess is assumed zero (callers guarantee it)
local function shl64(hi: number, lo: number, n: number): (number, number)
	if n == 0 then
		return hi, lo
	end
	if n == 32 then
		return lo, 0
	end
	if n > 32 then
		return lo * 2 ^ (n - 32) % TWO32, 0
	end
	local div = 2 ^ n
	return (hi * div + math.floor(lo / 2 ^ (32 - n))) % TWO32, lo * div % TWO32
end

-- 32x32 to 64-bit product via 16-bit halves (exact); returns (hi, lo)
local function mul32(a: number, b: number): (number, number)
	const a0 = a % 65536
	const a1 = math.floor(a / 65536)
	const b0 = b % 65536
	const b1 = math.floor(b / 65536)
	const mid = a0 * b1 + a1 * b0 + math.floor(a0 * b0 / 65536)
	const lo = (mid % 65536) * 65536 + a0 * b0 % 65536
	return (a1 * b1 + math.floor(mid / 65536)) % TWO32, lo % TWO32
end

-- (mhi*2^32 + mlo) * 2^d as four limbs (n3, n2, n1, n0), d in 0..64
local function shl2to4(mhi: number, mlo: number, d: number): (number, number, number, number)
	local lw = math.floor(d / 32)
	local bb = d % 32
	local n3, n2, n1, n0 = 0, 0, mhi, mlo
	if bb > 0 then
		const inv = 2 ^ (32 - bb)
		local c = math.floor(n0 / inv)
		n0 = (n0 % inv) * 2 ^ bb
		local t = (n1 % inv) * 2 ^ bb + c
		c = math.floor(n1 / inv) + math.floor(t / TWO32)
		n1 = t % TWO32
		t = (n2 % inv) * 2 ^ bb + c
		c = math.floor(n2 / inv) + math.floor(t / TWO32)
		n2 = t % TWO32
		n3 = (n3 % inv) * 2 ^ bb + c
	end
	if lw == 1 then
		return n2, n1, n0, 0
	elseif lw == 2 then
		return n1, n0, 0, 0
	end
	return n3, n2, n1, n0
end

-- split an exact nonzero value W = n3*2^96 + n2*2^64 + n1*2^32 + n0 scaled by
-- 2^(K-63) into (E, Mhi, Mlo, guard, sticky) with M's bit63 set
local function split128(
	K: number,
	n3: number,
	n2: number,
	n1: number,
	n0: number
): (number, number, number, number, number)
	local p = 127
	if n3 ~= 0 then
		p = 96 + 31 - clz32(n3)
	elseif n2 ~= 0 then
		p = 64 + 31 - clz32(n2)
	elseif n1 ~= 0 then
		p = 32 + 31 - clz32(n1)
	else
		p = 31 - clz32(n0)
	end
	if p < 63 then
		local n = 63 - p
		local hi, lo = shl64(n1, n0, n)
		return K - n, hi, lo, 0, 0
	end
	local sh = p - 63
	local lw = math.floor(sh / 32)
	local bb = sh % 32
	local k0, k1, k2
	if lw == 0 then
		k0, k1, k2 = n0, n1, n2
	elseif lw == 1 then
		k0, k1, k2 = n1, n2, n3
	elseif lw == 2 then
		k0, k1, k2 = n2, n3, 0
	else
		k0, k1, k2 = n3, 0, 0
	end
	local sticky = 0
	if lw >= 1 and n0 ~= 0 then
		sticky = 1
	end
	if lw >= 2 and n1 ~= 0 then
		sticky = 1
	end
	if lw >= 3 and n2 ~= 0 then
		sticky = 1
	end
	if bb >= 1 then
		const guard = math.floor(k0 / 2 ^ (bb - 1)) % 2
		if k0 % 2 ^ (bb - 1) ~= 0 then
			sticky = 1
		end
		-- top 64 bits of (k2:k1:k0) shifted right by bb, in exact 32-bit limbs
		const mhi = math.floor(k1 / 2 ^ bb) + (k2 % 2 ^ bb) * 2 ^ (32 - bb)
		const mlo = math.floor(k0 / 2 ^ bb) + (k1 % 2 ^ bb) * 2 ^ (32 - bb)
		return K + p - 63, mhi % TWO32, mlo % TWO32, guard, sticky
	end
	-- whole-limb shift: the guard is bit 31 of the limb just below the kept part
	local gl: number
	if lw == 1 then
		gl = n0
	elseif lw == 2 then
		gl = n1
	elseif lw == 3 then
		gl = n2
	else
		gl = 0
	end
	local guard = 0
	if gl >= 0x80000000 then
		guard = 1
		if gl ~= 0x80000000 then
			sticky = 1
		end
	elseif gl ~= 0 then
		sticky = 1
	end
	return K + p - 63, k1 % TWO32, k0 % TWO32, guard, sticky
end

---------------------------------------------------------------------
-- register state
---------------------------------------------------------------------

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

local function tagFor(e: number, hi: number, lo: number): number
	if e == NAN_EXP then
		return TAG_SPECIAL
	end
	if hi == 0 and lo == 0 then
		return TAG_ZERO
	end
	return TAG_VALID
end

local function setRegister(
	self: Fpu,
	physical: number,
	s: number,
	e: number,
	hi: number,
	lo: number
)
	self.rSign[physical] = s
	self.rExp[physical] = e
	self.rHi[physical] = hi
	self.rLo[physical] = lo
	self.tags[physical] = tagFor(e, hi, lo)
end

local function getStPacked(self: Fpu, index: number): (number, number, number, number)
	const physical = (self.top + index) % 8
	return self.rSign[physical], self.rExp[physical], self.rHi[physical], self.rLo[physical]
end

local function setStPacked(self: Fpu, index: number, s: number, e: number, hi: number, lo: number)
	setRegister(self, (self.top + index) % 8, s, e, hi, lo)
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

local function push(self: Fpu, s: number, e: number, hi: number, lo: number): boolean
	if not canPush(self) then
		stackFault(self)
		return false
	end
	self.top = (self.top + 7) % 8
	setRegister(self, self.top, s, e, hi, lo)
	syncTop(self)
	return true
end

local function pop(self: Fpu)
	self.tags[self.top] = TAG_EMPTY
	self.rSign[self.top] = 0
	self.rExp[self.top] = 0
	self.rHi[self.top] = 0
	self.rLo[self.top] = 0
	self.top = (self.top + 1) % 8
	syncTop(self)
end

---------------------------------------------------------------------
-- classification, rounding, packing
---------------------------------------------------------------------

-- kinds: 0 number, 1 zero, 2 infinity, 3 quiet nan, 4 signalling nan.
-- returns kind, sign, unbiased exponent, mantissa (hi, lo) with bit63 set.
local function classify(
	s: number,
	e: number,
	hi: number,
	lo: number
): (number, number, number, number, number)
	if e == NAN_EXP then
		if hi == INF_HI and lo == 0 then
			return 2, s, 0, 0, 0
		end
		if hi >= 0x80000000 then
			return 3, s, 0, hi, lo
		end
		return 4, s, 0, hi, lo
	end
	if e == 0 then
		if hi == 0 and lo == 0 then
			return 1, s, 0, 0, 0
		end
		if hi >= 0x80000000 then
			return 0, s, MIN_EXP, hi, lo -- pseudo-denormal acts as exponent 1
		end
		local n = clz64(hi, lo)
		local nhi, nlo = shl64(hi, lo, n)
		return 0, s, MIN_EXP - n, nhi, nlo
	end
	if hi >= 0x80000000 then
		return 0, s, e - 16383, hi, lo
	end
	local n = clz64(hi, lo)
	local nhi, nlo = shl64(hi, lo, n)
	return 0, s, e - 16383 - n, nhi, nlo
end

local function denormalOperand(self: Fpu, e: number, hi: number, lo: number)
	if e == 0 and (hi ~= 0 or lo ~= 0) then
		raiseException(self, DE)
	end
end

local function roundMode(self: Fpu): number
	return band(rshift(self.control, 10), 3)
end

local function roundIncr(self: Fpu, sign: number, lo: number, g: number, st: number): number
	const rc = roundMode(self)
	if g ~= 0 then
		if rc == 0 then
			return if st ~= 0 or lo % 2 == 1 then 1 else 0
		end
		if rc == 1 then
			return if sign == 1 then 1 else 0
		end
		if rc == 2 then
			return if sign == 0 then 1 else 0
		end
		return 0
	end
	if st ~= 0 then
		if rc == 1 then
			return if sign == 1 then 1 else 0
		end
		if rc == 2 then
			return if sign == 0 then 1 else 0
		end
	end
	return 0
end

local function precision(self: Fpu): number
	const pc = band(rshift(self.control, 8), 3)
	if pc == 2 then
		return 53
	end
	if pc == 3 then
		return 64
	end
	return 24
end

local function setRoundC1(self: Fpu, incr: number)
	self.status = bor(band(self.status, bit32.bnot(C1)), if incr ~= 0 then C1 else 0)
end

local function addOne(hi: number, lo: number): (number, number)
	local nhi, nlo = hi, lo + 1
	if nlo >= TWO32 then
		nlo -= TWO32
		nhi += 1
	end
	return nhi, nlo
end

-- round value = M*2^(E-63) + (guard/2 + sticky*[0,1/2)) ulps to the target
-- format and return the stored (s, eb, hi, lo)
local function pack(
	self: Fpu,
	sign: number,
	E: number,
	hi: number,
	lo: number,
	g: number,
	st: number,
	prec: number,
	minExp: number,
	maxExp: number,
	dw: number
): (number, number, number, number)
	setRoundC1(self, 0)
	if prec < 64 then
		local dhi, dlo, g2, s2 = shr64gs(hi, lo, 64 - prec, st)
		hi, lo, g, st = dhi, dlo, g2, s2
		E += 64 - prec
	end
	if E < minExp + 64 - prec then
		-- single round at the target's denormal precision (no 64-bit pre-round)
		const s = minExp + 63 - dw - E
		if s >= 64 then
			local any = if hi ~= 0 or lo ~= 0 or g ~= 0 or st ~= 0 then 1 else 0
			hi, lo, g, st = 0, 0, 0, any
		else
			local nhi, nlo, g2, s2 = shr64gs(hi, lo, s, st)
			hi, lo, g, st = nhi, nlo, g2, s2
		end
		E = minExp
		const incr = roundIncr(self, sign, lo, g, st)
		setRoundC1(self, incr)
		const inexact = if g ~= 0 or st ~= 0 then 1 else 0
		if incr ~= 0 then
			hi, lo = addOne(hi, lo)
		end
		if inexact ~= 0 then
			raiseException(self, PE)
			raiseException(self, UE)
		end
		if hi == 0 and lo == 0 then
			return sign, 0, 0, 0
		end
		-- m >= 2^dw (rounded up to the minimum normal)?
		local big: boolean
		if dw >= 32 then
			big = hi >= 2 ^ (dw - 32)
		else
			big = hi > 0 or lo >= 2 ^ dw
		end
		if big then
			return sign, E + 16383, hi, lo
		end
		raiseException(self, DE)
		return sign, 0, hi, lo
	end
	local incr = roundIncr(self, sign, lo, g, st)
	setRoundC1(self, incr)
	local carried = false
	if incr ~= 0 then
		hi, lo = addOne(hi, lo)
		if prec >= 32 then
			carried = hi == 2 ^ (prec - 32) and lo == 0
		else
			carried = hi == 0 and lo == 2 ^ prec
		end
		if carried then
			hi, lo = INF_HI, 0
			E += 1 - (64 - prec)
		end
	end
	-- overflow: true exponent = E - (64 - prec) unless the increment carried
	-- out (then the mantissa is 1.0 and the exponent is already true-scale)
	local overflow: boolean
	if carried or prec >= 64 then
		overflow = E > maxExp
	else
		overflow = E > maxExp + 64 - prec
	end
	if overflow then
		raiseException(self, OE)
		if g ~= 0 or st ~= 0 then
			raiseException(self, PE)
		end
		local mh, ml = 0xFFFFFFFF, 0xFFFFFFFF
		if prec == 53 then
			mh, ml = 0xFFFFFFFF, 0xFFFFF800
		elseif prec == 24 then
			mh, ml = 0xFFFFFF00, 0
		end
		const rc = roundMode(self)
		if rc == 0 then
			return sign, NAN_EXP, INF_HI, 0
		end
		if rc == 3 then
			return sign, maxExp + 16383, mh, ml
		end
		if rc == 2 then
			if sign == 0 then
				return 0, NAN_EXP, INF_HI, 0
			end
			return 1, maxExp + 16383, mh, ml
		end
		if sign == 1 then
			return 1, NAN_EXP, INF_HI, 0
		end
		return 0, maxExp + 16383, mh, ml
	end
	if g ~= 0 or st ~= 0 then
		raiseException(self, PE)
	end
	return sign, E + 16383, hi, lo
end

---------------------------------------------------------------------
-- NaN propagation and the subtract-magnitudes core
---------------------------------------------------------------------

local function propagateNan(
	self: Fpu,
	ka: number,
	sa: number,
	ha: number,
	la: number,
	kb: number,
	sb: number,
	hb: number,
	lb: number
): (number, number, number, number)
	if ka == 4 or kb == 4 then
		invalid(self)
	end
	const na = if ka >= 3 then true else false
	const nb = if kb >= 3 then true else false
	if na and nb then
		const qa = bor(ha, NAN_TOP_HI)
		const qb = bor(hb, NAN_TOP_HI)
		if qa > qb or (qa == qb and la >= lb) then
			return sa, NAN_EXP, qa, la
		end
		return sb, NAN_EXP, qb, lb
	end
	if na then
		return sa, NAN_EXP, bor(ha, NAN_TOP_HI), la
	end
	return sb, NAN_EXP, bor(hb, NAN_TOP_HI), lb
end

-- |first - second| where first = M1*2^(E1-63), second = M2*2^(E2-63), E1 >= E2.
-- Returns dom (1 first dominates, -1 second, 0 equal), E, Mhi, Mlo, g, st.
local function subMag(
	E1: number,
	M1h: number,
	M1l: number,
	E2: number,
	M2h: number,
	M2l: number
): (number, number, number, number, number, number)
	local d = E1 - E2
	if d >= 65 then
		if M2h == 0 and M2l == 0 then
			return 1, E1, M1h, M1l, 0, 0
		end
		if M1h == 0x80000000 and M1l == 0 then
			local E = E1 - 1
			local g, st = 1, 1
			if d == 65 then
				if M2h == 0x80000000 and M2l == 0 then
					g, st = 1, 0
				elseif M2h > 0x80000000 then
					g, st = 0, 1
				end
			end
			return 1, E, 0xFFFFFFFF, 0xFFFFFFFF, g, st
		end
		return 1, E1, M1h - 1, M1l, 1, 1
	end
	if d == 0 then
		if M1h == M2h and M1l == M2l then
			return 0, E1, 0, 0, 0, 0
		end
		if M1h < M2h or (M1h == M2h and M1l < M2l) then
			local d0 = M2l - M1l
			if d0 < 0 then
				d0 += TWO32
			end
			local d1 = M2h - M1h
			if d1 < 0 then
				d1 += TWO32
			end
			local E, hi, lo, g, st = split128(E2, 0, 0, d1, d0)
			return -1, E, hi, lo, g, st
		end
	end
	local n3, n2, n1, n0 = shl2to4(M1h, M1l, d)
	local d0 = n0 - M2l
	if d0 < 0 then
		d0 += TWO32
	end
	local b1 = if n0 < M2l then 1 else 0
	local d1 = n1 - M2h - b1
	if d1 < 0 then
		d1 += TWO32
	end
	local b2 = if n1 - M2h - b1 < 0 then 1 else 0
	local d2 = n2 - b2
	if d2 < 0 then
		d2 += TWO32
	end
	local b3 = if n2 < b2 then 1 else 0
	n3 -= b3
	local E, hi, lo, g, st = split128(E2, n3, d2, d1, d0)
	return 1, E, hi, lo, g, st
end

---------------------------------------------------------------------
-- arithmetic engines (packed 80-bit values in and out)
---------------------------------------------------------------------

local function addEngine(
	self: Fpu,
	flipB: boolean,
	sa: number,
	ea: number,
	ha: number,
	la: number,
	sb: number,
	eb: number,
	hb: number,
	lb: number
): (number, number, number, number)
	const ka, sa2, Ea, Mha, Mla = classify(sa, ea, ha, la)
	local kb, sb2, Eb, Mhb, Mlb = classify(sb, eb, hb, lb)
	if flipB then
		sb2 = bxor(sb2, 1)
	end
	denormalOperand(self, ea, ha, la)
	denormalOperand(self, eb, hb, lb)
	if ka >= 3 or kb >= 3 then
		return propagateNan(self, ka, sa2, Mha, Mla, kb, sb2, Mhb, Mlb)
	end
	const prec = precision(self)
	if ka == 2 and kb == 2 then
		if sa2 ~= sb2 then
			invalid(self)
			return 1, NAN_EXP, NAN_TOP_HI, 0
		end
		return sa2, NAN_EXP, INF_HI, 0
	end
	if ka == 2 then
		return sa2, NAN_EXP, INF_HI, 0
	end
	if kb == 2 then
		return sb2, NAN_EXP, INF_HI, 0
	end
	if ka == 1 and kb == 1 then
		if sa2 == sb2 then
			return sa2, 0, 0, 0
		end
		return (if roundMode(self) == 1 then 1 else 0), 0, 0, 0
	end
	if ka == 1 then
		-- surviving operand, canonically encoded
		if Eb >= MIN_EXP then
			return sb2, Eb + 16383, Mhb, Mlb
		end
		local dhi, dlo = shr64gs(Mhb, Mlb, MIN_EXP - Eb, 0)
		return sb2, 0, dhi, dlo
	end
	if kb == 1 then
		if Ea >= MIN_EXP then
			return sa2, Ea + 16383, Mha, Mla
		end
		local dhi, dlo = shr64gs(Mha, Mla, MIN_EXP - Ea, 0)
		return sa2, 0, dhi, dlo
	end
	local d = Ea - Eb
	local fa, fEa, fMha, fMla = sa2, Ea, Mha, Mla
	local fb, fEb, fMhb, fMlb = sb2, Eb, Mhb, Mlb
	if d < 0 then
		fa, fEa, fMha, fMla, fb, fEb, fMhb, fMlb = fb, fEb, fMhb, fMlb, fa, fEa, fMha, fMla
		d = -d
	end
	if sa2 == sb2 then
		if d >= 65 then
			const st = if fMhb ~= 0 or fMlb ~= 0 then 1 else 0
			return pack(self, fa, fEa, fMha, fMla, 0, st, prec, MIN_EXP, MAX_EXP, 63)
		end
		local n3, n2, n1, n0 = shl2to4(fMha, fMla, d)
		local s0 = n0 + fMlb
		n0 = s0 % TWO32
		local c = math.floor(s0 / TWO32)
		local s1 = n1 + fMhb + c
		n1 = s1 % TWO32
		c = math.floor(s1 / TWO32)
		local s2 = n2 + c
		n2 = s2 % TWO32
		c = math.floor(s2 / TWO32)
		n3 += c
		local E, hi, lo, g, st = split128(fEb, n3, n2, n1, n0)
		return pack(self, fa, E, hi, lo, g, st, prec, MIN_EXP, MAX_EXP, 63)
	end
	local dom, E, hi, lo, g, st = subMag(fEa, fMha, fMla, fEb, fMhb, fMlb)
	if dom == 0 then
		return (if roundMode(self) == 1 then 1 else 0), 0, 0, 0
	end
	local rsign = if dom == 1 then fa else fb
	return pack(self, rsign, E, hi, lo, g, st, prec, MIN_EXP, MAX_EXP, 63)
end

local function mulEngine(
	self: Fpu,
	sa: number,
	ea: number,
	ha: number,
	la: number,
	sb: number,
	eb: number,
	hb: number,
	lb: number
): (number, number, number, number)
	const ka, sa2, Ea, Mha, Mla = classify(sa, ea, ha, la)
	const kb, sb2, Eb, Mhb, Mlb = classify(sb, eb, hb, lb)
	const sign = bxor(sa2, sb2)
	denormalOperand(self, ea, ha, la)
	denormalOperand(self, eb, hb, lb)
	if ka >= 3 or kb >= 3 then
		return propagateNan(self, ka, sa2, Mha, Mla, kb, sb2, Mhb, Mlb)
	end
	const prec = precision(self)
	if ka == 2 or kb == 2 then
		if ka == 1 or kb == 1 then
			invalid(self)
			return 1, NAN_EXP, NAN_TOP_HI, 0
		end
		return sign, NAN_EXP, INF_HI, 0
	end
	if ka == 1 or kb == 1 then
		return sign, 0, 0, 0
	end
	local p1h, p1l = mul32(Mla, Mlb) -- bits 0..63
	local p2h, p2l = mul32(Mla, Mhb) -- bits 32..95
	local p3h, p3l = mul32(Mha, Mlb) -- bits 32..95
	local p4h, p4l = mul32(Mha, Mhb) -- bits 64..127
	local s0 = p1l
	const b0 = s0 % TWO32
	local s1 = p1h + p2l + p3l + math.floor(s0 / TWO32)
	const b1 = s1 % TWO32
	local s2 = p2h + p3h + p4l + math.floor(s1 / TWO32)
	const b2 = s2 % TWO32
	const b3 = p4h + math.floor(s2 / TWO32)
	local E, hi, lo, g, st = split128(Ea + Eb - 63, b3, b2, b1, b0)
	return pack(self, sign, E, hi, lo, g, st, prec, MIN_EXP, MAX_EXP, 63)
end

-- 67-bit restoring division: q = floor(Ma * 2^67 / Mb) as (qh, ql) plus the
-- 65-bit remainder (r2, rh, rl)
local function div67(
	mha: number,
	mla: number,
	mhb: number,
	mlb: number
): (number, number, number, number, number)
	local r2, rh, rl = 0, mha, mla
	local qh, ql = 0, 0
	if mha > mhb or (mha == mhb and mla >= mlb) then
		-- dividend >= divisor: consume the 2^67 quotient bit so the loop's
		-- restoring invariant r < divisor holds (the preset bit lands at
		-- position 67 after the 67 shifts)
		ql = 1
		local d0 = mla - mlb
		if d0 < 0 then
			d0 += TWO32
		end
		local b1 = if mla < mlb then 1 else 0
		rh = mha - mhb - b1
		rl = d0
	end
	for _ = 1, 67 do
		r2 = math.floor(rh / 2 ^ 31)
		rh = (rh * 2 + math.floor(rl / 2 ^ 31)) % TWO32
		rl = rl * 2 % TWO32
		local qbit = 0
		if r2 == 1 or rh > mhb or (rh == mhb and rl >= mlb) then
			qbit = 1
			local d0 = rl - mlb
			if d0 < 0 then
				d0 += TWO32
			end
			local b1 = if rl < mlb then 1 else 0
			local d1 = rh - mhb - b1
			if d1 < 0 then
				d1 += TWO32
			end
			local b2 = if rh - mhb - b1 < 0 then 1 else 0
			r2 -= b2
			rh, rl = d1, d0
		end
		qh = qh * 2 + math.floor(ql / 2 ^ 31)
		ql = (ql * 2 + qbit) % TWO32
	end
	return qh, ql, r2, rh, rl
end

local function divEngine(
	self: Fpu,
	sa: number,
	ea: number,
	ha: number,
	la: number,
	sb: number,
	eb: number,
	hb: number,
	lb: number
): (number, number, number, number)
	const ka, sa2, Ea, Mha, Mla = classify(sa, ea, ha, la)
	const kb, sb2, Eb, Mhb, Mlb = classify(sb, eb, hb, lb)
	const sign = bxor(sa2, sb2)
	denormalOperand(self, ea, ha, la)
	denormalOperand(self, eb, hb, lb)
	if ka >= 3 or kb >= 3 then
		return propagateNan(self, ka, sa2, Mha, Mla, kb, sb2, Mhb, Mlb)
	end
	const prec = precision(self)
	if (ka == 2 and kb == 2) or (ka == 1 and kb == 1) then
		invalid(self)
		return 1, NAN_EXP, NAN_TOP_HI, 0
	end
	if ka == 2 then
		return sign, NAN_EXP, INF_HI, 0
	end
	if kb == 1 then
		raiseException(self, ZE)
		return sign, NAN_EXP, INF_HI, 0
	end
	if kb == 2 then
		return sign, 0, 0, 0
	end
	if ka == 1 then
		return sign, 0, 0, 0
	end
	const qh, ql, r2, rh, rl = div67(Mha, Mla, Mhb, Mlb)
	const p = if qh >= 2 ^ 35 then 67 else 66
	const sh = p - 63
	local mhi, mlo, dropped
	if sh == 3 then
		mhi = math.floor(qh / 8)
		mlo = ((qh % 8) * 2 ^ 29 + math.floor(ql / 8)) % TWO32
		dropped = ql % 8
	else
		mhi = math.floor(qh / 16)
		mlo = ((qh % 16) * 2 ^ 28 + math.floor(ql / 16)) % TWO32
		dropped = ql % 16
	end
	const g = math.floor(dropped / 2 ^ (sh - 1)) % 2
	const st = if dropped % 2 ^ (sh - 1) ~= 0 or r2 ~= 0 or rh ~= 0 or rl ~= 0 then 1 else 0
	const E = Ea - Eb + p - 67
	return pack(self, sign, E, mhi, mlo, g, st, prec, MIN_EXP, MAX_EXP, 63)
end

local function sqrtEngine(
	self: Fpu,
	s: number,
	e: number,
	hi: number,
	lo: number
): (number, number, number, number)
	const kind, s2, E, Mhi, Mlo = classify(s, e, hi, lo)
	if kind >= 3 then
		return propagateNan(self, kind, s2, Mhi, Mlo, 0, 0, 0, 0)
	end
	if kind == 2 then
		return 0, NAN_EXP, INF_HI, 0
	end
	if kind == 1 then
		return s2, 0, 0, 0
	end
	if s2 == 1 then
		invalid(self)
		return 1, NAN_EXP, NAN_TOP_HI, 0
	end
	denormalOperand(self, e, hi, lo)
	const prec = precision(self)
	const pp = (E - 63) % 2
	-- radicand N = M * 2^pp * 2^64 (129 bits for pp=1, 128 for pp=0); the
	-- digit recurrence yields Q with the root scaled to a whole power of two
	local r4, r3, r2, r1, r0
	if pp == 0 then
		r4, r3, r2, r1, r0 = 0, Mhi, Mlo, 0, 0
	else
		r4 = math.floor(Mhi / 2 ^ 31)
		r3 = (Mhi * 2 + math.floor(Mlo / 2 ^ 31)) % TWO32
		r2 = Mlo * 2 % TWO32
		r1, r0 = 0, 0
	end
	-- digit recurrence: bit starts at 2^128 (pp=1) or 2^126 (pp=0)
	local q4, q3, q2, q1, q0 = 0, 0, 0, 0, 0
	local b4, b3, b2, b1, b0
	if pp == 0 then
		b4, b3, b2, b1, b0 = 0, 0x40000000, 0, 0, 0 -- 2^126
	else
		b4, b3, b2, b1, b0 = 1, 0, 0, 0, 0 -- 2^128
	end
	local iterations = if pp == 0 then 64 else 65
	for _ = 1, iterations do
		-- t = q + bit
		local t0 = q0 + b0
		const t0m = t0 % TWO32
		const tc0 = math.floor(t0 / TWO32)
		local t1 = q1 + b1 + tc0
		const t1m = t1 % TWO32
		const tc1 = math.floor(t1 / TWO32)
		local t2 = q2 + b2 + tc1
		const t2m = t2 % TWO32
		const tc2 = math.floor(t2 / TWO32)
		local t3 = q3 + b3 + tc2
		const t3m = t3 % TWO32
		const tc3 = math.floor(t3 / TWO32)
		local t4 = q4 + b4 + tc3
		-- compare (r4..r0) >= (t4..t0)
		local ge: boolean
		if r4 ~= t4 then
			ge = r4 > t4
		elseif r3 ~= t3m then
			ge = r3 > t3m
		elseif r2 ~= t2m then
			ge = r2 > t2m
		elseif r1 ~= t1m then
			ge = r1 > t1m
		else
			ge = r0 >= t0m
		end
		if ge then
			local d0 = r0 - t0m
			if d0 < 0 then
				d0 += TWO32
			end
			const sb1 = if r0 < t0m then 1 else 0
			local d1 = r1 - t1m - sb1
			if d1 < 0 then
				d1 += TWO32
			end
			const sb2 = if r1 - t1m - sb1 < 0 then 1 else 0
			local d2 = r2 - t2m - sb2
			if d2 < 0 then
				d2 += TWO32
			end
			const sb3 = if r2 - t2m - sb2 < 0 then 1 else 0
			local d3 = r3 - t3m - sb3
			if d3 < 0 then
				d3 += TWO32
			end
			const sb4 = if r3 - t3m - sb3 < 0 then 1 else 0
			r4 = r4 - t4 - sb4
			r3, r2, r1, r0 = d3, d2, d1, d0
			-- q = floor(q / 2) + bit
			q0 = math.floor(q0 / 2) + (q1 % 2) * 2 ^ 31
			q1 = (math.floor(q1 / 2) + (q2 % 2) * 2 ^ 31) % TWO32
			q2 = (math.floor(q2 / 2) + (q3 % 2) * 2 ^ 31) % TWO32
			q3 = (math.floor(q3 / 2) + (q4 % 2) * 2 ^ 31) % TWO32
			q4 = math.floor(q4 / 2)
			local s0 = q0 + b0
			q0 = s0 % TWO32
			const c0 = math.floor(s0 / TWO32)
			local sum1 = q1 + b1 + c0
			q1 = sum1 % TWO32
			const c1 = math.floor(sum1 / TWO32)
			local sum2 = q2 + b2 + c1
			q2 = sum2 % TWO32
			const c2 = math.floor(sum2 / TWO32)
			local sum3 = q3 + b3 + c2
			q3 = sum3 % TWO32
			q4 = (q4 + b4 + math.floor(sum3 / TWO32)) % TWO32
		else
			q0 = math.floor(q0 / 2) + (q1 % 2) * 2 ^ 31
			q1 = (math.floor(q1 / 2) + (q2 % 2) * 2 ^ 31) % TWO32
			q2 = (math.floor(q2 / 2) + (q3 % 2) * 2 ^ 31) % TWO32
			q3 = (math.floor(q3 / 2) + (q4 % 2) * 2 ^ 31) % TWO32
			q4 = math.floor(q4 / 2)
		end
		-- bit = bit / 4
		local c1b = b1 % 4
		local c2b = b2 % 4
		local c3b = b3 % 4
		local c4b = b4 % 4
		b0 = math.floor(b0 / 4) + c1b * 2 ^ 30
		b1 = (math.floor(b1 / 4) + c2b * 2 ^ 30) % TWO32
		b2 = (math.floor(b2 / 4) + c3b * 2 ^ 30) % TWO32
		b3 = (math.floor(b3 / 4) + c4b * 2 ^ 30) % TWO32
		b4 = math.floor(b4 / 4)
	end
	-- root Q = (q4..q0); remainder (r4..r0)
	local g, st
	local Rnz = if r4 ~= 0 or r3 ~= 0 or r2 ~= 0 or r1 ~= 0 or r0 ~= 0 then true else false
	if pp == 0 then
		-- Q < 2^64: fraction = sqrt(N) - Q; guard iff remainder > Q
		local gt: boolean
		if r2 ~= 0 then
			gt = true
		elseif r1 ~= q1 then
			gt = r1 > q1
		else
			gt = r0 > q0
		end
		g = if gt then 1 else 0
		st = if Rnz then 1 else 0
		local base = math.floor((E - 63) / 2) + 31
		return pack(self, 0, base, q1, q0, g, st, prec, MIN_EXP, MAX_EXP, 63)
	end
	-- pp == 1: Q is 65 bits; M = floor(Q / 2) with the dropped bit as guard
	g = q0 % 2
	st = if Rnz then 1 else 0
	local mlo = math.floor(q0 / 2) + (q1 % 2) * 2 ^ 31
	local mhi = (math.floor(q1 / 2) + (q2 % 2) * 2 ^ 31) % TWO32
	const base = math.floor((E - 64) / 2) + 32
	return pack(self, 0, base, mhi, mlo % TWO32, g, st, prec, MIN_EXP, MAX_EXP, 63)
end

---------------------------------------------------------------------
-- scale / extract / round-to-integer / compare / prem
---------------------------------------------------------------------

local function scaleEngine(
	self: Fpu,
	sa: number,
	ea: number,
	ha: number,
	la: number,
	sb: number,
	eb: number,
	hb: number,
	lb: number
): (number, number, number, number)
	const ka, sa2, Ea, Mha, Mla = classify(sa, ea, ha, la)
	const kb, sb2, Eb, Mhb, Mlb = classify(sb, eb, hb, lb)
	denormalOperand(self, ea, ha, la)
	if ka >= 3 or kb >= 3 then
		return propagateNan(self, ka, sa2, Mha, Mla, kb, sb2, Mhb, Mlb)
	end
	const prec = precision(self)
	if kb == 2 then
		invalid(self)
		return 1, NAN_EXP, NAN_TOP_HI, 0
	end
	if ka == 2 then
		return sa2, NAN_EXP, INF_HI, 0
	end
	if ka == 1 then
		return sa2, 0, 0, 0
	end
	local n: number
	if kb == 1 then
		n = 0
	elseif Eb >= 63 then
		-- magnitude at least 2^33: always saturates
		n = 2 ^ 62
	else
		-- floor((Mhb*2^32 + Mlb) / 2^(63 - Eb)), exact in limbs
		local k = 63 - Eb
		if k <= 32 then
			n = Mhb * 2 ^ (32 - k) + math.floor(Mlb / 2 ^ k)
		else
			-- Mlb/2^k < 1 cannot carry into the quotient: floor(M/2^k) = floor(Mhb/2^(k-32))
			n = math.floor(Mhb / 2 ^ (k - 32))
		end
	end
	if sb2 == 1 then
		n = -n
	end
	if n > 2 ^ 62 then
		n = 2 ^ 62
	elseif n < -(2 ^ 62) then
		n = -(2 ^ 62)
	end
	return pack(self, sa2, Ea + n, Mha, Mla, 0, 0, prec, MIN_EXP, MAX_EXP, 63)
end

-- returns significand (s, eb, hi, lo) then exponent (s, eb, hi, lo)
local function xtractEngine(
	self: Fpu,
	s: number,
	e: number,
	hi: number,
	lo: number
): (number, number, number, number, number, number, number, number)
	const kind, s2, E, Mhi, Mlo = classify(s, e, hi, lo)
	if kind >= 3 then
		invalid(self)
		return 1, NAN_EXP, NAN_TOP_HI, 0, 1, NAN_EXP, NAN_TOP_HI, 0
	end
	if kind == 2 then
		return s2, NAN_EXP, INF_HI, 0, s2, NAN_EXP, INF_HI, 0
	end
	if kind == 1 then
		return s2, 0, 0, 0, s2, NAN_EXP, INF_HI, 0
	end
	denormalOperand(self, e, hi, lo)
	-- exponent as a real number: |E| encoded with a 64-bit mantissa
	local mag = math.abs(E)
	local expSe = if E < 0 then 1 else 0
	if mag == 0 then
		return s2, 0x3FFF, Mhi, Mlo, expSe, 0, 0, 0
	end
	local bl = 32 - clz32(mag)
	return s2, 0x3FFF, Mhi, Mlo, expSe, 16382 + bl, mag * 2 ^ (32 - bl) % TWO32, 0
end

local function roundIntEngine(
	self: Fpu,
	s: number,
	e: number,
	hi: number,
	lo: number
): (number, number, number, number)
	const kind, s2, E, Mhi, Mlo = classify(s, e, hi, lo)
	if kind >= 3 then
		return propagateNan(self, kind, s2, Mhi, Mlo, 0, 0, 0, 0)
	end
	if kind == 2 then
		return s2, NAN_EXP, INF_HI, 0
	end
	if kind == 1 then
		return s2, 0, 0, 0
	end
	denormalOperand(self, e, hi, lo)
	if E >= 63 then
		return s2, E + 16383, Mhi, Mlo
	end
	const nhi, nlo, g, st = shr64gs(Mhi, Mlo, 63 - E, 0)
	const incr = roundIncr(self, s2, nlo, g, st)
	setRoundC1(self, incr)
	local uhi, ulo = nhi, nlo
	if incr ~= 0 then
		uhi, ulo = addOne(uhi, ulo)
	end
	if g ~= 0 or st ~= 0 then
		raiseException(self, PE)
	end
	if uhi == 0 and ulo == 0 then
		return s2, 0, 0, 0
	end
	const n = clz64(uhi, ulo)
	local fhi, flo = shl64(uhi, ulo, n)
	return s2, 16383 + 63 - n, fhi, flo
end

-- relation: 0 greater, 1 less, 2 equal, 3 unordered
local function compareEngine(
	self: Fpu,
	quiet: boolean,
	sa: number,
	ea: number,
	ha: number,
	la: number,
	sb: number,
	eb: number,
	hb: number,
	lb: number
): number
	const ka, sa2, Ea, Mha, Mla = classify(sa, ea, ha, la)
	const kb, sb2, Eb, Mhb, Mlb = classify(sb, eb, hb, lb)
	if ka >= 3 or kb >= 3 then
		if not quiet or ka == 4 or kb == 4 then
			invalid(self)
		end
		setCondition(self, true, false, true, true)
		return 3
	end
	local rel: number
	if ka == 1 and kb ~= 1 then
		rel = if sb2 == 0 then 1 else 0
	elseif kb == 1 and ka ~= 1 then
		rel = if sa2 == 0 then 0 else 1
	elseif ka == 2 or kb == 2 then
		if ka == 2 and kb == 2 then
			rel = if sa2 == sb2 then 2 else if sa2 == 0 then 0 else 1
		elseif ka == 2 then
			rel = if sa2 == 0 then 0 else 1
		else
			rel = if sb2 ~= 0 then 0 else 1
		end
	elseif ka ~= 1 and kb ~= 1 and sa2 ~= sb2 then
		rel = if sb2 ~= 0 then 0 else 1
	elseif Ea ~= Eb then
		rel = if Ea > Eb then 0 else 1
	elseif Mha ~= Mhb then
		rel = if Mha > Mhb then 0 else 1
	elseif Mla ~= Mlb then
		rel = if Mla > Mlb then 0 else 1
	else
		rel = 2
	end
	setCondition(self, rel == 1, false, false, rel == 2)
	return rel
end

local function premEngine(
	self: Fpu,
	nearest: boolean,
	sa: number,
	ea: number,
	ha: number,
	la: number,
	sb: number,
	eb: number,
	hb: number,
	lb: number
): (number, number, number, number)
	local ka, sa2, Ea, Mha, Mla = classify(sa, ea, ha, la)
	const kb, sb2, Eb, Mhb, Mlb = classify(sb, eb, hb, lb)
	denormalOperand(self, ea, ha, la)
	denormalOperand(self, eb, hb, lb)
	if ka >= 3 or kb >= 3 then
		local r1, r2v, r3v, r4v = propagateNan(self, ka, sa2, Mha, Mla, kb, sb2, Mhb, Mlb)
		setCondition(self, false, false, false, false)
		return r1, r2v, r3v, r4v
	end
	setCondition(self, false, false, false, false)
	if ka == 2 or kb == 1 then
		invalid(self)
		return 1, NAN_EXP, NAN_TOP_HI, 0
	end
	if ka == 1 then
		return sa2, 0, 0, 0
	end
	if kb == 2 then
		return sa2, ea, ha, la
	end
	local sign = sa2
	local D = Ea - Eb
	while D >= 64 do
		local r2, rh, rl = 0, Mha, Mla
		for _ = 1, 32 do
			r2 = math.floor(rh / 2 ^ 31)
			rh = (rh * 2 + math.floor(rl / 2 ^ 31)) % TWO32
			rl = rl * 2 % TWO32
			if r2 == 1 or rh > Mhb or (rh == Mhb and rl >= Mlb) then
				local d0 = rl - Mlb
				if d0 < 0 then
					d0 += TWO32
				end
				const b1 = if rl < Mlb then 1 else 0
				local d1 = rh - Mhb - b1
				if d1 < 0 then
					d1 += TWO32
				end
				rh, rl = d1, d0
			end
		end
		local bl = 64 - clz64(rh, rl)
		Mha, Mla = shl64(rh, rl, 64 - bl)
		Ea = Eb + D - 32 + bl - 64
		D = Ea - Eb
	end
	local qmod = 0
	if D >= 0 then
		-- 65-bit restoring division: r2 holds R's bit 64 across the shift
		local r2, rh, rl = 0, 0, 0
		for t = 0, 63 + D do
			local bit: number
			if t < 32 then
				bit = math.floor(Mha / 2 ^ (31 - t)) % 2
			elseif t < 64 then
				bit = math.floor(Mla / 2 ^ (63 - t)) % 2
			else
				bit = 0
			end
			r2 = math.floor(rh / 2 ^ 31)
			rh = (rh * 2 + math.floor(rl / 2 ^ 31)) % TWO32
			rl = (rl * 2 + bit) % TWO32
			if r2 == 1 or rh > Mhb or (rh == Mhb and rl >= Mlb) then
				local d0 = rl - Mlb
				if d0 < 0 then
					d0 += TWO32
				end
				const b1 = if rl < Mlb then 1 else 0
				local d1 = rh - Mhb - b1
				if d1 < 0 then
					d1 += TWO32
				end
				rh, rl = d1, d0
				qmod = (qmod * 2 + 1) % 8
			else
				qmod = qmod * 2 % 8
			end
		end
		local rounded = false
		if nearest then
			const carry = math.floor(rh / 2 ^ 31)
			const tl = rl * 2 % TWO32
			const th = (rh * 2 + math.floor(rl / 2 ^ 31)) % TWO32
			if carry == 1 or th > Mhb or (th == Mhb and tl >= Mlb) then
				if not (carry == 0 and th == Mhb and tl == Mlb and qmod % 2 == 0) then
					rounded = true
				end
			end
		end
		local E, hi, lo
		if rounded then
			qmod = (qmod + 1) % 8
			sign = bxor(sa2, 1)
			local d0 = Mlb - rl
			if d0 < 0 then
				d0 += TWO32
			end
			local d1 = Mhb - rh
			if d1 < 0 then
				d1 += TWO32
			end
			local n = clz64(d1, d0)
			hi, lo = shl64(d1, d0, n)
			E = Eb - n
		elseif rh == 0 and rl == 0 then
			setCondition(
				self,
				math.floor(qmod / 4) % 2 == 1,
				qmod % 2 == 1,
				false,
				math.floor(qmod / 2) % 2 == 1
			)
			return sa2, 0, 0, 0
		else
			local n = clz64(rh, rl)
			hi, lo = shl64(rh, rl, n)
			E = Eb - n
		end
		local r1, r2v, r3v, r4v = pack(self, sign, E, hi, lo, 0, 0, 64, MIN_EXP, MAX_EXP, 63)
		setCondition(
			self,
			math.floor(qmod / 4) % 2 == 1,
			qmod % 2 == 1,
			false,
			math.floor(qmod / 2) % 2 == 1
		)
		return r1, r2v, r3v, r4v
	end
	-- D less than zero: quotient 0 (or 1 when FPREM1 rounds up).
	-- Q = 1 iff ST0 >= ST1/2, i.e. the (Ea, Ma) pair dominates (Eb - 1, Mb).
	local q1 = nearest
		and (Ea > Eb - 1 or (Ea == Eb - 1 and (Mha > Mhb or (Mha == Mhb and Mla >= Mlb))))
	local r1, r2v, r3v, r4v
	if not q1 then
		r1, r2v, r3v, r4v = pack(self, sa2, Ea, Mha, Mla, 0, 0, 64, MIN_EXP, MAX_EXP, 63)
	else
		local _, E, hi, lo, g, st = subMag(Eb, Mhb, Mlb, Ea, Mha, Mla)
		r1, r2v, r3v, r4v = pack(self, bxor(sa2, 1), E, hi, lo, g, st, 64, MIN_EXP, MAX_EXP, 63)
	end
	setCondition(self, false, q1, false, false)
	return r1, r2v, r3v, r4v
end

---------------------------------------------------------------------
-- double conversion (exact widening and nearest narrowing)
---------------------------------------------------------------------

local function fromDouble(d: number): (number, number, number, number)
	buffer.writef64(cvt, 0, d)
	const lo = buffer.readu32(cvt, 0)
	const hi = buffer.readu32(cvt, 4)
	const s = math.floor(hi / 2 ^ 31)
	const e11 = math.floor(hi / 2 ^ 20) % 0x800
	const m52 = hi % 2 ^ 20
	if e11 == 0x7FF then
		if m52 == 0 and lo == 0 then
			return s, NAN_EXP, INF_HI, 0
		end
		return s, NAN_EXP, NAN_TOP_HI, 0
	end
	if e11 == 0 then
		if m52 == 0 and lo == 0 then
			return s, 0, 0, 0
		end
		-- 64-bit mantissa (m52:lo) scaled by 2^11, assembled in exact limbs
		local mhi = m52 * 2 ^ 11 + math.floor(lo / 2 ^ 21)
		local mlo = (lo % 2 ^ 21) * 2 ^ 11
		local n = clz64(mhi, mlo)
		local fhi, flo = shl64(mhi, mlo, n)
		return s, 16383 - 1022 - n, fhi, flo
	end
	const carry = math.floor(lo / 2 ^ 21)
	return s, e11 - 1023 + 16383, (INF_HI + m52 * 2 ^ 11 + carry) % TWO32, lo * 2 ^ 11 % TWO32
end

-- narrow to a double with round-to-nearest (ignoring the control word's RC)
local function toDoubleNearest(self: Fpu, s: number, e: number, hi: number, lo: number): number
	const kind, s2, E, Mhi, Mlo = classify(s, e, hi, lo)
	if kind >= 3 then
		return 0 / 0
	end
	if kind == 2 then
		return if s2 == 1 then -math.huge else math.huge
	end
	if kind == 1 then
		return if s2 == 1 then -0.0 else 0.0
	end
	const saved = self.control
	self.control = band(saved, bit32.bnot(0x0C00))
	const savedStatus = self.status
	const rs, reb, rhi, rlo = pack(self, s2, E, Mhi, Mlo, 0, 0, 53, -1022, 1023, 52)
	self.control = saved
	self.status = savedStatus
	if reb == NAN_EXP then
		return if rs == 1 then -math.huge else math.huge
	end
	if reb == 0 then
		if rhi == 0 and rlo == 0 then
			return if rs == 1 then -0.0 else 0.0
		end
		buffer.writeu32(cvt, 0, rlo)
		buffer.writeu32(cvt, 4, rs * 2 ^ 31)
	else
		buffer.writeu32(cvt, 0, rlo)
		buffer.writeu32(cvt, 4, rs * 2 ^ 31 + (reb - 16383 - 11 + 1023) * 2 ^ 20 + rhi % 2 ^ 20)
	end
	return buffer.readf64(cvt, 0)
end

-- returns the two u32 halves of the f64 bit pattern
local function f64BitsFrom(
	s: number,
	eb: number,
	hi: number,
	lo: number,
	eScale: number
): (number, number)
	if eb == NAN_EXP then
		return s * 2 ^ 31 + 0x7FF00000, 0
	end
	if eb == 0 then
		if hi == 0 and lo == 0 then
			return s * 2 ^ 31, 0
		end
		return s * 2 ^ 31, lo
	end
	return s * 2 ^ 31 + (eb - 16383 - eScale + 1023) * 2 ^ 20 + hi % 2 ^ 20, lo
end

local function f32BitsFrom(s: number, eb: number, hi: number, lo: number, eScale: number): number
	if eb == NAN_EXP then
		return s * 2 ^ 31 + 0x7F800000
	end
	if eb == 0 then
		if hi == 0 and lo == 0 then
			return s * 2 ^ 31
		end
		return s * 2 ^ 31 + lo
	end
	return s * 2 ^ 31 + (eb - 16383 - eScale + 127) * 2 ^ 23 + lo % 2 ^ 23
end

local function storeF64(self: Fpu, s: number, e: number, hi: number, lo: number): (number, number)
	const kind, s2, E, Mhi, Mlo = classify(s, e, hi, lo)
	if kind >= 3 then
		return s2 * 2 ^ 31 + 0x7FF80000, 0
	end
	if kind == 2 then
		return s2 * 2 ^ 31 + 0x7FF00000, 0
	end
	if kind == 1 then
		return s2 * 2 ^ 31, 0
	end
	const savedStatus = self.status
	const rs, reb, rhi, rlo = pack(self, s2, E, Mhi, Mlo, 0, 0, 53, -1022, 1023, 52)
	-- narrowing stores report PE plus the rounding direction (C1)
	self.status = bor(band(savedStatus, bit32.bnot(bor(PE, C1))), band(self.status, bor(PE, C1)))
	return f64BitsFrom(rs, reb, rhi, rlo, 11)
end

local function storeF32(self: Fpu, s: number, e: number, hi: number, lo: number): number
	const kind, s2, E, Mhi, Mlo = classify(s, e, hi, lo)
	if kind >= 3 then
		return s2 * 2 ^ 31 + 0x7FC00000
	end
	if kind == 2 then
		return s2 * 2 ^ 31 + 0x7F800000
	end
	if kind == 1 then
		return s2 * 2 ^ 31
	end
	const savedStatus = self.status
	const rs, reb, rhi, rlo = pack(self, s2, E, Mhi, Mlo, 0, 0, 24, -126, 127, 23)
	-- narrowing stores report PE plus the rounding direction (C1)
	self.status = bor(band(savedStatus, bit32.bnot(bor(PE, C1))), band(self.status, bor(PE, C1)))
	return f32BitsFrom(rs, reb, rhi, rlo, 40)
end

-- convert to a 64-bit integer with control-word rounding; returns
-- (uhi, ulo, overflow)
local function toInt64(
	self: Fpu,
	s: number,
	e: number,
	hi: number,
	lo: number,
	limitBits: number
): (number, number, boolean)
	const kind, s2, E, Mhi, Mlo = classify(s, e, hi, lo)
	if kind >= 2 then
		invalid(self)
		return 0x80000000, 0, true
	end
	local uhi, ulo
	local inexact = false
	if E >= 63 then
		if E > 63 then
			return 0x80000000, 0, true
		end
		uhi, ulo = Mhi, Mlo
	else
		local nhi, nlo, g, st = shr64gs(Mhi, Mlo, 63 - E, 0)
		uhi, ulo = nhi, nlo
		inexact = g ~= 0 or st ~= 0
		const incr = roundIncr(self, s2, nlo, g, st)
		setRoundC1(self, incr)
		if incr ~= 0 then
			uhi, ulo = addOne(uhi, ulo)
			if uhi >= TWO32 then
				return 0x80000000, 0, true
			end
		end
		if inexact then
			raiseException(self, PE)
		end
	end
	-- range check in limbs: limit = 2^limitBits
	local limH = math.floor(2 ^ limitBits / TWO32) % TWO32
	local limL = 2 ^ limitBits % TWO32
	local above: boolean
	if uhi ~= limH then
		above = uhi > limH
	else
		above = ulo > limL
	end
	if s2 == 1 then
		if above then
			return 0x80000000, 0, true
		end
	else
		if above or (uhi == limH and ulo == limL) then
			return 0x80000000, 0, true
		end
	end
	return uhi, ulo, false
end

local function fromInt64(hi: number, lo: number, neg: boolean): (number, number, number, number)
	if hi == 0 and lo == 0 then
		return if neg then 1 else 0, 0, 0, 0
	end
	const bl = 64 - clz64(hi, lo)
	local mhi, mlo = shl64(hi, lo, 64 - bl)
	return if neg then 1 else 0, 16383 + bl - 1, mhi, mlo
end

local function fromInt(v: number): (number, number, number, number)
	local neg = v < 0
	if neg then
		v = -v
	end
	return fromInt64(math.floor(v / TWO32) % TWO32, v % TWO32, neg)
end

---------------------------------------------------------------------
-- memory operands
---------------------------------------------------------------------

local function memoryAddress(cpu: any, e: any, size: number): number
	return cpu:linear(e.seg or "ds", e.off or 0, size)
end

local function readM32(cpu: any, e: any): number
	buffer.writeu32(cvt, 0, cpu:read32(memoryAddress(cpu, e, 4)))
	return buffer.readf32(cvt, 0)
end

local function readM64(cpu: any, e: any): number
	buffer.writeu32(cvt, 0, cpu:read32(memoryAddress(cpu, e, 8)))
	buffer.writeu32(cvt, 4, cpu:read32(memoryAddress(cpu, e, 8) + 4))
	return buffer.readf64(cvt, 0)
end

local function readM80At(cpu: any, address: number): (number, number, number, number)
	const lo = cpu:read32(address)
	const hi = cpu:read32(address + 4)
	const se = cpu:read16(address + 8)
	return math.floor(se / 2 ^ 15), band(se, 0x7FFF), hi, lo
end

local function writeM80At(cpu: any, address: number, s: number, exp: number, hi: number, lo: number)
	cpu:write32(address, lo)
	cpu:write32(address + 4, hi)
	cpu:write16(address + 8, bor(band(exp, 0x7FFF), lshift(band(s, 1), 15)))
end

local function readM80(cpu: any, e: any): (number, number, number, number)
	return readM80At(cpu, memoryAddress(cpu, e, 10))
end

local function writeM80(cpu: any, e: any, s: number, exp: number, hi: number, lo: number)
	writeM80At(cpu, memoryAddress(cpu, e, 10), s, exp, hi, lo)
end

local function addI(h1: number, l1: number, h2: number, l2: number): (number, number)
	local l = l1 + l2
	local carry = math.floor(l / TWO32)
	local h = h1 + h2 + carry
	return h % TWO32, l % TWO32
end

local function shlI(h: number, l: number, n: number): (number, number)
	if n == 0 then
		return h, l
	end
	if n >= 32 then
		return l * 2 ^ (n - 32) % TWO32, 0
	end
	local div = 2 ^ n
	return (h * div + math.floor(l / 2 ^ (32 - n))) % TWO32, l * div % TWO32
end

local function readBcd(cpu: any, e: any): (number, number)
	const address = memoryAddress(cpu, e, 10)
	local h, l = 0, 0
	for index = 8, 0, -1 do
		const byte = cpu:read8(address + index)
		const d = rshift(byte, 4) * 10 + band(byte, 0x0F)
		-- value = value * 100 + d, via (v*16 + v*8 + v) * 4 + d? use v*96 + v*4
		local a1, a0 = shlI(h, l, 5) -- 32
		local b1, b0 = shlI(h, l, 6) -- 64
		local c1, c0 = shlI(h, l, 2) -- 4
		local t1, t0 = addI(a1, a0, b1, b0) -- 96
		local m1, m0 = addI(t1, t0, c1, c0) -- 100
		h, l = addI(m1, m0, 0, d)
	end
	if band(cpu:read8(address + 9), 0x80) ~= 0 then
		h = bxor(h, 0x80000000)
	end
	return h, l
end

---------------------------------------------------------------------
-- instruction implementations
---------------------------------------------------------------------

local function doFld(self: Fpu, s: number, e: number, hi: number, lo: number)
	push(self, s, e, hi, lo)
end

local function doFstNarrow(self: Fpu, cpu: any, e: any, is32: boolean, popAfter: boolean)
	if not ensureStack(self, 1) then
		return
	end
	const s, exp, hi, lo = getStPacked(self, 0)
	const address = memoryAddress(cpu, e, if is32 then 4 else 8)
	if is32 then
		cpu:write32(address, storeF32(self, s, exp, hi, lo))
	else
		local bh, bl = storeF64(self, s, exp, hi, lo)
		cpu:write32(address, bl)
		cpu:write32(address + 4, bh)
	end
	if popAfter then
		pop(self)
	end
end

local function doFcom(
	self: Fpu,
	quiet: boolean,
	s: number,
	e: number,
	hi: number,
	lo: number,
	popAfter: boolean
)
	if not ensureStack(self, 1) then
		return
	end
	const sa, ea, ha, la = getStPacked(self, 0)
	compareEngine(self, quiet, sa, ea, ha, la, s, e, hi, lo)
	if popAfter then
		pop(self)
	end
end

local function fcomRegister(self: Fpu, index: number, popAfter: boolean, quiet: boolean)
	if not ensureStack(self, 1) or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	const sa, ea, ha, la = getStPacked(self, 0)
	const sb, eb, hb, lb = getStPacked(self, index)
	compareEngine(self, quiet, sa, ea, ha, la, sb, eb, hb, lb)
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
	const p0 = (self.top + 0) % 8
	const p1 = (self.top + index) % 8
	self.rSign[p0], self.rSign[p1] = self.rSign[p1], self.rSign[p0]
	self.rExp[p0], self.rExp[p1] = self.rExp[p1], self.rExp[p0]
	self.rHi[p0], self.rHi[p1] = self.rHi[p1], self.rHi[p0]
	self.rLo[p0], self.rLo[p1] = self.rLo[p1], self.rLo[p0]
	local tag = self.tags[p0]
	self.tags[p0], self.tags[p1] = self.tags[p1], tag
end

-- computes (first OP second) where first = ST0 and second = ST(index) unless
-- reverse swaps them; the result lands in ST(targetIndex), then pops on demand
local function topArithmetic(
	self: Fpu,
	index: number,
	op: number,
	reverse: boolean,
	targetIndex: number,
	popAfter: boolean
)
	if not ensureStack(self, 1) then
		return
	end
	if index ~= 0 and stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	local a0, a1, a2, a3 = getStPacked(self, 0)
	local b0, b1, b2, b3 = getStPacked(self, index)
	if reverse then
		a0, a1, a2, a3, b0, b1, b2, b3 = b0, b1, b2, b3, a0, a1, a2, a3
	end
	local r1, r2v, r3v, r4v
	if op == 0 then
		r1, r2v, r3v, r4v = addEngine(self, false, a0, a1, a2, a3, b0, b1, b2, b3)
	elseif op == 1 then
		r1, r2v, r3v, r4v = addEngine(self, true, a0, a1, a2, a3, b0, b1, b2, b3)
	elseif op == 2 then
		r1, r2v, r3v, r4v = mulEngine(self, a0, a1, a2, a3, b0, b1, b2, b3)
	else
		r1, r2v, r3v, r4v = divEngine(self, a0, a1, a2, a3, b0, b1, b2, b3)
	end
	setStPacked(self, targetIndex, r1, r2v, r3v, r4v)
	if popAfter then
		pop(self)
	end
end

local function binaryTopConstant(
	self: Fpu,
	op: number,
	cs: number,
	ce: number,
	ch: number,
	cl: number,
	reverse: boolean
)
	if not ensureStack(self, 1) then
		return
	end
	local a0, a1, a2, a3 = getStPacked(self, 0)
	if reverse then
		local t0, t1, t2, t3 = a0, a1, a2, a3
		a0, a1, a2, a3 = cs, ce, ch, cl
		cs, ce, ch, cl = t0, t1, t2, t3
	end
	local r1, r2v, r3v, r4v
	if op == 0 then
		r1, r2v, r3v, r4v = addEngine(self, false, cs, ce, ch, cl, a0, a1, a2, a3)
	elseif op == 1 then
		r1, r2v, r3v, r4v = addEngine(self, true, cs, ce, ch, cl, a0, a1, a2, a3)
	elseif op == 2 then
		r1, r2v, r3v, r4v = mulEngine(self, cs, ce, ch, cl, a0, a1, a2, a3)
	else
		r1, r2v, r3v, r4v = divEngine(self, cs, ce, ch, cl, a0, a1, a2, a3)
	end
	setStPacked(self, 0, r1, r2v, r3v, r4v)
end

local function ftst(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	const sa, ea, ha, la = getStPacked(self, 0)
	compareEngine(self, false, sa, ea, ha, la, 0, 0, 0, 0)
end

local function fxam(self: Fpu)
	const tag = stackTag(self, 0)
	if tag == TAG_EMPTY then
		setCondition(self, true, false, false, true)
		return
	end
	const s, e, hi, lo = getStPacked(self, 0)
	const negative = s == 1
	if e == NAN_EXP then
		if hi == INF_HI and lo == 0 then
			setCondition(self, true, negative, true, false) -- infinity
		else
			setCondition(self, true, negative, false, false) -- nan
		end
	elseif e == 0 then
		if hi == 0 and lo == 0 then
			setCondition(self, false, negative, false, true) -- zero
		else
			setCondition(self, false, negative, true, true) -- denormal
		end
	else
		setCondition(self, false, negative, true, false) -- normal
	end
end

local function f2xm1(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	const s, e, hi, lo = getStPacked(self, 0)
	const kind = classify(s, e, hi, lo)
	const value = toDoubleNearest(self, s, e, hi, lo)
	if kind >= 2 or value < -1 or value > 1 then
		invalid(self)
		setStPacked(self, 0, 1, NAN_EXP, NAN_TOP_HI, 0)
		return
	end
	if value == 0 then
		return -- -0 stays -0
	end
	const ns, ne, nhi, nlo = fromDouble(2 ^ value - 1)
	setStPacked(self, 0, ns, ne, nhi, nlo)
end

local function fyl2x(self: Fpu)
	if not ensureStack(self, 2) then
		return
	end
	const xs, xe, xhi, xlo = getStPacked(self, 0)
	const ys, ye, yhi, ylo = getStPacked(self, 1)
	const xkind = classify(xs, xe, xhi, xlo)
	const ykind = classify(ys, ye, yhi, ylo)
	if xkind >= 3 or ykind >= 3 or (xkind == 0 and xs == 1) then
		invalid(self)
		setStPacked(self, 1, 1, NAN_EXP, NAN_TOP_HI, 0)
	else
		if xkind == 1 then
			raiseException(self, ZE)
		end
		const x = toDoubleNearest(self, xs, xe, xhi, xlo)
		const y = toDoubleNearest(self, ys, ye, yhi, ylo)
		const r = y * (math.log(x) / math.log(2))
		const ns, ne, nhi, nlo = fromDouble(r)
		setStPacked(self, 1, ns, ne, nhi, nlo)
	end
	pop(self)
end

local function fyl2xp1(self: Fpu)
	if not ensureStack(self, 2) then
		return
	end
	const xs, xe, xhi, xlo = getStPacked(self, 0)
	const ys, ye, yhi, ylo = getStPacked(self, 1)
	const xkind = classify(xs, xe, xhi, xlo)
	const ykind = classify(ys, ye, yhi, ylo)
	const x = toDoubleNearest(self, xs, xe, xhi, xlo)
	if xkind >= 3 or ykind >= 3 or x <= -1 then
		invalid(self)
		setStPacked(self, 1, 1, NAN_EXP, NAN_TOP_HI, 0)
	else
		const y = toDoubleNearest(self, ys, ye, yhi, ylo)
		const r = y * (math.log(1 + x) / math.log(2))
		const ns, ne, nhi, nlo = fromDouble(r)
		setStPacked(self, 1, ns, ne, nhi, nlo)
	end
	pop(self)
end

local function trigDomainCheck(self: Fpu): boolean
	const s, e, hi, lo = getStPacked(self, 0)
	const kind = classify(s, e, hi, lo)
	if kind >= 2 then
		invalid(self)
		setStPacked(self, 0, 1, NAN_EXP, NAN_TOP_HI, 0)
		return false
	end
	if kind == 0 and e - 16383 >= 63 then
		-- argument too large for exact reduction
		setCondition(self, false, false, true, false)
		return false
	end
	return true
end

local function fsin(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	if not trigDomainCheck(self) then
		return
	end
	const s, e, hi, lo = getStPacked(self, 0)
	const value = toDoubleNearest(self, s, e, hi, lo)
	if value == 0 then
		return
	end
	const ns, ne, nhi, nlo = fromDouble(math.sin(value))
	setStPacked(self, 0, ns, ne, nhi, nlo)
end

local function fcos(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	if not trigDomainCheck(self) then
		return
	end
	const s, e, hi, lo = getStPacked(self, 0)
	const value = toDoubleNearest(self, s, e, hi, lo)
	if value == 0 then
		setStPacked(self, 0, 0, 0x3FFF, 0x80000000, 0)
		return
	end
	const ns, ne, nhi, nlo = fromDouble(math.cos(value))
	setStPacked(self, 0, ns, ne, nhi, nlo)
end

local function fsincos(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	if not canPush(self) then
		stackFault(self)
		return
	end
	if not trigDomainCheck(self) then
		return
	end
	const s, e, hi, lo = getStPacked(self, 0)
	const value = toDoubleNearest(self, s, e, hi, lo)
	if value == 0 then
		setStPacked(self, 0, 0, 0x3FFF, 0x80000000, 0)
		push(self, s, 0, 0, 0)
		return
	end
	const ns, ne, nhi, nlo = fromDouble(math.sin(value))
	const cs, ce, chi, clo = fromDouble(math.cos(value))
	setStPacked(self, 0, cs, ce, chi, clo)
	push(self, ns, ne, nhi, nlo)
end

local function fptan(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	if not canPush(self) then
		stackFault(self)
		return
	end
	if not trigDomainCheck(self) then
		return
	end
	const s, e, hi, lo = getStPacked(self, 0)
	const value = toDoubleNearest(self, s, e, hi, lo)
	if value == 0 then
		push(self, 0, 0x3FFF, 0x80000000, 0)
		return
	end
	const ns, ne, nhi, nlo = fromDouble(math.tan(value))
	setStPacked(self, 0, ns, ne, nhi, nlo)
	push(self, 0, 0x3FFF, 0x80000000, 0)
end

local function fpatan(self: Fpu)
	if not ensureStack(self, 2) then
		return
	end
	const xs, xe, xhi, xlo = getStPacked(self, 0)
	const ys, ye, yhi, ylo = getStPacked(self, 1)
	const xkind = classify(xs, xe, xhi, xlo)
	const ykind = classify(ys, ye, yhi, ylo)
	if xkind >= 3 or ykind >= 3 then
		invalid(self)
		setStPacked(self, 1, 1, NAN_EXP, NAN_TOP_HI, 0)
	else
		const x = toDoubleNearest(self, xs, xe, xhi, xlo)
		const y = toDoubleNearest(self, ys, ye, yhi, ylo)
		const ns, ne, nhi, nlo = fromDouble(math.atan2(y, x))
		setStPacked(self, 1, ns, ne, nhi, nlo)
	end
	pop(self)
end

local function fxtract(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	if not canPush(self) then
		stackFault(self)
		return
	end
	const s, e, hi, lo = getStPacked(self, 0)
	const ss, se, sh, sl, es, ee, eh, el = xtractEngine(self, s, e, hi, lo)
	setStPacked(self, 0, ss, se, sh, sl)
	push(self, es, ee, eh, el)
end

local function fscale(self: Fpu)
	if not ensureStack(self, 2) then
		return
	end
	const a0, a1, a2, a3 = getStPacked(self, 0)
	const b0, b1, b2, b3 = getStPacked(self, 1)
	const r1, r2v, r3v, r4v = scaleEngine(self, b0, b1, b2, b3, a0, a1, a2, a3)
	setStPacked(self, 0, r1, r2v, r3v, r4v)
end

local function frndint(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	const s, e, hi, lo = getStPacked(self, 0)
	const r1, r2v, r3v, r4v = roundIntEngine(self, s, e, hi, lo)
	setStPacked(self, 0, r1, r2v, r3v, r4v)
end

local function fprem(self: Fpu, nearest: boolean)
	if not ensureStack(self, 2) then
		return
	end
	const a0, a1, a2, a3 = getStPacked(self, 0)
	const b0, b1, b2, b3 = getStPacked(self, 1)
	const r1, r2v, r3v, r4v = premEngine(self, nearest, a0, a1, a2, a3, b0, b1, b2, b3)
	setStPacked(self, 0, r1, r2v, r3v, r4v)
end

local function fsqrt(self: Fpu)
	if not ensureStack(self, 1) then
		return
	end
	const s, e, hi, lo = getStPacked(self, 0)
	const r1, r2v, r3v, r4v = sqrtEngine(self, s, e, hi, lo)
	setStPacked(self, 0, r1, r2v, r3v, r4v)
end

local function fcmov(self: Fpu, index: number, condition: boolean)
	if not ensureStack(self, 1) or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	if condition then
		const s, e, hi, lo = getStPacked(self, index)
		setStPacked(self, 0, s, e, hi, lo)
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
		self.rSign[index] = 0
		self.rExp[index] = 0
		self.rHi[index] = 0
		self.rLo[index] = 0
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
	-- FSTENV/FNSTENV/FNSAVE mask all exceptions after writing the image
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

local function fnsave(self: Fpu, cpu: any, e: any)
	const size = writeEnvironment(self, cpu, e)
	const address = memoryAddress(cpu, e, size) + size
	for index = 0, 7 do
		if self.tags[(self.top + index) % 8] == TAG_EMPTY then
			cpu:write32(address + index * 10, 0)
			cpu:write32(address + index * 10 + 4, 0)
			cpu:write16(address + index * 10 + 8, 0)
		else
			const s, exp, hi, lo = getStPacked(self, index)
			writeM80At(cpu, address + index * 10, s, exp, hi, lo)
		end
	end
	fninit(self)
end

local function frstor(self: Fpu, cpu: any, e: any)
	const size = readEnvironment(self, cpu, e)
	const address = memoryAddress(cpu, e, size) + size
	for index = 0, 7 do
		const physical = (self.top + index) % 8
		const s, exp, hi, lo = readM80At(cpu, address + index * 10)
		self.rSign[physical] = s
		self.rExp[physical] = exp
		self.rHi[physical] = hi
		self.rLo[physical] = lo
	end
end

local function storeInteger(self: Fpu, cpu: any, e: any, size: number, popAfter: boolean)
	if not ensureStack(self, 1) then
		return
	end
	const s, exp, hi, lo = getStPacked(self, 0)
	const kind = classify(s, exp, hi, lo)
	local uhi, ulo, ovf
	if kind >= 2 then
		invalid(self)
		uhi, ulo, ovf = 0x80000000, 0, true
	else
		uhi, ulo, ovf = toInt64(self, s, exp, hi, lo, size - 1)
	end
	const address = memoryAddress(cpu, e, math.floor(size / 8))
	if ovf then
		invalid(self)
		uhi, ulo = 0x80000000, 0
		if size == 16 then
			cpu:write16(address, 0x8000)
		elseif size == 32 then
			cpu:write32(address, 0x80000000)
		else
			cpu:write32(address, 0)
			cpu:write32(address + 4, 0x80000000)
		end
	else
		if s == 1 then
			-- two's complement of the magnitude
			if ulo == 0 then
				uhi = (TWO32 - uhi) % TWO32
			else
				uhi = (TWO32 - 1 - uhi) % TWO32
				ulo = TWO32 - ulo
			end
		end
		if size == 16 then
			cpu:write16(address, ulo % 0x10000)
		elseif size == 32 then
			cpu:write32(address, ulo)
		else
			cpu:write32(address, ulo)
			cpu:write32(address + 4, uhi)
		end
	end
	if popAfter then
		pop(self)
	end
end

local function writeBcd(self: Fpu, cpu: any, e: any)
	if not ensureStack(self, 1) then
		return
	end
	const s, exp, hi, lo = getStPacked(self, 0)
	const kind = classify(s, exp, hi, lo)
	local uhi, ulo, ovf
	if kind >= 2 then
		invalid(self)
		uhi, ulo, ovf = 0x80000000, 0, true
	else
		uhi, ulo, ovf = toInt64(self, s, exp, hi, lo, 63)
	end
	const address = memoryAddress(cpu, e, 10)
	-- 10^18 = 0xDE0B6B3A7640000
	if ovf or uhi > 0xDE0B6B3 or (uhi == 0xDE0B6B3 and ulo >= 0xA7640000) then
		invalid(self)
		for index = 0, 9 do
			cpu:write8(address + index, 0xFF)
		end
	else
		for index = 0, 8 do
			-- two decimal digits per byte: divide by 10 twice in limb space
			local rem = uhi % 10
			uhi = math.floor(uhi / 10)
			local num = rem * TWO32 + ulo
			ulo = math.floor(num / 10) % TWO32
			uhi += math.floor(num / 10 / TWO32)
			const digit0 = num % 10
			rem = uhi % 10
			uhi = math.floor(uhi / 10)
			num = rem * TWO32 + ulo
			ulo = math.floor(num / 10) % TWO32
			uhi += math.floor(num / 10 / TWO32)
			const digit1 = num % 10
			cpu:write8(address + index, bor(digit0, lshift(digit1, 4)))
		end
		cpu:write8(address + 9, if s == 1 then 0x80 else 0x00)
	end
	pop(self)
end

local function setCompareFlags(cpu: any, relation: number)
	const mask = bor(0x0001, 0x0004, 0x0040) -- CF, PF and ZF
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

local function compareAndSetFlags(
	self: Fpu,
	cpu: any,
	index: number,
	quiet: boolean,
	popAfter: boolean
)
	if not ensureStack(self, 1) or stackTag(self, index) == TAG_EMPTY then
		stackFault(self)
		return
	end
	const sa, ea, ha, la = getStPacked(self, 0)
	const sb, eb, hb, lb = getStPacked(self, index)
	const relation = compareEngine(self, quiet, sa, ea, ha, la, sb, eb, hb, lb)
	setCompareFlags(cpu, relation)
	if popAfter then
		pop(self)
	end
end

---------------------------------------------------------------------
-- dispatch
---------------------------------------------------------------------

local function executeMemory(self: Fpu, cpu: any, opcode: number, e: any)
	const group = opcode - 0xD8
	const reg = e.reg
	if group == 0 then -- D8: m32 arithmetic
		if reg == 0 then
			const d1, d2, d3, d4 = fromDouble(readM32(cpu, e))
			binaryTopConstant(self, 0, d1, d2, d3, d4, false)
		elseif reg == 1 then
			const d1, d2, d3, d4 = fromDouble(readM32(cpu, e))
			binaryTopConstant(self, 2, d1, d2, d3, d4, false)
		elseif reg == 2 then
			const d1, d2, d3, d4 = fromDouble(readM32(cpu, e))
			doFcom(self, false, d1, d2, d3, d4, false)
		elseif reg == 3 then
			const d1, d2, d3, d4 = fromDouble(readM32(cpu, e))
			doFcom(self, false, d1, d2, d3, d4, true)
		elseif reg == 4 then
			const d1, d2, d3, d4 = fromDouble(readM32(cpu, e))
			binaryTopConstant(self, 1, d1, d2, d3, d4, true)
		elseif reg == 5 then
			const d1, d2, d3, d4 = fromDouble(readM32(cpu, e))
			binaryTopConstant(self, 1, d1, d2, d3, d4, false)
		elseif reg == 6 then
			const d1, d2, d3, d4 = fromDouble(readM32(cpu, e))
			binaryTopConstant(self, 3, d1, d2, d3, d4, true)
		else
			const d1, d2, d3, d4 = fromDouble(readM32(cpu, e))
			binaryTopConstant(self, 3, d1, d2, d3, d4, false)
		end
	elseif group == 1 then -- D9: m32 load/store, environment, control word
		if reg == 0 then
			const d1, d2, d3, d4 = fromDouble(readM32(cpu, e))
			doFld(self, d1, d2, d3, d4)
		elseif reg == 2 then
			doFstNarrow(self, cpu, e, true, false)
		elseif reg == 3 then
			doFstNarrow(self, cpu, e, true, true)
		elseif reg == 4 then
			readEnvironment(self, cpu, e)
		elseif reg == 5 then
			self.control = cpu:read16(memoryAddress(cpu, e, 2))
			refreshPending(self)
		elseif reg == 6 then
			writeEnvironment(self, cpu, e)
		elseif reg == 7 then
			cpu:write16(memoryAddress(cpu, e, 2), self.control)
		else
			invalid(self)
		end
	elseif group == 2 then -- DA: m32 integer arithmetic
		const address = memoryAddress(cpu, e, 4)
		const raw = cpu:read32(address)
		const value = if raw >= 0x80000000 then raw - TWO32 else raw
		local d1, d2, d3, d4 = fromInt(value)
		if reg == 0 then
			binaryTopConstant(self, 0, d1, d2, d3, d4, false)
		elseif reg == 1 then
			binaryTopConstant(self, 2, d1, d2, d3, d4, false)
		elseif reg == 2 then
			doFcom(self, false, d1, d2, d3, d4, false)
		elseif reg == 3 then
			doFcom(self, false, d1, d2, d3, d4, true)
		elseif reg == 4 then
			binaryTopConstant(self, 1, d1, d2, d3, d4, true)
		elseif reg == 5 then
			binaryTopConstant(self, 1, d1, d2, d3, d4, false)
		elseif reg == 6 then
			binaryTopConstant(self, 3, d1, d2, d3, d4, true)
		else
			binaryTopConstant(self, 3, d1, d2, d3, d4, false)
		end
	elseif group == 3 then -- DB: m32 integer, m80 load/store
		if reg == 0 then
			const address = memoryAddress(cpu, e, 4)
			const raw = cpu:read32(address)
			const value = if raw >= 0x80000000 then raw - TWO32 else raw
			const d1, d2, d3, d4 = fromInt(value)
			doFld(self, d1, d2, d3, d4)
		elseif reg == 2 then
			storeInteger(self, cpu, e, 32, false)
		elseif reg == 3 then
			storeInteger(self, cpu, e, 32, true)
		elseif reg == 5 then
			const d1, d2, d3, d4 = readM80(cpu, e)
			push(self, d1, d2, d3, d4)
		elseif reg == 7 then
			if ensureStack(self, 1) then
				const s, exp, hi, lo = getStPacked(self, 0)
				writeM80(cpu, e, s, exp, hi, lo)
				pop(self)
			end
		else
			invalid(self)
		end
	elseif group == 4 then -- DC: m64 arithmetic
		const d1, d2, d3, d4 = fromDouble(readM64(cpu, e))
		if reg == 0 then
			binaryTopConstant(self, 0, d1, d2, d3, d4, false)
		elseif reg == 1 then
			binaryTopConstant(self, 2, d1, d2, d3, d4, false)
		elseif reg == 2 then
			doFcom(self, false, d1, d2, d3, d4, false)
		elseif reg == 3 then
			doFcom(self, false, d1, d2, d3, d4, true)
		elseif reg == 4 then
			binaryTopConstant(self, 1, d1, d2, d3, d4, true)
		elseif reg == 5 then
			binaryTopConstant(self, 1, d1, d2, d3, d4, false)
		elseif reg == 6 then
			binaryTopConstant(self, 3, d1, d2, d3, d4, true)
		else
			binaryTopConstant(self, 3, d1, d2, d3, d4, false)
		end
	elseif group == 5 then -- DD: m64 load/store, state, status word
		if reg == 0 then
			const d1, d2, d3, d4 = fromDouble(readM64(cpu, e))
			doFld(self, d1, d2, d3, d4)
		elseif reg == 2 then
			doFstNarrow(self, cpu, e, false, false)
		elseif reg == 3 then
			doFstNarrow(self, cpu, e, false, true)
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
		const raw = cpu:read16(memoryAddress(cpu, e, 2))
		const value = if raw >= 0x8000 then raw - 0x10000 else raw
		const d1, d2, d3, d4 = fromInt(value)
		if reg == 0 then
			binaryTopConstant(self, 0, d1, d2, d3, d4, false)
		elseif reg == 1 then
			binaryTopConstant(self, 2, d1, d2, d3, d4, false)
		elseif reg == 2 then
			doFcom(self, false, d1, d2, d3, d4, false)
		elseif reg == 3 then
			doFcom(self, false, d1, d2, d3, d4, true)
		elseif reg == 4 then
			binaryTopConstant(self, 1, d1, d2, d3, d4, true)
		elseif reg == 5 then
			binaryTopConstant(self, 1, d1, d2, d3, d4, false)
		elseif reg == 6 then
			binaryTopConstant(self, 3, d1, d2, d3, d4, true)
		else
			binaryTopConstant(self, 3, d1, d2, d3, d4, false)
		end
	else -- DF: m16/m64 integer, BCD load/store
		if reg == 0 then
			const raw = cpu:read16(memoryAddress(cpu, e, 2))
			const value = if raw >= 0x8000 then raw - 0x10000 else raw
			const d1, d2, d3, d4 = fromInt(value)
			doFld(self, d1, d2, d3, d4)
		elseif reg == 2 then
			storeInteger(self, cpu, e, 16, false)
		elseif reg == 3 then
			storeInteger(self, cpu, e, 16, true)
		elseif reg == 4 then
			const bh, bl = readBcd(cpu, e)
			local neg = bh >= 0x80000000
			local d1, d2, d3, d4 = fromInt64(bh % 0x80000000, bl, neg)
			doFld(self, d1, d2, d3, d4)
		elseif reg == 5 then
			const address = memoryAddress(cpu, e, 8)
			const lo = cpu:read32(address)
			const hi = cpu:read32(address + 4)
			const d1, d2, d3, d4 = fromInt64(hi, lo, hi >= 0x80000000)
			doFld(self, d1, d2, d3, d4)
		elseif reg == 6 then
			writeBcd(self, cpu, e)
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
			topArithmetic(self, index, 0, false, 0, false)
		elseif reg == 1 then
			topArithmetic(self, index, 2, false, 0, false)
		elseif reg == 2 then
			fcomRegister(self, index, false, false)
		elseif reg == 3 then
			fcomRegister(self, index, true, false)
		elseif reg == 4 then
			topArithmetic(self, index, 1, false, 0, false)
		elseif reg == 5 then
			topArithmetic(self, index, 1, true, 0, false)
		elseif reg == 6 then
			topArithmetic(self, index, 3, false, 0, false)
		else
			topArithmetic(self, index, 3, true, 0, false)
		end
	elseif group == 1 then -- D9: register and transcendental opcodes
		if reg == 0 then
			if stackTag(self, index) == TAG_EMPTY then
				stackFault(self)
				return
			end
			const s, exp, hi, lo = getStPacked(self, index)
			push(self, s, exp, hi, lo)
		elseif reg == 1 then
			fxch(self, index)
		elseif reg == 2 then
			if index ~= 0 then
				invalid(self)
			end
		elseif reg == 4 then
			if index == 0 then
				if ensureStack(self, 1) then
					const s = self.rSign[self.top]
					setStPacked(
						self,
						0,
						bxor(s, 1),
						self.rExp[self.top],
						self.rHi[self.top],
						self.rLo[self.top]
					)
				end
			elseif index == 1 then
				if ensureStack(self, 1) then
					setStPacked(
						self,
						0,
						0,
						self.rExp[self.top],
						self.rHi[self.top],
						self.rLo[self.top]
					)
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
				push(self, 0, 0x3FFF, 0x80000000, 0)
			elseif index == 1 then
				push(self, 0, 0x4000, 0xD49A784B, 0xCD1B8AFE)
			elseif index == 2 then
				push(self, 0, 0x3FFF, 0xB8AA3B29, 0x5C17F0BC)
			elseif index == 3 then
				push(self, 0, 0x4000, 0xC90FDAA2, 0x2168C235)
			elseif index == 4 then
				push(self, 0, 0x3FFD, 0x9A209A84, 0xFBCFF799)
			elseif index == 5 then
				push(self, 0, 0x3FFE, 0xB17217F7, 0xD1CF79AC)
			elseif index == 6 then
				push(self, 0, 0, 0, 0)
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
				fsqrt(self)
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
				const sa, ea, ha, la = getStPacked(self, 0)
				const sb, eb, hb, lb = getStPacked(self, 1)
				compareEngine(self, true, sa, ea, ha, la, sb, eb, hb, lb)
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
			compareAndSetFlags(self, cpu, index, true, false)
		elseif reg == 6 then
			compareAndSetFlags(self, cpu, index, false, false)
		else
			invalid(self)
		end
	elseif group == 4 then -- DC: ST(i),ST0 arithmetic
		if reg == 0 then
			topArithmetic(self, index, 0, true, index, false)
		elseif reg == 1 then
			topArithmetic(self, index, 2, true, index, false)
		elseif reg == 2 then
			fcomRegister(self, index, false, false)
		elseif reg == 3 then
			fcomRegister(self, index, true, false)
		elseif reg == 4 then
			topArithmetic(self, index, 1, true, index, false)
		elseif reg == 5 then
			topArithmetic(self, index, 1, false, index, false)
		elseif reg == 6 then
			topArithmetic(self, index, 3, false, index, false)
		else
			topArithmetic(self, index, 3, true, index, false)
		end
	elseif group == 5 then -- DD: stack/register move and unordered compare
		if reg == 0 then
			const physical = (self.top + index) % 8
			self.tags[physical] = TAG_EMPTY
		elseif reg == 1 then
			fxch(self, index)
		elseif reg == 2 then
			if not ensureStack(self, 1) then
				return
			end
			const s, exp, hi, lo = getStPacked(self, 0)
			setStPacked(self, index, s, exp, hi, lo)
		elseif reg == 3 then
			if not ensureStack(self, 1) then
				return
			end
			const s, exp, hi, lo = getStPacked(self, 0)
			setStPacked(self, index, s, exp, hi, lo)
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
			topArithmetic(self, index, 0, true, index, true)
		elseif reg == 1 then
			topArithmetic(self, index, 2, true, index, true)
		elseif reg == 2 then
			fcomRegister(self, index, true, false)
		elseif reg == 3 then
			if index == 1 then
				if ensureStack(self, 2) then
					const sa, ea, ha, la = getStPacked(self, 0)
					const sb, eb, hb, lb = getStPacked(self, 1)
					compareEngine(self, false, sa, ea, ha, la, sb, eb, hb, lb)
					pop(self)
					pop(self)
				end
			else
				invalid(self)
			end
		elseif reg == 4 then
			topArithmetic(self, index, 1, true, index, true)
		elseif reg == 5 then
			topArithmetic(self, index, 1, false, index, true)
		elseif reg == 6 then
			topArithmetic(self, index, 3, false, index, true)
		else
			topArithmetic(self, index, 3, true, index, true)
		end
	else -- DF: FNSTSW AX / FCOMI(P) / FUCOMI(P)
		if reg == 4 and index == 0 then
			cpu:wr(0, band(self.status, 0xFFFF))
		elseif reg == 5 then
			compareAndSetFlags(self, cpu, index, true, true)
		elseif reg == 6 then
			compareAndSetFlags(self, cpu, index, false, true)
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
	const s, e, hi, lo = getStPacked(self, index)
	return toDoubleNearest(self, s, e, hi, lo)
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
	self.rSign = {}
	self.rExp = {}
	self.rHi = {}
	self.rLo = {}
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
		self.rSign[index] = 0
		self.rExp[index] = 0
		self.rHi[index] = 0
		self.rLo[index] = 0
		self.tags[index] = TAG_EMPTY
	end
	syncTop(self)
	return self
end

return Fpu
