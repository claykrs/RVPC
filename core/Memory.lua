--!strict
-- Memory.lua -- 32-bit physical memory for a 486/Pentium-class PC.
--
-- The RAM buffer is a flat byte array (16/32/64 MiB by default), but the first
-- megabyte follows the PC memory map:
--
--   00000-9FFFF  conventional RAM
--   A0000-AFFFF  VGA graphics aperture (routed to the VGA device)
--   B0000-B7FFF  monochrome text (unused on VGA)
--   B8000-BFFFF  colour text aperture (plain RAM; VGA text reads B8000)
--   C0000-DFFFF  option ROM / expansion space (open bus when a BIOS is present)
--   E0000-FFFFF  BIOS ROM (256 KiB SeaBIOS image; reset vector at FFFF0)
--
-- With no ROM installed the E0000-FFFFF window stays backed by RAM so the old
-- RVDM hypervisor stubs (IVT trampolines at F000:0100, XMS entry at F100:00C0)
-- keep working. Once loadRom() is called, ROM reads are served from the image
-- and writes to ROM are ignored.
--
-- A20M is applied before the memory map: while the gate is closed address bit
-- 20 is forced low, so the 1-2 MiB range folds onto 0-1 MiB. Higher address
-- bits are not folded (0x200000 stays 0x200000), which is what a real 486
-- chipset does.
--
-- There is no wrap at the top of RAM. Addresses outside RAM/ROM/aperture are
-- open bus: reads return 0xFF and writes are dropped.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const Memory = {}
Memory.__index = Memory

Memory.SIZE = 16 * 1024 * 1024
Memory.ROM_BASE = 0xE0000
Memory.ROM_SIZE = 0x40000
Memory.ROM_ALIAS = 0xF0000 -- legacy entry point inside the 256 KiB image
const A20_BIT = 0x100000
const APERTURE_START = 0xA0000
const APERTURE_END = 0xAFFFF
const TEXT_START = 0xB0000
const TEXT_END = 0xBFFFF
const ONE_MIB = 0x100000

export type Aperture = {
	read8: (self: any, addr: number) -> number,
	write8: (self: any, addr: number, value: number) -> (),
	read16: (self: any, addr: number) -> number,
	write16: (self: any, addr: number, value: number) -> (),
}

export type Memory = typeof(setmetatable(
	{} :: {
		buf: buffer,
		size: number,
		mask: number,
		a20: boolean,
		protectStart: number?,
		protectEnd: number?,
		aperture: Aperture?,
		rom: buffer?,
		romBase: number,
		romSize: number,
		romLowOffset: number,
		romHighBase: number,
		romShadowed: boolean,
		lowRomLocked: boolean,
	},
	Memory
))

function Memory.new(size: number?): Memory
	const bytes = size or Memory.SIZE
	if bytes < 1024 or band(bytes, bytes - 1) ~= 0 then
		error(("memory size must be a power of two >= 1024 (got %d)"):format(bytes))
	end
	if bytes > 0x100000000 then
		error(("memory size must fit the 32-bit physical bus (got %d)"):format(bytes))
	end
	return setmetatable({
		buf = buffer.create(bytes),
		size = bytes,
		mask = bytes - 1,
		a20 = false,
		rom = nil,
		romBase = Memory.ROM_BASE,
		romSize = 0,
		romLowOffset = 0,
		romHighBase = 0,
		romShadowed = false,
		lowRomLocked = false,
	}, Memory)
end

-- Load a BIOS image. QEMU/SeaBIOS's 256 KiB build is linked for the top of the
-- 32-bit address space (0xFFFC0000-0xFFFFFFFF) and its last 128 KiB are
-- mirrored at E0000-FFFFF for the legacy reset/BIOS window. The reset vector's
-- far jump to F000:E05B therefore lands in the low mirror while the main body
-- can also be fetched through the high mapping by 32-bit code.
function Memory:loadRom(image: buffer, base: number?)
	const length = buffer.len(image)
	if length == 0 or length > Memory.ROM_SIZE then
		error(("BIOS image must be 1..%d bytes (got %d)"):format(Memory.ROM_SIZE, length))
	end
	const start = base or Memory.ROM_BASE
	if start < Memory.ROM_BASE or start + math.min(length, 0x20000) > 0x100000 then
		error(("BIOS low window %d bytes does not fit E0000-FFFFF (base %X)"):format(length, start))
	end
	self.rom = image
	self.romBase = start
	self.romSize = length
	-- The legacy window is the last 128 KiB of the image, placed linearly at
	-- E0000. For a 256 KiB image that is offset 0x20000.
	self.romLowOffset = math.max(0, length - 0x20000)
	self.romHighBase = 0x100000000 - length
	-- Real chipsets shadow the BIOS into RAM before POST finishes. SeaBIOS's
	-- 32-bit flat code/BSS and F-segment allocator live in E0000-FFFFF, so the
	-- legacy alias is a writable copy of the image's last 128 KiB. The 256 KiB
	-- high mapping at 0xFFFC0000 remains the read-only ROM.
	if self.size >= 0x100000 then
		const shadowLength = math.min(length, 0x20000)
		buffer.copy(self.buf, 0xE0000, image, length - shadowLength, shadowLength)
		self.romShadowed = true
	end
	return start
end

function Memory:hasRom(): boolean
	return self.rom ~= nil
end

-- SeaBIOS locks the legacy BIOS shadow through the i440FX PAM registers just
-- before boot. Keeping C0000-FFFFF writable after that lets a boot loader's
-- El Torito image overwrite the running firmware.
function Memory:lockLowRom(locked: boolean)
	self.lowRomLocked = locked
end

-- Option ROMs are shadowed into the C0000-DFFFF expansion window. The window
-- is already plain RAM, so a copy is enough for SeaBIOS's option-ROM scanner.
function Memory:loadOptionRom(image: buffer, base: number?)
	const length = buffer.len(image)
	const start = base or 0xC0000
	if length == 0 or start < 0xC0000 or start + length > 0xE0000 then
		error(("option ROM %d bytes does not fit C0000-DFFFF (base %X)"):format(length, start))
	end
	if self.size < start + length then
		error("option ROM exceeds configured RAM")
	end
	buffer.copy(self.buf, start, image, 0, length)
	return start
end

-- Physical translation: A20M first, then the 32-bit bus. No wrap at RAM size.
function Memory:translate(addr: number): number
	addr = band(addr, 0xFFFFFFFF)
	if not self.a20 then
		addr = band(addr, bit32.bnot(A20_BIT))
	end
	return addr
end

-- A20 is exposed both as a plain field (mem.a20 = true, used by XMS) and as a
-- gate helper so chipset code can share the port-0x92 path.
function Memory:setA20(on: boolean)
	self.a20 = on
end

function Memory:isProtected(addr: number): boolean
	const start = self.protectStart
	const stop = self.protectEnd
	return start ~= nil and stop ~= nil and addr >= start and addr <= stop
end

-- True when [addr, addr+length) is plain RAM with no aperture or ROM shadow.
function Memory:isRam(addr: number, length: number): boolean
	if length <= 0 or addr + length > self.size then
		return false
	end
	const last = addr + length - 1
	if addr < APERTURE_START then
		return last < APERTURE_START
	elseif addr < ONE_MIB then
		if addr >= TEXT_START and addr <= TEXT_END then
			return last <= TEXT_END
		end
		-- C0000-DFFFF is option-ROM/shadow RAM. SeaBIOS copies its 32-bit
		-- decompression stub there before switching to flat protected mode.
		if addr >= 0xC0000 and last <= 0xDFFFF then
			return true
		end
		if self.romShadowed and addr >= 0xE0000 and last <= 0xFFFFF then
			return true
		end
		return false
	end
	return true
end

function Memory:read8(addr: number): number
	addr = self:translate(addr)
	const rom = self.rom
	if rom then
		if addr >= self.romHighBase then
			const offset = addr - self.romHighBase
			if offset < self.romSize then
				return buffer.readu8(rom, offset)
			end
		end
		const romBase: number = self.romBase
		if addr >= romBase and addr <= 0xFFFFF then
			const shadowed = self.romShadowed and addr >= 0xE0000
			if not shadowed then
				const lowBase: number = self.romLowOffset
				const lowOffset: number = lowBase + addr - romBase
				if lowOffset < self.romSize then
					return buffer.readu8(rom, lowOffset)
				end
			end
		end
	end
	if self:isRam(addr, 1) then
		return buffer.readu8(self.buf, addr)
	end
	if addr >= APERTURE_START and addr <= APERTURE_END and self.aperture then
		return self.aperture:read8(addr)
	end
	-- No ROM installed: preserve the RVDM hypervisor's writable high segment.
	if not rom and addr >= Memory.ROM_BASE and addr <= 0xFFFFF and addr < self.size then
		return buffer.readu8(self.buf, addr)
	end
	return 0xFF
end

function Memory:read16(addr: number): number
	addr = self:translate(addr)
	if self:isRam(addr, 2) then
		return buffer.readu16(self.buf, addr)
	end
	if addr >= APERTURE_START and addr + 1 <= APERTURE_END and self.aperture then
		return self.aperture:read16(addr)
	end
	return bor(self:read8(addr), lshift(self:read8(addr + 1), 8))
end

function Memory:read32(addr: number): number
	addr = self:translate(addr)
	if self:isRam(addr, 4) then
		return buffer.readu32(self.buf, addr)
	end
	return bor(self:read16(addr), lshift(self:read16(addr + 2), 16))
end

function Memory:write8(addr: number, value: number)
	addr = self:translate(addr)
	if self:isProtected(addr) then
		return
	end
	if self.lowRomLocked and addr >= 0xC0000 and addr <= 0xFFFFF then
		return
	end
	if self:isRam(addr, 1) then
		buffer.writeu8(self.buf, addr, band(value, 0xFF))
		return
	end
	if addr >= APERTURE_START and addr <= APERTURE_END and self.aperture then
		self.aperture:write8(addr, value)
		return
	end
	-- No ROM installed: keep the hypervisor stub window writable.
	if not self.rom and addr >= Memory.ROM_BASE and addr <= 0xFFFFF and addr < self.size then
		buffer.writeu8(self.buf, addr, band(value, 0xFF))
	end
	-- ROM, option ROM and open bus are read-only.
end

function Memory:write16(addr: number, value: number)
	addr = self:translate(addr)
	if self:isProtected(addr) then
		return
	end
	if self.lowRomLocked and addr <= 0xFFFFF and addr + 1 >= 0xC0000 then
		self:write8(addr, band(value, 0xFF))
		self:write8(addr + 1, band(rshift(value, 8), 0xFF))
		return
	end
	if self:isRam(addr, 2) then
		buffer.writeu16(self.buf, addr, band(value, 0xFFFF))
		return
	end
	if addr >= APERTURE_START and addr + 1 <= APERTURE_END and self.aperture then
		self.aperture:write16(addr, value)
		return
	end
	self:write8(addr, value)
	self:write8(addr + 1, rshift(value, 8))
end

function Memory:write32(addr: number, value: number)
	addr = self:translate(addr)
	if self:isProtected(addr) then
		return
	end
	if self.lowRomLocked and addr <= 0xFFFFF and addr + 3 >= 0xC0000 then
		for index = 0, 3 do
			self:write8(addr + index, band(rshift(value, index * 8), 0xFF))
		end
		return
	end
	if self:isRam(addr, 4) then
		buffer.writeu32(self.buf, addr, band(value, 0xFFFFFFFF))
		return
	end
	self:write16(addr, band(value, 0xFFFF))
	self:write16(addr + 2, band(rshift(value, 16), 0xFFFF))
end

-- Copy a Luau buffer into memory at a physical address. This bypasses MMIO but
-- still respects ROM shadows and memory bounds.
function Memory:copyFrom(addr: number, src: buffer)
	const length = buffer.len(src)
	addr = self:translate(addr)
	if self:isRam(addr, length) and not self:isProtected(addr) then
		buffer.copy(self.buf, addr, src, 0, length)
		return
	end
	for index = 0, length - 1 do
		self:write8(addr + index, buffer.readu8(src, index))
	end
end

-- Copy a region of memory out as a new buffer.
function Memory:copyTo(addr: number, length: number): buffer
	local out = buffer.create(length)
	addr = self:translate(addr)
	if self:isRam(addr, length) then
		buffer.copy(out, 0, self.buf, addr, length)
		return out
	end
	for index = 0, length - 1 do
		buffer.writeu8(out, index, self:read8(addr + index))
	end
	return out
end

function Memory:writeString(addr: number, str: string)
	const base: number = self:translate(addr)
	for index = 1, #str do
		const byte = string.byte(str, index) :: number
		self:write8(base + index - 1, byte)
	end
end

function Memory:readString(addr: number, length: number): string
	const base: number = self:translate(addr)
	local parts: { string } = {}
	for index = 0, length - 1 do
		const byte: number = self:read8(base + index)
		parts[index + 1] = string.char(byte)
	end
	return table.concat(parts)
end

-- 8086-style segment:offset helper (20-bit wrap). 386 code should use the
-- CPU's segment caches instead; this remains for legacy callers and tests.
function Memory.phys(seg: number, off: number): number
	return band(lshift(seg, 4) + off, 0xFFFFF)
end

return Memory
