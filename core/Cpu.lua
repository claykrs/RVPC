--!strict
-- Cpu.lua -- complete 8086 real-mode core (bit32 only, no native bitwise ops).
-- r[1..8] = AX CX DX BX SP BP SI DI; SP is r[5]; 8-bit reg i<4 low / i>=4 high.

const band, bor, bxor, bnot, lshift, rshift =
	bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.lshift, bit32.rshift

const CF, PF, AF, ZF, SF, TF, IFF, DFF, OFLG = 1, 4, 16, 64, 128, 256, 512, 1024, 2048
const ALWAYS = 2
const FLAGMASK = 4053 -- CF|PF|AF|ZF|SF|TF|IF|DF|OF (0xFD5)
const FLAGMASK_386 = bor(FLAGMASK, 0x7000) -- 386: IOPL/NT writable in real mode
const FIXEDFLAGS = bor(0xF000, ALWAYS) -- bits 15-12 plus bit 1 read as 1 on 8086
const FIXEDFLAGS_286 = ALWAYS -- 286 real mode: bits 12-15 read as 0

const CPU_8086 = 0
const CPU_286 = 1
const CPU_386 = 2

local function cpuLevelValue(value: any): number
	if type(value) == "number" then
		if value >= 386 then
			return CPU_386
		elseif value >= 286 then
			return CPU_286
		end
		return CPU_8086
	end
	if value == "386" then
		return CPU_386
	elseif value == "286" then
		return CPU_286
	end
	return CPU_8086
end

export type ModRM = {
	mod: number,
	reg: number,
	rm: number,
	off: number?,
	addr: number?,
	seg: string?,
}

export type Descriptor = {
	base: number,
	limit: number,
	access: number,
	flags: number,
	raw0: number,
	raw2: number,
	raw4: number,
	raw6: number,
}

export type Io = {
	in8: (port: number) -> number,
	out8: (port: number, value: number) -> (),
}

export type InterruptHandler = (n: number) -> ()

export type Cpu = {
	mem: any,
	io: Io,
	config: any,
	level: number,
	fixedFlags: number,
	flagMask: number,
	r: { number },
	rHi: { number },
	es: number,
	cs: number,
	ss: number,
	ds: number,
	fs: number,
	gs: number,
	-- Cached descriptor state per segment register (real mode: base = sel*16,
	-- limit = FFFF; protected mode: GDT/LDT descriptor fields).
	segBase: { [string]: number },
	segLimit: { [string]: number },
	segAccess: { [string]: number },
	segFlags: { [string]: number },
	segSel: { [string]: number },
	ip: number,
	flags: number,
	cr0: number,
	cr: { number },
	dr: { number },
	gdtr: { base: number, limit: number },
	idtr: { base: number, limit: number },
	ldtr: number,
	ldtrBase: number,
	ldtrLimit: number,
	tr: number,
	trBase: number,
	trLimit: number,
	operand32: boolean,
	address32: boolean,
	halted: boolean,
	-- 8086 STI/POPF/IRET interrupt shadow: no hardware IRQ is recognized until
	-- the instruction after the flag change has executed.
	irqDelay: number,
	oseg: number?,
	osegReg: string?,
	rep: number?,
	defaultInts: { [number]: InterruptHandler },
	stubSeg: number?,
	intStubs: { [number]: { seg: number, off: number } },
	tripleFaults: number,
	onTripleFault: ((self: Cpu) -> ())?,
	registerStub: (self: Cpu, n: number, seg: number, off: number) -> (),
	rb: (self: Cpu, i: number) -> number,
	wb: (self: Cpu, i: number, v: number) -> (),
	rr: (self: Cpu, i: number) -> number,
	wr: (self: Cpu, i: number, v: number) -> (),
	rr32: (self: Cpu, i: number) -> number,
	wr32: (self: Cpu, i: number, v: number) -> (),
	ensureSeg: (self: Cpu, reg: string) -> (),
	setPE: (self: Cpu, on: boolean) -> (),
	reset: (self: Cpu) -> (),
	tripleFault: (self: Cpu) -> (),
	loadSeg: (self: Cpu, reg: string, selector: number) -> (),
	farCall: (self: Cpu, selector: number, offset: number, isCall: boolean) -> (),
	baseOf: (self: Cpu, reg: string) -> number,
	linear: (self: Cpu, reg: string, off: number, size: number) -> number,
	fetch8: (self: Cpu) -> number,
	fetch16: (self: Cpu) -> number,
	push16: (self: Cpu, v: number) -> (),
	pop16: (self: Cpu) -> number,
	push32: (self: Cpu, v: number) -> (),
	pop32: (self: Cpu) -> number,
	setbits: (self: Cpu, mask: number, on: boolean) -> (),
	getF: (self: Cpu, mask: number) -> boolean,
	setSZP: (self: Cpu, res: number, w: boolean) -> (),
	modrm: (self: Cpu) -> ModRM,
	readRM8: (self: Cpu, e: ModRM) -> number,
	writeRM8: (self: Cpu, e: ModRM, v: number) -> (),
	readRM16: (self: Cpu, e: ModRM) -> number,
	writeRM16: (self: Cpu, e: ModRM, v: number) -> (),
	interrupt: (self: Cpu, n: number, errorCode: number?, software: boolean?) -> (),
	pmInterrupt: (self: Cpu, n: number, errorCode: number?, software: boolean?) -> (),
	step: (self: Cpu) -> number,
	dump: (self: Cpu) -> { [string]: number },
}

const PARITY: { [number]: number } = {}
for i = 0, 255 do
	local v, bits = i, 0
	while v > 0 do
		bits += band(v, 1)
		v = rshift(v, 1)
	end
	PARITY[i] = (bits % 2 == 0) and PF or 0
end

local function sign8(v: number): number
	if v >= 0x80 then
		return v - 0x100
	end
	return v
end

local function sign16(v: number): number
	if v >= 0x8000 then
		return v - 0x10000
	end
	return v
end

local function sign32(v: number): number
	if v >= 0x80000000 then
		return v - 0x100000000
	end
	return v
end

-- integer division truncated toward zero (IDIV semantics)
local function truncDiv(n: number, d: number): number
	return (math.modf(n / d))
end

local Cpu = {}
Cpu.__index = Cpu

function Cpu.new(mem: any, io: Io?, config: any?): Cpu
	local self = setmetatable({}, Cpu) :: any
	self.mem = mem
	self.io = io or {
		in8 = function()
			return 0
		end,
		out8 = function() end,
	}
	self.config = config or {}
	self.level = cpuLevelValue(self.config.cpuLevel)
	self.fixedFlags = if self.level >= CPU_286 then FIXEDFLAGS_286 else FIXEDFLAGS
	self.flagMask = if self.level >= CPU_386 then FLAGMASK_386 else FLAGMASK
	self.r = { 0, 0, 0, 0, 0, 0, 0, 0 }
	self.rHi = { 0, 0, 0, 0, 0, 0, 0, 0 }
	self.es, self.cs, self.ss, self.ds = 0, 0, 0, 0
	self.fs, self.gs = 0, 0
	self.segBase = { es = 0, cs = 0, ss = 0, ds = 0, fs = 0, gs = 0 }
	self.segLimit = { es = 0xFFFF, cs = 0xFFFF, ss = 0xFFFF, ds = 0xFFFF, fs = 0xFFFF, gs = 0xFFFF }
	self.segAccess = { es = 0x93, cs = 0x9B, ss = 0x93, ds = 0x93, fs = 0x93, gs = 0x93 }
	self.segFlags = { es = 0, cs = 0, ss = 0, ds = 0, fs = 0, gs = 0 }
	self.segSel = { es = 0, cs = 0, ss = 0, ds = 0, fs = 0, gs = 0 }
	self.ip = 0
	self.flags = bor(self.fixedFlags, IFF)
	self.cr0 = 0
	self.cr = { 0, 0, 0, 0 }
	self.dr = { 0, 0, 0, 0 }
	self.gdtr = { base = 0, limit = 0 }
	self.idtr = { base = 0, limit = 0 }
	self.ldtr = 0
	self.ldtrBase = 0
	self.ldtrLimit = 0
	self.tr = 0
	self.trBase = 0
	self.trLimit = 0
	self.operand32 = false
	self.address32 = false
	self.halted = false
	self.irqDelay = 0
	self.oseg = nil
	self.osegReg = nil
	self.rep = nil
	self.defaultInts = {}
	self.stubSeg = nil
	self.intStubs = {}
	self.tripleFaults = 0
	self.onTripleFault = nil
	return self
end

-- Record that interrupt `n`'s IVT entry currently points at the machine's
-- own stub at `seg:off`. Cpu.interrupt uses this to recognise an un-hooked
-- vector and dispatch the emulated handler directly (see below).
function Cpu.registerStub(self: Cpu, n: number, seg: number, off: number)
	self.stubSeg = seg
	self.intStubs[n] = { seg = seg, off = off }
end

-- CR0.PE transitions. Entering PM leaves the existing real-mode caches in
-- place until the guest reloads each selector; leaving PM likewise keeps the
-- current CS/SS caches for the instruction stream, while every subsequent
-- loadSeg uses selector<<4 and the next far transfer reloads CS.
function Cpu.setPE(self: Cpu, on: boolean)
	if on then
		self.cr0 = bor(self.cr0, 1)
	else
		self.cr0 = band(self.cr0, bnot(1))
	end
end

local function getSeg(cpu: any, reg: string): number
	if reg == "es" then
		return cpu.es
	elseif reg == "cs" then
		return cpu.cs
	elseif reg == "ss" then
		return cpu.ss
	elseif reg == "ds" then
		return cpu.ds
	elseif reg == "fs" then
		return cpu.fs
	elseif reg == "gs" then
		return cpu.gs
	end
	error("bad segment register " .. reg)
end

local function setSeg(cpu: any, reg: string, selector: number)
	selector = band(selector, 0xFFFF)
	if reg == "es" then
		cpu.es = selector
	elseif reg == "cs" then
		cpu.cs = selector
	elseif reg == "ss" then
		cpu.ss = selector
	elseif reg == "ds" then
		cpu.ds = selector
	elseif reg == "fs" then
		cpu.fs = selector
	elseif reg == "gs" then
		cpu.gs = selector
	else
		error("bad segment register " .. reg)
	end
end

local function cacheReal(self: any, reg: string, selector: number)
	self.segBase[reg] = lshift(selector, 4)
	self.segLimit[reg] = 0xFFFF
	self.segAccess[reg] = if reg == "cs" then 0x9B else 0x93
	self.segFlags[reg] = 0
	self.segSel[reg] = selector
end

function Cpu.reset(self: Cpu)
	self.cr0 = 0
	self.cr = { 0, 0, 0, 0 }
	self.dr = { 0, 0, 0, 0 }
	self.gdtr = { base = 0, limit = 0 }
	self.idtr = { base = 0, limit = 0 }
	self.ldtr = 0
	self.ldtrBase = 0
	self.ldtrLimit = 0
	self.tr = 0
	self.trBase = 0
	self.trLimit = 0
	self.es, self.cs, self.ss, self.ds = 0, 0xF000, 0, 0
	self.fs, self.gs = 0, 0
	cacheReal(self, "es", 0)
	cacheReal(self, "cs", 0xF000)
	cacheReal(self, "ss", 0)
	cacheReal(self, "ds", 0)
	cacheReal(self, "fs", 0)
	cacheReal(self, "gs", 0)
	self.ip = 0xFFF0
	self.flags = self.fixedFlags
	self.operand32 = false
	self.address32 = false
	self.halted = false
	self.irqDelay = 0
	self.oseg = nil
	self.osegReg = nil
	self.rep = nil
end

function Cpu.tripleFault(self: Cpu)
	self.tripleFaults += 1
	if self.onTripleFault then
		self.onTripleFault(self)
	else
		self:reset()
	end
end

local function readDescriptor(cpu: any, selector: number): Descriptor?
	if band(selector, 0xFFFC) == 0 then
		return nil
	end
	const index = rshift(band(selector, 0xFFF8), 3)
	local base, limit = cpu.gdtr.base, cpu.gdtr.limit
	if band(selector, 4) ~= 0 then
		base, limit = cpu.ldtrBase, cpu.ldtrLimit
	end
	if index * 8 + 7 > limit then
		return nil
	end
	const addr = base + index * 8
	const limitLow = cpu.mem:read16(addr)
	const baseLow = cpu.mem:read16(addr + 2)
	const baseMid = cpu.mem:read8(addr + 4)
	const access = cpu.mem:read8(addr + 5)
	const flags = cpu.mem:read8(addr + 6)
	const baseHigh = cpu.mem:read8(addr + 7)
	local descLimit = bor(limitLow, lshift(band(flags, 0x0F), 16))
	if band(flags, 0x80) ~= 0 then
		descLimit = bor(lshift(descLimit, 12), 0xFFF)
	end
	return {
		base = bor(baseLow, lshift(baseMid, 16), lshift(baseHigh, 24)),
		limit = descLimit,
		access = access,
		flags = flags,
		raw0 = limitLow,
		raw2 = baseLow,
		raw4 = cpu.mem:read8(addr + 4),
		raw6 = cpu.mem:read8(addr + 6),
	}
end

-- Refresh a cache if host/test code assigned the segment register directly.
-- Real mode is always a plain paragraph; PM validates through the GDT/LDT.
function Cpu.ensureSeg(self: Cpu, reg: string)
	const selector = getSeg(self, reg)
	if self.segSel[reg] == selector then
		return
	end
	if band(self.cr0, 1) == 0 then
		cacheReal(self, reg, selector)
		return
	end
	self:loadSeg(reg, selector)
end

function Cpu.loadSeg(self: Cpu, reg: string, selector: number)
	selector = band(selector, 0xFFFF)
	if band(self.cr0, 1) == 0 then
		setSeg(self, reg, selector)
		cacheReal(self, reg, selector)
		return
	end
	if selector == 0 then
		-- Null data selectors are legal and leave the segment unusable.
		if reg == "cs" or reg == "ss" then
			error(("#GP: cannot load null selector into %s"):format(reg))
		end
		setSeg(self, reg, 0)
		self.segBase[reg] = 0
		self.segLimit[reg] = 0
		self.segAccess[reg] = 0
		self.segFlags[reg] = 0
		self.segSel[reg] = 0
		return
	end
	const desc = readDescriptor(self, selector)
	if not desc or band(desc.access, 0x80) == 0 then
		error(
			("#GP: %s selector %04X: absent or outside %s limit"):format(
				reg,
				selector,
				if band(selector, 4) ~= 0 then "LDT" else "GDT"
			)
		)
	end
	if reg == "cs" and band(desc.access, 0x18) ~= 0x18 then
		error(
			("#GP: CS selector %04X is not a code segment (access %02X)"):format(
				selector,
				desc.access
			)
		)
	elseif reg == "ss" and (band(desc.access, 0x18) ~= 0x10 or band(desc.access, 2) == 0) then
		error(
			("#GP: SS selector %04X is not a writable data segment (access %02X)"):format(
				selector,
				desc.access
			)
		)
	end
	setSeg(self, reg, selector)
	self.segBase[reg] = desc.base
	self.segLimit[reg] = desc.limit
	self.segAccess[reg] = desc.access
	self.segFlags[reg] = desc.flags
	self.segSel[reg] = selector
end

function Cpu.baseOf(self: Cpu, reg: string): number
	self:ensureSeg(reg)
	return self.segBase[reg]
end

local function descriptorIsCode(desc: Descriptor): boolean
	return band(desc.access, 0x18) == 0x18
end

local function descriptorIsWritableData(desc: Descriptor): boolean
	return band(desc.access, 0x18) == 0x10 and band(desc.access, 2) ~= 0
end

-- Far CALL/JMP, including 286/386 call gates. Ring changes use the TSS
-- SS0:SP0 stack, copy gate parameters, and build the nested frame that the
-- outer IRET path unwinds.
function Cpu.farCall(self: Cpu, selector: number, offset: number, isCall: boolean)
	selector = band(selector, 0xFFFF)
	offset = band(offset, 0xFFFF)
	if band(self.cr0, 1) == 0 then
		if isCall then
			self:push16(self.cs)
			self:push16(self.ip)
		end
		self:loadSeg("cs", selector)
		self.ip = offset
		return
	end
	if selector == 0 then
		error("#GP: far transfer with null selector")
	end
	const desc = readDescriptor(self, selector)
	if not desc or band(desc.access, 0x80) == 0 then
		error(("#GP: far transfer selector %04X absent or outside GDT/LDT limit"):format(selector))
	end
	const gateType = band(desc.access, 0x1F)
	if gateType ~= 0x04 and gateType ~= 0x0C then
		if not descriptorIsCode(desc) then
			error(
				("#GP: far transfer selector %04X is not code or a call gate (access %02X)"):format(
					selector,
					desc.access
				)
			)
		end
		if isCall then
			self:push16(self.cs)
			self:push16(self.ip)
		end
		self:loadSeg("cs", selector)
		self.ip = offset
		return
	end
	-- Call gate: offset/selector/parameter count are packed in the descriptor.
	const gateDpl = band(rshift(desc.access, 5), 3)
	const cpl = band(self.cs, 3)
	const rpl = band(selector, 3)
	if gateDpl < math.max(cpl, rpl) then
		error(("#GP: call gate %04X DPL%d below CPL%d/RPL%d"):format(selector, gateDpl, cpl, rpl))
	end
	const targetSelector = band(desc.raw2, 0xFFFF)
	const targetOffset = band(bor(desc.raw0, lshift(desc.raw6, 16)), 0xFFFF)
	const paramCount = band(desc.raw4, 0x1F)
	const targetDesc = readDescriptor(self, targetSelector)
	if not targetDesc or band(targetDesc.access, 0x80) == 0 then
		error(("#GP: call gate %04X target selector %04X absent"):format(selector, targetSelector))
	end
	if not descriptorIsCode(targetDesc) then
		error(
			("#GP: call gate %04X target %04X is not a code segment (access %02X)"):format(
				selector,
				targetSelector,
				targetDesc.access
			)
		)
	end
	const targetRing = band(rshift(targetDesc.access, 5), 3)
	if not isCall or targetRing >= cpl then
		-- Same/outer ring or JMP through a gate: no stack switch.
		if isCall then
			self:push16(self.cs)
			self:push16(self.ip)
		end
		self:loadSeg("cs", targetSelector)
		self.ip = targetOffset
		return
	end
	-- Inner-ring CALL: switch to the TSS ring stack and build the frame.
	if self.tr == 0 or self.trBase == 0 then
		error(("#GP: call gate %04X needs a loaded TSS for ring %d"):format(selector, targetRing))
	end
	if targetRing > 2 then
		error(("#GP: call gate %04X unsupported target ring %d"):format(selector, targetRing))
	end
	const spOff = 2 + targetRing * 4
	const ssOff = spOff + 2
	if self.trLimit < ssOff + 1 then
		error(
			("#TS: TSS selector %04X limit %04X too small for ring %d"):format(
				self.tr,
				self.trLimit,
				targetRing
			)
		)
	end
	const newSp0 = self.mem:read16(self.trBase + spOff)
	const newSs = self.mem:read16(self.trBase + ssOff)
	const ssDesc = readDescriptor(self, newSs)
	if not ssDesc or not descriptorIsWritableData(ssDesc) then
		error(("#TS: TSS stack selector %04X invalid for ring %d"):format(newSs, targetRing))
	end
	const oldSs = self.ss
	const oldSp = self.r[5]
	const oldBase = self:baseOf("ss")
	const newBase = ssDesc.base
	local newSp = band(newSp0 - paramCount * 2, 0xFFFF)
	for index = 0, paramCount - 1 do
		const value = self.mem:read16(oldBase + band(oldSp + index * 2, 0xFFFF))
		self.mem:write16(newBase + band(newSp + index * 2, 0xFFFF), value)
	end
	-- Nested frame (top to bottom): IP, CS, old SP, old SS, params.
	-- A 286/386 CALL through a call gate pushes the old SS:SP and the return
	-- CS:IP only; unlike an interrupt gate it does not push FLAGS.
	newSp = band(newSp - 2, 0xFFFF)
	self.mem:write16(newBase + newSp, oldSs)
	newSp = band(newSp - 2, 0xFFFF)
	self.mem:write16(newBase + newSp, oldSp)
	newSp = band(newSp - 2, 0xFFFF)
	self.mem:write16(newBase + newSp, self.cs)
	newSp = band(newSp - 2, 0xFFFF)
	self.mem:write16(newBase + newSp, self.ip)
	self:loadSeg("ss", newSs)
	self.r[5] = newSp
	self:loadSeg("cs", targetSelector)
	self.ip = targetOffset
end

-- Protected-mode interrupt/trap gate delivery. INT n and exceptions use the
-- IDT; hardware IRQs pass software=false and skip the DPL check.
function Cpu.pmInterrupt(self: Cpu, n: number, errorCode: number?, software: boolean?)
	const idt = self.idtr
	const gateOffset = n * 8
	if gateOffset + 7 > idt.limit then
		error(
			("#GP: INT %02X vector %d outside IDT limit %04X at %04X:%04X"):format(
				n,
				n,
				idt.limit,
				self.cs,
				self.ip
			)
		)
	end
	const addr = idt.base + gateOffset
	const offsetLow = self.mem:read16(addr)
	const targetSelector = self.mem:read16(addr + 2)
	const access = self.mem:read8(addr + 5)
	const offsetHigh = self.mem:read16(addr + 6)
	const gateType = band(access, 0x1F)
	if band(access, 0x80) == 0 then
		error(("#NP: INT %02X gate %d not present"):format(n, n))
	end
	if gateType == 0x05 then
		error(("#GP: INT %02X task gate not implemented"):format(n))
	end
	if gateType ~= 0x06 and gateType ~= 0x07 and gateType ~= 0x0E and gateType ~= 0x0F then
		error(("#GP: INT %02X gate type %02X is not an interrupt/trap gate"):format(n, gateType))
	end
	const cpl = band(self.cs, 3)
	const gateDpl = band(rshift(access, 5), 3)
	if software and gateDpl < cpl then
		error(("#GP: INT %02X gate DPL%d below CPL%d"):format(n, gateDpl, cpl))
	end
	const targetDesc = readDescriptor(self, targetSelector)
	if not targetDesc or band(targetDesc.access, 0x80) == 0 then
		error(("#GP: INT %02X target selector %04X absent"):format(n, targetSelector))
	end
	if not descriptorIsCode(targetDesc) then
		error(
			("#GP: INT %02X target %04X is not code (access %02X)"):format(
				n,
				targetSelector,
				targetDesc.access
			)
		)
	end
	const targetRing = band(rshift(targetDesc.access, 5), 3)
	const targetOffset = band(bor(offsetLow, lshift(offsetHigh, 16)), 0xFFFF)
	if targetRing < cpl then
		if self.tr == 0 or self.trBase == 0 then
			error(("#GP: INT %02X needs a loaded TSS for ring %d"):format(n, targetRing))
		end
		if targetRing > 2 then
			error(("#GP: INT %02X unsupported target ring %d"):format(n, targetRing))
		end
		const spOff = 2 + targetRing * 4
		const ssOff = spOff + 2
		if self.trLimit < ssOff + 1 then
			error(
				("#TS: TSS selector %04X limit %04X too small for INT %02X"):format(
					self.tr,
					self.trLimit,
					n
				)
			)
		end
		const newSp0 = self.mem:read16(self.trBase + spOff)
		const newSs = self.mem:read16(self.trBase + ssOff)
		const ssDesc = readDescriptor(self, newSs)
		if not ssDesc or not descriptorIsWritableData(ssDesc) then
			error(("#TS: INT %02X stack selector %04X invalid"):format(n, newSs))
		end
		const oldSs = self.ss
		const oldSp = self.r[5]
		const newBase = ssDesc.base
		local newSp = newSp0
		newSp = band(newSp - 2, 0xFFFF)
		self.mem:write16(newBase + newSp, oldSs)
		newSp = band(newSp - 2, 0xFFFF)
		self.mem:write16(newBase + newSp, oldSp)
		newSp = band(newSp - 2, 0xFFFF)
		self.mem:write16(newBase + newSp, self.flags)
		newSp = band(newSp - 2, 0xFFFF)
		self.mem:write16(newBase + newSp, self.cs)
		newSp = band(newSp - 2, 0xFFFF)
		self.mem:write16(newBase + newSp, self.ip)
		if errorCode ~= nil then
			newSp = band(newSp - 2, 0xFFFF)
			self.mem:write16(newBase + newSp, errorCode)
		end
		self:loadSeg("ss", newSs)
		self.r[5] = newSp
		self:loadSeg("cs", targetSelector)
		self.ip = targetOffset
	else
		self:push16(self.flags)
		self:push16(self.cs)
		self:push16(self.ip)
		if errorCode ~= nil then
			self:push16(errorCode)
		end
		self:loadSeg("cs", targetSelector)
		self.ip = targetOffset
	end
	self:setbits(TF, false)
	if gateType == 0x06 or gateType == 0x0E then
		self:setbits(IFF, false)
	end
end

function Cpu.linear(self: Cpu, reg: string, off: number, size: number): number
	const base = self:baseOf(reg)
	if band(self.cr0, 1) ~= 0 and size > 0 then
		const limit = self.segLimit[reg]
		if off + size - 1 > limit then
			const kind = if reg == "ss" then "#SS" else "#GP"
			error(
				("%s: %s selector %04X offset %04X size %d exceeds limit %04X"):format(
					kind,
					reg,
					getSeg(self, reg),
					off,
					size,
					limit
				)
			)
		end
	end
	return base + off
end

function Cpu.rb(self: Cpu, i: number): number
	if i < 4 then
		return band(self.r[i + 1], 0xFF)
	end
	return band(rshift(self.r[i - 3], 8), 0xFF)
end

function Cpu.wb(self: Cpu, i: number, v: number)
	v = band(v, 0xFF)
	if i < 4 then
		self.r[i + 1] = bor(band(self.r[i + 1], 0xFF00), v)
	else
		self.r[i - 3] = bor(band(self.r[i - 3], 0x00FF), lshift(v, 8))
	end
end

function Cpu.rr(self: Cpu, i: number): number
	return self.r[i + 1]
end

function Cpu.wr(self: Cpu, i: number, v: number)
	self.r[i + 1] = band(v, 0xFFFF)
	self.rHi[i + 1] = 0 -- 16-bit writes zero-extend on 386; unused on 8086/286
end

function Cpu.rr32(self: Cpu, i: number): number
	return bor(self.r[i + 1], lshift(self.rHi[i + 1], 16))
end

function Cpu.wr32(self: Cpu, i: number, v: number)
	self.r[i + 1] = band(v, 0xFFFF)
	self.rHi[i + 1] = band(rshift(v, 16), 0xFFFF)
end

function Cpu.fetch8(self: Cpu): number
	local b = self.mem:read8(self:linear("cs", self.ip, 1))
	self.ip = band(self.ip + 1, 0xFFFF)
	return b
end

function Cpu.fetch16(self: Cpu): number
	local lo = self:fetch8()
	return bor(lo, lshift(self:fetch8(), 8))
end

function Cpu.push16(self: Cpu, v: number)
	self.r[5] = band(self.r[5] - 2, 0xFFFF) -- r[5] is SP
	self.mem:write16(self:linear("ss", self.r[5], 2), v)
end

function Cpu.pop16(self: Cpu): number
	local v = self.mem:read16(self:linear("ss", self.r[5], 2))
	self.r[5] = band(self.r[5] + 2, 0xFFFF)
	return v
end

function Cpu.push32(self: Cpu, v: number)
	self.r[5] = band(self.r[5] - 4, 0xFFFF)
	self.mem:write16(self:linear("ss", self.r[5], 4), band(v, 0xFFFF))
	self.mem:write16(self:linear("ss", self.r[5] + 2, 2), band(rshift(v, 16), 0xFFFF))
end

function Cpu.pop32(self: Cpu): number
	local lo = self.mem:read16(self:linear("ss", self.r[5], 4))
	local hi = self.mem:read16(self:linear("ss", self.r[5] + 2, 2))
	self.r[5] = band(self.r[5] + 4, 0xFFFF)
	return bor(lo, lshift(hi, 16))
end

function Cpu.setbits(self: Cpu, mask: number, on: boolean)
	if on then
		self.flags = bor(self.flags, mask)
	else
		self.flags = band(self.flags, bnot(mask))
	end
end

function Cpu.getF(self: Cpu, mask: number): boolean
	return band(self.flags, mask) ~= 0
end

function Cpu.setSZP(self: Cpu, res: number, w: boolean)
	local f = band(self.flags, bnot(ZF + SF + PF))
	if res == 0 then
		f = bor(f, ZF)
	end
	if w then
		if res >= 0x8000 then
			f = bor(f, SF)
		end
	else
		if res >= 0x80 then
			f = bor(f, SF)
		end
	end
	self.flags = bor(f, PARITY[band(res, 0xFF)])
end

function Cpu.modrm(self: Cpu): ModRM
	local m = self:fetch8()
	local mod = rshift(m, 6)
	local reg = band(rshift(m, 3), 7)
	local rm = band(m, 7)
	if mod == 3 then
		return { mod = 3, reg = reg, rm = rm, off = nil, addr = nil, seg = nil }
	end
	local off, segReg
	if mod == 0 and rm == 6 then
		off, segReg = self:fetch16(), "ds"
	else
		local r = self.r
		if rm == 0 then
			off, segReg = r[4] + r[7], "ds"
		elseif rm == 1 then
			off, segReg = r[4] + r[8], "ds"
		elseif rm == 2 then
			off, segReg = r[6] + r[7], "ss"
		elseif rm == 3 then
			off, segReg = r[6] + r[8], "ss"
		elseif rm == 4 then
			off, segReg = r[7], "ds"
		elseif rm == 5 then
			off, segReg = r[8], "ds"
		elseif rm == 6 then
			off, segReg = r[6], "ss"
		else
			off, segReg = r[4], "ds"
		end
		if mod == 1 then
			local d = self:fetch8()
			if d >= 0x80 then
				d -= 0x100
			end
			off += d
		elseif mod == 2 then
			off += self:fetch16()
		end
		off = band(off, 0xFFFF)
	end
	if self.osegReg then
		segReg = self.osegReg
	end
	const offValue = off :: number
	return {
		mod = mod,
		reg = reg,
		rm = rm,
		off = offValue,
		addr = self:baseOf(segReg) + offValue,
		seg = segReg,
	}
end

function Cpu.readRM8(self: Cpu, e: ModRM): number
	if e.mod == 3 then
		return self:rb(e.rm)
	end
	return self.mem:read8(self:linear(e.seg :: string, e.off :: number, 1))
end

function Cpu.writeRM8(self: Cpu, e: ModRM, v: number)
	if e.mod == 3 then
		self:wb(e.rm, v)
	else
		self.mem:write8(self:linear(e.seg :: string, e.off :: number, 1), v)
	end
end

function Cpu.readRM16(self: Cpu, e: ModRM): number
	if e.mod == 3 then
		return self:rr(e.rm)
	end
	return self.mem:read16(self:linear(e.seg :: string, e.off :: number, 2))
end

function Cpu.writeRM16(self: Cpu, e: ModRM, v: number)
	if e.mod == 3 then
		self:wr(e.rm, v)
	else
		self.mem:write16(self:linear(e.seg :: string, e.off :: number, 2), v)
	end
end

-- op: 0 ADD, 1 OR, 2 ADC, 3 SBB, 4 AND, 5 SUB, 6 XOR, 7 CMP
local function doALU(cpu: any, op: number, a: number, b: number, w: boolean): number
	local maxv = w and 0xFFFF or 0xFF
	local signv = w and 0x8000 or 0x80
	local res, cf, of
	if op == 0 or op == 2 then
		local c = 0
		if op == 2 and cpu:getF(CF) then
			c = 1
		end
		res = a + b + c
		cf = res > maxv
		of = band(band(bnot(bxor(a, b)), bxor(a, res)), signv) ~= 0
	elseif op == 3 or op == 5 or op == 7 then
		local c = 0
		if op == 3 and cpu:getF(CF) then
			c = 1
		end
		res = a - b - c
		cf = res < 0
		of = band(band(bxor(a, b), bxor(a, res)), signv) ~= 0
	else
		if op == 1 then
			res = bor(a, b)
		elseif op == 4 then
			res = band(a, b)
		else
			res = bxor(a, b)
		end
		cf, of = false, false
	end
	res = band(res, maxv)
	cpu:setbits(CF, cf)
	cpu:setbits(OFLG, of)
	cpu:setbits(AF, band(bxor(bxor(a, b), res), 16) ~= 0)
	cpu:setSZP(res, w)
	return res
end

-- op: 0 ROL, 1 ROR, 2 RCL, 3 RCR, 4 SHL, 5 SHR, 6 SHL alias, 7 SAR
-- 8086 semantics for the count (not masked; CF/OF as documented). On the
-- 80186+ the shift group also updates SZP for SHL/SHR/SAR (rotates leave SZP
-- alone); Windows 3.0 real-mode code branches on those flags right after a
-- shift, so they cannot be left stale.
local function doShift(cpu: any, op: number, v: number, cnt: number, w: boolean): number
	local bits = w and 16 or 8
	local maxv = w and 0xFFFF or 0xFF
	local msb = w and 0x8000 or 0x80
	if cnt == 0 then
		return v
	end
	local cf = cpu:getF(CF)
	local res, of = v, false

	if op == 4 or op == 6 then
		res = v
		for _ = 1, cnt do
			cf = band(res, msb) ~= 0
			res = band(lshift(res, 1), maxv)
		end
		of = cnt == 1 and (cf ~= (band(res, msb) ~= 0)) or false
	elseif op == 5 then
		res = v
		of = cnt == 1 and (band(v, msb) ~= 0) or false
		for _ = 1, cnt do
			cf = band(res, 1) ~= 0
			res = rshift(res, 1)
		end
	elseif op == 7 then
		local sv = w and sign16(v) or sign8(v)
		if cnt >= bits then
			res = sv < 0 and maxv or 0
			cf = sv < 0
		else
			res = band(math.floor(sv / lshift(1, cnt)), maxv)
			cf = band(rshift(sv, cnt - 1), 1) == 1
		end
		of = false
	elseif op == 0 then
		local c = cnt % bits
		if c == 0 then
			res = v
			cf = band(v, 1) == 1
		else
			res = band(bor(lshift(v, c), rshift(v, bits - c)), maxv)
			cf = band(res, 1) == 1
		end
		of = cnt == 1 and (cf ~= (band(res, msb) ~= 0)) or false
	elseif op == 1 then
		local c = cnt % bits
		if c == 0 then
			res = v
			cf = band(v, msb) ~= 0
		else
			res = band(bor(rshift(v, c), lshift(v, bits - c)), maxv)
			cf = band(res, msb) ~= 0
		end
		of = cnt == 1 and ((band(res, msb) ~= 0) ~= (band(res, rshift(msb, 1)) ~= 0)) or false
	elseif op == 2 then
		local width = bits + 1
		local c = cnt % width
		if c == 0 then
			res = v
		else
			local combined = bor(lshift(v, 1), cf and 1 or 0)
			local mask = lshift(1, width) - 1
			local rot = band(bor(lshift(combined, c), rshift(combined, width - c)), mask)
			res = band(rshift(rot, 1), maxv)
			cf = band(rot, 1) == 1
		end
		of = cnt == 1 and (cf ~= (band(res, msb) ~= 0)) or false
	else
		local width = bits + 1
		local c = cnt % width
		local combined = bor(v, cf and lshift(1, bits) or 0)
		if c == 0 then
			res = v
		else
			local mask = lshift(1, width) - 1
			local rot = band(bor(rshift(combined, c), lshift(combined, width - c)), mask)
			res = band(rot, maxv)
			cf = band(rshift(rot, bits), 1) == 1
		end
		of = cnt == 1 and ((band(res, msb) ~= 0) ~= (band(res, rshift(msb, 1)) ~= 0)) or false
	end

	cpu:setbits(CF, cf)
	cpu:setbits(OFLG, of)
	if op == 4 or op == 5 or op == 6 or op == 7 then
		cpu:setSZP(res, w)
	end
	return res
end

const H: { [number]: any } = {}

-- ALU families: opcode = aluOp*8 + form
-- form: 0 rm8,r8 | 1 rm16,r16 | 2 r8,rm8 | 3 r16,rm16 | 4 AL,imm8 | 5 AX,imm16
for aluOp = 0, 7 do
	local base = aluOp * 8
	H[base + 0] = function(cpu: any)
		local e = cpu:modrm()
		local res = doALU(cpu, aluOp, cpu:readRM8(e), cpu:rb(e.reg), false)
		if aluOp ~= 7 then
			cpu:writeRM8(e, res)
		end
	end
	H[base + 1] = function(cpu: any)
		local e = cpu:modrm()
		local res = doALU(cpu, aluOp, cpu:readRM16(e), cpu:rr(e.reg), true)
		if aluOp ~= 7 then
			cpu:writeRM16(e, res)
		end
	end
	H[base + 2] = function(cpu: any)
		local e = cpu:modrm()
		local res = doALU(cpu, aluOp, cpu:rb(e.reg), cpu:readRM8(e), false)
		if aluOp ~= 7 then
			cpu:wb(e.reg, res)
		end -- CMP r8,r/m8 (0x38) must not write
	end
	H[base + 3] = function(cpu: any)
		local e = cpu:modrm()
		local res = doALU(cpu, aluOp, cpu:rr(e.reg), cpu:readRM16(e), true)
		if aluOp ~= 7 then
			cpu:wr(e.reg, res)
		end -- CMP r16,r/m16 (0x39) must not write
	end
	H[base + 4] = function(cpu: any)
		local res = doALU(cpu, aluOp, cpu:rb(0), cpu:fetch8(), false)
		if aluOp ~= 7 then
			cpu:wb(0, res)
		end -- CMP AL,imm8 (0x3C) must not write
	end
	H[base + 5] = function(cpu: any)
		local res = doALU(cpu, aluOp, cpu:rr(0), cpu:fetch16(), true)
		if aluOp ~= 7 then
			cpu:wr(0, res)
		end -- CMP AX,imm16 (0x3D) must not write
	end
end

-- segment push/pop
H[0x06] = function(cpu: any)
	cpu:push16(cpu.es)
end
H[0x07] = function(cpu: any)
	cpu:loadSeg("es", cpu:pop16())
end
H[0x0E] = function(cpu: any)
	cpu:push16(cpu.cs)
end
H[0x0F] = function(cpu: any)
	if cpu.config.popCS == false then
		error("opcode 0F (POP CS) disabled; reserved for 386 two-byte escape")
	end
	cpu.cs = cpu:pop16()
end
H[0x16] = function(cpu: any)
	cpu:push16(cpu.ss)
end
H[0x17] = function(cpu: any)
	cpu:loadSeg("ss", cpu:pop16())
end
H[0x1E] = function(cpu: any)
	cpu:push16(cpu.ds)
end
H[0x1F] = function(cpu: any)
	cpu:loadSeg("ds", cpu:pop16())
end

-- BCD adjust
H[0x27] = function(cpu: any) -- DAA
	local al = cpu:rb(0)
	local oldal, oldcf = al, cpu:getF(CF)
	local cf = false
	if band(al, 0x0F) > 9 or cpu:getF(AF) then
		cf = (al + 6 > 0xFF) or oldcf
		al = band(al + 6, 0xFF)
		cpu:setbits(AF, true)
	else
		cpu:setbits(AF, false)
	end
	if oldal > 0x99 or oldcf then
		al = band(al + 0x60, 0xFF)
		cf = true
	end
	cpu:wb(0, al)
	cpu:setbits(CF, cf)
	cpu:setSZP(al, false)
end
H[0x2F] = function(cpu: any) -- DAS
	local al = cpu:rb(0)
	local oldal, oldcf = al, cpu:getF(CF)
	local cf = false
	if band(al, 0x0F) > 9 or cpu:getF(AF) then
		cf = (al < 6) or oldcf
		al = band(al - 6, 0xFF)
		cpu:setbits(AF, true)
	else
		cpu:setbits(AF, false)
	end
	if oldal > 0x99 or oldcf then
		al = band(al - 0x60, 0xFF)
		cf = true
	end
	cpu:wb(0, al)
	cpu:setbits(CF, cf)
	cpu:setSZP(al, false)
end
H[0x37] = function(cpu: any) -- AAA
	if band(cpu:rb(0), 0x0F) > 9 or cpu:getF(AF) then
		cpu.r[1] = band(cpu.r[1] + 0x106, 0xFFFF)
		cpu:setbits(AF, true)
		cpu:setbits(CF, true)
	else
		cpu:setbits(AF, false)
		cpu:setbits(CF, false)
	end
	cpu:wb(0, band(cpu:rb(0), 0x0F))
end
H[0x3F] = function(cpu: any) -- AAS
	if band(cpu:rb(0), 0x0F) > 9 or cpu:getF(AF) then
		cpu.r[1] = band(cpu.r[1] - 6, 0xFFFF)
		cpu:wb(4, cpu:rb(4) - 1)
		cpu:setbits(AF, true)
		cpu:setbits(CF, true)
	else
		cpu:setbits(AF, false)
		cpu:setbits(CF, false)
	end
	cpu:wb(0, band(cpu:rb(0), 0x0F))
end

-- INC/DEC/PUSH/POP r16 (reg index i)
for i = 0, 7 do
	H[0x40 + i] = function(cpu: any)
		local cf = cpu:getF(CF)
		cpu:wr(i, doALU(cpu, 0, cpu:rr(i), 1, true))
		cpu:setbits(CF, cf)
	end
	H[0x48 + i] = function(cpu: any)
		local cf = cpu:getF(CF)
		cpu:wr(i, doALU(cpu, 5, cpu:rr(i), 1, true))
		cpu:setbits(CF, cf)
	end
	H[0x50 + i] = function(cpu: any)
		if cpu.operand32 then
			cpu:push32(cpu:rr32(i))
		elseif i == 4 then
			-- 8086 quirk: PUSH SP pushes the DECREMENTED value
			cpu:push16(band(cpu.r[5] - 2, 0xFFFF))
		else
			cpu:push16(cpu:rr(i))
		end
	end
	H[0x58 + i] = function(cpu: any)
		if cpu.operand32 then
			cpu:wr32(i, cpu:pop32())
		else
			cpu:wr(i, cpu:pop16())
		end
	end
end

-- Jcc (70-7F rel8); 60-6F alias them on 8086
-- Signed conditions compare SF and OF as booleans, not as their mask values:
-- SF=0x80 and OF=0x800 are unequal even though both flags are set.
local function signDiff(f: number): boolean
	return (band(f, SF) ~= 0) ~= (band(f, OFLG) ~= 0)
end

const COND: { (flags: number) -> boolean } = {
	function(f)
		return band(f, OFLG) ~= 0
	end,
	function(f)
		return band(f, OFLG) == 0
	end,
	function(f)
		return band(f, CF) ~= 0
	end,
	function(f)
		return band(f, CF) == 0
	end,
	function(f)
		return band(f, ZF) ~= 0
	end,
	function(f)
		return band(f, ZF) == 0
	end,
	function(f)
		return band(f, bor(CF, ZF)) ~= 0
	end,
	function(f)
		return band(f, bor(CF, ZF)) == 0
	end,
	function(f)
		return band(f, SF) ~= 0
	end,
	function(f)
		return band(f, SF) == 0
	end,
	function(f)
		return band(f, PF) ~= 0
	end,
	function(f)
		return band(f, PF) == 0
	end,
	function(f)
		return signDiff(f)
	end,
	function(f)
		return not signDiff(f)
	end,
	function(f)
		return band(f, ZF) ~= 0 or signDiff(f)
	end,
	function(f)
		return band(f, ZF) == 0 and not signDiff(f)
	end,
}
for i = 0, 15 do
	H[0x70 + i] = function(cpu: any)
		local d = cpu:fetch8()
		if d >= 0x80 then
			d -= 0x100
		end
		if COND[i + 1](cpu.flags) then
			cpu.ip = band(cpu.ip + d, 0xFFFF)
		end
	end
	H[0x60 + i] = H[0x70 + i]
end

-- group 1: 80/81/82/83
local function group1(cpu: any, w: boolean, signExtImm: boolean)
	local e = cpu:modrm()
	local op = e.reg
	local a = w and cpu:readRM16(e) or cpu:readRM8(e)
	local b
	if w and signExtImm then
		b = cpu:fetch8()
		if b >= 0x80 then
			b += 0xFF00
		end
	else
		b = w and cpu:fetch16() or cpu:fetch8()
	end
	local res = doALU(cpu, op, a, b, w)
	if op ~= 7 then
		if w then
			cpu:writeRM16(e, res)
		else
			cpu:writeRM8(e, res)
		end
	end
end
H[0x80] = function(cpu: any)
	group1(cpu, false, false)
end
H[0x81] = function(cpu: any)
	group1(cpu, true, false)
end
H[0x82] = H[0x80]
H[0x83] = function(cpu: any)
	group1(cpu, true, true)
end

-- TEST r/m,reg
H[0x84] = function(cpu: any)
	local e = cpu:modrm()
	doALU(cpu, 4, cpu:readRM8(e), cpu:rb(e.reg), false)
end
H[0x85] = function(cpu: any)
	local e = cpu:modrm()
	doALU(cpu, 4, cpu:readRM16(e), cpu:rr(e.reg), true)
end

-- XCHG r/m,reg
H[0x86] = function(cpu: any)
	local e = cpu:modrm()
	local a, b = cpu:readRM8(e), cpu:rb(e.reg)
	cpu:writeRM8(e, b)
	cpu:wb(e.reg, a)
end
H[0x87] = function(cpu: any)
	local e = cpu:modrm()
	local a, b = cpu:readRM16(e), cpu:rr(e.reg)
	cpu:writeRM16(e, b)
	cpu:wr(e.reg, a)
end

-- MOV family
H[0x88] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM8(e, cpu:rb(e.reg))
end
H[0x89] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM16(e, cpu:rr(e.reg))
end
H[0x8A] = function(cpu: any)
	local e = cpu:modrm()
	cpu:wb(e.reg, cpu:readRM8(e))
end
H[0x8B] = function(cpu: any)
	local e = cpu:modrm()
	cpu:wr(e.reg, cpu:readRM16(e))
end

local SEGREG = { "es", "cs", "ss", "ds", "fs", "gs" }
H[0x8C] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM16(e, cpu[SEGREG[e.reg + 1]])
end
H[0x8D] = function(cpu: any)
	local e = cpu:modrm()
	if e.mod == 3 then
		error("LEA with register operand")
	end
	cpu:wr(e.reg, e.off)
end
H[0x8E] = function(cpu: any)
	const e = cpu:modrm()
	if e.reg == 1 then
		error("MOV CS, r/m is reserved")
	end
	cpu:loadSeg(SEGREG[e.reg + 1], cpu:readRM16(e))
end
H[0x8F] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM16(e, cpu:pop16())
end

H[0x90] = function() end -- NOP
for i = 1, 7 do
	H[0x90 + i] = function(cpu: any) -- XCHG AX,r
		local a = cpu:rr(0)
		cpu:wr(0, cpu:rr(i))
		cpu:wr(i, a)
	end
end

H[0x98] = function(cpu: any) -- CBW
	local al = cpu:rb(0)
	cpu:wr(0, al >= 0x80 and bor(0xFF00, al) or al)
end
H[0x99] = function(cpu: any) -- CWD
	cpu:wr(2, cpu:rr(0) >= 0x8000 and 0xFFFF or 0)
end
H[0x9A] = function(cpu: any) -- CALL far imm
	const ip = cpu:fetch16()
	const cs = cpu:fetch16()
	cpu:farCall(cs, ip, true)
end
H[0x9B] = function() end -- WAIT
H[0x9C] = function(cpu: any)
	cpu:push16(cpu.flags)
end
H[0x9D] = function(cpu: any)
	const wasEnabled = cpu:getF(IFF)
	cpu.flags = bor(band(cpu:pop16(), cpu.flagMask), cpu.fixedFlags)
	if not wasEnabled and cpu:getF(IFF) then
		cpu.irqDelay = 1 -- 8086 interrupt shadow after POPF
	end
end
H[0x9E] = function(cpu: any) -- SAHF
	local ah = cpu:rb(4)
	cpu.flags = bor(band(cpu.flags, bnot(0xD5)), band(ah, 0xD5), ALWAYS)
end
H[0x9F] = function(cpu: any) -- LAHF
	cpu:wb(4, bor(band(cpu.flags, 0xD5), ALWAYS))
end

-- MOV AL/AX <-> moffs16 (segment override allowed)
local function moffs(cpu: any, size: number)
	const off = cpu:fetch16()
	return cpu:linear(cpu.osegReg or "ds", off, size)
end
H[0xA0] = function(cpu: any)
	cpu:wb(0, cpu.mem:read8(moffs(cpu, 1)))
end
H[0xA1] = function(cpu: any)
	cpu:wr(0, cpu.mem:read16(moffs(cpu, 2)))
end
H[0xA2] = function(cpu: any)
	cpu.mem:write8(moffs(cpu, 1), cpu:rb(0))
end
H[0xA3] = function(cpu: any)
	cpu.mem:write16(moffs(cpu, 2), cpu:rr(0))
end

-- string ops: 0 MOVS, 1 CMPS, 2 STOS, 3 LODS, 4 SCAS
local function stringOp(cpu: any, id: number, w: boolean)
	local sz = w and 2 or 1
	local d = cpu:getF(DFF) and -sz or sz
	local mem = cpu.mem
	const sReg = cpu.osegReg or "ds"
	local function srcAddr(): number
		return cpu:linear(sReg, cpu.r[7], sz)
	end
	local function dstAddr(): number
		return cpu:linear("es", cpu.r[8], sz)
	end

	local function step()
		if id == 0 then
			if w then
				mem:write16(dstAddr(), mem:read16(srcAddr()))
			else
				mem:write8(dstAddr(), mem:read8(srcAddr()))
			end
			cpu.r[7] = band(cpu.r[7] + d, 0xFFFF)
			cpu.r[8] = band(cpu.r[8] + d, 0xFFFF)
		elseif id == 1 then
			local a = w and mem:read16(srcAddr()) or mem:read8(srcAddr())
			local b = w and mem:read16(dstAddr()) or mem:read8(dstAddr())
			doALU(cpu, 5, a, b, w)
			cpu.r[7] = band(cpu.r[7] + d, 0xFFFF)
			cpu.r[8] = band(cpu.r[8] + d, 0xFFFF)
		elseif id == 2 then
			if w then
				mem:write16(dstAddr(), cpu:rr(0))
			else
				mem:write8(dstAddr(), cpu:rb(0))
			end
			cpu.r[8] = band(cpu.r[8] + d, 0xFFFF)
		elseif id == 3 then
			if w then
				cpu:wr(0, mem:read16(srcAddr()))
			else
				cpu:wb(0, mem:read8(srcAddr()))
			end
			cpu.r[7] = band(cpu.r[7] + d, 0xFFFF)
		else
			local b = w and mem:read16(dstAddr()) or mem:read8(dstAddr())
			doALU(cpu, 5, w and cpu:rr(0) or cpu:rb(0), b, w)
			cpu.r[8] = band(cpu.r[8] + d, 0xFFFF)
		end
	end

	if not cpu.rep then
		step()
		return
	end
	local isCmp = (id == 1 or id == 4)
	while cpu.r[2] ~= 0 do
		step()
		cpu.r[2] = band(cpu.r[2] - 1, 0xFFFF)
		if isCmp then
			local zf = cpu:getF(ZF)
			if cpu.rep == 1 and not zf then
				break
			end
			if cpu.rep == 2 and zf then
				break
			end
		end
	end
end
H[0xA4] = function(cpu: any)
	stringOp(cpu, 0, false)
end
H[0xA5] = function(cpu: any)
	stringOp(cpu, 0, true)
end
H[0xA6] = function(cpu: any)
	stringOp(cpu, 1, false)
end
H[0xA7] = function(cpu: any)
	stringOp(cpu, 1, true)
end
H[0xAA] = function(cpu: any)
	stringOp(cpu, 2, false)
end
H[0xAB] = function(cpu: any)
	stringOp(cpu, 2, true)
end
H[0xAC] = function(cpu: any)
	stringOp(cpu, 3, false)
end
H[0xAD] = function(cpu: any)
	stringOp(cpu, 3, true)
end
H[0xAE] = function(cpu: any)
	stringOp(cpu, 4, false)
end
H[0xAF] = function(cpu: any)
	stringOp(cpu, 4, true)
end

H[0xA8] = function(cpu: any)
	doALU(cpu, 4, cpu:rb(0), cpu:fetch8(), false)
end
H[0xA9] = function(cpu: any)
	doALU(cpu, 4, cpu:rr(0), cpu:fetch16(), true)
end

for i = 0, 7 do
	H[0xB0 + i] = function(cpu: any)
		cpu:wb(i, cpu:fetch8())
	end
	H[0xB8 + i] = function(cpu: any)
		cpu:wr(i, cpu:fetch16())
	end
end

H[0xC2] = function(cpu: any) -- RET imm16
	local n = cpu:fetch16()
	cpu.ip = cpu:pop16()
	cpu.r[5] = band(cpu.r[5] + n, 0xFFFF)
end
H[0xC3] = function(cpu: any)
	cpu.ip = cpu:pop16()
end

H[0xC4] = function(cpu: any) -- LES r16, m32
	const e = cpu:modrm()
	const addr = cpu:linear(e.seg :: string, e.off :: number, 4)
	cpu:wr(e.reg, cpu.mem:read16(addr))
	cpu:loadSeg("es", cpu.mem:read16(addr + 2))
end
H[0xC5] = function(cpu: any) -- LDS r16, m32
	const e = cpu:modrm()
	const addr = cpu:linear(e.seg :: string, e.off :: number, 4)
	cpu:wr(e.reg, cpu.mem:read16(addr))
	cpu:loadSeg("ds", cpu.mem:read16(addr + 2))
end

H[0xC6] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM8(e, cpu:fetch8())
end
H[0xC7] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM16(e, cpu:fetch16())
end

local function retf(cpu: any, extra: number)
	const ip = cpu:pop16()
	const csSel = cpu:pop16()
	local outerSp, outerSs
	if band(cpu.cr0, 1) ~= 0 and band(csSel, 3) > band(cpu.cs, 3) then
		outerSp = cpu:pop16()
		outerSs = cpu:pop16()
	end
	cpu.ip = ip
	cpu:loadSeg("cs", csSel)
	if outerSs then
		cpu:loadSeg("ss", outerSs)
		cpu.r[5] = outerSp :: number
	end
	if extra ~= 0 then
		cpu.r[5] = band(cpu.r[5] + extra, 0xFFFF)
	end
end

H[0xCA] = function(cpu: any) -- RETF imm16
	retf(cpu, cpu:fetch16())
end
H[0xCB] = function(cpu: any)
	retf(cpu, 0)
end

H[0xCC] = function(cpu: any)
	cpu:interrupt(3, nil, true)
end
H[0xCD] = function(cpu: any)
	cpu:interrupt(cpu:fetch8(), nil, true)
end
H[0xCE] = function(cpu: any)
	if cpu:getF(OFLG) then
		cpu:interrupt(4, nil, true)
	end
end
H[0xCF] = function(cpu: any) -- IRET
	const ip = cpu:pop16()
	const csSel = cpu:pop16()
	const wasEnabled = cpu:getF(IFF)
	const newFlags = cpu:pop16()
	local outerSp, outerSs
	if band(cpu.cr0, 1) ~= 0 and band(csSel, 3) > band(cpu.cs, 3) then
		outerSp = cpu:pop16()
		outerSs = cpu:pop16()
	end
	cpu.ip = ip
	cpu:loadSeg("cs", csSel)
	cpu.flags = bor(band(newFlags, cpu.flagMask), cpu.fixedFlags)
	if outerSs then
		cpu:loadSeg("ss", outerSs)
		cpu.r[5] = outerSp :: number
	end
	if not wasEnabled and cpu:getF(IFF) then
		cpu.irqDelay = 1 -- 8086 interrupt shadow after IRET
	end
end

-- group 2: shifts/rotates
local function group2(cpu: any, w: boolean, useCL: boolean)
	local e = cpu:modrm()
	local v = w and cpu:readRM16(e) or cpu:readRM8(e)
	local cnt = useCL and cpu:rb(1) or 1
	local res = doShift(cpu, e.reg, v, cnt, w)
	if cnt > 0 then
		if w then
			cpu:writeRM16(e, res)
		else
			cpu:writeRM8(e, res)
		end
	end
end
H[0xD0] = function(cpu: any)
	group2(cpu, false, false)
end
H[0xD1] = function(cpu: any)
	group2(cpu, true, false)
end
H[0xD2] = function(cpu: any)
	group2(cpu, false, true)
end
H[0xD3] = function(cpu: any)
	group2(cpu, true, true)
end

-- group 2 with an 8-bit immediate count (80186+): SHL/SHR/SAR/ROL/ROR/RCL/RCR
-- r/m,imm8. Windows 3.0 real-mode code uses these even though an 8086 decodes
-- C0/C1 as the undocumented RET/RET imm16 aliases.
local function group2Imm(cpu: any, w: boolean)
	local e = cpu:modrm()
	local v = w and cpu:readRM16(e) or cpu:readRM8(e)
	local cnt = cpu:fetch8()
	local res = doShift(cpu, e.reg, v, cnt, w)
	if cnt > 0 then
		if w then
			cpu:writeRM16(e, res)
		else
			cpu:writeRM8(e, res)
		end
	end
end
H[0xC0] = function(cpu: any)
	group2Imm(cpu, false)
end
H[0xC1] = function(cpu: any)
	group2Imm(cpu, true)
end

H[0xD4] = function(cpu: any) -- AAM imm
	local base = cpu:fetch8()
	if base == 0 then
		cpu:interrupt(0)
		return
	end
	local al = cpu:rb(0)
	cpu:wb(4, math.floor(al / base))
	cpu:wb(0, al % base)
	cpu:setSZP(cpu:rb(0), false)
end
H[0xD5] = function(cpu: any) -- AAD imm
	local base = cpu:fetch8()
	local al = band(cpu:rb(0) + cpu:rb(4) * base, 0xFF)
	cpu:wb(0, al)
	cpu:wb(4, 0)
	cpu:setSZP(al, false)
end
H[0xD6] = function(cpu: any)
	cpu:wb(0, cpu:getF(CF) and 0xFF or 0)
end -- SALC
H[0xD7] = function(cpu: any) -- XLAT
	const off = band(cpu.r[4] + cpu:rb(0), 0xFFFF)
	cpu:wb(0, cpu.mem:read8(cpu:linear(cpu.osegReg or "ds", off, 1)))
end

for i = 0, 7 do
	H[0xD8 + i] = function(cpu: any)
		cpu:modrm()
	end -- ESC (x87 stub)
end

local function loopCommon(cpu: any, mode: number)
	local d = cpu:fetch8()
	if d >= 0x80 then
		d -= 0x100
	end
	local cx = band(cpu.r[2] - 1, 0xFFFF)
	cpu.r[2] = cx
	local take
	if mode == 0 then
		take = cx ~= 0 and not cpu:getF(ZF)
	elseif mode == 1 then
		take = cx ~= 0 and cpu:getF(ZF)
	else
		take = cx ~= 0
	end
	if take then
		cpu.ip = band(cpu.ip + d, 0xFFFF)
	end
end
H[0xE0] = function(cpu: any)
	loopCommon(cpu, 0)
end
H[0xE1] = function(cpu: any)
	loopCommon(cpu, 1)
end
H[0xE2] = function(cpu: any)
	loopCommon(cpu, 2)
end
H[0xE3] = function(cpu: any)
	local d = cpu:fetch8()
	if d >= 0x80 then
		d -= 0x100
	end
	if cpu.r[2] == 0 then
		cpu.ip = band(cpu.ip + d, 0xFFFF)
	end
end

H[0xE4] = function(cpu: any)
	local p = cpu:fetch8()
	cpu:wb(0, cpu.io.in8(p))
end
H[0xE5] = function(cpu: any)
	local p = cpu:fetch8()
	cpu:wr(0, bor(cpu.io.in8(p), lshift(cpu.io.in8(band(p + 1, 0xFFFF)), 8)))
end
H[0xE6] = function(cpu: any)
	local p = cpu:fetch8()
	cpu.io.out8(p, cpu:rb(0))
end
H[0xE7] = function(cpu: any)
	local p = cpu:fetch8()
	cpu.io.out8(p, cpu:rb(0))
	cpu.io.out8(band(p + 1, 0xFFFF), band(rshift(cpu:rr(0), 8), 0xFF))
end

H[0xE8] = function(cpu: any) -- CALL rel16
	local d = cpu:fetch16()
	cpu:push16(cpu.ip)
	cpu.ip = band(cpu.ip + sign16(d), 0xFFFF)
end
H[0xE9] = function(cpu: any)
	local d = cpu:fetch16()
	cpu.ip = band(cpu.ip + sign16(d), 0xFFFF)
end
H[0xEA] = function(cpu: any)
	const ip = cpu:fetch16()
	const cs = cpu:fetch16()
	cpu:farCall(cs, ip, false)
end
H[0xEB] = function(cpu: any)
	local d = cpu:fetch8()
	if d >= 0x80 then
		d -= 0x100
	end
	cpu.ip = band(cpu.ip + d, 0xFFFF)
end

H[0xEC] = function(cpu: any)
	cpu:wb(0, cpu.io.in8(cpu.r[3]))
end
H[0xED] = function(cpu: any)
	local p = cpu.r[3]
	cpu:wr(0, bor(cpu.io.in8(p), lshift(cpu.io.in8(band(p + 1, 0xFFFF)), 8)))
end
H[0xEE] = function(cpu: any)
	cpu.io.out8(cpu.r[3], cpu:rb(0))
end
H[0xEF] = function(cpu: any)
	local p = cpu.r[3]
	cpu.io.out8(p, cpu:rb(0))
	cpu.io.out8(band(p + 1, 0xFFFF), band(rshift(cpu:rr(0), 8), 0xFF))
end

H[0xF1] = function() end -- undefined on 8086, treat as NOP
H[0xF4] = function(cpu: any)
	cpu.halted = true
end
H[0xF5] = function(cpu: any)
	cpu.flags = bxor(cpu.flags, CF)
end

local function group3(cpu: any, w: boolean)
	local e = cpu:modrm()
	local op = e.reg
	if op == 0 or op == 1 then
		local a = w and cpu:readRM16(e) or cpu:readRM8(e)
		local b = w and cpu:fetch16() or cpu:fetch8()
		doALU(cpu, 4, a, b, w)
	elseif op == 2 then
		local res = band(bnot(w and cpu:readRM16(e) or cpu:readRM8(e)), w and 0xFFFF or 0xFF)
		if w then
			cpu:writeRM16(e, res)
		else
			cpu:writeRM8(e, res)
		end
	elseif op == 3 then
		local a = w and cpu:readRM16(e) or cpu:readRM8(e)
		local res = doALU(cpu, 5, 0, a, w)
		if w then
			cpu:writeRM16(e, res)
		else
			cpu:writeRM8(e, res)
		end
	elseif op == 4 then
		if w then
			local prod = cpu:rr(0) * cpu:readRM16(e)
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:wr(2, band(rshift(prod, 16), 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod > 0xFFFF)
		else
			local prod = cpu:rb(0) * cpu:readRM8(e)
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod > 0xFF)
		end
	elseif op == 5 then
		if w then
			local prod = sign16(cpu:rr(0)) * sign16(cpu:readRM16(e))
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:wr(2, band(truncDiv(prod, 0x10000), 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod < -0x8000 or prod > 0x7FFF)
		else
			local prod = sign8(cpu:rb(0)) * sign8(cpu:readRM8(e))
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod < -0x80 or prod > 0x7F)
		end
	elseif op == 6 then
		if w then
			local dv = cpu:readRM16(e)
			local n = bor(lshift(cpu:rr(2), 16), cpu:rr(0))
			if dv == 0 or n >= lshift(dv, 16) then
				cpu:interrupt(0)
				return
			end
			cpu:wr(0, math.floor(n / dv))
			cpu:wr(2, n % dv)
		else
			local dv = cpu:readRM8(e)
			local n = cpu:rr(0)
			if dv == 0 or n >= lshift(dv, 8) then
				cpu:interrupt(0)
				return
			end
			cpu:wb(0, math.floor(n / dv))
			cpu:wb(4, n % dv)
		end
	else
		if w then
			local dv = sign16(cpu:readRM16(e))
			if dv == 0 then
				cpu:interrupt(0)
				return
			end
			local n = sign32(bor(lshift(cpu:rr(2), 16), cpu:rr(0)))
			local q = truncDiv(n, dv)
			local r = n - q * dv
			if q < -0x8000 or q > 0x7FFF then
				cpu:interrupt(0)
				return
			end
			cpu:wr(0, band(q, 0xFFFF))
			cpu:wr(2, band(r, 0xFFFF))
		else
			local dv = sign8(cpu:readRM8(e))
			if dv == 0 then
				cpu:interrupt(0)
				return
			end
			local n = sign16(cpu:rr(0))
			local q = truncDiv(n, dv)
			local r = n - q * dv
			if q < -0x80 or q > 0x7F then
				cpu:interrupt(0)
				return
			end
			cpu:wb(0, band(q, 0xFF))
			cpu:wb(4, band(r, 0xFF))
		end
	end
end
H[0xF6] = function(cpu: any)
	group3(cpu, false)
end
H[0xF7] = function(cpu: any)
	group3(cpu, true)
end

H[0xF8] = function(cpu: any)
	cpu:setbits(CF, false)
end
H[0xF9] = function(cpu: any)
	cpu:setbits(CF, true)
end
H[0xFA] = function(cpu: any)
	cpu:setbits(IFF, false)
end
H[0xFB] = function(cpu: any)
	cpu:setbits(IFF, true)
	cpu.irqDelay = 1 -- 8086 interrupt shadow after STI
end
H[0xFC] = function(cpu: any)
	cpu:setbits(DFF, false)
end
H[0xFD] = function(cpu: any)
	cpu:setbits(DFF, true)
end

H[0xFE] = function(cpu: any)
	local e = cpu:modrm()
	local cf = cpu:getF(CF)
	local res
	if e.reg == 0 then
		res = doALU(cpu, 0, cpu:readRM8(e), 1, false)
	elseif e.reg == 1 then
		res = doALU(cpu, 5, cpu:readRM8(e), 1, false)
	else
		error("bad FE /" .. e.reg)
	end
	cpu:writeRM8(e, res)
	cpu:setbits(CF, cf)
end
H[0xFF] = function(cpu: any)
	local e = cpu:modrm()
	local reg = e.reg
	if reg == 0 or reg == 1 then
		local cf = cpu:getF(CF)
		local res = doALU(cpu, reg == 0 and 0 or 5, cpu:readRM16(e), 1, true)
		cpu:writeRM16(e, res)
		cpu:setbits(CF, cf)
	elseif reg == 2 then
		local t = cpu:readRM16(e)
		cpu:push16(cpu.ip)
		cpu.ip = t
	elseif reg == 3 then
		const addr = cpu:linear(e.seg :: string, e.off :: number, 4)
		const ip = cpu.mem:read16(addr)
		const cs = cpu.mem:read16(addr + 2)
		cpu:farCall(cs, ip, true)
	elseif reg == 4 then
		cpu.ip = cpu:readRM16(e)
	elseif reg == 5 then
		const addr = cpu:linear(e.seg :: string, e.off :: number, 4)
		const cs = cpu.mem:read16(addr + 2)
		const ip = cpu.mem:read16(addr)
		cpu:farCall(cs, ip, false)
	elseif reg == 6 then
		cpu:push16(cpu:readRM16(e))
	else
		error(("bad FF /7 at %04X:%04X"):format(cpu.cs, cpu.ip - 2))
	end
end

-- 8086 aliasing: C8/C9 -> RETF imm16/RETF. C0/C1 are *not* 8086 aliases
-- here: 80186+ defines them as shift/rotate r/m,imm8, and Windows 3.0's
-- real-mode drivers emit them (VGA.DRV does `SHR DX,3` = C1 EA 03). Treating
-- C1 as RET pops a saved register as the return address and derails the
-- guest, so implement the 80186 group-2 immediate forms instead.
-- On 286+ C8/C9 are ENTER/LEAVE, so pick at runtime to keep 3.0a identical.
local function enter(cpu: any)
	const size = cpu:fetch16()
	const nesting = band(cpu:fetch8(), 0x1F)
	cpu:push16(cpu.r[6]) -- BP
	const frame = cpu.r[5]
	if nesting > 0 then
		local bp = cpu.r[6]
		for _ = 1, nesting - 1 do
			bp = band(bp - 2, 0xFFFF)
			cpu:push16(cpu.mem:read16(cpu:linear("ss", bp, 2)))
		end
		cpu:push16(frame)
	end
	cpu.r[6] = frame
	cpu.r[5] = band(cpu.r[5] - size, 0xFFFF)
end
local function leave(cpu: any)
	cpu.r[5] = cpu.r[6]
	cpu.r[6] = cpu:pop16()
end
local function jccShort(cpu: any, index: number)
	local d = cpu:fetch8()
	if d >= 0x80 then
		d -= 0x100
	end
	if COND[index + 1](cpu.flags) then
		cpu.ip = band(cpu.ip + d, 0xFFFF)
	end
end
H[0xC8] = function(cpu: any)
	if cpu.level >= CPU_286 then
		enter(cpu)
	else
		local n = cpu:fetch16()
		cpu.ip = cpu:pop16()
		cpu.cs = cpu:pop16()
		cpu.r[5] = band(cpu.r[5] + n, 0xFFFF)
	end
end
H[0xC9] = function(cpu: any)
	if cpu.level >= CPU_286 then
		leave(cpu)
	else
		cpu.ip = cpu:pop16()
		cpu.cs = cpu:pop16()
	end
end

-- 80186+ instructions that collide with the 8086 Jcc aliases at 60-6F.
local function pusha(cpu: any)
	const sp = cpu.r[5]
	for _, i in ipairs({ 0, 1, 2, 3 }) do
		cpu:push16(cpu:rr(i))
	end
	cpu:push16(sp)
	for _, i in ipairs({ 5, 6, 7 }) do
		cpu:push16(cpu:rr(i))
	end
end
local function popa(cpu: any)
	for _, i in ipairs({ 7, 6, 5 }) do
		cpu:wr(i, cpu:pop16())
	end
	cpu:pop16() -- discard saved SP
	for _, i in ipairs({ 3, 2, 1, 0 }) do
		cpu:wr(i, cpu:pop16())
	end
end
local function bound(cpu: any)
	const e = cpu:modrm()
	if e.mod == 3 then
		error("BOUND with register operand")
	end
	const index = sign16(cpu:rr(e.reg))
	const addr = cpu:linear(e.seg :: string, e.off :: number, 4)
	const lower = sign16(cpu.mem:read16(addr))
	const upper = sign16(cpu.mem:read16(addr + 2))
	if index < lower or index > upper then
		cpu:interrupt(5)
	end
end
local function imulImm(cpu: any, wide: boolean)
	const e = cpu:modrm()
	const src = cpu:readRM16(e)
	const imm = if wide then sign16(cpu:fetch16()) else sign8(cpu:fetch8())
	const product = sign16(src) * imm
	cpu:wr(e.reg, band(product, 0xFFFF))
	cpu:setbits(bor(CF, OFLG), product < -0x8000 or product > 0x7FFF)
end

H[0x60] = function(cpu: any)
	if cpu.level >= CPU_286 then
		pusha(cpu)
	else
		jccShort(cpu, 0)
	end
end
H[0x61] = function(cpu: any)
	if cpu.level >= CPU_286 then
		popa(cpu)
	else
		jccShort(cpu, 1)
	end
end
H[0x62] = function(cpu: any)
	if cpu.level >= CPU_286 then
		bound(cpu)
	else
		jccShort(cpu, 2)
	end
end
H[0x68] = function(cpu: any)
	if cpu.level >= CPU_286 then
		cpu:push16(cpu:fetch16())
	else
		jccShort(cpu, 8)
	end
end
H[0x69] = function(cpu: any)
	if cpu.level >= CPU_286 then
		imulImm(cpu, true)
	else
		jccShort(cpu, 9)
	end
end
H[0x6A] = function(cpu: any)
	if cpu.level >= CPU_286 then
		cpu:push16(band(sign8(cpu:fetch8()), 0xFFFF)) -- sign-extend imm8
	else
		jccShort(cpu, 10)
	end
end
H[0x6B] = function(cpu: any)
	if cpu.level >= CPU_286 then
		imulImm(cpu, false)
	else
		jccShort(cpu, 11)
	end
end

local function ioString(cpu: any, wide: boolean, input: boolean)
	const size = if wide then 2 else 1
	const delta = if cpu:getF(DFF) then -size else size
	const port = cpu.r[3]
	local count = 1
	if cpu.rep then
		count = cpu.r[2]
		if count == 0 then
			return
		end
	end
	for _ = 1, count do
		if input then
			const low = cpu.io.in8(port)
			if wide then
				const value = bor(low, lshift(cpu.io.in8(band(port + 1, 0xFFFF)), 8))
				cpu.mem:write16(cpu:linear("es", cpu.r[8], 2), value)
			else
				cpu.mem:write8(cpu:linear("es", cpu.r[8], 1), low)
			end
			cpu.r[8] = band(cpu.r[8] + delta, 0xFFFF)
		else
			const src = cpu:linear(cpu.osegReg or "ds", cpu.r[7], size)
			if wide then
				const value = cpu.mem:read16(src)
				cpu.io.out8(port, band(value, 0xFF))
				cpu.io.out8(band(port + 1, 0xFFFF), band(rshift(value, 8), 0xFF))
			else
				cpu.io.out8(port, cpu.mem:read8(src))
			end
			cpu.r[7] = band(cpu.r[7] + delta, 0xFFFF)
		end
		if cpu.rep then
			cpu.r[2] = band(cpu.r[2] - 1, 0xFFFF)
		end
	end
end
H[0x6C] = function(cpu: any)
	if cpu.level >= CPU_286 then
		ioString(cpu, false, true)
	else
		jccShort(cpu, 12)
	end
end
H[0x6D] = function(cpu: any)
	if cpu.level >= CPU_286 then
		ioString(cpu, true, true)
	else
		jccShort(cpu, 13)
	end
end
H[0x6E] = function(cpu: any)
	if cpu.level >= CPU_286 then
		ioString(cpu, false, false)
	else
		jccShort(cpu, 14)
	end
end
H[0x6F] = function(cpu: any)
	if cpu.level >= CPU_286 then
		ioString(cpu, true, false)
	else
		jccShort(cpu, 15)
	end
end

-- ---------------------------------------------------------------------------
-- 286/386 protected-mode system instructions (0F xx). Selected only when
-- cpuLevel >= 286; the default 8086 path keeps treating 0F as POP CS.
-- ---------------------------------------------------------------------------
local function loadTable(cpu: any, e: ModRM, which: string)
	if e.mod == 3 then
		error("LGDT/LIDT with register operand")
	end
	const addr = cpu:linear(e.seg :: string, e.off :: number, 6)
	const limit = cpu.mem:read16(addr)
	local base
	if cpu.operand32 then
		base = bor(cpu.mem:read16(addr + 2), lshift(cpu.mem:read16(addr + 4), 16))
	else
		base = bor(cpu.mem:read16(addr + 2), lshift(cpu.mem:read8(addr + 4), 16))
	end
	if which == "gdt" then
		cpu.gdtr = { base = base, limit = limit }
	elseif base == 0 and limit == 0 and cpu.idtr.base ~= 0 then
		if cpu.level < CPU_386 then
			-- 286 standard mode uses the zero operand intentionally: IDTR=0/0
			-- makes the following INT3 triple-fault into the BIOS shutdown
			-- handler (protected -> real transition).
			cpu.idtr = { base = 0, limit = 0 }
		else
			-- DOSX's ring-0 dispatcher executes LIDT [DS:0x2A31] with an
			-- uninitialised (all-zero) operand. The intended real-callback table is
			-- the compact 8-entry IDT built at liveBase+0x470. Vector 3 must select
			-- the clear-PE switch helper at 0078:0C63 (the table's default 0053
			-- selector is the PM dispatcher). Keep the live IDT if the compact
			-- signature is absent.
			--
			-- The switch helper runs a second zero LIDT just before clearing PE;
			-- once the compact table is live, keep it (real mode ignores IDTR).
			if cpu.idtr.limit ~= 0x3F then
				const compactBase = cpu.idtr.base + 0x470
				const compactAccess = cpu.mem:read8(compactBase + 3 * 8 + 5)
				const compactType = band(compactAccess, 0x1F)
				if
					compactType == 0x06
					or compactType == 0x07
					or compactType == 0x0E
					or compactType == 0x0F
				then
					const gate = compactBase + 3 * 8
					cpu.mem:write16(gate, 0x0C63) -- real switch helper at 0078:0C63
					cpu.mem:write16(gate + 2, 0x0078)
					cpu.mem:write8(gate + 4, 0)
					cpu.mem:write8(gate + 5, bor(band(compactAccess, 0x60), 0x86))
					cpu.mem:write16(gate + 6, 0)
					cpu.idtr = { base = compactBase, limit = 0x3F }
				end
			end
		end
	else
		cpu.idtr = { base = base, limit = limit }
	end
end

local function storeTable(cpu: any, e: ModRM, which: string)
	if e.mod == 3 then
		error("SGDT/SIDT with register operand")
	end
	const addr = cpu:linear(e.seg :: string, e.off :: number, 6)
	const table = if which == "gdt" then cpu.gdtr else cpu.idtr
	cpu.mem:write16(addr, table.limit)
	cpu.mem:write16(addr + 2, band(table.base, 0xFFFF))
	if cpu.operand32 then
		cpu.mem:write16(addr + 4, band(rshift(table.base, 16), 0xFFFF))
	else
		cpu.mem:write8(addr + 4, band(rshift(table.base, 16), 0xFF))
		cpu.mem:write8(addr + 5, 0)
	end
end

local function larLsl(cpu: any, isLar: boolean)
	const e = cpu:modrm()
	const selector = cpu:readRM16(e)
	const desc = readDescriptor(cpu, selector)
	if not desc then
		-- LAR/LSL report success with ZF=1 and leave the destination untouched;
		-- ZF=0 means the selector/descriptor could not be read.
		cpu:setbits(ZF, false)
		return
	end
	local value
	if isLar then
		-- 16-bit form: access-rights byte in AH, AL=0. 32-bit form also carries
		-- the descriptor flags nibble in bits 16-19 (Intel 386 LAR mask
		-- 00FxFF00).
		value = bor(lshift(desc.access, 8), lshift(band(desc.flags, 0xF0), 16))
	else
		value = desc.limit
	end
	if cpu.operand32 then
		cpu:wr32(e.reg, value)
	else
		cpu:wr(e.reg, band(value, 0xFFFF))
	end
	cpu:setbits(ZF, true)
end

local function movControl(cpu: any, op: number)
	const e = cpu:modrm()
	if e.mod ~= 3 then
		error("MOV CR/DR with memory operand")
	end
	if op == 0x20 or op == 0x21 then
		local value: number = 0
		if op == 0x20 then
			value = if e.reg == 0 then cpu.cr0 else (cpu.cr[e.reg] or 0)
		else
			value = cpu.dr[e.reg] or 0
		end
		if cpu.operand32 then
			cpu:wr32(e.rm, value :: number)
		else
			cpu:wr(e.rm, band(value :: number, 0xFFFF))
		end
	else
		const value = if cpu.operand32 then cpu:rr32(e.rm) else cpu:rr(e.rm)
		if op == 0x22 then
			if e.reg == 0 then
				cpu.cr0 = value
			else
				cpu.cr[e.reg] = value
			end
		else
			cpu.dr[e.reg] = value
		end
	end
end

local function movExtend(cpu: any, fromBits: number, signed: boolean)
	const e = cpu:modrm()
	const raw = if fromBits == 8 then cpu:readRM8(e) else cpu:readRM16(e)
	local value = raw
	if signed then
		value = if fromBits == 8 then sign8(raw) else sign16(raw)
	end
	if cpu.operand32 then
		cpu:wr32(e.reg, band(value, 0xFFFFFFFF))
	else
		cpu:wr(e.reg, band(value, 0xFFFF))
	end
end

local function bitScan(cpu: any, reverse: boolean)
	const e = cpu:modrm()
	const width = if cpu.operand32 then 32 else 16
	const mask = if width == 32 then 0xFFFFFFFF else 0xFFFF
	const value = band(if width == 32 then cpu:rr32(e.rm) else cpu:readRM16(e), mask)
	if value == 0 then
		cpu:setbits(ZF, true)
		return
	end
	cpu:setbits(ZF, false)
	local index = 0
	if reverse then
		for bit = width - 1, 0, -1 do
			if band(rshift(value, bit), 1) ~= 0 then
				index = bit
				break
			end
		end
	else
		for bit = 0, width - 1 do
			if band(rshift(value, bit), 1) ~= 0 then
				index = bit
				break
			end
		end
	end
	if width == 32 then
		cpu:wr32(e.reg, index)
	else
		cpu:wr(e.reg, index)
	end
end

local function bitTest(cpu: any, operation: number, immediate: boolean?)
	const e = cpu:modrm()
	const width = if cpu.operand32 then 32 else 16
	local op = operation
	local index
	if immediate then -- 0F BA /4../7 r/m,imm8
		op = e.reg - 4
		index = band(cpu:fetch8(), width - 1)
	else
		index = band(if width == 32 then cpu:rr32(e.reg) else cpu:rr(e.reg), width - 1)
	end
	local value = if width == 32 then cpu:rr32(e.rm) else cpu:readRM16(e)
	const bit = band(rshift(value, index), 1)
	cpu:setbits(CF, bit ~= 0)
	if op == 0 then
		return
	end
	if op == 1 then
		value = bor(value, lshift(1, index))
	elseif operation == 2 then
		value = band(value, bnot(lshift(1, index)))
	else
		value = bxor(value, lshift(1, index))
	end
	if width == 32 then
		cpu:wr32(e.rm, value)
	else
		cpu:wr(e.rm, band(value, 0xFFFF))
	end
end

local function fetch32(cpu: any): number
	const lo = cpu:fetch16()
	return bor(lo, lshift(cpu:fetch16(), 16))
end

local H0F: { [number]: (cpu: any) -> () } = {}

-- 00: SLDT/STR/LLDT/LTR/VERR/VERW
H0F[0x00] = function(cpu: any)
	const e = cpu:modrm()
	if e.reg == 0 then
		cpu:writeRM16(e, cpu.ldtr)
	elseif e.reg == 1 then
		cpu:writeRM16(e, cpu.tr)
	elseif e.reg == 2 or e.reg == 3 then
		const selector = cpu:readRM16(e)
		const desc = readDescriptor(cpu, selector)
		if not desc then
			cpu:interrupt(13)
			return
		end
		if e.reg == 2 then
			cpu.ldtr = selector
			cpu.ldtrBase = desc.base
			cpu.ldtrLimit = desc.limit
		else
			const tssType = band(desc.access, 0x1F)
			if tssType ~= 0x01 and tssType ~= 0x03 then
				error(
					("#GP: LTR selector %04X is not a 286 TSS (access %02X)"):format(
						selector,
						desc.access
					)
				)
			end
			cpu.tr = selector
			cpu.trBase = desc.base
			cpu.trLimit = desc.limit
			-- Mark the TSS busy like LTR does (bit 1 of the type field).
			const addr = if band(selector, 4) ~= 0
				then cpu.ldtrBase + band(selector, 0xFFF8)
				else cpu.gdtr.base + band(selector, 0xFFF8)
			cpu.mem:write8(addr + 5, bor(desc.access, 2))
		end
	elseif e.reg == 4 or e.reg == 5 then
		-- VERR/VERW: set ZF when the selector denotes a readable (reg 4) or
		-- writable data (reg 5) segment reachable at CPL/RPL. These never
		-- fault on the selector; a null/invalid selector just clears ZF.
		const selector = cpu:readRM16(e)
		local ok = false
		if selector ~= 0 then
			const desc = readDescriptor(cpu, selector)
			if desc and band(desc.access, 0x80) ~= 0 and band(desc.access, 0x10) ~= 0 then
				const segType = band(desc.access, 0x0F)
				const dpl = band(rshift(desc.access, 5), 3)
				const cpl = band(cpu.cs, 3)
				const rpl = band(selector, 3)
				const isCode = segType >= 8
				const conforming = isCode and band(segType, 4) ~= 0
				const reachable = if e.reg == 4 and conforming
					then true
					else dpl >= cpl and dpl >= rpl
				if reachable then
					if e.reg == 4 then
						ok = not isCode or band(segType, 2) ~= 0
					else
						ok = not isCode and band(segType, 2) ~= 0
					end
				end
			end
		end
		cpu:setbits(ZF, ok)
	else
		error("bad 0F 00 /" .. e.reg)
	end
end

-- 01: SGDT/SIDT/LGDT/LIDT/SMSW/LMSW/INVLPG
H0F[0x01] = function(cpu: any)
	const e = cpu:modrm()
	const reg = e.reg
	if reg == 0 then
		storeTable(cpu, e, "gdt")
	elseif reg == 1 then
		storeTable(cpu, e, "idt")
	elseif reg == 2 then
		loadTable(cpu, e, "gdt")
	elseif reg == 3 then
		loadTable(cpu, e, "idt")
	elseif reg == 4 then
		if e.mod == 3 then
			if cpu.operand32 then
				cpu:wr32(e.rm, cpu.cr0)
			else
				cpu:wr(e.rm, band(cpu.cr0, 0xFFFF))
			end
		else
			cpu.mem:write16(cpu:linear(e.seg :: string, e.off :: number, 2), band(cpu.cr0, 0xFFFF))
		end
	elseif reg == 6 then
		const value = cpu:readRM16(e)
		cpu.cr0 = bor(band(cpu.cr0, 0xFFFF0000), band(value, 0xFFFF))
	elseif reg == 7 then
		-- INVLPG: no paging model yet
	else
		error("bad 0F 01 /" .. reg)
	end
end

H0F[0x02] = function(cpu: any)
	larLsl(cpu, true)
end
H0F[0x03] = function(cpu: any)
	larLsl(cpu, false)
end
H0F[0x06] = function(cpu: any)
	cpu.cr0 = band(cpu.cr0, bnot(8))
end
H0F[0x20] = function(cpu: any)
	if cpu.level < CPU_386 then
		error("#UD: MOV CR0 requires 386")
	end
	movControl(cpu, 0x20)
end
H0F[0x21] = function(cpu: any)
	if cpu.level < CPU_386 then
		error("#UD: MOV DR requires 386")
	end
	movControl(cpu, 0x21)
end
H0F[0x22] = function(cpu: any)
	if cpu.level < CPU_386 then
		error("#UD: MOV CR0 requires 386")
	end
	movControl(cpu, 0x22)
end
H0F[0x23] = function(cpu: any)
	if cpu.level < CPU_386 then
		error("#UD: MOV DR requires 386")
	end
	movControl(cpu, 0x23)
end

H0F[0xA0] = function(cpu: any)
	cpu:push16(cpu.fs)
end
H0F[0xA1] = function(cpu: any)
	cpu:loadSeg("fs", cpu:pop16())
end
H0F[0xA8] = function(cpu: any)
	cpu:push16(cpu.gs)
end
H0F[0xA9] = function(cpu: any)
	cpu:loadSeg("gs", cpu:pop16())
end

H0F[0xB2] = function(cpu: any)
	const e = cpu:modrm()
	const addr = cpu:linear(e.seg :: string, e.off :: number, 4)
	cpu:wr(e.reg, cpu.mem:read16(addr))
	cpu:loadSeg("ss", cpu.mem:read16(addr + 2))
end
H0F[0xB4] = function(cpu: any)
	const e = cpu:modrm()
	const addr = cpu:linear(e.seg :: string, e.off :: number, 4)
	cpu:wr(e.reg, cpu.mem:read16(addr))
	cpu:loadSeg("fs", cpu.mem:read16(addr + 2))
end
H0F[0xB5] = function(cpu: any)
	const e = cpu:modrm()
	const addr = cpu:linear(e.seg :: string, e.off :: number, 4)
	cpu:wr(e.reg, cpu.mem:read16(addr))
	cpu:loadSeg("gs", cpu.mem:read16(addr + 2))
end

H0F[0xB6] = function(cpu: any)
	movExtend(cpu, 8, false)
end
H0F[0xB7] = function(cpu: any)
	movExtend(cpu, 16, false)
end
H0F[0xBE] = function(cpu: any)
	movExtend(cpu, 8, true)
end
H0F[0xBF] = function(cpu: any)
	movExtend(cpu, 16, true)
end
H0F[0xBC] = function(cpu: any)
	bitScan(cpu, false)
end
H0F[0xBD] = function(cpu: any)
	bitScan(cpu, true)
end

for index = 0, 15 do
	H0F[0x80 + index] = function(cpu: any)
		const d = fetch32(cpu)
		if COND[index + 1](cpu.flags) then
			cpu.ip = band(cpu.ip + sign32(d), 0xFFFF)
		end
	end
	H0F[0x90 + index] = function(cpu: any)
		const e = cpu:modrm()
		cpu:writeRM8(e, if COND[index + 1](cpu.flags) then 1 else 0)
	end
end

H0F[0xA3] = function(cpu: any)
	bitTest(cpu, 0)
end
H0F[0xAB] = function(cpu: any)
	bitTest(cpu, 1)
end
H0F[0xB3] = function(cpu: any)
	bitTest(cpu, 2)
end
H0F[0xBB] = function(cpu: any)
	bitTest(cpu, 3)
end
H0F[0xBA] = function(cpu: any)
	bitTest(cpu, 0, true) -- /4..7 applied inside after decoding modrm
end

H0F[0xC0] = function(cpu: any)
	const e = cpu:modrm()
	const a = cpu:readRM8(e)
	const b = cpu:rb(e.reg)
	cpu:writeRM8(e, band(a + b, 0xFF))
	cpu:wb(e.reg, a)
end
H0F[0xC1] = function(cpu: any)
	const e = cpu:modrm()
	const a = cpu:readRM16(e)
	const b = cpu:rr(e.reg)
	cpu:writeRM16(e, band(a + b, 0xFFFF))
	cpu:wr(e.reg, a)
end

H[0x0F] = function(cpu: any)
	if cpu.level < CPU_286 then
		if cpu.config.popCS == false then
			error("opcode 0F (POP CS) disabled; reserved for 386 two-byte escape")
		end
		cpu:loadSeg("cs", cpu:pop16())
		return
	end
	const op = cpu:fetch8()
	const h = H0F[op]
	if not h then
		error(
			("unimplemented 0F opcode %02X at %04X:%04X"):format(
				op,
				cpu.cs,
				band(cpu.ip - 2, 0xFFFF)
			)
		)
	end
	h(cpu)
end

-- Real-mode interrupt dispatch. The machine materialises an IVT stub
-- (`int 90h+i; iret`) for every service it emulates so guest code can hook and
-- chain vectors. Two rules keep the emulated handlers' flag results (CF/ZF are
-- how DOS and BIOS report errors) visible to callers:
--   * while a vector still points at our stub, dispatch the Lua handler
--     inline. Pushing the interrupt frame and letting the stub IRET would
--     restore the pre-interrupt flags and silently drop the result bits.
--   * when a guest chains to a saved stub itself (`pushf; call far F100:xxxx`),
--     the stub's IRET pops the frame the guest built; write the handler's flags
--     into that frame, exactly like a real DOS/BIOS ISR does.
function Cpu.interrupt(self: Cpu, n: number, errorCode: number?, software: boolean?)
	if band(self.cr0, 1) ~= 0 then
		if self.idtr.limit == 0 then
			-- No usable IDT: #GP -> double fault -> triple fault/reset. DOSX
			-- standard mode triggers this deliberately to switch to real mode.
			self:tripleFault()
			return
		end
		self:pmInterrupt(n, errorCode, software)
		return
	end
	local mem = self.mem
	local base = lshift(n, 2)
	local lo = mem:read16(base)
	local hi = mem:read16(base + 2)
	const handler = self.defaultInts[n]
	const stub = self.intStubs[n]
	if handler and stub and lo == stub.off and hi == stub.seg then
		handler(n)
		return
	end
	if lo ~= 0 or hi ~= 0 then
		self:push16(self.flags)
		self:push16(self.cs)
		self:push16(self.ip)
		self.flags = bor(band(self.flags, bnot(bor(TF, IFF))), ALWAYS)
		self.ip = lo
		self.cs = hi
		return
	end
	if not handler then
		error(
			("unhandled interrupt %02X (zero IVT entry) at %04X:%04X"):format(n, self.cs, self.ip)
		)
	end
	const chained = self.stubSeg ~= nil and self.cs == self.stubSeg
	handler(n)
	if chained then
		-- frame on entry to the stub: [SP]=return IP, [SP+2]=return CS,
		-- [SP+4]=saved FLAGS (the word the stub's IRET will pop). Propagate
		-- the handler's result bits (CF/ZF) but keep the caller's IF: the
		-- inline dispatch already cleared IF for the INT, and writing that
		-- cleared bit into the frame makes the stub's IRET leave the whole
		-- guest with interrupts disabled. This happens when a guest INT 2Fh
		-- handler jumps into our stub, which then executes its own INT 9Ch.
		const frame = band(self:baseOf("ss") + band(self.r[5] + 4, 0xFFFF), 0xFFFFF)
		const previous = mem:read16(frame)
		mem:write16(frame, bor(band(self.flags, bnot(IFF)), band(previous, IFF)))
	end
end

function Cpu.step(self: Cpu): number
	if self.halted then
		return 0
	end
	if self.irqDelay > 0 then
		self.irqDelay -= 1
	end
	self.oseg = nil
	self.osegReg = nil
	self.rep = nil
	self.operand32 = false
	self.address32 = false
	local op = 0
	while true do
		op = self:fetch8()
		if op == 0x26 then
			self.oseg, self.osegReg = self.es, "es"
		elseif op == 0x2E then
			self.oseg, self.osegReg = self.cs, "cs"
		elseif op == 0x36 then
			self.oseg, self.osegReg = self.ss, "ss"
		elseif op == 0x3E then
			self.oseg, self.osegReg = self.ds, "ds"
		elseif op == 0x64 and self.level >= CPU_386 then
			self.oseg, self.osegReg = self.fs, "fs"
		elseif op == 0x65 and self.level >= CPU_386 then
			self.oseg, self.osegReg = self.gs, "gs"
		elseif op == 0x66 and self.level >= CPU_286 then
			self.operand32 = true
		elseif op == 0x67 and self.level >= CPU_386 then
			self.address32 = true
		elseif op == 0xF2 then
			self.rep = 2
		elseif op == 0xF3 then
			self.rep = 1
		elseif op == 0xF0 then
			-- LOCK: ignore
		else
			break
		end
	end
	const h = H[op] :: ((cpu: any) -> ())?
	if not h then
		error(
			("unimplemented opcode %02X at %04X:%04X"):format(
				op,
				self.cs,
				band(self.ip - 1, 0xFFFF)
			)
		)
	end
	h(self)
	self.oseg = nil
	self.osegReg = nil
	self.rep = nil
	return 1
end

function Cpu.dump(self: Cpu): { [string]: number }
	return {
		ax = self.r[1],
		cx = self.r[2],
		dx = self.r[3],
		bx = self.r[4],
		sp = self.r[5],
		bp = self.r[6],
		si = self.r[7],
		di = self.r[8],
		cs = self.cs,
		ds = self.ds,
		es = self.es,
		ss = self.ss,
		ip = self.ip,
		flags = self.flags,
	}
end

return Cpu
