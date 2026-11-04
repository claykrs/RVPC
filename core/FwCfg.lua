--!strict
-- FwCfg.lua -- minimal QEMU fw_cfg PIO interface for the prebuilt SeaBIOS ROM.
--
-- QEMU's SeaBIOS build asks fw_cfg for the initial e820 map before it falls
-- back to CMOS. Providing the file directory and etc/e820 is what lets the
-- firmware see the machine's RAM without QEMU's help. No DMA and no ACPI table
-- blobs are advertised; SeaBIOS falls back to its built-in ACPI/SMBIOS paths.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const FwCfg = {}
FwCfg.__index = FwCfg

const PORT_SELECT = 0x510
const PORT_DATA = 0x511

const SIG = 0x0000
const ID = 0x0001
const UUID = 0x0002
const NOGRAPHIC = 0x0004
const NB_CPUS = 0x0005
const NUMA = 0x000D
const BOOT_MENU = 0x000E
const MAX_CPUS = 0x000F
const FILE_DIR = 0x0019
const ACPI_TABLES = 0x8000
const SMBIOS_ENTRIES = 0x8001
const IRQ0_OVERRIDE = 0x8002
const E820_TABLE = 0x8003

export type FwCfg = typeof(setmetatable(
	{} :: {
		entries: { [number]: string },
		selector: number,
		offset: number,
		selectCount: number,
		lastSelector: number,
		in8: (self: FwCfg, port: number) -> number,
		out8: (self: FwCfg, port: number, value: number) -> (),
		in16: (self: FwCfg, port: number) -> number,
		out16: (self: FwCfg, port: number, value: number) -> (),
	},
	FwCfg
))

local function u16le(value: number): string
	return string.char(band(value, 0xFF), band(rshift(value, 8), 0xFF))
end

local function u32le(value: number): string
	return string.char(
		band(value, 0xFF),
		band(rshift(value, 8), 0xFF),
		band(rshift(value, 16), 0xFF),
		band(rshift(value, 24), 0xFF)
	)
end

local function u16be(value: number): string
	return string.char(band(rshift(value, 8), 0xFF), band(value, 0xFF))
end

local function u32be(value: number): string
	return string.char(
		band(rshift(value, 24), 0xFF),
		band(rshift(value, 16), 0xFF),
		band(rshift(value, 8), 0xFF),
		band(value, 0xFF)
	)
end

local function u64le(value: number): string
	return u32le(band(value, 0xFFFFFFFF))
		.. u32le(band(math.floor(value / 0x100000000), 0xFFFFFFFF))
end

local function e820Entry(address: number, length: number, kind: number): string
	return u64le(address) .. u64le(length) .. u32le(kind)
end

local function buildE820(memorySize: number): string
	const lowRam = 0x9FC00
	const parts = {
		e820Entry(0, lowRam, 1),
		e820Entry(lowRam, 0x400, 2),
		e820Entry(0xA0000, 0x60000, 2),
		e820Entry(0x100000, memorySize - 0x100000, 1),
		e820Entry(0xFFFC0000, 0x40000, 2),
	}
	return table.concat(parts)
end

local function padName(name: string): string
	if #name >= 56 then
		return string.sub(name, 1, 56)
	end
	return name .. string.rep("\0", 56 - #name)
end

local function buildDirectory(files: { { name: string, select: number, data: string } }): string
	local parts = { u32be(#files) }
	for _, file in files do
		parts[#parts + 1] = u32be(#file.data)
		parts[#parts + 1] = u16be(file.select)
		parts[#parts + 1] = u16be(0)
		parts[#parts + 1] = padName(file.name)
	end
	return table.concat(parts)
end

function FwCfg.new(memorySize: number, vgaRom: buffer?): FwCfg
	local self = setmetatable({}, FwCfg) :: any
	const e820 = buildE820(memorySize)
	-- SeaBIOS matches bootorder entries against enumerated /pci paths. Put the
	-- slave ATAPI CD first, then the master HDD, so a blank disk cannot mask a
	-- bootable ISO.
	const bootOrder = "/pci@i0cf8/*@1/drive@0/disk@1\n/pci@i0cf8/*@1/drive@0/disk@0\n"
	const files = {
		{ name = "etc/e820", select = 0x20, data = e820 },
		{ name = "bootorder", select = 0x21, data = bootOrder },
		-- <0 disables the timed "Press ESC" wait and goes straight to the
		-- device list; useful for headless diagnostics.
		{ name = "etc/boot-menu-wait", select = 0x23, data = u32le(0xFFFFFFFF) },
	}
	if vgaRom then
		files[#files + 1] = {
			name = "vgaroms/vgabios-stdvga.bin",
			select = 0x22,
			data = buffer.tostring(vgaRom),
		}
	end
	self.entries = {
		[SIG] = "QEMU",
		[ID] = u32le(1), -- traditional PIO only
		[UUID] = string.rep("\0", 16),
		[NOGRAPHIC] = u16le(0),
		[NB_CPUS] = u16le(1),
		[NUMA] = u64le(0),
		[BOOT_MENU] = u16le(1),
		[MAX_CPUS] = u16le(1),
		[FILE_DIR] = buildDirectory(files),
		[ACPI_TABLES] = u16le(0),
		[SMBIOS_ENTRIES] = u16le(0),
		[IRQ0_OVERRIDE] = string.char(0),
		[E820_TABLE] = u32le(0),
	}
	for _, file in files do
		self.entries[file.select] = file.data
	end
	self.selector = 0
	self.offset = 0
	self.selectCount = 0
	self.lastSelector = 0
	return self
end

function FwCfg.out8(self: FwCfg, port: number, value: number)
	if port == PORT_SELECT then
		self.selector = band(value, 0xFF)
		self.offset = 0
	end
end

function FwCfg.out16(self: FwCfg, port: number, value: number)
	if port == PORT_SELECT then
		self.selector = band(value, 0xFFFF)
		self.offset = 0
		self.selectCount += 1
		self.lastSelector = self.selector
	end
end

function FwCfg.in8(self: FwCfg, port: number): number
	if port == PORT_SELECT then
		return band(self.selector, 0xFF)
	elseif port == PORT_DATA then
		const data = self.entries[self.selector] or ""
		if self.offset >= #data then
			return 0
		end
		const value = string.byte(data, self.offset + 1) :: number
		self.offset += 1
		return value
	end
	return 0xFF
end

function FwCfg.in16(self: FwCfg, port: number): number
	if port == PORT_SELECT then
		return self.selector
	end
	return bor(self:in8(port), lshift(self:in8(port), 8))
end

return FwCfg
