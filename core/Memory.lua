--!strict
-- Memory.lua -- configurable real-mode/physical address space backed by a buffer.
-- 1 MiB by default (3.0a baseline); 4 MiB for Windows 3.1 PM/HMA work.
-- A20 is off after reset, so addresses above 1 MiB fold into low memory until
-- the guest (XMS driver) enables the gate.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const Memory = {}
Memory.__index = Memory

Memory.SIZE = 1024 * 1024
const MASK_20 = 0xFFFFF
const APERTURE_START = 0xA0000
const APERTURE_END = 0xAFFFF

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
	},
	Memory
))

function Memory.new(size: number?): Memory
	local bytes = size or Memory.SIZE
	if bytes < 1024 or band(bytes, bytes - 1) ~= 0 then
		error(("memory size must be a power of two >= 1024 (got %d)"):format(bytes))
	end
	return setmetatable({
		buf = buffer.create(bytes),
		size = bytes,
		mask = bytes - 1,
		a20 = false,
	}, Memory)
end

-- physical address translation: A20 gate first (fold bit 20 and above while
-- off), then wrap at the configured RAM size.
function Memory:translate(addr: number): number
	if not self.a20 then
		addr = band(addr, MASK_20)
	end
	return band(addr, self.mask)
end

-- (annotated above so callers see a plain number; the buffer API is untyped)

-- The hypervisor's IVT/timer/XMS stubs live in the top of conventional RAM
-- (F100:xxxx). Real BIOS ROM is not writable, but our segment is backed by
-- RAM; Windows 3.1's WSWAP zero-fills all free memory above its program and
-- would otherwise wipe the stubs while the IVT still points at them.
function Memory:isProtected(addr: number): boolean
	const start = self.protectStart
	const stop = self.protectEnd
	return start ~= nil and stop ~= nil and addr >= start and addr <= stop
end

function Memory:read8(addr: number): number
	addr = self:translate(addr)
	const aperture = self.aperture
	if aperture and addr >= APERTURE_START and addr <= APERTURE_END then
		return aperture:read8(addr)
	end
	return buffer.readu8(self.buf, addr)
end

function Memory:read16(addr: number): number
	addr = self:translate(addr)
	const aperture = self.aperture
	if aperture and addr >= APERTURE_START and addr < APERTURE_END then
		return aperture:read16(addr)
	end
	if addr < self.mask then
		return buffer.readu16(self.buf, addr)
	end
	return bor(self:read8(addr), lshift(self:read8(addr + 1), 8))
end

function Memory:write8(addr: number, value: number)
	addr = self:translate(addr)
	if self:isProtected(addr) then
		return
	end
	const aperture = self.aperture
	if aperture and addr >= APERTURE_START and addr <= APERTURE_END then
		aperture:write8(addr, value)
		return
	end
	buffer.writeu8(self.buf, addr, band(value, 0xFF))
end

function Memory:write16(addr: number, value: number)
	addr = self:translate(addr)
	if self:isProtected(addr) then
		return
	end
	const aperture = self.aperture
	if aperture and addr >= APERTURE_START and addr < APERTURE_END then
		aperture:write16(addr, value)
		return
	end
	if addr < self.mask then
		buffer.writeu16(self.buf, addr, band(value, 0xFFFF))
	else
		self:write8(addr, value)
		self:write8(addr + 1, rshift(value, 8))
	end
end

-- Copy a Luau buffer into memory at a physical address.
function Memory:copyFrom(addr: number, src: buffer)
	buffer.copy(self.buf, self:translate(addr), src, 0, buffer.len(src))
end

-- Copy a region of memory out as a new buffer.
function Memory:copyTo(addr: number, length: number): buffer
	local out = buffer.create(length)
	buffer.copy(out, 0, self.buf, self:translate(addr), length)
	return out
end

function Memory:writeString(addr: number, str: string)
	const base: number = self:translate(addr)
	for index = 1, #str do
		const byte = string.byte(str, index) :: number
		buffer.writeu8(self.buf, base + index - 1, byte)
	end
end

function Memory:readString(addr: number, length: number): string
	const base: number = self:translate(addr)
	local parts: { string } = {}
	for index = 0, length - 1 do
		const byte: number = buffer.readu8(self.buf, base + index)
		parts[index + 1] = string.char(byte)
	end
	return table.concat(parts)
end

-- physical segment:offset helper (20-bit wrap like a real 8086)
function Memory.phys(seg: number, off: number): number
	return band(lshift(seg, 4) + off, MASK_20)
end

return Memory
