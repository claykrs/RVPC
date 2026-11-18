--!nonstrict
-- MemoryTests.lua -- 32-bit physical memory, A20, RAM bounds and ROM mapping.

const Memory = require("../core/Memory")

const MB = 1024 * 1024

local TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

T("configurable_sizes", function(expect)
	for _, size in ipairs({ 16 * MB, 32 * MB, 64 * MB }) do
		const mem = Memory.new(size)
		expect(mem.size == size, "size=" .. mem.size)
		expect(mem.mask == size - 1, "mask=" .. mem.mask)
	end
end)

T("32bit_ram_above_1m", function(expect)
	const mem = Memory.new(32 * MB)
	mem.a20 = true
	mem:write32(0x01234560, 0xDEADBEEF)
	expect(mem:read32(0x01234560) == 0xDEADBEEF, "read32")
	mem:write16(0x01FFFFFE, 0xCAFE)
	expect(mem:read16(0x01FFFFFE) == 0xCAFE, "read16")
	mem:write8(0x01FFFF00, 0xA5)
	expect(mem:read8(0x01FFFF00) == 0xA5, "read8 near 32M")
end)

T("a20_folds_bit_20", function(expect)
	const mem = Memory.new(16 * MB)
	mem.a20 = false
	mem:write8(0x000000, 0x11)
	mem:write8(0x100000, 0x22)
	expect(mem:read8(0x000000) == 0x22, "1M should alias 0 while A20 is off")
	-- A20M only forces bit 20 low; bit 21 and above are untouched.
	mem:write8(0x200000, 0x33)
	expect(mem:read8(0x200000) == 0x33, "2M should not fold")
	mem.a20 = true
	mem:write8(0x100000, 0x44)
	expect(mem:read8(0x000000) == 0x22, "0 changed when A20 opened")
	expect(mem:read8(0x100000) == 0x44, "1M not writable with A20 on")
end)

T("open_bus_above_ram", function(expect)
	const mem = Memory.new(16 * MB)
	mem.a20 = true
	expect(mem:read8(0x02000000) == 0xFF, "unmapped read8")
	expect(mem:read16(0x02000000) == 0xFFFF, "unmapped read16")
	expect(mem:read32(0x02000000) == 0xFFFFFFFF, "unmapped read32")
	mem:write8(0x02000000, 0x12)
	mem:write32(0x02000000, 0x12345678)
	expect(mem:read8(0x02000000) == 0xFF, "unmapped write changed memory")
end)

T("bios_rom_low_and_high", function(expect)
	const mem = Memory.new(32 * MB)
	mem.a20 = true
	const image = buffer.create(0x40000)
	for index = 0, 0x3FFFF do
		buffer.writeu8(image, index, index % 251)
	end
	buffer.writeu8(image, 0x3FFF0, 0xEA)
	buffer.writeu8(image, 0x3FFF1, 0x5B)
	buffer.writeu8(image, 0x3FFFF, 0xAA)
	mem:loadRom(image)
	-- The low alias is the last 128 KiB, shadowed into RAM at E0000.
	expect(mem:read8(0xFFFF0) == 0xEA, "low reset vector")
	expect(mem:read8(0xFFFFF) == 0xAA, "low last byte")
	-- The full 256 KiB image is mapped read-only at the top of 32-bit space.
	expect(mem:read8(0xFFFC0000 + 0x3FFFF) == 0xAA, "high last byte")
	mem:write8(0xFFFC0000 + 0x3FFFF, 0x55)
	expect(mem:read8(0xFFFC0000 + 0x3FFFF) == 0xAA, "high ROM write was not ignored")
	-- The F-segment is shadow RAM: SeaBIOS needs writable BSS there.
	mem:write8(0xF0000, 0x5A)
	expect(mem:read8(0xF0000) == 0x5A, "F-segment shadow is not writable")
end)

T("option_rom_window", function(expect)
	const mem = Memory.new(16 * MB)
	const rom = buffer.create(512)
	buffer.writeu8(rom, 0, 0x55)
	buffer.writeu8(rom, 1, 0xAA)
	mem:loadOptionRom(rom, 0xC0000)
	expect(mem:read8(0xC0000) == 0x55 and mem:read8(0xC0001) == 0xAA, "option ROM header")
	mem:write8(0xC0000, 0x00)
	expect(mem:read8(0xC0000) == 0x00, "option ROM shadow should be writable")
end)

return TESTS
