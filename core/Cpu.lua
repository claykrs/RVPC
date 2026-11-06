--!strict
-- Cpu.lua -- 8086/286/386/486 integer core (bit32 only, no native bitwise ops).
-- r[1..8] = AX CX DX BX SP BP SI DI; SP is r[5]; 8-bit reg i<4 low / i>=4 high.
-- rHi[1..8] holds bits 16-31 on the 386/486 path. EIP is kept in `ip` as a full
-- 32-bit value; 16-bit code masks it to 64 KiB on every fetch.

const band, bor, bxor, bnot, lshift, rshift =
	bit32.band, bit32.bor, bit32.bxor, bit32.bnot, bit32.lshift, bit32.rshift

const CF, PF, AF, ZF, SF, TF, IFF, DFF, OFLG = 1, 4, 16, 64, 128, 256, 512, 1024, 2048
const RF = 0x10000
const VM = 0x20000
const NT = 0x4000
const AC = 0x40000
const ALWAYS = 2
const FLAGMASK = 4053 -- CF|PF|AF|ZF|SF|TF|IF|DF|OF (0xFD5)
const FLAGMASK_386 = bor(FLAGMASK, 0x7000, RF, VM, AC) -- 386: IOPL/NT/RF/VM/AC
const FIXEDFLAGS = bor(0xF000, ALWAYS) -- bits 15-12 plus bit 1 read as 1 on 8086
const FIXEDFLAGS_286 = ALWAYS -- 286 real mode: bits 12-15 read as 0

const CR0_PE = 0x00000001
const CR0_EM = 0x00000004
const CR0_TS = 0x00000008
const CR0_WP = 0x00010000
const CR0_PG = 0x80000000

-- Paging TLB entry layout: bits 1-20 hold the frame (phys>>12 for 4 KiB pages,
-- phys>>22 for 4 MiB pages), bit 0 records that the PTE dirty bit is already
-- set, bit 21/22 cache the R/W and U/S AND of PDE and PTE, bit 23 marks 4 MiB
-- entries, bit 24 the PDE PAT bit the reserved-bit fault checks, bits 25-31
-- the epoch that turns a full flush into an increment.
const TLB_D = 1
const TLB_FRAME = lshift(0xFFFFF, 1)
const TLB_FRAME_4M = lshift(0x3FF, 1)
const TLB_RW = lshift(1, 21)
const TLB_US = lshift(1, 22)
const TLB_4M = lshift(1, 23)
const TLB_PAT = lshift(1, 24)

-- Unique sentinel used to unwind a faulting instruction after #PF delivery.
-- Cpu.step only catches it when paging is enabled; every other error still
-- propagates to the host as an unimplemented-hardware diagnostic.
const ABORT_INSTRUCTION = { kind = "cpu-abort" }

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
	if value == "386" or value == "486" or value == "586" or value == "pentium" then
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
	in16: ((port: number) -> number)?,
	out16: ((port: number, value: number) -> ())?,
	in32: ((port: number) -> number)?,
	out32: ((port: number, value: number) -> ())?,
}

export type InterruptHandler = (n: number) -> ()

export type Cpu = {
	mem: any,
	io: Io,
	config: any,
	fpu: any?,
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
	cr3: number,
	cr: { number },
	dr: { number },
	-- Software paging TLB: one slot per linear page (2^20 entries), allocated
	-- on the first paged walk. pfTrack remembers physical page-directory and
	-- page-table frames so stores into them can invalidate what maps through.
	tlb: { [number]: number }?,
	tlbEpoch: number,
	pfTrack: { [number]: number },
	pfCount: number,
	baseOperand32: boolean,
	baseAddress32: boolean,
	pageFaults: number,
	lastPageFault: { addr: number, errorCode: number, write: boolean, user: boolean }?,
	inPageFault: boolean,
	aborting: boolean,
	-- Start of the instruction currently executing (architectural fault EIP) and
	-- the pending fault context used when a #PF or synchronous exception frame
	-- is built.
	opIP: number,
	opCS: number,
	faultIP: number?,
	faultCS: number?,
	tsc: number,
	lastIoStringDest: number,
	lastIoStringCount: number,
	lastIoStringPort: number,
	intCounts: { [number]: number },
	traceEnabled: boolean,
	trace: { string },
	traceIndex: number,
	lastIrq: { [string]: number }?,
	lastIrqTrace: { string }?,
	lastIret: { [string]: number }?,
	lastFarCall: { [string]: number }?,
	lastRetf: { [string]: number }?,
	lastSwInt: { [string]: number }?,
	badCsTrace: { string }?,
	gdtr: { base: number, limit: number },
	idtr: { base: number, limit: number },
	ldtr: number,
	ldtrBase: number,
	ldtrLimit: number,
	tr: number,
	trBase: number,
	trLimit: number,
	tr32: boolean,
	operand32: boolean,
	address32: boolean,
	modrmScratch: ModRM,
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
	isProtected: (self: Cpu) -> boolean,
	isV86: (self: Cpu) -> boolean,
	cpl: (self: Cpu) -> number,
	code32: (self: Cpu) -> boolean,
	stack32: (self: Cpu) -> boolean,
	ipMask: (self: Cpu) -> number,
	pagingEnabled: (self: Cpu) -> boolean,
	translatePage: (
		self: Cpu,
		addr: number,
		write: boolean,
		user: boolean,
		fetch: boolean?
	) -> number,
	flushTlb: (self: Cpu) -> (),
	flushTlbPage: (self: Cpu, addr: number) -> (),
	trackPageFrame: (self: Cpu, frame: number, kind: number) -> (),
	invalidatePageTableWrite: (self: Cpu, addr: number) -> (),
	pageFault: (
		self: Cpu,
		addr: number,
		write: boolean,
		user: boolean,
		reserved: boolean,
		fetch: boolean,
		present: boolean?
	) -> (),
	fault: (self: Cpu, n: number, errorCode: number?) -> (),
	read8: (self: Cpu, addr: number, supervisor: boolean?) -> number,
	read16: (self: Cpu, addr: number, supervisor: boolean?) -> number,
	read32: (self: Cpu, addr: number, supervisor: boolean?) -> number,
	write8: (self: Cpu, addr: number, value: number, supervisor: boolean?) -> (),
	write16: (self: Cpu, addr: number, value: number, supervisor: boolean?) -> (),
	write32: (self: Cpu, addr: number, value: number, supervisor: boolean?) -> (),
	reset: (self: Cpu) -> (),
	tripleFault: (self: Cpu) -> (),
	loadSeg: (self: Cpu, reg: string, selector: number) -> (),
	farCall: (self: Cpu, selector: number, offset: number, isCall: boolean) -> (),
	taskSwitch: (self: Cpu, newSelector: number, kind: string) -> (),
	baseOf: (self: Cpu, reg: string) -> number,
	linear: (self: Cpu, reg: string, off: number, size: number) -> number,
	fetch8: (self: Cpu) -> number,
	fetch16: (self: Cpu) -> number,
	fetch32: (self: Cpu) -> number,
	getSP: (self: Cpu) -> number,
	setSP: (self: Cpu, value: number) -> (),
	pushValue: (self: Cpu, v: number, width: number) -> (),
	popValue: (self: Cpu, width: number) -> number,
	push16: (self: Cpu, v: number) -> (),
	pop16: (self: Cpu) -> number,
	push32: (self: Cpu, v: number) -> (),
	pop32: (self: Cpu) -> number,
	setbits: (self: Cpu, mask: number, on: boolean) -> (),
	getF: (self: Cpu, mask: number) -> boolean,
	setSZP: (self: Cpu, res: number, w: any) -> (),
	modrm: (self: Cpu) -> ModRM,
	readRM8: (self: Cpu, e: ModRM) -> number,
	writeRM8: (self: Cpu, e: ModRM, v: number) -> (),
	readRM16: (self: Cpu, e: ModRM) -> number,
	writeRM16: (self: Cpu, e: ModRM, v: number) -> (),
	readRM32: (self: Cpu, e: ModRM) -> number,
	writeRM32: (self: Cpu, e: ModRM, v: number) -> (),
	readRM: (self: Cpu, e: ModRM) -> number,
	writeRM: (self: Cpu, e: ModRM, v: number) -> (),
	rrw: (self: Cpu, i: number) -> number,
	wrw: (self: Cpu, i: number, v: number) -> (),
	interrupt: (self: Cpu, n: number, errorCode: number?, software: boolean?) -> (),
	pmInterrupt: (self: Cpu, n: number, errorCode: number?, software: boolean?) -> (),
	executeStep: (self: Cpu) -> number,
	step: (self: Cpu) -> number,
	traceDump: (self: Cpu, count: number) -> { string },
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
	self.fpu = self.config.fpu
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
	self.tr32 = false
	self.operand32 = false
	self.address32 = false
	self.baseOperand32 = false
	self.baseAddress32 = false
	self.modrmScratch = { mod = 0, reg = 0, rm = 0, off = nil, addr = nil, seg = nil }
	self.halted = false
	self.irqDelay = 0
	self.oseg = nil
	self.osegReg = nil
	self.rep = nil
	self.cr3 = 0
	self.tlb = nil
	self.tlbEpoch = 1
	self.pfTrack = {}
	self.pfCount = 0
	self.pageFaults = 0
	self.lastPageFault = nil
	self.inPageFault = false
	self.aborting = false
	self.opIP = 0
	self.opCS = 0
	self.faultIP = nil
	self.faultCS = nil
	self.tsc = 0
	self.lastIoStringDest = 0
	self.lastIoStringCount = 0
	self.lastIoStringPort = 0
	self.intCounts = {}
	self.traceEnabled = false
	self.trace = {}
	self.traceIndex = 0
	self.lastIrq = nil
	self.lastIrqTrace = nil
	self.lastIret = nil
	self.lastFarCall = nil
	self.lastRetf = nil
	self.lastSwInt = nil
	self.badCsTrace = nil
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
		self.cr0 = bor(self.cr0, CR0_PE)
	else
		self.cr0 = band(self.cr0, bnot(CR0_PE))
	end
	self.cr[0] = self.cr0
end

function Cpu.isProtected(self: Cpu): boolean
	return band(self.cr0, CR0_PE) ~= 0
end

function Cpu.isV86(self: Cpu): boolean
	return self:isProtected() and band(self.flags, VM) ~= 0
end

-- Current privilege level. V86 always executes at ring 3 even though no
-- protected-mode selector is loaded.
function Cpu.cpl(self: Cpu): number
	if self:isV86() then
		return 3
	end
	if self:isProtected() then
		return band(self.cs, 3)
	end
	return 0
end

-- CS.D controls the default operand/address size and EIP width. Real mode and
-- V86 are 16-bit unless the V86 CS descriptor set D=1.
function Cpu.code32(self: Cpu): boolean
	if not self:isProtected() then
		return false
	end
	return band(self.segFlags.cs or 0, 0x40) ~= 0
end

function Cpu.stack32(self: Cpu): boolean
	return self:isProtected() and band(self.segFlags.ss or 0, 0x40) ~= 0
end

function Cpu.ipMask(self: Cpu): number
	if band(self.cr0, CR0_PE) ~= 0 and band(self.segFlags.cs or 0, 0x40) ~= 0 then
		return 0xFFFFFFFF
	end
	return 0xFFFF
end

function Cpu.pagingEnabled(self: Cpu): boolean
	return band(self.cr0, CR0_PG) ~= 0
end

function Cpu.fault(self: Cpu, n: number, errorCode: number?)
	self.faultIP = self.opIP
	self.faultCS = self.opCS
	self:interrupt(n, errorCode, false)
end

-- Deliver a page fault. The exception frame is built by the normal IDT path;
-- the sentinel unwinds the faulting instruction so no partial architectural
-- result escapes. Nested faults during frame construction are fatal.
function Cpu.pageFault(
	self: Cpu,
	addr: number,
	write: boolean,
	user: boolean,
	reserved: boolean,
	fetch: boolean,
	present: boolean?
)
	self.pageFaults += 1
	local errorCode = if present then 1 else 0
	if write then
		errorCode = bor(errorCode, 2)
	end
	if user then
		errorCode = bor(errorCode, 4)
	end
	if reserved then
		errorCode = bor(errorCode, 8)
	end
	if fetch then
		errorCode = bor(errorCode, 16) -- 486 I/D bit
	end
	self.lastPageFault = { addr = addr, errorCode = errorCode, write = write, user = user }
	self.faultIP = self.opIP
	self.faultCS = self.opCS
	if self.inPageFault then
		self:tripleFault()
		self.aborting = true
		error(ABORT_INSTRUCTION, 0)
	end
	self.inPageFault = true
	const ok, _err = pcall(function()
		self:interrupt(14, errorCode, false)
	end)
	self.inPageFault = false
	if not ok then
		self.aborting = true
		error(ABORT_INSTRUCTION, 0)
	end
	self.aborting = true
	error(ABORT_INSTRUCTION, 0)
end

-- Full TLB flush. Bumping the epoch retires every cached entry at once; the
-- 1M-slot table itself only clears when the 7-bit epoch wraps.
function Cpu.flushTlb(self: Cpu)
	local epoch = self.tlbEpoch + 1
	if epoch > 127 then
		epoch = 1
		if self.tlb then
			table.clear(self.tlb)
		end
	end
	self.tlbEpoch = epoch
end

function Cpu.flushTlbPage(self: Cpu, addr: number)
	local tlb = self.tlb
	if tlb then
		tlb[band(rshift(addr, 12), 0xFFFFF)] = 0
	end
end

-- Remember which physical frames back page directories and page tables so
-- stores into them can invalidate the entries that map through the changed
-- slot. Frames outside RAM are skipped: stores there are open bus anyway.
function Cpu.trackPageFrame(self: Cpu, frame: number, kind: number)
	if frame >= self.mem.size then
		return
	end
	const old = self.pfTrack[frame]
	if old == nil then
		self.pfTrack[frame] = kind
		self.pfCount += 1
	elseif band(old, kind) == 0 then
		self.pfTrack[frame] = bor(old, kind)
	end
end

-- A paged store landed inside a tracked page-directory/page-table frame. Drop
-- entries that read the changed slot: one PDE slot covers a 4 MiB linear
-- region, one PTE slot the same offset in every page table. The walker's own
-- accessed/dirty writeback bypasses this path on purpose - A/D updates never
-- change the mapping. Device/DMA writes to page tables are not tracked; no
-- real guest programs page tables over DMA.
function Cpu.invalidatePageTableWrite(self: Cpu, addr: number)
	const frame = band(addr, 0xFFFFF000)
	const kind = self.pfTrack[frame]
	if kind == nil or self.tlb == nil then
		return
	end
	local slot = rshift(addr - frame, 2)
	const slotEnd = rshift(addr + 3 - frame, 2)
	while slot <= slotEnd and slot < 1024 do
		if band(kind, 1) ~= 0 then
			const base = lshift(slot, 10)
			for index = 0, 1023 do
				self.tlb[base + index] = 0
			end
		end
		if band(kind, 2) ~= 0 then
			for dir = 0, 1023 do
				self.tlb[bor(lshift(dir, 10), slot)] = 0
			end
		end
		slot += 1
	end
end

-- 386 two-level paging with a software TLB. CR3 is a physical address; the
-- page-table walk only runs on a miss. Hits re-check U/S and R/W (and the 4 MiB
-- reserved-bit condition) against the current access and CR0.WP, so every #PF
-- carries the same error-code bits an uncached walk would produce. 4 MiB pages
-- require CR4.PSE, which this 486-class core leaves disabled, but accepting a
-- present 4 MiB PDE is useful for guests that set it by hand.
function Cpu.translatePage(
	self: Cpu,
	addr: number,
	write: boolean,
	user: boolean,
	fetch: boolean?
): number
	if not self:pagingEnabled() then
		return addr
	end
	const vpn = rshift(addr, 12)
	if self.tlb == nil then
		self.tlb = table.create(0x100000) :: { [number]: number }
	end
	local tlb = self.tlb :: { [number]: number }
	local entry = tlb[vpn]
	if entry ~= nil and band(rshift(entry, 25), 0x7F) == self.tlbEpoch then
		if write and band(entry, TLB_D) == 0 then
			-- First write to this page since a read cached it: the PTE still
			-- needs its dirty bit, and only the walk does that bookkeeping.
			tlb[vpn] = 0
		else
			if user and band(entry, TLB_US) == 0 then
				self:pageFault(addr, write, user, false, fetch or false, true)
			end
			if write and band(entry, TLB_RW) == 0 and (user or band(self.cr0, CR0_WP) ~= 0) then
				self:pageFault(addr, write, user, false, fetch or false, true)
			end
			if band(entry, TLB_4M) ~= 0 then
				if band(addr, 0x3FF000) ~= 0 and band(entry, TLB_PAT) ~= 0 then
					self:pageFault(addr, write, user, true, fetch or false, true)
				end
				return lshift(band(entry, TLB_FRAME_4M), 21) + band(addr, 0x3FFFFF)
			end
			return lshift(band(entry, TLB_FRAME), 11) + band(addr, 0xFFF)
		end
	end
	const dirBase = band(self.cr3, 0xFFFFF000)
	const dirIndex = rshift(addr, 22)
	const pdeAddr = dirBase + dirIndex * 4
	const pde = self.mem:read32(pdeAddr)
	if band(pde, 1) == 0 then
		self:pageFault(addr, write, user, false, fetch or false)
	end
	const userPage = band(pde, 4) ~= 0
	const writable = band(pde, 2) ~= 0
	if user and not userPage then
		self:pageFault(addr, write, user, false, fetch or false, true)
	end
	if write and not writable and (user or band(self.cr0, CR0_WP) ~= 0) then
		self:pageFault(addr, write, user, false, fetch or false, true)
	end
	local entryBits = 0
	if userPage then
		entryBits = TLB_US
	end
	if writable then
		entryBits = bor(entryBits, TLB_RW)
	end
	if band(pde, 0x80) ~= 0 then -- 4 MiB page (PSE)
		if band(addr, 0x3FF000) ~= 0 and band(pde, 0x40000000) ~= 0 then
			self:pageFault(addr, write, user, true, fetch or false, true)
		end
		self:trackPageFrame(dirBase, 1)
		tlb[vpn] = bor(
			entryBits,
			TLB_4M,
			TLB_D,
			if band(pde, 0x40000000) ~= 0 then TLB_PAT else 0,
			rshift(band(pde, 0xFFC00000), 21),
			lshift(self.tlbEpoch, 25)
		)
		return band(pde, 0xFFC00000) + band(addr, 0x3FFFFF)
	end
	const tableBase = band(pde, 0xFFFFF000)
	const pteAddr = tableBase + band(rshift(addr, 12), 0x3FF) * 4
	const pte = self.mem:read32(pteAddr)
	if band(pte, 1) == 0 then
		self:pageFault(addr, write, user, false, fetch or false)
	end
	if user and band(pte, 4) == 0 then
		self:pageFault(addr, write, user, false, fetch or false, true)
	end
	if write and band(pte, 2) == 0 and (user or band(self.cr0, CR0_WP) ~= 0) then
		self:pageFault(addr, write, user, false, fetch or false, true)
	end
	-- Accessed/dirty bookkeeping, as a real 486 does. The PDE accessed bit is
	-- left alone, exactly as the old uncached walk did.
	const touched = bor(pte, 0x20)
	const withDirty = if write then bor(touched, 0x40) else touched
	if withDirty ~= pte then
		self.mem:write32(pteAddr, withDirty)
	end
	if band(pte, 4) == 0 then
		entryBits = band(entryBits, bnot(TLB_US))
	end
	if band(pte, 2) == 0 then
		entryBits = band(entryBits, bnot(TLB_RW))
	end
	self:trackPageFrame(dirBase, 1)
	self:trackPageFrame(tableBase, 2)
	tlb[vpn] = bor(
		entryBits,
		if band(withDirty, 0x40) ~= 0 then TLB_D else 0,
		rshift(band(pte, 0xFFFFF000), 11),
		lshift(self.tlbEpoch, 25)
	)
	return band(pte, 0xFFFFF000) + band(addr, 0xFFF)
end

-- Linear (post-segmentation) memory access. All instruction and data traffic
-- goes through these helpers so paging applies uniformly, including descriptor
-- and interrupt-table reads.
-- Paging-off is the common case (real mode, DOS extenders, most of SeaBIOS
-- POST). Skip the CPL and page-walk calls entirely when CR0.PG is clear.
function Cpu.read8(self: Cpu, addr: number, supervisor: boolean?): number
	if band(self.cr0, CR0_PG) == 0 then
		return self.mem:read8(addr)
	end
	const user = not supervisor and self:cpl() == 3
	const phys = self:translatePage(addr, false, user, false)
	if self.aborting then
		return 0
	end
	return self.mem:read8(phys)
end

function Cpu.read16(self: Cpu, addr: number, supervisor: boolean?): number
	if band(self.cr0, CR0_PG) == 0 then
		return self.mem:read16(addr)
	end
	const user = not supervisor and self:cpl() == 3
	const phys = self:translatePage(addr, false, user, false)
	if self.aborting then
		return 0
	end
	return self.mem:read16(phys)
end

function Cpu.read32(self: Cpu, addr: number, supervisor: boolean?): number
	if band(self.cr0, CR0_PG) == 0 then
		return self.mem:read32(addr)
	end
	const user = not supervisor and self:cpl() == 3
	const phys = self:translatePage(addr, false, user, false)
	if self.aborting then
		return 0
	end
	return self.mem:read32(phys)
end

function Cpu.write8(self: Cpu, addr: number, value: number, supervisor: boolean?): ()
	if band(self.cr0, CR0_PG) == 0 then
		self.mem:write8(addr, value)
		return
	end
	const user = not supervisor and self:cpl() == 3
	const phys = self:translatePage(addr, true, user, false)
	if self.aborting then
		return
	end
	self.mem:write8(phys, value)
	if self.pfCount > 0 and self.pfTrack[band(phys, 0xFFFFF000)] ~= nil then
		self:invalidatePageTableWrite(phys)
	end
end

function Cpu.write16(self: Cpu, addr: number, value: number, supervisor: boolean?): ()
	if band(self.cr0, CR0_PG) == 0 then
		self.mem:write16(addr, value)
		return
	end
	const user = not supervisor and self:cpl() == 3
	const phys = self:translatePage(addr, true, user, false)
	if self.aborting then
		return
	end
	self.mem:write16(phys, value)
	if self.pfCount > 0 and self.pfTrack[band(phys, 0xFFFFF000)] ~= nil then
		self:invalidatePageTableWrite(phys)
	end
end

function Cpu.write32(self: Cpu, addr: number, value: number, supervisor: boolean?): ()
	if band(self.cr0, CR0_PG) == 0 then
		self.mem:write32(addr, value)
		return
	end
	const user = not supervisor and self:cpl() == 3
	const phys = self:translatePage(addr, true, user, false)
	if self.aborting then
		return
	end
	self.mem:write32(phys, value)
	if self.pfCount > 0 and self.pfTrack[band(phys, 0xFFFFF000)] ~= nil then
		self:invalidatePageTableWrite(phys)
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
	self.cr3 = 0
	self.tlb = nil
	self.tlbEpoch = 1
	self.pfTrack = {}
	self.pfCount = 0
	self.cr = { 0, 0, 0, 0 }
	self.dr = { 0, 0, 0, 0 }
	self.inPageFault = false
	self.aborting = false
	self.faultIP = nil
	self.faultCS = nil
	self.opIP = 0
	self.opCS = 0
	self.tsc = 0
	self.intCounts = {}
	self.gdtr = { base = 0, limit = 0 }
	self.idtr = { base = 0, limit = 0 }
	self.ldtr = 0
	self.ldtrBase = 0
	self.ldtrLimit = 0
	self.tr = 0
	self.trBase = 0
	self.trLimit = 0
	self.tr32 = false
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
	if self.fpu then
		self.fpu:reset()
	end
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
	const limitLow = cpu:read16(addr, true)
	const baseLow = cpu:read16(addr + 2, true)
	const baseMid = cpu:read8(addr + 4, true)
	const access = cpu:read8(addr + 5, true)
	const flags = cpu:read8(addr + 6, true)
	const baseHigh = cpu:read8(addr + 7, true)
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
		raw4 = baseMid,
		raw6 = cpu:read16(addr + 6, true), -- gate offset high word
	}
end

-- Refresh a cache if host/test code assigned the segment register directly.
-- Real mode is always a plain paragraph; PM validates through the GDT/LDT.
function Cpu.ensureSeg(self: Cpu, reg: string)
	const selector = getSeg(self, reg)
	if self.segSel[reg] == selector then
		return
	end
	if not self:isProtected() or self:isV86() then
		cacheReal(self, reg, selector)
		return
	end
	self:loadSeg(reg, selector)
end

function Cpu.loadSeg(self: Cpu, reg: string, selector: number)
	selector = band(selector, 0xFFFF)
	if not self:isProtected() or self:isV86() then
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
	offset = band(offset, 0xFFFFFFFF)
	const nearWidth = if self.operand32 then 4 else 2
	if not self:isProtected() or self:isV86() then
		if self.traceEnabled and isCall then
			self.lastFarCall = {
				fromCs = self.cs,
				fromIp = self.ip,
				toCs = selector,
				toIp = offset,
				ss = self.ss,
				sp = self:getSP(),
			}
		end
		if isCall then
			self:pushValue(self.cs, nearWidth)
			self:pushValue(self.ip, nearWidth)
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
	if gateType == 0x01 or gateType == 0x03 or gateType == 0x09 or gateType == 0x0B then
		-- Far CALL/JMP to a TSS: hardware task switch. CALL nests (back-link
		-- + NT), JMP replaces the task outright.
		self:taskSwitch(selector, if isCall then "call" else "jmp")
		return
	end
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
			self:pushValue(self.cs, nearWidth)
			self:pushValue(self.ip, nearWidth)
		end
		self:loadSeg("cs", selector)
		self.ip = offset
		return
	end
	-- Call gate: offset/selector/parameter count are packed in the descriptor.
	const gate32 = gateType == 0x0C
	const gateWidth = if gate32 then 4 else 2
	const gateDpl = band(rshift(desc.access, 5), 3)
	const cpl = self:cpl()
	const rpl = band(selector, 3)
	if gateDpl < math.max(cpl, rpl) then
		error(("#GP: call gate %04X DPL%d below CPL%d/RPL%d"):format(selector, gateDpl, cpl, rpl))
	end
	const targetSelector = band(desc.raw2, 0xFFFF)
	const targetOffset = if gate32
		then band(bor(desc.raw0, lshift(desc.raw6, 16)), 0xFFFFFFFF)
		else band(desc.raw0, 0xFFFF)
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
			self:pushValue(self.cs, gateWidth)
			self:pushValue(self.ip, gateWidth)
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
	local spOff, ssOff
	if self.tr32 then
		spOff = 4 + targetRing * 8
		ssOff = spOff + 4
	else
		spOff = 2 + targetRing * 4
		ssOff = spOff + 2
	end
	if self.trLimit < ssOff + (if self.tr32 then 3 else 1) then
		error(
			("#TS: TSS selector %04X limit %04X too small for ring %d"):format(
				self.tr,
				self.trLimit,
				targetRing
			)
		)
	end
	const newSp0 = if self.tr32
		then self:read32(self.trBase + spOff, true)
		else self:read16(self.trBase + spOff, true)
	const newSs = self:read16(self.trBase + ssOff, true)
	const ssDesc = readDescriptor(self, newSs)
	if not ssDesc or not descriptorIsWritableData(ssDesc) then
		error(("#TS: TSS stack selector %04X invalid for ring %d"):format(newSs, targetRing))
	end
	const oldSs = self.ss
	const oldSp = self:getSP()
	const oldBase = self:baseOf("ss")
	const oldMask = if self:stack32() then 0xFFFFFFFF else 0xFFFF
	const newBase = ssDesc.base
	const newStack32 = band(ssDesc.flags, 0x40) ~= 0
	const newMask = if newStack32 then 0xFFFFFFFF else 0xFFFF
	local newSp = band(newSp0 - paramCount * gateWidth, newMask)
	for index = 0, paramCount - 1 do
		const offsetInFrame = band(oldSp + index * gateWidth, oldMask)
		const value = if gateWidth == 4
			then self:read32(oldBase + offsetInFrame)
			else self:read16(oldBase + offsetInFrame)
		if gateWidth == 4 then
			self:write32(newBase + band(newSp + index * 4, newMask), value, true)
		else
			self:write16(newBase + band(newSp + index * 2, newMask), value, true)
		end
	end
	-- Nested frame (top to bottom): IP, CS, old SP, old SS, params.
	-- A 286/386 CALL through a call gate pushes the old SS:SP and the return
	-- CS:IP only; unlike an interrupt gate it does not push FLAGS.
	if gateWidth == 4 then
		newSp = band(newSp - 4, newMask)
		self:write32(newBase + newSp, oldSs, true)
		newSp = band(newSp - 4, newMask)
		self:write32(newBase + newSp, oldSp, true)
		newSp = band(newSp - 4, newMask)
		self:write32(newBase + newSp, self.cs, true)
		newSp = band(newSp - 4, newMask)
		self:write32(newBase + newSp, self.ip, true)
	else
		newSp = band(newSp - 2, newMask)
		self:write16(newBase + newSp, oldSs, true)
		newSp = band(newSp - 2, newMask)
		self:write16(newBase + newSp, oldSp, true)
		newSp = band(newSp - 2, newMask)
		self:write16(newBase + newSp, self.cs, true)
		newSp = band(newSp - 2, newMask)
		self:write16(newBase + newSp, self.ip, true)
	end
	self:loadSeg("ss", newSs)
	self:setSP(newSp)
	self:loadSeg("cs", targetSelector)
	self.ip = targetOffset
end

-- Hardware task switch: save the current task into its TSS (TR), load the new
-- task's state from the TSS named by newSelector, and maintain the nested-task
-- chain. kind is "jmp" (plain switch, old task unbusies), "call"/"int"
-- (nested: old task stays busy, back-link + NT written into the new task), or
-- "iret" (return through the back-link of a busy task; resumed task keeps the
-- NT from its saved flags so deeper nesting chains keep working).
function Cpu.taskSwitch(self: Cpu, newSelector: number, kind: string)
	newSelector = band(newSelector, 0xFFFF)
	const tsCode = band(newSelector, 0xFFFC)
	if tsCode == 0 then
		self:fault(10, 0)
	end
	if self.tr == 0 then
		error("#TS: task switch with no current TSS (LTR never ran)")
	end
	const desc = readDescriptor(self, newSelector)
	if desc == nil then
		self:fault(10, tsCode)
		return
	end
	if band(desc.access, 0x80) == 0 then
		self:fault(10, tsCode)
		return
	end
	const tssType = band(desc.access, 0x1F)
	const newIs32 = tssType == 0x09 or tssType == 0x0B
	const newBusy = tssType == 0x03 or tssType == 0x0B
	if tssType ~= 0x01 and tssType ~= 0x03 and tssType ~= 0x09 and tssType ~= 0x0B then
		self:fault(10, tsCode)
		return
	end
	if newBusy and kind ~= "iret" then
		self:fault(10, tsCode)
		return
	end
	if desc.limit < (if newIs32 then 0x67 else 0x2B) then
		self:fault(10, tsCode)
		return
	end
	const t = desc.base

	-- Save the current task. The old task's busy bit survives a nested switch
	-- (it is suspended and still linked) and clears for JMP/IRET exits.
	const oldTss = self.trBase
	if self.tr32 then
		self:write32(oldTss + 0x1C, self.cr3, true)
		self:write32(oldTss + 0x20, band(self.ip, self:ipMask()), true)
		self:write32(oldTss + 0x24, self.flags, true)
		for i = 0, 7 do
			self:write32(oldTss + 0x28 + i * 4, self:rr32(i), true)
		end
		self:write32(oldTss + 0x48, self.es, true)
		self:write32(oldTss + 0x4C, self.cs, true)
		self:write32(oldTss + 0x50, self.ss, true)
		self:write32(oldTss + 0x54, self.ds, true)
		self:write32(oldTss + 0x58, self.fs, true)
		self:write32(oldTss + 0x5C, self.gs, true)
	else
		self:write16(oldTss + 0x1A, band(self.ip, 0xFFFF), true)
		self:write16(oldTss + 0x1C, band(self.flags, 0xFFFF), true)
		for i = 0, 7 do
			self:write16(oldTss + 0x1E + i * 2, self:rr(i), true)
		end
		self:write16(oldTss + 0x2E, self.es, true)
		self:write16(oldTss + 0x30, self.cs, true)
		self:write16(oldTss + 0x32, self.ss, true)
		self:write16(oldTss + 0x34, self.ds, true)
	end
	local oldDescAddr = if band(self.tr, 4) ~= 0
		then self.ldtrBase + band(self.tr, 0xFFF8)
		else self.gdtr.base + band(self.tr, 0xFFF8)
	if kind == "jmp" or kind == "iret" then
		local oldAccess = self:read8(oldDescAddr + 5, true)
		self:write8(oldDescAddr + 5, band(oldAccess, 0xFD), true)
	end

	-- Read the new task's register image. segs follows the 32-bit TSS order
	-- ES CS SS DS FS GS; a 16-bit TSS has no FS/GS slots, which load as null.
	local newIp: number
	local newFlags: number
	local newCr3: number? = nil
	local segs: { number }
	if newIs32 then
		newCr3 = band(self:read32(t + 0x1C, true), 0xFFFFF000)
		newIp = self:read32(t + 0x20, true)
		newFlags = self:read32(t + 0x24, true)
		for i = 0, 7 do
			self:wr32(i, self:read32(t + 0x28 + i * 4, true))
		end
		segs = {
			self:read32(t + 0x48, true),
			self:read32(t + 0x4C, true),
			self:read32(t + 0x50, true),
			self:read32(t + 0x54, true),
			self:read32(t + 0x58, true),
			self:read32(t + 0x5C, true),
		}
	else
		newIp = self:read16(t + 0x1A, true)
		newFlags = self:read16(t + 0x1C, true)
		for i = 0, 7 do
			self:wr(i, self:read16(t + 0x1E + i * 2, true))
		end
		segs = {
			self:read16(t + 0x2E, true),
			self:read16(t + 0x30, true),
			self:read16(t + 0x32, true),
			self:read16(t + 0x34, true),
			0,
			0,
		}
	end
	if kind == "call" or kind == "int" then
		self:write16(t + 0x00, self.tr, true)
		newFlags = bor(newFlags, NT)
	end

	-- Mark the new TSS busy and install it as the current task.
	local newDescAddr = if band(newSelector, 4) ~= 0
		then self.ldtrBase + band(newSelector, 0xFFF8)
		else self.gdtr.base + band(newSelector, 0xFFF8)
	if not newBusy then
		local newAccess = self:read8(newDescAddr + 5, true)
		self:write8(newDescAddr + 5, bor(newAccess, 2), true)
	end
	self.tr = newSelector
	self.trBase = t
	self.trLimit = desc.limit
	self.tr32 = newIs32
	if newCr3 and self.cr3 ~= newCr3 then
		self.cr3 = newCr3
		self.cr[3] = newCr3
		self:flushTlb()
	end

	-- Segment loads: data segments first, then SS so the stored SP applies
	-- with the new stack width, then CS last so ipMask follows the new D bit.
	self:loadSeg("es", segs[1])
	self:loadSeg("ds", segs[4])
	self:loadSeg("fs", segs[5])
	self:loadSeg("gs", segs[6])
	self:loadSeg("ss", segs[3])
	if newIs32 then
		self:setSP(self:read32(t + 0x38, true))
	else
		self:setSP(self:read16(t + 0x26, true))
	end
	self:loadSeg("cs", segs[2])
	self.flags = bor(band(newFlags, self.flagMask), self.fixedFlags)
	self.ip = band(newIp, self:ipMask())
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
	const offsetLow = self:read16(addr, true)
	const targetSelector = self:read16(addr + 2, true)
	const access = self:read8(addr + 5, true)
	const offsetHigh = self:read16(addr + 6, true)
	const gateType = band(access, 0x1F)
	if band(access, 0x80) == 0 then
		error(("#NP: INT %02X gate %d not present"):format(n, n))
	end
	if gateType == 0x05 then
		-- Task gate: the DPL check still applies to software INTs, then
		-- delivery is a nested task switch to the gate's TSS selector.
		const gateDpl = band(rshift(access, 5), 3)
		if software and gateDpl < self:cpl() then
			error(("#GP: INT %02X task gate DPL%d below CPL%d"):format(n, gateDpl, self:cpl()))
		end
		self:taskSwitch(targetSelector, "int")
		return
	end
	if gateType ~= 0x06 and gateType ~= 0x07 and gateType ~= 0x0E and gateType ~= 0x0F then
		error(("#GP: INT %02X gate type %02X is not an interrupt/trap gate"):format(n, gateType))
	end
	const gate32 = gateType == 0x0E or gateType == 0x0F
	const frameWidth = if gate32 then 4 else 2
	const cpl = self:cpl()
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
	const targetOffset = if gate32
		then band(bor(offsetLow, lshift(offsetHigh, 16)), 0xFFFFFFFF)
		else band(offsetLow, 0xFFFF)
	const v86 = self:isV86()
	const savedFlags = self.flags
	-- Synchronous exceptions restart at the faulting instruction. Software
	-- INTs and hardware IRQs save the next instruction. IRET must be able to
	-- retry a faulting access after the handler has mapped the page.
	const savedIP = if software then self.ip else (self.faultIP or self.ip)
	const savedCS = if software then self.cs else (self.faultCS or self.cs)
	-- A V86 interrupt switches to ring 0 before the frame is written and before
	-- SS/CS are reloaded from the GDT. Clearing VM here (the saved copy keeps
	-- the guest's VM bit) makes the stack writes supervisor accesses and makes
	-- loadSeg take the protected-mode descriptor path.
	if v86 then
		self.flags = band(self.flags, bnot(VM))
	end
	if targetRing < cpl then
		if self.tr == 0 or self.trBase == 0 then
			error(("#GP: INT %02X needs a loaded TSS for ring %d"):format(n, targetRing))
		end
		if targetRing > 2 then
			error(("#GP: INT %02X unsupported target ring %d"):format(n, targetRing))
		end
		local spOff, ssOff
		if self.tr32 then
			spOff = 4 + targetRing * 8
			ssOff = spOff + 4
		else
			spOff = 2 + targetRing * 4
			ssOff = spOff + 2
		end
		if self.trLimit < ssOff + (if self.tr32 then 3 else 1) then
			error(
				("#TS: TSS selector %04X limit %04X too small for INT %02X"):format(
					self.tr,
					self.trLimit,
					n
				)
			)
		end
		const newSp0 = if self.tr32
			then self:read32(self.trBase + spOff, true)
			else self:read16(self.trBase + spOff, true)
		const newSs = self:read16(self.trBase + ssOff, true)
		const ssDesc = readDescriptor(self, newSs)
		if not ssDesc or not descriptorIsWritableData(ssDesc) then
			error(("#TS: INT %02X stack selector %04X invalid"):format(n, newSs))
		end
		const oldSs = self.ss
		const oldSp = self:getSP()
		const newBase = ssDesc.base
		const newStack32 = band(ssDesc.flags, 0x40) ~= 0
		const newMask = if newStack32 then 0xFFFFFFFF else 0xFFFF
		local newSp = band(newSp0, newMask)
		const pushWidth = if v86 or gate32 then 4 else 2
		const writeStack = function(value: number)
			newSp = band(newSp - pushWidth, newMask)
			if pushWidth == 4 then
				self:write32(newBase + newSp, value, true)
			else
				self:write16(newBase + newSp, value, true)
			end
		end
		-- Virtual-8086 frames additionally preserve the four data segments.
		if v86 then
			writeStack(self.gs)
			writeStack(self.fs)
			writeStack(self.ds)
			writeStack(self.es)
		end
		writeStack(oldSs)
		writeStack(oldSp)
		writeStack(savedFlags)
		writeStack(savedCS)
		writeStack(savedIP)
		if errorCode ~= nil then
			writeStack(errorCode)
		end
		self:loadSeg("ss", newSs)
		self:setSP(newSp)
		self:loadSeg("cs", targetSelector)
		self.ip = targetOffset
	else
		self:pushValue(savedFlags, frameWidth)
		self:pushValue(savedCS, frameWidth)
		self:pushValue(savedIP, frameWidth)
		if errorCode ~= nil then
			self:pushValue(errorCode, frameWidth)
		end
		self:loadSeg("cs", targetSelector)
		self.ip = targetOffset
	end
	self.flags = band(self.flags, bnot(VM))
	self:setbits(TF, false)
	if gateType == 0x06 or gateType == 0x0E then
		self:setbits(IFF, false)
	end
	self.faultIP = nil
	self.faultCS = nil
end

function Cpu.linear(self: Cpu, reg: string, off: number, size: number): number
	local selector
	if reg == "es" then
		selector = self.es
	elseif reg == "cs" then
		selector = self.cs
	elseif reg == "ss" then
		selector = self.ss
	elseif reg == "ds" then
		selector = self.ds
	elseif reg == "fs" then
		selector = self.fs
	elseif reg == "gs" then
		selector = self.gs
	else
		error("bad segment register " .. reg)
	end
	local base = self.segBase[reg]
	if self.segSel[reg] ~= selector then
		base = self:baseOf(reg)
	end
	if band(self.cr0, 1) ~= 0 and size > 0 then
		const limit = self.segLimit[reg]
		if off + size - 1 > limit then
			const kind = if reg == "ss" then "#SS" else "#GP"
			error(
				("%s: %s selector %04X offset %04X size %d exceeds limit %04X"):format(
					kind,
					reg,
					selector,
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
	-- On 386+, a 16-bit register write leaves the upper 16 bits intact.
	-- The 8086/286 have no upper half, so keep it zero there.
	if self.level < CPU_386 then
		self.rHi[i + 1] = 0
	end
end

function Cpu.rr32(self: Cpu, i: number): number
	return bor(self.r[i + 1], lshift(self.rHi[i + 1], 16))
end

function Cpu.wr32(self: Cpu, i: number, v: number)
	self.r[i + 1] = band(v, 0xFFFF)
	self.rHi[i + 1] = band(rshift(v, 16), 0xFFFF)
end

function Cpu.fetch8(self: Cpu): number
	local ip = self.ip
	-- Unpaged code fetch: avoid the generic segment/page/abort wrappers. The
	-- selector check preserves ensureSeg's lazy real-mode reload behavior.
	if self.segSel.cs == self.cs and band(self.cr0, CR0_PG) == 0 then
		const protectedMode = band(self.cr0, CR0_PE) ~= 0
		if not protectedMode or ip <= self.segLimit.cs then
			const b = self.mem:read8(self.segBase.cs + ip)
			const mask = if protectedMode and band(self.segFlags.cs or 0, 0x40) ~= 0
				then 0xFFFFFFFF
				else 0xFFFF
			self.ip = band(ip + 1, mask)
			return b
		end
	end
	local b = self:read8(self:linear("cs", ip, 1))
	self.ip = band(ip + 1, self:ipMask())
	if self.aborting then
		return 0
	end
	return b
end

function Cpu.fetch16(self: Cpu): number
	local ip = self.ip
	if self.segSel.cs == self.cs and band(self.cr0, CR0_PG) == 0 then
		const protectedMode = band(self.cr0, CR0_PE) ~= 0
		const mask = if protectedMode and band(self.segFlags.cs or 0, 0x40) ~= 0
			then 0xFFFFFFFF
			else 0xFFFF
		if (not protectedMode or ip + 1 <= self.segLimit.cs) and ip + 1 <= mask then
			const value = self.mem:read16(self.segBase.cs + ip)
			self.ip = band(ip + 2, mask)
			return value
		end
	end
	const lo = self:fetch8()
	return bor(lo, lshift(self:fetch8(), 8))
end

function Cpu.fetch32(self: Cpu): number
	local ip = self.ip
	if self.segSel.cs == self.cs and band(self.cr0, CR0_PG) == 0 then
		const protectedMode = band(self.cr0, CR0_PE) ~= 0
		const mask = if protectedMode and band(self.segFlags.cs or 0, 0x40) ~= 0
			then 0xFFFFFFFF
			else 0xFFFF
		if (not protectedMode or ip + 3 <= self.segLimit.cs) and ip + 3 <= mask then
			const value = self.mem:read32(self.segBase.cs + ip)
			self.ip = band(ip + 4, mask)
			return value
		end
	end
	const lo = self:fetch16()
	return bor(lo, lshift(self:fetch16(), 16))
end

function Cpu.getSP(self: Cpu): number
	return if self:stack32() then self:rr32(4) else self.r[5]
end

function Cpu.setSP(self: Cpu, value: number)
	if self:stack32() then
		self:wr32(4, value)
	else
		self.r[5] = band(value, 0xFFFF)
	end
end

function Cpu.pushValue(self: Cpu, v: number, width: number)
	const mask = if self:stack32() then 0xFFFFFFFF else 0xFFFF
	const sp = band(self:getSP() - width, mask)
	self:setSP(sp)
	if width == 4 then
		self:write32(self:linear("ss", sp, 4), v)
	elseif width == 2 then
		self:write16(self:linear("ss", sp, 2), v)
	else
		self:write8(self:linear("ss", sp, 1), v)
	end
end

function Cpu.popValue(self: Cpu, width: number): number
	const mask = if self:stack32() then 0xFFFFFFFF else 0xFFFF
	const sp = self:getSP()
	local value
	if width == 4 then
		value = self:read32(self:linear("ss", sp, 4))
	elseif width == 2 then
		value = self:read16(self:linear("ss", sp, 2))
	else
		value = self:read8(self:linear("ss", sp, 1))
	end
	self:setSP(band(sp + width, mask))
	return value
end

function Cpu.push16(self: Cpu, v: number)
	-- Real-mode word stack operations avoid the generic stack-width, segment
	-- translation and paging wrappers. The selector check keeps ensureSeg's
	-- lazy real-mode reload semantics for directly assigned SS.
	if band(self.cr0, CR0_PE) == 0 and self.segSel.ss == self.ss then
		const sp = band(self.r[5] - 2, 0xFFFF)
		self.r[5] = sp
		self.mem:write16(self.segBase.ss + sp, v)
		return
	end
	self:pushValue(v, 2)
end

function Cpu.pop16(self: Cpu): number
	if band(self.cr0, CR0_PE) == 0 and self.segSel.ss == self.ss then
		const sp = self.r[5]
		const value = self.mem:read16(self.segBase.ss + sp)
		self.r[5] = band(sp + 2, 0xFFFF)
		return value
	end
	return self:popValue(2)
end

function Cpu.push32(self: Cpu, v: number)
	self:pushValue(v, 4)
end

function Cpu.pop32(self: Cpu): number
	return self:popValue(4)
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

-- w accepts the historical boolean (false=8-bit, true=16-bit) plus 32 for the
-- 386 operand-size prefix. Keeping the boolean form avoids churning every
-- 8086/286 handler while still giving 32-bit ALU/shift results correct SZP.
function Cpu.setSZP(self: Cpu, res: number, w: any)
	local f = band(self.flags, bnot(ZF + SF + PF))
	if res == 0 then
		f = bor(f, ZF)
	end
	const signBit = if w == 32 then 0x80000000 elseif w == 16 or w == true then 0x8000 else 0x80
	if res >= signBit then
		f = bor(f, SF)
	end
	self.flags = bor(f, PARITY[band(res, 0xFF)])
end

function Cpu.modrm(self: Cpu): ModRM
	-- Reused because no handler retains a decoded ModRM across another decode.
	-- This removes a small table allocation from every memory/register operand.
	local e = self.modrmScratch
	local m = self:fetch8()
	const mod = rshift(m, 6)
	const reg = band(rshift(m, 3), 7)
	const rm = band(m, 7)
	e.mod = mod
	e.reg = reg
	e.rm = rm
	if mod == 3 then
		e.off = nil
		e.addr = nil
		e.seg = nil
		return e
	end
	local off, segReg
	if self.address32 then
		local base: number? = nil
		local index: number? = nil
		local scale = 1
		segReg = "ds"
		if rm == 4 then
			const sib = self:fetch8()
			scale = lshift(1, rshift(sib, 6))
			const indexField = band(rshift(sib, 3), 7)
			const baseField = band(sib, 7)
			if indexField ~= 4 then
				index = self:rr32(indexField)
			end
			if mod == 0 and baseField == 5 then
				off = self:fetch32()
			else
				base = self:rr32(baseField)
				if baseField == 4 or baseField == 5 then
					segReg = "ss"
				end
			end
		elseif mod == 0 and rm == 5 then
			off = self:fetch32()
		else
			base = self:rr32(rm)
			if rm == 5 then
				segReg = "ss"
			end
		end
		if off == nil then
			local displacement = 0
			if mod == 1 then
				displacement = sign8(self:fetch8())
			elseif mod == 2 then
				displacement = self:fetch32()
			end
			off = band((base or 0) + displacement, 0xFFFFFFFF)
		end
		if index then
			off = band((off :: number) + index * scale, 0xFFFFFFFF)
		end
	else
		if mod == 0 and rm == 6 then
			off, segReg = self:fetch16(), "ds"
		else
			const r = self.r
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
				off += sign8(self:fetch8())
			elseif mod == 2 then
				off += self:fetch16()
			end
			off = band(off, 0xFFFF)
		end
	end
	if self.osegReg then
		segReg = self.osegReg
	end
	const offValue = off :: number
	e.off = offValue
	e.addr = self:baseOf(segReg) + offValue
	e.seg = segReg
	return e
end

function Cpu.readRM8(self: Cpu, e: ModRM): number
	if e.mod == 3 then
		return self:rb(e.rm)
	end
	return self:read8(self:linear(e.seg :: string, e.off :: number, 1))
end

function Cpu.writeRM8(self: Cpu, e: ModRM, v: number)
	if e.mod == 3 then
		self:wb(e.rm, v)
	else
		self:write8(self:linear(e.seg :: string, e.off :: number, 1), v)
	end
end

function Cpu.readRM16(self: Cpu, e: ModRM): number
	if e.mod == 3 then
		return self:rr(e.rm)
	end
	return self:read16(self:linear(e.seg :: string, e.off :: number, 2))
end

function Cpu.writeRM16(self: Cpu, e: ModRM, v: number)
	if e.mod == 3 then
		self:wr(e.rm, v)
	else
		self:write16(self:linear(e.seg :: string, e.off :: number, 2), v)
	end
end

function Cpu.readRM32(self: Cpu, e: ModRM): number
	if e.mod == 3 then
		return self:rr32(e.rm)
	end
	return self:read32(self:linear(e.seg :: string, e.off :: number, 4))
end

function Cpu.writeRM32(self: Cpu, e: ModRM, v: number)
	if e.mod == 3 then
		self:wr32(e.rm, v)
	else
		self:write32(self:linear(e.seg :: string, e.off :: number, 4), v)
	end
end

-- Operand-size-directed helpers (16-bit unless the current instruction has a
-- 0x66 prefix and the CPU is a 386+).
function Cpu.readRM(self: Cpu, e: ModRM): number
	if e.mod == 3 then
		if self.operand32 then
			return bor(self.r[e.rm + 1], lshift(self.rHi[e.rm + 1], 16))
		end
		return self.r[e.rm + 1]
	end
	const addr = self:linear(e.seg :: string, e.off :: number, if self.operand32 then 4 else 2)
	if self.operand32 then
		return self:read32(addr)
	end
	return self:read16(addr)
end

function Cpu.writeRM(self: Cpu, e: ModRM, v: number)
	if e.mod == 3 then
		if self.operand32 then
			self.r[e.rm + 1] = band(v, 0xFFFF)
			self.rHi[e.rm + 1] = band(rshift(v, 16), 0xFFFF)
		else
			self.r[e.rm + 1] = band(v, 0xFFFF)
			if self.level < CPU_386 then
				self.rHi[e.rm + 1] = 0
			end
		end
		return
	end
	const addr = self:linear(e.seg :: string, e.off :: number, if self.operand32 then 4 else 2)
	if self.operand32 then
		self:write32(addr, v)
	else
		self:write16(addr, v)
	end
end

function Cpu.rrw(self: Cpu, i: number): number
	if self.operand32 then
		return bor(self.r[i + 1], lshift(self.rHi[i + 1], 16))
	end
	return self.r[i + 1]
end

function Cpu.wrw(self: Cpu, i: number, v: number)
	if self.operand32 then
		self.r[i + 1] = band(v, 0xFFFF)
		self.rHi[i + 1] = band(rshift(v, 16), 0xFFFF)
	else
		self.r[i + 1] = band(v, 0xFFFF)
		-- On 386+, a 16-bit register write leaves the upper 16 bits intact.
		if self.level < CPU_386 then
			self.rHi[i + 1] = 0
		end
	end
end

-- op: 0 ADD, 1 OR, 2 ADC, 3 SBB, 4 AND, 5 SUB, 6 XOR, 7 CMP
-- w: false/8 = byte, true/16 = word, 32 = dword.
local function doALU(cpu: any, op: number, a: number, b: number, w: any): number
	const width = if w == 32 then 32 elseif w == 16 or w == true then 16 else 8
	const maxv = if width == 32 then 0xFFFFFFFF elseif width == 16 then 0xFFFF else 0xFF
	const signv = if width == 32 then 0x80000000 elseif width == 16 then 0x8000 else 0x80
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
	-- Equivalent to three setbits calls plus setSZP, but keeps the flags word
	-- in a local for the common ALU path.
	local f = band(cpu.flags, bnot(bor(CF, OFLG, AF, ZF, SF, PF)))
	if cf then
		f = bor(f, CF)
	end
	if of then
		f = bor(f, OFLG)
	end
	if band(bxor(bxor(a, b), res), 16) ~= 0 then
		f = bor(f, AF)
	end
	if res == 0 then
		f = bor(f, ZF)
	end
	if res >= signv then
		f = bor(f, SF)
	end
	cpu.flags = bor(f, PARITY[band(res, 0xFF)])
	return res
end

-- op: 0 ROL, 1 ROR, 2 RCL, 3 RCR, 4 SHL, 5 SHR, 6 SHL alias, 7 SAR
-- 8086 semantics for the count (not masked; CF/OF as documented). On the
-- 80186+ the shift group also updates SZP for SHL/SHR/SAR (rotates leave SZP
-- alone); Windows 3.0 real-mode code branches on those flags right after a
-- shift, so they cannot be left stale.
local function doShift(cpu: any, op: number, v: number, cnt: number, w: any): number
	const width = if w == 32 then 32 elseif w == 16 or w == true then 16 else 8
	const bits = width
	const maxv = if width == 32 then 0xFFFFFFFF elseif width == 16 then 0xFFFF else 0xFF
	const msb = if width == 32 then 0x80000000 elseif width == 16 then 0x8000 else 0x80
	if cnt == 0 then
		return band(v, maxv)
	end
	-- 386+ masks the count to five bits; an 8086/286 uses the raw CL value.
	if cpu.level >= CPU_386 then
		cnt = band(cnt, 0x1F)
		if cnt == 0 then
			return band(v, maxv)
		end
	end
	local cf = cpu:getF(CF)
	local res, of = band(v, maxv), false

	if op == 4 or op == 6 then
		res = band(v, maxv)
		for _ = 1, cnt do
			cf = band(res, msb) ~= 0
			res = band(lshift(res, 1), maxv)
		end
		of = cnt == 1 and (cf ~= (band(res, msb) ~= 0)) or false
	elseif op == 5 then
		res = band(v, maxv)
		of = cnt == 1 and (band(v, msb) ~= 0) or false
		for _ = 1, cnt do
			cf = band(res, 1) ~= 0
			res = rshift(res, 1)
		end
	elseif op == 7 then
		local sv = if width == 32
			then sign32(band(v, 0xFFFFFFFF))
			elseif width == 16 then sign16(v)
			else sign8(v)
		if cnt >= bits then
			res = sv < 0 and maxv or 0
			cf = sv < 0
		else
			res = band(math.floor(sv / (2 ^ cnt)), maxv)
			cf = band(rshift(band(sv, maxv), cnt - 1), 1) == 1
		end
		of = false
	elseif op == 0 then
		local c = cnt % bits
		if c == 0 then
			res = band(v, maxv)
			cf = band(v, 1) == 1
		else
			res = band(bor(lshift(v, c), rshift(v, bits - c)), maxv)
			cf = band(res, 1) == 1
		end
		of = cnt == 1 and (cf ~= (band(res, msb) ~= 0)) or false
	elseif op == 1 then
		local c = cnt % bits
		if c == 0 then
			res = band(v, maxv)
			cf = band(v, msb) ~= 0
		else
			res = band(bor(rshift(v, c), lshift(v, bits - c)), maxv)
			cf = band(res, msb) ~= 0
		end
		of = cnt == 1 and ((band(res, msb) ~= 0) ~= (band(res, rshift(msb, 1)) ~= 0)) or false
	elseif op == 2 then
		if width == 32 then
			res = band(v, 0xFFFFFFFF)
			for _ = 1, cnt do
				const nextCf = band(res, msb) ~= 0
				res = band(bor(lshift(res, 1), if cf then 1 else 0), 0xFFFFFFFF)
				cf = nextCf
			end
			-- A 33-bit rotate leaves the original CF after a full turn.
			if cnt % 33 == 0 then
				cf = cpu:getF(CF)
			end
		else
			const rotWidth = bits + 1
			const c = cnt % rotWidth
			if c == 0 then
				res = band(v, maxv)
			else
				const combined = bor(lshift(v, 1), if cf then 1 else 0)
				const mask = lshift(1, rotWidth) - 1
				const rot = band(bor(lshift(combined, c), rshift(combined, rotWidth - c)), mask)
				res = band(rshift(rot, 1), maxv)
				cf = band(rot, 1) == 1
			end
		end
		of = cnt == 1 and (cf ~= (band(res, msb) ~= 0)) or false
	else
		if width == 32 then
			res = band(v, 0xFFFFFFFF)
			for _ = 1, cnt do
				const nextCf = band(res, 1) ~= 0
				res = band(bor(rshift(res, 1), if cf then msb else 0), 0xFFFFFFFF)
				cf = nextCf
			end
			if cnt % 33 == 0 then
				cf = cpu:getF(CF)
			end
		else
			const rotWidth = bits + 1
			const c = cnt % rotWidth
			const combined = bor(v, if cf then lshift(1, bits) else 0)
			if c == 0 then
				res = band(v, maxv)
			else
				const mask = lshift(1, rotWidth) - 1
				const rot = band(bor(rshift(combined, c), lshift(combined, rotWidth - c)), mask)
				res = band(rot, maxv)
				cf = band(rshift(rot, bits), 1) == 1
			end
		end
		of = cnt == 1 and ((band(res, msb) ~= 0) ~= (band(res, rshift(msb, 1)) ~= 0)) or false
	end

	cpu:setbits(CF, cf)
	cpu:setbits(OFLG, of)
	if op == 4 or op == 5 or op == 6 or op == 7 then
		cpu:setSZP(res, width)
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
		const width = if cpu.operand32 then 32 else 16
		local res = doALU(cpu, aluOp, cpu:readRM(e), cpu:rrw(e.reg), width)
		if aluOp ~= 7 then
			cpu:writeRM(e, res)
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
		const width = if cpu.operand32 then 32 else 16
		local res = doALU(cpu, aluOp, cpu:rrw(e.reg), cpu:readRM(e), width)
		if aluOp ~= 7 then
			cpu:wrw(e.reg, res)
		end -- CMP r16,r/m16 (0x39) must not write
	end
	H[base + 4] = function(cpu: any)
		local res = doALU(cpu, aluOp, cpu:rb(0), cpu:fetch8(), false)
		if aluOp ~= 7 then
			cpu:wb(0, res)
		end -- CMP AL,imm8 (0x3C) must not write
	end
	H[base + 5] = function(cpu: any)
		const width = if cpu.operand32 then 32 else 16
		local res = doALU(
			cpu,
			aluOp,
			cpu:rrw(0),
			if width == 32 then cpu:fetch32() else cpu:fetch16(),
			width
		)
		if aluOp ~= 7 then
			cpu:wrw(0, res)
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
		const width = if cpu.operand32 then 32 else 16
		cpu:wrw(i, doALU(cpu, 0, cpu:rrw(i), 1, width))
		cpu:setbits(CF, cf)
	end
	H[0x48 + i] = function(cpu: any)
		local cf = cpu:getF(CF)
		const width = if cpu.operand32 then 32 else 16
		cpu:wrw(i, doALU(cpu, 5, cpu:rrw(i), 1, width))
		cpu:setbits(CF, cf)
	end
	H[0x50 + i] = function(cpu: any)
		if cpu.operand32 then
			cpu:push32(cpu:rr32(i))
		elseif i == 4 and cpu.level == CPU_8086 then
			-- 8086 quirk: PUSH SP pushes the DECREMENTED value.
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
			cpu.ip = band(cpu.ip + d, cpu:ipMask())
		end
	end
	H[0x60 + i] = H[0x70 + i]
end

-- group 1: 80/81/82/83
local function group1(cpu: any, width: number, signExtImm: boolean)
	local e = cpu:modrm()
	local op = e.reg
	local a = if width == 8 then cpu:readRM8(e) else cpu:readRM(e)
	local b
	if width ~= 8 and signExtImm then
		b = sign8(cpu:fetch8())
		if width == 32 then
			b = band(b, 0xFFFFFFFF)
		else
			b = band(b, 0xFFFF)
		end
	elseif width == 32 then
		b = cpu:fetch32()
	elseif width == 16 then
		b = cpu:fetch16()
	else
		b = cpu:fetch8()
	end
	local res = doALU(cpu, op, a, b, width)
	if op ~= 7 then
		if width == 8 then
			cpu:writeRM8(e, res)
		else
			cpu:writeRM(e, res)
		end
	end
end
H[0x80] = function(cpu: any)
	group1(cpu, 8, false)
end
H[0x81] = function(cpu: any)
	group1(cpu, if cpu.operand32 then 32 else 16, false)
end
H[0x82] = H[0x80]
H[0x83] = function(cpu: any)
	group1(cpu, if cpu.operand32 then 32 else 16, true)
end

-- TEST r/m,reg
H[0x84] = function(cpu: any)
	local e = cpu:modrm()
	doALU(cpu, 4, cpu:readRM8(e), cpu:rb(e.reg), false)
end
H[0x85] = function(cpu: any)
	local e = cpu:modrm()
	doALU(cpu, 4, cpu:readRM(e), cpu:rrw(e.reg), if cpu.operand32 then 32 else 16)
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
	local a, b = cpu:readRM(e), cpu:rrw(e.reg)
	cpu:writeRM(e, b)
	cpu:wrw(e.reg, a)
end

-- MOV family
H[0x88] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM8(e, cpu:rb(e.reg))
end
H[0x89] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM(e, cpu:rrw(e.reg))
end
H[0x8A] = function(cpu: any)
	local e = cpu:modrm()
	cpu:wb(e.reg, cpu:readRM8(e))
end
H[0x8B] = function(cpu: any)
	local e = cpu:modrm()
	cpu:wrw(e.reg, cpu:readRM(e))
end

local SEGREG = { "es", "cs", "ss", "ds", "fs", "gs" }
H[0x8C] = function(cpu: any)
	local e = cpu:modrm()
	const value = cpu[SEGREG[e.reg + 1]]
	if e.mod == 3 and cpu.level >= CPU_386 and cpu.operand32 then
		-- MOV r32,Sreg zero-extends the 16-bit selector into the 32-bit
		-- destination (386+). The memory form always stores 16 bits.
		cpu:wr32(e.rm, value)
	else
		cpu:writeRM16(e, value)
	end
end
H[0x8D] = function(cpu: any)
	local e = cpu:modrm()
	if e.mod == 3 then
		error("LEA with register operand")
	end
	cpu:wrw(e.reg, e.off)
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
	if cpu.operand32 then
		cpu:writeRM32(e, cpu:pop32())
	else
		cpu:writeRM16(e, cpu:pop16())
	end
end

H[0x90] = function() end -- NOP
for i = 1, 7 do
	H[0x90 + i] = function(cpu: any) -- XCHG eAX,r
		const a = cpu:rrw(0)
		cpu:wrw(0, cpu:rrw(i))
		cpu:wrw(i, a)
	end
end

H[0x98] = function(cpu: any) -- CBW / CWDE
	if cpu.operand32 then
		const ax = cpu:rr(0)
		cpu:wr32(0, if ax >= 0x8000 then bor(0xFFFF0000, ax) else ax)
	else
		local al = cpu:rb(0)
		cpu:wr(0, al >= 0x80 and bor(0xFF00, al) or al)
	end
end
H[0x99] = function(cpu: any) -- CWD / CDQ
	if cpu.operand32 then
		cpu:wr32(2, if cpu:rr32(0) >= 0x80000000 then 0xFFFFFFFF else 0)
	else
		cpu:wr(2, cpu:rr(0) >= 0x8000 and 0xFFFF or 0)
	end
end
H[0x9A] = function(cpu: any) -- CALL far imm
	const ip = if cpu.operand32 then cpu:fetch32() else cpu:fetch16()
	const cs = cpu:fetch16()
	cpu:farCall(cs, ip, true)
end
H[0x9B] = function(cpu: any) -- WAIT/FWAIT observes a pending x87 #MF
	if cpu.fpu then
		cpu.fpu:wait(cpu)
	end
end
H[0x9C] = function(cpu: any) -- PUSHF / PUSHFD
	if cpu.operand32 then
		cpu:push32(bor(cpu.flags, ALWAYS))
	else
		cpu:push16(cpu.flags)
	end
end
H[0x9D] = function(cpu: any) -- POPF / POPFD
	const wasEnabled = cpu:getF(IFF)
	local value
	if cpu.operand32 then
		value = cpu:pop32()
	else
		value = cpu:pop16()
	end
	cpu.flags = bor(band(value, cpu.flagMask), cpu.fixedFlags)
	if not wasEnabled and cpu:getF(IFF) then
		cpu.irqDelay = 1 -- interrupt shadow after POPF
	end
end
H[0x9E] = function(cpu: any) -- SAHF
	local ah = cpu:rb(4)
	cpu.flags = bor(band(cpu.flags, bnot(0xD5)), band(ah, 0xD5), ALWAYS)
end
H[0x9F] = function(cpu: any) -- LAHF
	cpu:wb(4, bor(band(cpu.flags, 0xD5), ALWAYS))
end

-- MOV AL/AX/EAX <-> moffs (address-size prefix controls the offset width).
local function moffs(cpu: any, size: number)
	const off = if cpu.address32 then cpu:fetch32() else cpu:fetch16()
	return cpu:linear(cpu.osegReg or "ds", off, size)
end
H[0xA0] = function(cpu: any)
	cpu:wb(0, cpu:read8(moffs(cpu, 1)))
end
H[0xA1] = function(cpu: any)
	if cpu.operand32 then
		cpu:wr32(0, cpu:read32(moffs(cpu, 4)))
	else
		cpu:wr(0, cpu:read16(moffs(cpu, 2)))
	end
end
H[0xA2] = function(cpu: any)
	cpu:write8(moffs(cpu, 1), cpu:rb(0))
end
H[0xA3] = function(cpu: any)
	if cpu.operand32 then
		cpu:write32(moffs(cpu, 4), cpu:rr32(0))
	else
		cpu:write16(moffs(cpu, 2), cpu:rr(0))
	end
end

-- string ops: 0 MOVS, 1 CMPS, 2 STOS, 3 LODS, 4 SCAS
local function stringOp(cpu: any, id: number, width: number)
	const sz = width
	const delta = if cpu:getF(DFF) then -sz else sz
	const mask = if cpu.address32 then 0xFFFFFFFF else 0xFFFF
	const sReg = cpu.osegReg or "ds"
	local function indexValue(index: number): number
		return if cpu.address32 then cpu:rr32(index) else cpu:rr(index)
	end
	local function setIndex(index: number, value: number)
		if cpu.address32 then
			cpu:wr32(index, value)
		else
			cpu:wr(index, value)
		end
	end
	local function srcAddr(): number
		return cpu:linear(sReg, indexValue(6), sz)
	end
	local function dstAddr(): number
		return cpu:linear("es", indexValue(7), sz)
	end
	local function readMem(addr: number): number
		if sz == 4 then
			return cpu:read32(addr)
		elseif sz == 2 then
			return cpu:read16(addr)
		end
		return cpu:read8(addr)
	end
	local function writeMem(addr: number, value: number)
		if sz == 4 then
			cpu:write32(addr, value)
		elseif sz == 2 then
			cpu:write16(addr, value)
		else
			cpu:write8(addr, value)
		end
	end

	local function step()
		if id == 0 then
			writeMem(dstAddr(), readMem(srcAddr()))
			setIndex(6, band(indexValue(6) + delta, mask))
			setIndex(7, band(indexValue(7) + delta, mask))
		elseif id == 1 then
			doALU(cpu, 5, readMem(srcAddr()), readMem(dstAddr()), sz)
			setIndex(6, band(indexValue(6) + delta, mask))
			setIndex(7, band(indexValue(7) + delta, mask))
		elseif id == 2 then
			writeMem(
				dstAddr(),
				if sz == 4 then cpu:rr32(0) elseif sz == 2 then cpu:rr(0) else cpu:rb(0)
			)
			setIndex(7, band(indexValue(7) + delta, mask))
		elseif id == 3 then
			const value = readMem(srcAddr())
			if sz == 4 then
				cpu:wr32(0, value)
			elseif sz == 2 then
				cpu:wr(0, value)
			else
				cpu:wb(0, value)
			end
			setIndex(6, band(indexValue(6) + delta, mask))
		else
			const value = if sz == 4 then cpu:rr32(0) elseif sz == 2 then cpu:rr(0) else cpu:rb(0)
			doALU(cpu, 5, value, readMem(dstAddr()), sz)
			setIndex(7, band(indexValue(7) + delta, mask))
		end
	end

	if not cpu.rep then
		step()
		return
	end
	const isCmp = (id == 1 or id == 4)
	while indexValue(1) ~= 0 do
		step()
		setIndex(1, band(indexValue(1) - 1, mask))
		if isCmp then
			const zf = cpu:getF(ZF)
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
	stringOp(cpu, 0, 1)
end
H[0xA5] = function(cpu: any)
	stringOp(cpu, 0, if cpu.operand32 then 4 else 2)
end
H[0xA6] = function(cpu: any)
	stringOp(cpu, 1, 1)
end
H[0xA7] = function(cpu: any)
	stringOp(cpu, 1, if cpu.operand32 then 4 else 2)
end
H[0xAA] = function(cpu: any)
	stringOp(cpu, 2, 1)
end
H[0xAB] = function(cpu: any)
	stringOp(cpu, 2, if cpu.operand32 then 4 else 2)
end
H[0xAC] = function(cpu: any)
	stringOp(cpu, 3, 1)
end
H[0xAD] = function(cpu: any)
	stringOp(cpu, 3, if cpu.operand32 then 4 else 2)
end
H[0xAE] = function(cpu: any)
	stringOp(cpu, 4, 1)
end
H[0xAF] = function(cpu: any)
	stringOp(cpu, 4, if cpu.operand32 then 4 else 2)
end

H[0xA8] = function(cpu: any)
	doALU(cpu, 4, cpu:rb(0), cpu:fetch8(), false)
end
H[0xA9] = function(cpu: any)
	const width = if cpu.operand32 then 32 else 16
	doALU(cpu, 4, cpu:rrw(0), if width == 32 then cpu:fetch32() else cpu:fetch16(), width)
end

for i = 0, 7 do
	H[0xB0 + i] = function(cpu: any)
		cpu:wb(i, cpu:fetch8())
	end
	H[0xB8 + i] = function(cpu: any)
		if cpu.operand32 then
			cpu:wr32(i, cpu:fetch32())
		else
			cpu:wr(i, cpu:fetch16())
		end
	end
end

H[0xC2] = function(cpu: any) -- RET imm16
	const n = cpu:fetch16()
	cpu.ip = if cpu.operand32 then cpu:pop32() else cpu:pop16()
	const mask = if cpu:stack32() then 0xFFFFFFFF else 0xFFFF
	cpu:setSP(band(cpu:getSP() + n, mask))
end
H[0xC3] = function(cpu: any)
	cpu.ip = if cpu.operand32 then cpu:pop32() else cpu:pop16()
end

H[0xC4] = function(cpu: any) -- LES r, m16:16 / m16:32
	const e = cpu:modrm()
	if cpu.operand32 then
		const addr = cpu:linear(e.seg :: string, e.off :: number, 6)
		cpu:wr32(e.reg, cpu:read32(addr))
		cpu:loadSeg("es", cpu:read16(addr + 4))
	else
		const addr = cpu:linear(e.seg :: string, e.off :: number, 4)
		cpu:wr(e.reg, cpu:read16(addr))
		cpu:loadSeg("es", cpu:read16(addr + 2))
	end
end
H[0xC5] = function(cpu: any) -- LDS r, m16:16 / m16:32
	const e = cpu:modrm()
	if cpu.operand32 then
		const addr = cpu:linear(e.seg :: string, e.off :: number, 6)
		cpu:wr32(e.reg, cpu:read32(addr))
		cpu:loadSeg("ds", cpu:read16(addr + 4))
	else
		const addr = cpu:linear(e.seg :: string, e.off :: number, 4)
		cpu:wr(e.reg, cpu:read16(addr))
		cpu:loadSeg("ds", cpu:read16(addr + 2))
	end
end

H[0xC6] = function(cpu: any)
	local e = cpu:modrm()
	cpu:writeRM8(e, cpu:fetch8())
end
H[0xC7] = function(cpu: any)
	local e = cpu:modrm()
	if cpu.operand32 then
		cpu:writeRM32(e, cpu:fetch32())
	else
		cpu:writeRM16(e, cpu:fetch16())
	end
end

local function retf(cpu: any, extra: number)
	const width = if cpu.operand32 then 4 else 2
	if cpu.traceEnabled then
		const ssBase = cpu:baseOf("ss")
		const sp = cpu:getSP()
		cpu.lastRetf = {
			fromCs = cpu.cs,
			fromIp = band(cpu.ip - 1, cpu:ipMask()),
			ss = cpu.ss,
			sp = sp,
			s0 = cpu.mem:read16(ssBase + band(sp, 0xFFFF)),
			s1 = cpu.mem:read16(ssBase + band(sp + 2, 0xFFFF)),
			s2 = cpu.mem:read16(ssBase + band(sp + 4, 0xFFFF)),
			s3 = cpu.mem:read16(ssBase + band(sp + 6, 0xFFFF)),
			s4 = cpu.mem:read16(ssBase + band(sp + 8, 0xFFFF)),
			s5 = cpu.mem:read16(ssBase + band(sp + 10, 0xFFFF)),
		}
	end
	const ip = cpu:popValue(width)
	const csSel = band(if width == 4 then cpu:pop32() else cpu:pop16(), 0xFFFF)
	if cpu.lastRetf then
		cpu.lastRetf.ip = ip
		cpu.lastRetf.cs = csSel
		cpu.lastRetf.afterSp = cpu:getSP()
	end
	local outerSp, outerSs
	if cpu:isProtected() and not cpu:isV86() and band(csSel, 3) > cpu:cpl() then
		outerSp = cpu:popValue(width)
		outerSs = band(if width == 4 then cpu:pop32() else cpu:pop16(), 0xFFFF)
	end
	cpu.ip = ip
	cpu:loadSeg("cs", csSel)
	if outerSs then
		cpu:loadSeg("ss", outerSs)
		cpu:setSP(outerSp :: number)
	end
	if extra ~= 0 then
		const mask = if cpu:stack32() then 0xFFFFFFFF else 0xFFFF
		cpu:setSP(band(cpu:getSP() + extra, mask))
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
H[0xCF] = function(cpu: any) -- IRET / IRETD
	if cpu:isProtected() and not cpu:isV86() and band(cpu.flags, NT) ~= 0 then
		-- Nested-task return: no frame is popped; the switch follows the
		-- back-link stored at offset 0 of the current task's TSS.
		const backLink = cpu:read16(cpu.trBase, true)
		cpu:taskSwitch(backLink, "iret")
		return
	end
	const width = if cpu.operand32 then 4 else 2
	const ip = if width == 4 then cpu:pop32() else cpu:pop16()
	const csSel = band(if width == 4 then cpu:pop32() else cpu:pop16(), 0xFFFF)
	const newFlags = if width == 4 then cpu:pop32() else cpu:pop16()
	if cpu.traceEnabled then
		const ssBase = cpu:baseOf("ss")
		const sp = cpu:getSP()
		cpu.lastIret = {
			ip = ip,
			cs = csSel,
			flags = newFlags,
			ss = cpu.ss,
			sp = sp,
			s0 = cpu.mem:read16(ssBase + band(sp, 0xFFFF)),
			s1 = cpu.mem:read16(ssBase + band(sp + 2, 0xFFFF)),
			s2 = cpu.mem:read16(ssBase + band(sp + 4, 0xFFFF)),
			s3 = cpu.mem:read16(ssBase + band(sp + 6, 0xFFFF)),
		}
	end
	const wasEnabled = cpu:getF(IFF)
	const targetV86 = band(newFlags, VM) ~= 0
	local outerSp, outerSs
	local outerSegs: { number }? = nil
	if targetV86 and cpu:cpl() == 0 then
		-- A V86 frame stores ESP, SS, ES, DS, FS and GS as 32-bit slots even
		-- when the monitor's IRET is 32-bit. CS/SS are 16-bit selectors in the
		-- low half of their slot.
		if width == 4 then
			outerSp = cpu:pop32()
			outerSs = band(cpu:pop32(), 0xFFFF)
			outerSegs = { cpu:pop32(), cpu:pop32(), cpu:pop32(), cpu:pop32() } -- ES DS FS GS
		else
			outerSp = cpu:pop16()
			outerSs = band(cpu:pop16(), 0xFFFF)
			outerSegs = { cpu:pop16(), cpu:pop16(), cpu:pop16(), cpu:pop16() }
		end
	elseif cpu:isProtected() and not cpu:isV86() and band(csSel, 3) > cpu:cpl() then
		outerSp = cpu:popValue(width)
		outerSs = band(if width == 4 then cpu:pop32() else cpu:pop16(), 0xFFFF)
	end
	cpu.flags = bor(band(newFlags, cpu.flagMask), cpu.fixedFlags)
	cpu.ip = ip
	cpu:loadSeg("cs", csSel)
	if outerSegs then
		cpu:loadSeg("es", outerSegs[1])
		cpu:loadSeg("ds", outerSegs[2])
		cpu:loadSeg("fs", outerSegs[3])
		cpu:loadSeg("gs", outerSegs[4])
	end
	if outerSs then
		cpu:loadSeg("ss", outerSs)
		cpu:setSP(outerSp :: number)
	end
	if not wasEnabled and cpu:getF(IFF) then
		cpu.irqDelay = 1 -- interrupt shadow after IRET
	end
end

-- group 2: shifts/rotates
local function group2(cpu: any, w: boolean, useCL: boolean)
	local e = cpu:modrm()
	const width = if not w then 8 elseif cpu.operand32 then 32 else 16
	const v = if w then cpu:readRM(e) else cpu:readRM8(e)
	const cnt = useCL and cpu:rb(1) or 1
	const res = doShift(cpu, e.reg, v, cnt, width)
	if cnt > 0 then
		if w then
			cpu:writeRM(e, res)
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
	const width = if not w then 8 elseif cpu.operand32 then 32 else 16
	const v = if w then cpu:readRM(e) else cpu:readRM8(e)
	const cnt = cpu:fetch8()
	const res = doShift(cpu, e.reg, v, cnt, width)
	if cnt > 0 then
		if w then
			cpu:writeRM(e, res)
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
		cpu:fault(0)
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
	cpu:wb(0, cpu:read8(cpu:linear(cpu.osegReg or "ds", off, 1)))
end

for i = 0, 7 do
	H[0xD8 + i] = function(cpu: any)
		const e = cpu:modrm()
		if not cpu.fpu then
			return
		end
		if band(cpu.cr0, bor(CR0_EM, CR0_TS)) ~= 0 then
			cpu:fault(7) -- #NM
			return
		end
		cpu.fpu:execute(cpu, 0xD8 + i, e)
	end
end

local function loopCommon(cpu: any, mode: number)
	local d = cpu:fetch8()
	if d >= 0x80 then
		d -= 0x100
	end
	const mask = if cpu.address32 then 0xFFFFFFFF else 0xFFFF
	const old = if cpu.address32 then cpu:rr32(1) else cpu:rr(1)
	const cx = band(old - 1, mask)
	if cpu.address32 then
		cpu:wr32(1, cx)
	else
		cpu:wr(1, cx)
	end
	local take
	if mode == 0 then
		take = cx ~= 0 and not cpu:getF(ZF)
	elseif mode == 1 then
		take = cx ~= 0 and cpu:getF(ZF)
	else
		take = cx ~= 0
	end
	if take then
		cpu.ip = band(cpu.ip + d, cpu:ipMask())
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
	const cx = if cpu.address32 then cpu:rr32(1) else cpu:rr(1)
	if cx == 0 then
		cpu.ip = band(cpu.ip + d, cpu:ipMask())
	end
end

-- I/O privilege for protected mode and V86. Real mode is unrestricted. In
-- protected mode, CPL <= IOPL is sufficient; otherwise the 32-bit TSS I/O
-- permission bitmap decides, with a missing/oversized bitmap denying access.
local function ioAllowed(cpu: any, port: number, width: number): boolean
	if not cpu:isProtected() then
		return true
	end
	const iopl = band(rshift(cpu.flags, 12), 3)
	if cpu:isV86() then
		if iopl == 3 then
			return true
		end
	elseif cpu:cpl() <= iopl then
		return true
	end
	if not cpu.tr32 or cpu.trLimit < 0x67 then
		return false
	end
	const mapBase = cpu:read16(cpu.trBase + 0x66, true)
	if mapBase >= cpu.trLimit then
		return false
	end
	for index = 0, width - 1 do
		const currentPort = band(port + index, 0xFFFF)
		const byteOffset = mapBase + rshift(currentPort, 3)
		if byteOffset > cpu.trLimit then
			return false
		end
		const mapByte = cpu:read8(cpu.trBase + byteOffset, true)
		if band(mapByte, lshift(1, band(currentPort, 7))) ~= 0 then
			return false
		end
	end
	return true
end

local function ioIn(cpu: any, port: number, width: number): number
	if not ioAllowed(cpu, port, width) then
		cpu:fault(13)
		return 0
	end
	if width == 4 then
		const read32 = cpu.io.in32 :: ((p: number) -> number)?
		if read32 then
			return read32(port)
		end
		return bor(
			cpu.io.in8(port),
			lshift(cpu.io.in8(band(port + 1, 0xFFFF)), 8),
			lshift(cpu.io.in8(band(port + 2, 0xFFFF)), 16),
			lshift(cpu.io.in8(band(port + 3, 0xFFFF)), 24)
		)
	elseif width == 2 then
		const read16 = cpu.io.in16 :: ((p: number) -> number)?
		if read16 then
			return read16(port)
		end
		return bor(cpu.io.in8(port), lshift(cpu.io.in8(band(port + 1, 0xFFFF)), 8))
	end
	return cpu.io.in8(port)
end

local function ioOut(cpu: any, port: number, width: number, value: number)
	if not ioAllowed(cpu, port, width) then
		cpu:fault(13)
		return
	end
	if width == 4 then
		const write32 = cpu.io.out32 :: ((p: number, v: number) -> ())?
		if write32 then
			write32(port, value)
			return
		end
		cpu.io.out8(port, band(value, 0xFF))
		cpu.io.out8(band(port + 1, 0xFFFF), band(rshift(value, 8), 0xFF))
		cpu.io.out8(band(port + 2, 0xFFFF), band(rshift(value, 16), 0xFF))
		cpu.io.out8(band(port + 3, 0xFFFF), band(rshift(value, 24), 0xFF))
	elseif width == 2 then
		const write16 = cpu.io.out16 :: ((p: number, v: number) -> ())?
		if write16 then
			write16(port, value)
			return
		end
		cpu.io.out8(port, band(value, 0xFF))
		cpu.io.out8(band(port + 1, 0xFFFF), band(rshift(value, 8), 0xFF))
	else
		cpu.io.out8(port, band(value, 0xFF))
	end
end

H[0xE4] = function(cpu: any)
	local p = cpu:fetch8()
	cpu:wb(0, ioIn(cpu, p, 1))
end
H[0xE5] = function(cpu: any)
	local p = cpu:fetch8()
	const width = if cpu.operand32 then 4 else 2
	if width == 4 then
		cpu:wr32(0, ioIn(cpu, p, 4))
	else
		cpu:wr(0, ioIn(cpu, p, 2))
	end
end
H[0xE6] = function(cpu: any)
	local p = cpu:fetch8()
	ioOut(cpu, p, 1, cpu:rb(0))
end
H[0xE7] = function(cpu: any)
	local p = cpu:fetch8()
	if cpu.operand32 then
		ioOut(cpu, p, 4, cpu:rr32(0))
	else
		ioOut(cpu, p, 2, cpu:rr(0))
	end
end

H[0xE8] = function(cpu: any) -- CALL rel16/32
	if cpu.operand32 then
		const d = sign32(cpu:fetch32())
		cpu:push32(cpu.ip)
		cpu.ip = band(cpu.ip + d, cpu:ipMask())
	else
		const d = cpu:fetch16()
		cpu:push16(cpu.ip)
		cpu.ip = band(cpu.ip + sign16(d), cpu:ipMask())
	end
end
H[0xE9] = function(cpu: any) -- JMP rel16/32
	if cpu.operand32 then
		const d = sign32(cpu:fetch32())
		cpu.ip = band(cpu.ip + d, cpu:ipMask())
	else
		const d = cpu:fetch16()
		cpu.ip = band(cpu.ip + sign16(d), cpu:ipMask())
	end
end
H[0xEA] = function(cpu: any)
	const ip = if cpu.operand32 then cpu:fetch32() else cpu:fetch16()
	const cs = cpu:fetch16()
	cpu:farCall(cs, ip, false)
end
H[0xEB] = function(cpu: any)
	local d = cpu:fetch8()
	if d >= 0x80 then
		d -= 0x100
	end
	cpu.ip = band(cpu.ip + d, cpu:ipMask())
end

H[0xEC] = function(cpu: any)
	cpu:wb(0, ioIn(cpu, cpu.r[3], 1))
end
H[0xED] = function(cpu: any)
	const p = cpu.r[3]
	if cpu.operand32 then
		cpu:wr32(0, ioIn(cpu, p, 4))
	else
		cpu:wr(0, ioIn(cpu, p, 2))
	end
end
H[0xEE] = function(cpu: any)
	ioOut(cpu, cpu.r[3], 1, cpu:rb(0))
end
H[0xEF] = function(cpu: any)
	const p = cpu.r[3]
	if cpu.operand32 then
		ioOut(cpu, p, 4, cpu:rr32(0))
	else
		ioOut(cpu, p, 2, cpu:rr(0))
	end
end

H[0xF1] = function() end -- undefined on 8086, treat as NOP
H[0xF4] = function(cpu: any)
	cpu.halted = true
end
H[0xF5] = function(cpu: any)
	cpu.flags = bxor(cpu.flags, CF)
end

-- Exact 32x32 -> 64 multiply for the 486 MUL/IMUL path (the host is
-- double-precision, so splitting into 16-bit limbs keeps every partial exact).
local function mul32(a: number, b: number): (number, number)
	const a0 = band(a, 0xFFFF)
	const a1 = rshift(a, 16)
	const b0 = band(b, 0xFFFF)
	const b1 = rshift(b, 16)
	const p0 = a0 * b0
	const p1 = a0 * b1
	const p2 = a1 * b0
	const p3 = a1 * b1
	const mid = math.floor(p0 / 0x10000) + band(p1, 0xFFFF) + band(p2, 0xFFFF)
	const lo = band(band(p0, 0xFFFF) + band(mid, 0xFFFF) * 0x10000, 0xFFFFFFFF)
	const hi = band(
		p3 + math.floor(p1 / 0x10000) + math.floor(p2 / 0x10000) + math.floor(mid / 0x10000),
		0xFFFFFFFF
	)
	return lo, hi
end

local function negate64(lo: number, hi: number): (number, number)
	const newLo = band(0 - lo, 0xFFFFFFFF)
	const newHi = band(bnot(hi) + (if newLo == 0 then 1 else 0), 0xFFFFFFFF)
	return newLo, newHi
end

-- Restoring division of a 64-bit unsigned value by a 32-bit divisor. Returns
-- (quotient, remainder); callers check the overflow conditions first.
local function div64by32(hi: number, lo: number, divisor: number): (number, number)
	local remainder = 0
	local quotient = 0
	for bit = 63, 0, -1 do
		const sourceBit = if bit >= 32
			then band(rshift(hi, bit - 32), 1)
			else band(rshift(lo, bit), 1)
		remainder = remainder * 2 + sourceBit
		if remainder >= divisor then
			remainder -= divisor
			quotient = quotient * 2 + 1
		else
			quotient = quotient * 2
		end
	end
	return quotient, remainder
end

local function group3(cpu: any, w: boolean)
	const e = cpu:modrm()
	const op = e.reg
	const width = if not w then 8 elseif cpu.operand32 then 32 else 16
	const readOperand = function(): number
		if width == 32 then
			return cpu:readRM32(e)
		elseif width == 16 then
			return cpu:readRM16(e)
		end
		return cpu:readRM8(e)
	end
	const writeOperand = function(value: number)
		if width == 32 then
			cpu:writeRM32(e, value)
		elseif width == 16 then
			cpu:writeRM16(e, value)
		else
			cpu:writeRM8(e, value)
		end
	end
	if op == 0 or op == 1 then
		const a = readOperand()
		const b = if width == 32
			then cpu:fetch32()
			elseif width == 16 then cpu:fetch16()
			else cpu:fetch8()
		doALU(cpu, 4, a, b, width)
	elseif op == 2 then
		writeOperand(
			band(
				bnot(readOperand()),
				if width == 32 then 0xFFFFFFFF elseif width == 16 then 0xFFFF else 0xFF
			)
		)
	elseif op == 3 then
		writeOperand(doALU(cpu, 5, 0, readOperand(), width))
	elseif op == 4 then
		if width == 32 then
			const lo, hi = mul32(cpu:rr32(0), cpu:readRM32(e))
			cpu:wr32(0, lo)
			cpu:wr32(2, hi)
			cpu:setbits(bor(CF, OFLG), hi ~= 0)
		elseif width == 16 then
			const prod = cpu:rr(0) * cpu:readRM16(e)
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:wr(2, band(rshift(prod, 16), 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod > 0xFFFF)
		else
			const prod = cpu:rb(0) * cpu:readRM8(e)
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod > 0xFF)
		end
	elseif op == 5 then
		if width == 32 then
			const a = sign32(cpu:rr32(0))
			const b = sign32(cpu:readRM32(e))
			const negative = (a < 0) ~= (b < 0)
			local lo, hi = mul32(math.abs(a), math.abs(b))
			if negative then
				lo, hi = negate64(lo, hi)
			end
			cpu:wr32(0, lo)
			cpu:wr32(2, hi)
			const signExt = if band(lo, 0x80000000) ~= 0 then 0xFFFFFFFF else 0
			cpu:setbits(bor(CF, OFLG), hi ~= signExt)
		elseif width == 16 then
			const prod = sign16(cpu:rr(0)) * sign16(cpu:readRM16(e))
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:wr(2, band(truncDiv(prod, 0x10000), 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod < -0x8000 or prod > 0x7FFF)
		else
			const prod = sign8(cpu:rb(0)) * sign8(cpu:readRM8(e))
			cpu:wr(0, band(prod, 0xFFFF))
			cpu:setbits(bor(CF, OFLG), prod < -0x80 or prod > 0x7F)
		end
	elseif op == 6 then
		if width == 32 then
			const dv = cpu:readRM32(e)
			const hi = cpu:rr32(2)
			const lo = cpu:rr32(0)
			if dv == 0 or hi >= dv then
				cpu:fault(0)
				return
			end
			const q, rem = div64by32(hi, lo, dv)
			cpu:wr32(0, q)
			cpu:wr32(2, rem)
		elseif width == 16 then
			const dv = cpu:readRM16(e)
			const n = bor(lshift(cpu:rr(2), 16), cpu:rr(0))
			if dv == 0 or n >= lshift(dv, 16) then
				cpu:fault(0)
				return
			end
			cpu:wr(0, math.floor(n / dv))
			cpu:wr(2, n % dv)
		else
			const dv = cpu:readRM8(e)
			const n = cpu:rr(0)
			if dv == 0 or n >= lshift(dv, 8) then
				cpu:fault(0)
				return
			end
			cpu:wb(0, math.floor(n / dv))
			cpu:wb(4, n % dv)
		end
	else
		if width == 32 then
			const dvSigned = sign32(cpu:readRM32(e))
			if dvSigned == 0 then
				cpu:fault(0)
				return
			end
			const nHi = cpu:rr32(2)
			const nLo = cpu:rr32(0)
			const negativeN = band(nHi, 0x80000000) ~= 0
			const negativeD = dvSigned < 0
			local magLo, magHi = nLo, nHi
			if negativeN then
				magLo, magHi = negate64(nLo, nHi)
			end
			const magDiv = math.abs(dvSigned)
			if magHi >= magDiv then
				cpu:fault(0)
				return
			end
			local q, rem = div64by32(magHi, magLo, magDiv)
			const negativeQ = negativeN ~= negativeD
			if negativeQ then
				if q > 0x80000000 then
					cpu:fault(0)
					return
				end
				q = band(0 - q, 0xFFFFFFFF)
				if rem ~= 0 then
					rem = band(0 - rem, 0xFFFFFFFF)
				end
			elseif q > 0x7FFFFFFF then
				cpu:fault(0)
				return
			end
			cpu:wr32(0, q)
			cpu:wr32(2, rem)
		elseif width == 16 then
			const dv = sign16(cpu:readRM16(e))
			if dv == 0 then
				cpu:fault(0)
				return
			end
			const n = sign32(bor(lshift(cpu:rr(2), 16), cpu:rr(0)))
			const q = truncDiv(n, dv)
			const r = n - q * dv
			if q < -0x8000 or q > 0x7FFF then
				cpu:fault(0)
				return
			end
			cpu:wr(0, band(q, 0xFFFF))
			cpu:wr(2, band(r, 0xFFFF))
		else
			const dv = sign8(cpu:readRM8(e))
			if dv == 0 then
				cpu:fault(0)
				return
			end
			const n = sign16(cpu:rr(0))
			const q = truncDiv(n, dv)
			const r = n - q * dv
			if q < -0x80 or q > 0x7F then
				cpu:fault(0)
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
	const width = if cpu.operand32 then 4 else 2
	if reg == 0 or reg == 1 then
		const cf = cpu:getF(CF)
		const res = doALU(cpu, reg == 0 and 0 or 5, cpu:readRM(e), 1, if width == 4 then 32 else 16)
		cpu:writeRM(e, res)
		cpu:setbits(CF, cf)
	elseif reg == 2 then
		const target = cpu:readRM(e)
		if width == 4 then
			cpu:push32(cpu.ip)
		else
			cpu:push16(cpu.ip)
		end
		cpu.ip = target
	elseif reg == 3 then
		const addr = cpu:linear(e.seg :: string, e.off :: number, width + 2)
		const ip = if width == 4 then cpu:read32(addr) else cpu:read16(addr)
		const cs = cpu:read16(addr + width)
		cpu:farCall(cs, ip, true)
	elseif reg == 4 then
		cpu.ip = cpu:readRM(e)
	elseif reg == 5 then
		const addr = cpu:linear(e.seg :: string, e.off :: number, width + 2)
		const cs = cpu:read16(addr + width)
		const ip = if width == 4 then cpu:read32(addr) else cpu:read16(addr)
		cpu:farCall(cs, ip, false)
	elseif reg == 6 then
		if width == 4 then
			cpu:push32(cpu:readRM32(e))
		else
			cpu:push16(cpu:readRM16(e))
		end
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
	const size = if cpu.operand32 then cpu:fetch16() else cpu:fetch16()
	const nesting = band(cpu:fetch8(), 0x1F)
	const width = if cpu.operand32 then 4 else 2
	const mask = if cpu:stack32() then 0xFFFFFFFF else 0xFFFF
	cpu:pushValue(cpu:rrw(5), width) -- BP
	const frame = cpu:getSP()
	if nesting > 0 then
		local bp = cpu:rrw(5)
		for _ = 1, nesting - 1 do
			bp = band(bp - width, mask)
			const value = if width == 4
				then cpu:read32(cpu:linear("ss", bp, 4))
				else cpu:read16(cpu:linear("ss", bp, 2))
			cpu:pushValue(value, width)
		end
		cpu:pushValue(frame, width)
	end
	cpu:wrw(5, frame)
	cpu:setSP(band(cpu:getSP() - size, mask))
end
local function leave(cpu: any)
	const width = if cpu.operand32 then 4 else 2
	cpu:setSP(cpu:rrw(5))
	cpu:wrw(5, cpu:popValue(width))
end
local function jccShort(cpu: any, index: number)
	local d = cpu:fetch8()
	if d >= 0x80 then
		d -= 0x100
	end
	if COND[index + 1](cpu.flags) then
		cpu.ip = band(cpu.ip + d, cpu:ipMask())
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
	const width = if cpu.operand32 then 4 else 2
	const sp = cpu:rrw(4)
	for _, i in ipairs({ 0, 1, 2, 3 }) do
		cpu:pushValue(cpu:rrw(i), width)
	end
	cpu:pushValue(sp, width)
	for _, i in ipairs({ 5, 6, 7 }) do
		cpu:pushValue(cpu:rrw(i), width)
	end
end
local function popa(cpu: any)
	const width = if cpu.operand32 then 4 else 2
	for _, i in ipairs({ 7, 6, 5 }) do
		cpu:wrw(i, cpu:popValue(width))
	end
	cpu:popValue(width) -- discard saved SP
	for _, i in ipairs({ 3, 2, 1, 0 }) do
		cpu:wrw(i, cpu:popValue(width))
	end
end
local function bound(cpu: any)
	const e = cpu:modrm()
	if e.mod == 3 then
		error("BOUND with register operand")
	end
	const index = sign16(cpu:rr(e.reg))
	const addr = cpu:linear(e.seg :: string, e.off :: number, 4)
	const lower = sign16(cpu:read16(addr))
	const upper = sign16(cpu:read16(addr + 2))
	if index < lower or index > upper then
		cpu:fault(5)
	end
end
local function imulImm(cpu: any, wide: boolean)
	const e = cpu:modrm()
	if cpu.operand32 then
		const src = sign32(cpu:readRM32(e))
		const imm = if wide then sign32(cpu:fetch32()) else sign8(cpu:fetch8())
		const product = src * imm
		cpu:wr32(e.reg, band(product, 0xFFFFFFFF))
		cpu:setbits(bor(CF, OFLG), product < -0x80000000 or product > 0x7FFFFFFF)
		return
	end
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
		if cpu.operand32 then
			cpu:push32(cpu:fetch32())
		else
			cpu:push16(cpu:fetch16())
		end
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
		if cpu.operand32 then
			cpu:push32(band(sign8(cpu:fetch8()), 0xFFFFFFFF))
		else
			cpu:push16(band(sign8(cpu:fetch8()), 0xFFFF))
		end
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
	const size = if wide then (if cpu.operand32 then 4 else 2) else 1
	const delta = if cpu:getF(DFF) then -size else size
	const addrMask = if cpu.address32 then 0xFFFFFFFF else 0xFFFF
	const port = cpu.r[3]
	local count = 1
	if cpu.rep then
		count = if cpu.address32 then cpu:rr32(1) else cpu:rr(1)
		if count == 0 then
			return
		end
	end
	if input and size >= 1 then
		cpu.lastIoStringDest = if cpu.address32 then cpu:rr32(7) else cpu:rr(7)
		cpu.lastIoStringCount = count
		cpu.lastIoStringPort = port
	end
	for _ = 1, count do
		const di = if cpu.address32 then cpu:rr32(7) else cpu:rr(7)
		const si = if cpu.address32 then cpu:rr32(6) else cpu:rr(6)
		if input then
			const dst = cpu:linear("es", di, size)
			if size == 4 then
				cpu:write32(dst, ioIn(cpu, port, 4))
			elseif size == 2 then
				cpu:write16(dst, ioIn(cpu, port, 2))
			else
				cpu:write8(dst, ioIn(cpu, port, 1))
			end
			const next = band(di + delta, addrMask)
			if cpu.address32 then
				cpu:wr32(7, next)
			else
				cpu:wr(7, next)
			end
		else
			const src = cpu:linear(cpu.osegReg or "ds", si, size)
			if size == 4 then
				ioOut(cpu, port, 4, cpu:read32(src))
			elseif size == 2 then
				ioOut(cpu, port, 2, cpu:read16(src))
			else
				ioOut(cpu, port, 1, cpu:read8(src))
			end
			const next = band(si + delta, addrMask)
			if cpu.address32 then
				cpu:wr32(6, next)
			else
				cpu:wr(6, next)
			end
		end
		if cpu.rep then
			if cpu.address32 then
				cpu:wr32(1, band(cpu:rr32(1) - 1, 0xFFFFFFFF))
			else
				cpu:wr(1, band(cpu:rr(1) - 1, 0xFFFF))
			end
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
	const limit = cpu:read16(addr)
	local base
	if cpu.operand32 then
		base = bor(cpu:read16(addr + 2), lshift(cpu:read16(addr + 4), 16))
	else
		base = bor(cpu:read16(addr + 2), lshift(cpu:read8(addr + 4), 16))
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
				const compactAccess = cpu:read8(compactBase + 3 * 8 + 5)
				const compactType = band(compactAccess, 0x1F)
				if
					compactType == 0x06
					or compactType == 0x07
					or compactType == 0x0E
					or compactType == 0x0F
				then
					const gate = compactBase + 3 * 8
					cpu:write16(gate, 0x0C63) -- real switch helper at 0078:0C63
					cpu:write16(gate + 2, 0x0078)
					cpu:write8(gate + 4, 0)
					cpu:write8(gate + 5, bor(band(compactAccess, 0x60), 0x86))
					cpu:write16(gate + 6, 0)
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
	cpu:write16(addr, table.limit)
	cpu:write16(addr + 2, band(table.base, 0xFFFF))
	if cpu.operand32 then
		cpu:write16(addr + 4, band(rshift(table.base, 16), 0xFFFF))
	else
		cpu:write8(addr + 4, band(rshift(table.base, 16), 0xFF))
		cpu:write8(addr + 5, 0)
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
			if e.reg == 0 then
				value = cpu.cr0
			elseif e.reg == 3 then
				value = cpu.cr3
			else
				value = cpu.cr[e.reg] or 0
			end
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
				local oldCr0 = cpu.cr0
				cpu.cr0 = value
				cpu.cr[0] = value
				if band(oldCr0, CR0_PG) ~= band(value, CR0_PG) then
					cpu:flushTlb()
				end
			elseif e.reg == 3 then
				cpu.cr3 = value
				cpu.cr[3] = value
				cpu:flushTlb()
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
	const value = band(if width == 32 then cpu:readRM32(e) else cpu:readRM16(e), mask)
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
	const value = if width == 32 then cpu:readRM32(e) else cpu:readRM16(e)
	const bit = band(rshift(value, index), 1)
	cpu:setbits(CF, bit ~= 0)
	if op == 0 then
		return
	end
	local updated
	if op == 1 then
		updated = bor(value, lshift(1, index))
	elseif op == 2 then
		updated = band(value, bnot(lshift(1, index)))
	else
		updated = bxor(value, lshift(1, index))
	end
	if width == 32 then
		cpu:writeRM32(e, updated)
	else
		cpu:writeRM16(e, band(updated, 0xFFFF))
	end
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
		if e.reg == 2 and selector == 0 then
			-- LLDT with a null selector is legal and invalidates LDTR.
			cpu.ldtr = 0
			cpu.ldtrBase = 0
			cpu.ldtrLimit = 0
			return
		end
		const desc = readDescriptor(cpu, selector)
		if not desc then
			cpu:fault(13)
			return
		end
		if e.reg == 2 then
			cpu.ldtr = selector
			cpu.ldtrBase = desc.base
			cpu.ldtrLimit = desc.limit
		else
			const tssType = band(desc.access, 0x1F)
			if tssType ~= 0x01 and tssType ~= 0x03 and tssType ~= 0x09 and tssType ~= 0x0B then
				error(
					("#GP: LTR selector %04X is not a TSS (access %02X)"):format(
						selector,
						desc.access
					)
				)
			end
			cpu.tr = selector
			cpu.trBase = desc.base
			cpu.trLimit = desc.limit
			cpu.tr32 = tssType == 0x09 or tssType == 0x0B
			-- Mark the TSS busy like LTR does (bit 1 of the type field).
			const addr = if band(selector, 4) ~= 0
				then cpu.ldtrBase + band(selector, 0xFFF8)
				else cpu.gdtr.base + band(selector, 0xFFF8)
			cpu:write8(addr + 5, bor(desc.access, 2))
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
			cpu:write16(cpu:linear(e.seg :: string, e.off :: number, 2), band(cpu.cr0, 0xFFFF))
		end
	elseif reg == 6 then
		const value = cpu:readRM16(e)
		local nextCr0 = bor(band(cpu.cr0, 0xFFFF0000), band(value, 0xFFFF))
		if band(cpu.cr0, CR0_PG) ~= band(nextCr0, CR0_PG) then
			cpu:flushTlb()
		end
		cpu.cr0 = nextCr0
		cpu.cr[0] = nextCr0
	elseif reg == 7 then
		-- INVLPG drops one cached translation. The register form (mod==3) is
		-- #UD on real hardware; keep the old lenient no-op for it.
		if e.mod ~= 3 then
			cpu:flushTlbPage(cpu:linear(e.seg :: string, e.off :: number, 1))
		end
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
	cpu.cr0 = band(cpu.cr0, bnot(CR0_TS))
	cpu.cr[0] = cpu.cr0
end
H0F[0x08] = function() end -- INVD (no caches in this model)
H0F[0x09] = function() end -- WBINVD
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
	if cpu.operand32 then
		cpu:push32(cpu.fs)
	else
		cpu:push16(cpu.fs)
	end
end
H0F[0xA1] = function(cpu: any)
	cpu:loadSeg("fs", if cpu.operand32 then cpu:pop32() else cpu:pop16())
end
H0F[0xA8] = function(cpu: any)
	if cpu.operand32 then
		cpu:push32(cpu.gs)
	else
		cpu:push16(cpu.gs)
	end
end
H0F[0xA9] = function(cpu: any)
	cpu:loadSeg("gs", if cpu.operand32 then cpu:pop32() else cpu:pop16())
end

local function loadFarSeg(cpu: any, e: ModRM, reg: string)
	const width = if cpu.operand32 then 6 else 4
	const addr = cpu:linear(e.seg :: string, e.off :: number, width)
	if cpu.operand32 then
		cpu:wr32(e.reg, cpu:read32(addr))
		cpu:loadSeg(reg, cpu:read16(addr + 4))
	else
		cpu:wr(e.reg, cpu:read16(addr))
		cpu:loadSeg(reg, cpu:read16(addr + 2))
	end
end
H0F[0xB2] = function(cpu: any)
	loadFarSeg(cpu, cpu:modrm(), "ss")
end
H0F[0xB4] = function(cpu: any)
	loadFarSeg(cpu, cpu:modrm(), "fs")
end
H0F[0xB5] = function(cpu: any)
	loadFarSeg(cpu, cpu:modrm(), "gs")
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
		local delta
		if cpu.operand32 then
			delta = sign32(cpu:fetch32())
		else
			delta = sign16(cpu:fetch16())
		end
		if COND[index + 1](cpu.flags) then
			cpu.ip = band(cpu.ip + delta, cpu:ipMask())
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

H0F[0x0B] = function(cpu: any): ()
	error(("#UD: UD2 at %04X:%08X"):format(cpu.cs, cpu.ip))
end
H0F[0xA2] = function(cpu: any) -- CPUID
	const leaf = cpu:rr32(0)
	if leaf == 0 then
		cpu:wr32(0, 1)
		cpu:wr32(3, 0x756E6547) -- "Genu"
		cpu:wr32(2, 0x49656E69) -- "ineI"
		cpu:wr32(1, 0x6C65746E) -- "ntel"
	elseif leaf == 1 then
		cpu:wr32(0, 0x00000400) -- 486-class signature
		cpu:wr32(3, 0)
		cpu:wr32(1, 0)
		local edx = 0x00000010 -- TSC (RDTSC is implemented)
		if cpu.fpu then
			edx = bor(edx, 0x00000001) -- FPU present
		end
		cpu:wr32(2, edx)
	elseif leaf == 0x80000000 then
		cpu:wr32(0, 0x80000000)
		cpu:wr32(3, 0)
		cpu:wr32(1, 0)
		cpu:wr32(2, 0)
	else
		cpu:wr32(0, 0)
		cpu:wr32(3, 0)
		cpu:wr32(1, 0)
		cpu:wr32(2, 0)
	end
end

H0F[0x31] = function(cpu: any) -- RDTSC (monotonic instruction count)
	cpu:wr32(0, band(cpu.tsc or 0, 0xFFFFFFFF))
	cpu:wr32(2, band(rshift(cpu.tsc or 0, 32), 0xFFFFFFFF))
end

H0F[0xAF] = function(cpu: any) -- IMUL r, r/m
	const e = cpu:modrm()
	if cpu.operand32 then
		const a = sign32(cpu:rr32(e.reg))
		const b = sign32(cpu:readRM32(e))
		const product = a * b
		cpu:wr32(e.reg, band(product, 0xFFFFFFFF))
		cpu:setbits(bor(CF, OFLG), product < -0x80000000 or product > 0x7FFFFFFF)
	else
		const a = sign16(cpu:rr(e.reg))
		const b = sign16(cpu:readRM16(e))
		const product = a * b
		cpu:wr(e.reg, band(product, 0xFFFF))
		cpu:setbits(bor(CF, OFLG), product < -0x8000 or product > 0x7FFF)
	end
end

local function doubleShift(cpu: any, left: boolean, immediate: boolean)
	const e = cpu:modrm()
	const width = if cpu.operand32 then 32 else 16
	const mask = if width == 32 then 0xFFFFFFFF else 0xFFFF
	const bits = width
	const count = if immediate then cpu:fetch8() else band(cpu:rb(1), 0x1F)
	local dest = if width == 32 then cpu:readRM32(e) else cpu:readRM16(e)
	const src = cpu:rrw(e.reg)
	const cnt = band(count, 0x1F)
	if cnt == 0 then
		return
	end
	const old = dest
	const shift = cnt % bits
	if shift == 0 then
		cpu:setbits(CF, band(dest, 1) ~= 0)
		return
	end
	if left then
		dest = band(bor(band(lshift(old, shift), mask), rshift(src, bits - shift)), mask)
		cpu:setbits(CF, band(rshift(old, bits - shift), 1) ~= 0)
	else
		dest = band(bor(rshift(old, shift), lshift(src, bits - shift)), mask)
		cpu:setbits(CF, band(rshift(old, shift - 1), 1) ~= 0)
	end
	if width == 32 then
		cpu:writeRM32(e, dest)
	else
		cpu:writeRM16(e, dest)
	end
	cpu:setSZP(dest, width)
end
H0F[0xA4] = function(cpu: any)
	doubleShift(cpu, true, true)
end
H0F[0xA5] = function(cpu: any)
	doubleShift(cpu, true, false)
end
H0F[0xAC] = function(cpu: any)
	doubleShift(cpu, false, true)
end
H0F[0xAD] = function(cpu: any)
	doubleShift(cpu, false, false)
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
	const a = cpu:readRM(e)
	const b = cpu:rrw(e.reg)
	cpu:writeRM(e, band(a + b, if cpu.operand32 then 0xFFFFFFFF else 0xFFFF))
	cpu:wrw(e.reg, a)
end

for index = 0, 7 do
	H0F[0xC8 + index] = function(cpu: any)
		const value = cpu:rr32(index)
		cpu:wr32(
			index,
			bor(
				lshift(band(value, 0xFF), 24),
				lshift(band(value, 0xFF00), 8),
				rshift(band(value, 0xFF0000), 8),
				rshift(band(value, 0xFF000000), 24)
			)
		)
	end
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
	self.intCounts[n] = (self.intCounts[n] or 0) + 1
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
	if self.traceEnabled and software and n == 0x10 then
		const ssBase = self:baseOf("ss")
		const sp = self:getSP()
		self.lastSwInt = {
			cs = self.cs,
			ip = self.ip,
			flags = self.flags,
			ss = self.ss,
			sp = sp,
			s0 = mem:read16(ssBase + band(sp, 0xFFFF)),
			s1 = mem:read16(ssBase + band(sp + 2, 0xFFFF)),
			s2 = mem:read16(ssBase + band(sp + 4, 0xFFFF)),
			s3 = mem:read16(ssBase + band(sp + 6, 0xFFFF)),
			s4 = mem:read16(ssBase + band(sp + 8, 0xFFFF)),
			s5 = mem:read16(ssBase + band(sp + 10, 0xFFFF)),
			s6 = mem:read16(ssBase + band(sp + 12, 0xFFFF)),
			s7 = mem:read16(ssBase + band(sp + 14, 0xFFFF)),
		}
	end
	const handler = self.defaultInts[n]
	const stub = self.intStubs[n]
	if handler and stub and lo == stub.off and hi == stub.seg then
		handler(n)
		return
	end
	if lo ~= 0 or hi ~= 0 then
		const returnIP = if software then self.ip else (self.faultIP or self.ip)
		if self.traceEnabled and n == 8 then
			const ssBase = self:baseOf("ss")
			const sp = self:getSP()
			self.lastIrqTrace = self:traceDump(512)
			self.lastIrq = {
				cs = self.cs,
				ip = returnIP,
				flags = self.flags,
				ss = self.ss,
				sp = sp,
				s0 = self.mem:read16(ssBase + band(sp, 0xFFFF)),
				s1 = self.mem:read16(ssBase + band(sp + 2, 0xFFFF)),
				s2 = self.mem:read16(ssBase + band(sp + 4, 0xFFFF)),
				s3 = self.mem:read16(ssBase + band(sp + 6, 0xFFFF)),
			}
		end
		self:push16(self.flags)
		self:push16(self.cs)
		self:push16(returnIP)
		self.flags = bor(band(self.flags, bnot(bor(TF, IFF))), ALWAYS)
		self.ip = lo
		self.cs = hi
		self.faultIP = nil
		self.faultCS = nil
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

function Cpu.executeStep(self: Cpu): number
	if self.halted then
		return 0
	end
	if self.irqDelay > 0 then
		self.irqDelay -= 1
	end
	self.opIP = self.ip
	self.opCS = self.cs
	self.faultIP = nil
	self.faultCS = nil
	self.oseg = nil
	self.osegReg = nil
	self.rep = nil
	self.baseOperand32 = self.level >= CPU_386
		and band(self.cr0, CR0_PE) ~= 0
		and band(self.segFlags.cs or 0, 0x40) ~= 0
	self.baseAddress32 = self.baseOperand32
	self.operand32 = self.baseOperand32
	self.address32 = self.baseAddress32
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
		elseif op == 0x66 and self.level >= CPU_386 then
			self.operand32 = not self.operand32
		elseif op == 0x66 and self.level >= CPU_286 then
			self.operand32 = true
		elseif op == 0x67 and self.level >= CPU_386 then
			self.address32 = not self.address32
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
			("unimplemented opcode %02X at %04X:%08X"):format(
				op,
				self.cs,
				band(self.ip - 1, self:ipMask())
			)
		)
	end
	h(self)
	-- Prefix state is cleared at the start of the next instruction; clearing
	-- it here as well only added three stores to every retired instruction.
	self.tsc += 1
	return 1
end

-- Paging faults unwind the faulting instruction after #PF has been delivered.
-- The pcall is only paid while CR0.PG is set; real-mode/PM bring-up stays fast.
function Cpu.step(self: Cpu): number
	if self.traceEnabled then
		self.traceIndex = (self.traceIndex % 4096) + 1
		self.trace[self.traceIndex] = ("%04X:%08X"):format(self.cs, self.ip)
		if self.badCsTrace == nil and self.cs == 0x0202 and self.ip == 0 then
			self.badCsTrace = self:traceDump(40)
		end
	end
	if band(self.cr0, CR0_PG) == 0 then
		return (self :: any):executeStep()
	end
	const ok, result = pcall(function()
		return (self :: any):executeStep()
	end)
	self.aborting = false
	if not ok then
		if result == ABORT_INSTRUCTION then
			return 1
		end
		error(result, 0)
	end
	return result :: number
end

function Cpu.traceDump(self: Cpu, count: number): { string }
	const out: { string } = {}
	const total = math.min(count, #self.trace)
	for index = total, 1, -1 do
		const slot = ((self.traceIndex - index) % 4096) + 1
		out[#out + 1] = self.trace[slot] or "?"
	end
	return out
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
