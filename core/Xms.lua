--!strict
-- Xms.lua -- minimal XMS 3.0 driver (HIMEM entry point, A20, HMA, EMB moves).
-- WIN.CNF probes INT 2Fh AX=4300/4310 and then calls the far entry; DOSX uses
-- the same interface after the CPU/version gate. No HIMEM.SYS binary needed.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const Xms = {}
Xms.__index = Xms

-- Reserved hypervisor segment: F100 hosts the IVT/timer/mouse stubs up to
-- 0x6D, so the XMS far entry goes at 0xC0 and cannot overlap a loaded program
-- (the DOS loader places images below the 0xA000 arena top, but a segment as
-- low as F200 looked "free" only until WSWAP happened to land there).
const ENTRY_SEG = 0xF100
const ENTRY_OFF = 0x00C0
const HMA_START = 0x100000
const HMA_SIZE = 0x10000
const EXT_START = HMA_START + HMA_SIZE

export type Block = {
	start: number,
	size: number,
}

export type Xms = {
	machine: any,
	a20: boolean,
	hmaInUse: boolean,
	blocks: { [number]: Block },
	nextHandle: number,
	entrySeg: number,
	entryOff: number,
	FN: { [number]: (self: Xms, cpu: any) -> () },
	enabled: (self: Xms) -> boolean,
	int2f: (self: Xms) -> boolean,
	dispatch: (self: Xms) -> (),
	releaseAll: (self: Xms) -> (),
}

function Xms.new(machine: any): Xms
	const self = setmetatable({}, Xms) :: any
	self.machine = machine
	-- HIMEM.SYS enables A20 while it initialises and leaves it on; real DOS
	-- extended-memory users (WSWAP) rely on that. 8086 keeps the 20-bit wrap.
	self.a20 = machine.cpu.level >= 1
	machine.mem.a20 = self.a20
	self.hmaInUse = false
	self.blocks = {}
	self.nextHandle = 1
	self.entrySeg = ENTRY_SEG
	self.entryOff = ENTRY_OFF
	-- Far entry: INT 9Fh (inline-dispatched by the machine's stub) ; RETF.
	machine.mem:write8(lshift(ENTRY_SEG, 4) + ENTRY_OFF, 0xCD)
	machine.mem:write8(lshift(ENTRY_SEG, 4) + ENTRY_OFF + 1, 0x9F)
	machine.mem:write8(lshift(ENTRY_SEG, 4) + ENTRY_OFF + 2, 0xCB)
	return self
end

function Xms.enabled(self: Xms): boolean
	return self.machine.cpu.level >= 1 -- 286+
end

-- INT 2Fh installation check / driver entry. Returns true when handled.
function Xms.int2f(self: Xms): boolean
	const cpu = self.machine.cpu
	if not self:enabled() then
		return false
	end
	const ax = cpu.r[1]
	if ax == 0x4300 then
		cpu:wb(0, 0x80)
		cpu:wr(3, 0x0100)
		return true
	elseif ax == 0x4310 then
		cpu.es = self.entrySeg
		cpu:wr(3, self.entryOff)
		return true
	end
	return false
end

local function setMemA20(self: Xms, on: boolean)
	self.a20 = on
	self.machine.mem.a20 = on
end

local function freeList(self: Xms): { Block }
	local list: { Block } = {}
	for _, block in pairs(self.blocks) do
		list[#list + 1] = block
	end
	table.sort(list, function(a: Block, b: Block): boolean
		return a.start < b.start
	end)
	return list
end

local function memoryTotals(self: Xms): (number, number)
	const memSize = self.machine.mem.size
	local cursor = EXT_START
	local largest, total = 0, 0
	for _, block in ipairs(freeList(self)) do
		const gap = block.start - cursor
		if gap > largest then
			largest = gap
		end
		total += gap
		cursor = block.start + block.size
	end
	const tail = memSize - cursor
	if tail > largest then
		largest = tail
	end
	total += tail
	return math.floor(largest / 1024), math.floor(total / 1024)
end

local function allocate(self: Xms, bytes: number): (number?, number?)
	local cursor = EXT_START
	const memSize = self.machine.mem.size
	for _, block in ipairs(freeList(self)) do
		if block.start - cursor >= bytes then
			const handle = self.nextHandle
			self.nextHandle += 1
			self.blocks[handle] = { start = cursor, size = bytes }
			return handle, cursor
		end
		cursor = block.start + block.size
	end
	if memSize - cursor >= bytes then
		const handle = self.nextHandle
		self.nextHandle += 1
		self.blocks[handle] = { start = cursor, size = bytes }
		return handle, cursor
	end
	return nil, nil
end

local function readDword(mem: any, addr: number): number
	return bor(mem:read16(addr), lshift(mem:read16(addr + 2), 16))
end

local function copyLinear(mem: any, dst: number, src: number, length: number)
	for index = 0, length - 1 do
		mem:write8(dst + index, mem:read8(src + index))
	end
end

Xms.FN = {}

Xms.FN[0x00] = function(_self: Xms, cpu: any) -- get version
	cpu:wr(0, 0x0300)
	cpu:wr(3, 0x0100)
end

Xms.FN[0x01] = function(self: Xms, cpu: any) -- request HMA (DX = KB)
	if self.hmaInUse then
		cpu:wr(0, 0)
		return
	end
	self.hmaInUse = true
	cpu:wr(0, 1)
end

Xms.FN[0x02] = function(self: Xms, cpu: any) -- release HMA
	self.hmaInUse = false
	cpu:wr(0, 1)
end

Xms.FN[0x03] = function(self: Xms, cpu: any) -- enable A20
	setMemA20(self, true)
	cpu:wr(0, 1)
end

Xms.FN[0x04] = function(self: Xms, cpu: any) -- disable A20
	setMemA20(self, false)
	cpu:wr(0, 1)
end

Xms.FN[0x05] = function(self: Xms, cpu: any) -- local enable A20
	setMemA20(self, true)
	cpu:wr(0, 1)
end

Xms.FN[0x06] = function(self: Xms, cpu: any) -- local disable A20
	setMemA20(self, false)
	cpu:wr(0, 1)
end

Xms.FN[0x07] = function(self: Xms, cpu: any) -- query A20
	cpu:wr(0, self.a20 and 1 or 0)
end

Xms.FN[0x08] = function(self: Xms, cpu: any) -- query free memory
	const largest, total = memoryTotals(self)
	cpu:wr(0, largest)
	cpu:wr(2, total)
end

Xms.FN[0x09] = function(self: Xms, cpu: any) -- allocate EMB (DX = KB)
	const handle = allocate(self, cpu.r[3] * 1024)
	if not handle then
		cpu:wr(0, 0)
		return
	end
	cpu:wr(0, 1)
	cpu:wr(2, handle) -- XMS 09: DX = handle, AX = 1
end

Xms.FN[0x0A] = function(self: Xms, cpu: any) -- free EMB
	if self.blocks[cpu.r[3]] then
		self.blocks[cpu.r[3]] = nil
		cpu:wr(0, 1)
	else
		cpu:wr(0, 0)
	end
end

Xms.FN[0x0B] = function(self: Xms, cpu: any) -- move extended memory block
	const mem = self.machine.mem
	const base = lshift(cpu.ds, 4) + cpu.r[7] -- DS:SI -> move structure
	const length = readDword(mem, base)
	const srcHandle = mem:read16(base + 4)
	const srcOffset = readDword(mem, base + 6)
	const dstHandle = mem:read16(base + 10)
	const dstOffset = readDword(mem, base + 12)
	-- XMS 0Bh: handle 0 means a real-mode segment:offset packed as a DWORD
	-- (segment in the high word), not a linear address. WSWAP depends on it.
	local function realAddress(offset: number): number
		return lshift(rshift(offset, 16), 4) + band(offset, 0xFFFF)
	end
	local src
	local dst
	if srcHandle == 0 then
		src = realAddress(srcOffset)
	else
		const block = self.blocks[srcHandle]
		if not block or srcOffset + length > block.size then
			cpu:wr(0, 0)
			return
		end
		src = block.start + srcOffset
	end
	if dstHandle == 0 then
		dst = realAddress(dstOffset)
	else
		const block = self.blocks[dstHandle]
		if not block or dstOffset + length > block.size then
			cpu:wr(0, 0)
			return
		end
		dst = block.start + dstOffset
	end
	-- XMS owns A20 during a move: the guest's current gate state must not fold
	-- destinations that live in extended memory (DOSX disables A20 while it
	-- prepares its GDT, then copies the table into an EMB with 0Bh).
	const savedA20 = mem.a20
	mem.a20 = true
	copyLinear(mem, dst, src, length)
	mem.a20 = savedA20
	cpu:wr(0, 1)
end

Xms.FN[0x0C] = function(self: Xms, cpu: any) -- lock EMB
	const block = self.blocks[cpu.r[3]]
	if not block then
		cpu:wr(0, 0)
		return
	end
	cpu:wr(0, 1)
	cpu:wr(3, band(block.start, 0xFFFF))
	cpu:wr(2, band(rshift(block.start, 16), 0xFFFF))
end

Xms.FN[0x0D] = function(self: Xms, cpu: any) -- unlock EMB
	cpu:wr(0, self.blocks[cpu.r[3]] and 1 or 0)
end

Xms.FN[0x0E] = function(self: Xms, cpu: any) -- get EMB info
	const block = self.blocks[cpu.r[3]]
	if not block then
		cpu:wr(0, 0)
		return
	end
	cpu:wr(0, 1)
	cpu:wr(3, 0) -- BL=0 locked blocks, BH=0 total blocks
	cpu:wr(2, band(block.size / 1024, 0xFFFF)) -- DX = size KB
end

Xms.FN[0x88] = function(self: Xms, cpu: any) -- query any extended memory
	const kb = math.floor((self.machine.mem.size - HMA_START) / 1024)
	cpu:wr(0, band(kb, 0xFFFF))
end

Xms.FN[0x89] = function(self: Xms, cpu: any) -- allocate any extended memory
	const handle = allocate(self, cpu.r[3] * 1024)
	if not handle then
		cpu:wr(0, 0)
		return
	end
	cpu:wr(0, 1)
	cpu:wr(2, handle)
end

-- A new image cannot inherit another process's extended-memory handles. Real
-- DOS leaves them allocated, but Windows 3.1's WSWAP keeps its swap block and
-- returns to WIN.CNF without freeing it, which would leave DOSX with no XMS.
-- Releasing on EXEC matches what a well-behaved DOS session needs.
function Xms.releaseAll(self: Xms)
	self.blocks = {}
	self.hmaInUse = false
end

function Xms.dispatch(self: Xms)
	const cpu = self.machine.cpu
	const fn = band(rshift(cpu.r[1], 8), 0xFF)
	const handler = self.FN[fn]
	if not handler then
		cpu:wr(0, 0)
		return
	end
	handler(self, cpu)
end

return Xms
