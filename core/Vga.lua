--!strict
-- Vga.lua -- environment-pure VGA device model for RVPC.
--
-- The device owns the A0000..AFFFF aperture rather than Memory: a real VGA has
-- four 64 KiB planes behind one 64 KiB window, so the linear 1 MiB buffer
-- cannot represent it. Machine must route A0000..AFFFF accesses here and call
-- in8/out8 for 0x3C0..0x3DA. Unknown ports and registers latch instead of
-- faulting; VGA.DRV probes several of them during mode set.
--
-- Implemented: mode 12h (640x480x16 planar), mode 13h (320x200x256 linear),
-- text mode 3 fallback, write modes 0/1/2/3, read map select, colour compare,
-- set/reset, data rotate, bit mask, map mask, CRTC start/offset, DAC writes.
-- Text mode 3 reads B8000 directly through mem and does not use odd/even plane
-- addressing. Mode 13h collapses chain-4 address decode to a linear 64 KiB
-- buffer; its write modes and bit mask are not applied.
-- Not implemented: sync timing, interlace/double-scan timing, odd/even chaining,
-- hardware panning/line compare/cursor, and the 256 KiB VGA
-- memory map beyond the first 64 KiB.

const band, bor, bxor, lshift, rshift, bnot =
	bit32.band, bit32.bor, bit32.bxor, bit32.lshift, bit32.rshift, bit32.bnot

const APERTURE_BASE = 0xA0000
const APERTURE_SIZE = 0x10000
const PLANE_SIZE = 0x10000
const TEXT_BASE = 0xB8000
const TEXT_COLS = 80
const TEXT_ROWS = 25
const TEXT_CELL_WIDTH = 8
const TEXT_CELL_HEIGHT = 16
const RGBA_BLACK = 0xFF000000

type ModeKind = "text" | "planar" | "linear"

export type ModeInfo = {
	mode: number,
	kind: ModeKind,
	width: number,
	height: number,
	rowBytes: number,
	bitsPerPixel: number,
	label: string,
}

export type Memory = {
	read8: (self: any, addr: number) -> number,
	write8: (self: any, addr: number, value: number) -> (),
	read16: (self: any, addr: number) -> number,
	write16: (self: any, addr: number, value: number) -> (),
	copyFrom: (self: any, addr: number, src: buffer) -> (),
}

export type DirtyRect = {
	x: number,
	y: number,
	width: number,
	height: number,
}

export type Snapshot = {
	width: number,
	height: number,
	stride: number,
	pixels: buffer,
}

type ModeRegisters = {
	seq: { number },
	crtc: { number },
	gfx: { number },
	attr: { number },
	misc: number,
}

const MODES: { [number]: ModeInfo } = {
	[0x03] = {
		mode = 0x03,
		kind = "text",
		width = 640,
		height = 400,
		rowBytes = TEXT_COLS,
		bitsPerPixel = 4,
		label = "text 80x25",
	},
	[0x12] = {
		mode = 0x12,
		kind = "planar",
		width = 640,
		height = 480,
		rowBytes = 80,
		bitsPerPixel = 4,
		label = "640x480x16 planar",
	},
	[0x13] = {
		mode = 0x13,
		kind = "linear",
		width = 320,
		height = 200,
		rowBytes = 320,
		bitsPerPixel = 8,
		label = "320x200x256 linear",
	},
}

-- Canonical VGA BIOS register loads. CRTC 0x11 keeps bit 7 set, which is the
-- real write-protect state for CRTC 0..7; guests unlock by writing bit 7 = 0.
const MODE_REGISTERS: { [number]: ModeRegisters } = {
	[0x03] = {
		seq = { 0x03, 0x00, 0x03, 0x00, 0x02 },
		crtc = {
			0x5F,
			0x4F,
			0x50,
			0x82,
			0x55,
			0x81,
			0xBF,
			0x1F,
			0x00,
			0x4F,
			0x0D,
			0x0E,
			0x00,
			0x00,
			0x00,
			0x00,
			0x9C,
			0x8E,
			0x8F,
			0x28,
			0x1F,
			0x96,
			0xB9,
			0xA3,
			0xFF,
		},
		gfx = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0E, 0x00, 0xFF },
		attr = {
			0x00,
			0x01,
			0x02,
			0x03,
			0x04,
			0x05,
			0x14,
			0x07,
			0x38,
			0x39,
			0x3A,
			0x3B,
			0x3C,
			0x3D,
			0x3E,
			0x3F,
			0x0C,
			0x00,
			0x0F,
			0x08,
			0x00,
		},
		misc = 0x67,
	},
	[0x12] = {
		seq = { 0x03, 0x01, 0x0F, 0x00, 0x06 },
		crtc = {
			0x5F,
			0x4F,
			0x50,
			0x82,
			0x54,
			0x80,
			0x0B,
			0x3E,
			0x00,
			0x40,
			0x00,
			0x00,
			0x00,
			0x00,
			0x00,
			0x00,
			0xEA,
			0x8C,
			0xDF,
			0x28,
			0x00,
			0xE7,
			0x04,
			0xE3,
			0xFF,
		},
		gfx = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x0F, 0xFF },
		attr = {
			0x00,
			0x01,
			0x02,
			0x03,
			0x04,
			0x05,
			0x06,
			0x07,
			0x08,
			0x09,
			0x0A,
			0x0B,
			0x0C,
			0x0D,
			0x0E,
			0x0F,
			0x01,
			0x00,
			0x0F,
			0x00,
			0x00,
		},
		misc = 0xE3,
	},
	[0x13] = {
		seq = { 0x03, 0x01, 0x0F, 0x00, 0x0E },
		crtc = {
			0x5F,
			0x4F,
			0x50,
			0x82,
			0x54,
			0x80,
			0xBF,
			0x1F,
			0x00,
			0x41,
			0x00,
			0x00,
			0x00,
			0x00,
			0x00,
			0x00,
			0x9C,
			0x8E,
			0x8F,
			0x28,
			0x40,
			0x96,
			0xB9,
			0xA3,
			0xFF,
		},
		gfx = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x40, 0x05, 0x0F, 0xFF },
		attr = {
			0x00,
			0x01,
			0x02,
			0x03,
			0x04,
			0x05,
			0x06,
			0x07,
			0x08,
			0x09,
			0x0A,
			0x0B,
			0x0C,
			0x0D,
			0x0E,
			0x0F,
			0x41,
			0x00,
			0x0F,
			0x00,
			0x00,
		},
		misc = 0x63,
	},
}

-- Standard VGA/EGA default DAC entries 0..15 (6-bit components).
const EGA_RGB: { { number } } = {
	{ 0, 0, 0 },
	{ 0, 0, 42 },
	{ 0, 42, 0 },
	{ 0, 42, 42 },
	{ 42, 0, 0 },
	{ 42, 0, 42 },
	{ 42, 21, 0 },
	{ 42, 42, 42 },
	{ 21, 21, 21 },
	{ 21, 21, 63 },
	{ 21, 63, 21 },
	{ 21, 63, 63 },
	{ 63, 21, 21 },
	{ 63, 21, 63 },
	{ 63, 63, 21 },
	{ 63, 63, 63 },
}

const CUBE_LEVELS: { number } = { 0, 12, 25, 38, 50, 63 }

-- 8x8 fallback glyphs for ASCII 32..126, one 16-hex-digit row-major bitmap per
-- character. Text mode is only a diagnostic fallback; VGA.DRV uses mode 12h.
const FONT_HEX: { string } = {
	"0000000000000000", -- space
	"0020202020202000", -- !
	"0050500000000000", -- "
	"0028287828705000", -- #
	"0030582018583810", -- $
	"003454780E151700", -- %
	"00102810344C3C00", -- &
	"0040400000000000", -- '
	"0020202040402020", -- (
	"0040202020202020", -- )
	"0020705000000000", -- *
	"0000101078100000", -- +
	"0000000000002020", -- ,
	"0000000060000000", -- -
	"0000000000002000", -- .
	"0020202040404000", -- /
	"0030484848483800", -- 0
	"0010301010101000", -- 1
	"0030480810207800", -- 2
	"0030481808483800", -- 3
	"0010103050781000", -- 4
	"0038203008483800", -- 5
	"0030487048483800", -- 6
	"0078080810102000", -- 7
	"0030482838483800", -- 8
	"0030484838483000", -- 9
	"0000002000002000", -- :
	"0000002000002020", -- ;
	"0000083060180000", -- <
	"0000007878000000", -- =
	"0000403018600000", -- >
	"0030480810101000", -- ?
	"001E212E52525F20", -- @
	"0010182838444400", -- A
	"0038242834243800", -- B
	"0018244040243C00", -- C
	"0038242424243800", -- D
	"003C20203C203C00", -- E
	"003C202038202000", -- F
	"001C22404E223E00", -- G
	"0024243C24242400", -- H
	"0020202020202000", -- I
	"0010101010503000", -- J
	"0024283028282400", -- K
	"0020202020203800", -- L
	"00222636363A2A00", -- M
	"002424342C2C2400", -- N
	"001C224242223C00", -- O
	"0038242438202000", -- P
	"001C2242422A3E00", -- Q
	"003C242438242400", -- R
	"003844300C443800", -- S
	"007C101010101000", -- T
	"0024242424243C00", -- U
	"0044442428181000", -- V
	"00494D2D35321200", -- W
	"0044281010284400", -- X
	"0044242810101000", -- Y
	"007C081010207C00", -- Z
	"0020202020202020", -- [
	"0040404020202000", -- backslash
	"0060202020202020", -- ]
	"0020305000000000", -- ^
	"0000000000000078", -- _
	"0060000000000000", -- `
	"0000007838487800", -- a
	"0020203828283800", -- b
	"0000003840403800", -- c
	"0008083848483800", -- d
	"0000003878403800", -- e
	"0020206020202000", -- f
	"0000003848483848", -- g
	"0020203828282800", -- h
	"0020002020202000", -- i
	"0040004040404040", -- j
	"0020203820302800", -- k
	"0020202020202000", -- l
	"0000003E2A2A2A00", -- m
	"0000003828282800", -- n
	"0000003848483800", -- o
	"0000003828283820", -- p
	"0000003848483808", -- q
	"0000003020202000", -- r
	"0000007860187000", -- s
	"0000206020202000", -- t
	"0000002828283800", -- u
	"0000004830303000", -- v
	"000000525C2C2400", -- w
	"0000007830304800", -- x
	"0000004830303020", -- y
	"0000007810207800", -- z
	"0020202060202020", -- {
	"0020202020202020", -- |
	"0040202020202020", -- }
	"0038480000000000", -- ~
}

const FONT_BYTES = table.concat(FONT_HEX, "")

local function decodeFont(): { [number]: { number } }
	local glyphs: { [number]: { number } } = {}
	for code = 32, 126 do
		const rows = table.create(8, 0) :: { number }
		const base = (code - 32) * 16 + 1
		for row = 0, 7 do
			const first = base + row * 2
			rows[row] = tonumber(string.sub(FONT_BYTES, first, first + 1), 16) or 0
		end
		glyphs[code] = rows
	end
	return glyphs
end

const FONT = decodeFont()

local function dac6To8(value: number): number
	const component = band(value, 0x3F)
	return bor(lshift(component, 2), rshift(component, 4))
end

local function rgbaWord(r: number, g: number, b: number): number
	return bor(bor(bor(r, lshift(g, 8)), lshift(b, 16)), 0xFF000000)
end

local function apertureOffset(addr: number): number
	if addr >= APERTURE_BASE then
		return band(addr - APERTURE_BASE, 0xFFFF)
	end
	return band(addr, 0xFFFF)
end

local function rotateRight(value: number, count: number): number
	if count == 0 then
		return band(value, 0xFF)
	end
	return band(bor(rshift(value, count), lshift(value, 8 - count)), 0xFF)
end

local function applyDataFunction(data: number, latch: number, fn: number): number
	if fn == 1 then
		return band(data, latch)
	elseif fn == 2 then
		return bor(data, latch)
	elseif fn == 3 then
		return bxor(data, latch)
	end
	return data
end

const Vga = {}
Vga.__index = Vga

Vga.APERTURE_BASE = APERTURE_BASE
Vga.APERTURE_SIZE = APERTURE_SIZE
Vga.PLANE_SIZE = PLANE_SIZE

-- Cheap routing predicate for a future Memory/CPU aperture hook.
function Vga.containsAddress(addr: number): boolean
	const physical = band(addr, 0xFFFFF)
	return physical >= APERTURE_BASE and physical < APERTURE_BASE + APERTURE_SIZE
end

export type Vga = typeof(setmetatable(
	{} :: {
		mem: Memory,
		modeNumber: number,
		info: ModeInfo,
		crtc: { number },
		crtcIndex: number,
		crtcProtected: boolean,
		seq: { number },
		seqIndex: number,
		gfx: { number },
		gfxIndex: number,
		attr: { number },
		attrIndex: number,
		attrFlipFlop: boolean,
		attrPas: boolean,
		misc: number,
		feature: number,
		dac: buffer,
		dacWriteIndex: number,
		dacReadIndex: number,
		dacWriteComponent: number,
		dacReadComponent: number,
		dacMask: number,
		planes: { buffer },
		chain4: buffer,
		latches: { number },
		rgba: buffer,
		widthPx: number,
		heightPx: number,
		dirty: boolean,
		dirtyX0: number,
		dirtyY0: number,
		dirtyX1: number,
		dirtyY1: number,
		statusPhase: boolean,
		paletteDirty: boolean,
		paletteRGBA: { number },
		color16RGBA: { number },
		latched: { [number]: number },
	},
	Vga
))

function Vga.new(mem: Memory): Vga
	const self = setmetatable({}, Vga) :: any
	self.mem = mem
	self.modeNumber = 0x03
	self.info = MODES[0x03] :: ModeInfo
	self.crtc = table.create(25, 0) :: { number }
	self.crtcIndex = 0
	self.crtcProtected = false
	self.seq = table.create(5, 0) :: { number }
	self.seqIndex = 0
	self.gfx = table.create(9, 0) :: { number }
	self.gfxIndex = 0
	self.attr = table.create(21, 0) :: { number }
	self.attrIndex = 0
	self.attrFlipFlop = true
	self.attrPas = true
	self.misc = 0
	self.feature = 0
	self.dac = buffer.create(256 * 3)
	self.dacWriteIndex = 0
	self.dacReadIndex = 0
	self.dacWriteComponent = 0
	self.dacReadComponent = 0
	self.dacMask = 0xFF
	self.planes = {
		buffer.create(PLANE_SIZE),
		buffer.create(PLANE_SIZE),
		buffer.create(PLANE_SIZE),
		buffer.create(PLANE_SIZE),
	}
	self.chain4 = buffer.create(PLANE_SIZE)
	self.latches = table.create(4, 0) :: { number }
	self.rgba = buffer.create(1) -- replaced by setMode
	self.widthPx = 640
	self.heightPx = 480
	self.dirty = false
	self.dirtyX0 = 0
	self.dirtyY0 = 0
	self.dirtyX1 = 0
	self.dirtyY1 = 0
	self.statusPhase = false
	self.paletteDirty = true
	self.paletteRGBA = table.create(256, 0) :: { number }
	self.color16RGBA = table.create(16, 0) :: { number }
	self.latched = {}
	self:resetPalette()
	self:setMode(0x03)
	return self
end

-- ---------------------------------------------------------------- mode state

function Vga.mode(self: Vga): number
	return self.modeNumber
end

function Vga.modeInfo(self: Vga): ModeInfo
	return self.info
end

function Vga.width(self: Vga): number
	return self.widthPx
end

function Vga.height(self: Vga): number
	return self.heightPx
end

function Vga.stride(self: Vga): number
	return self.widthPx * 4
end

function Vga.isTextMode(self: Vga): boolean
	return self.info.kind == "text"
end

function Vga.isChain4(self: Vga): boolean
	return band(self.seq[4], 0x08) ~= 0
end

function Vga.isOddEven(self: Vga): boolean
	return not self:isChain4() and band(self.seq[4], 0x04) == 0
end

function Vga.isBlanked(self: Vga): boolean
	return not self.attrPas or band(self.seq[1], 0x20) ~= 0 or band(self.misc, 0x02) == 0
end

function Vga.readCrtc(self: Vga, index: number): number
	return band(self.crtc[band(index, 0x1F)] or 0, 0xFF)
end

function Vga.readSeq(self: Vga, index: number): number
	return band(self.seq[band(index, 0x07)] or 0, 0xFF)
end

function Vga.readGfx(self: Vga, index: number): number
	return band(self.gfx[band(index, 0x0F)] or 0, 0xFF)
end

function Vga.readAttr(self: Vga, index: number): number
	return band(self.attr[band(index, 0x1F)] or 0, 0xFF)
end

function Vga.readDac(self: Vga, index: number): (number, number, number)
	const base = band(index, 0xFF) * 3
	return buffer.readu8(self.dac, base),
		buffer.readu8(self.dac, base + 1),
		buffer.readu8(self.dac, base + 2)
end

function Vga.setMode(self: Vga, mode: number): boolean
	const key = band(mode, 0xFF)
	const info = MODES[key]
	const registers = MODE_REGISTERS[key]
	if info == nil or registers == nil then
		return false
	end

	self.modeNumber = key
	self.info = info
	self.crtcProtected = false
	for index = 0, 24 do
		self.crtc[index] = registers.crtc[index + 1] or 0
	end
	for index = 0, 4 do
		self.seq[index] = registers.seq[index + 1] or 0
	end
	for index = 0, 8 do
		self.gfx[index] = registers.gfx[index + 1] or 0
	end
	for index = 0, 20 do
		self.attr[index] = registers.attr[index + 1] or 0
	end

	self.misc = registers.misc
	self.feature = 0
	self.crtcIndex = 0
	self.seqIndex = 0
	self.gfxIndex = 0
	self.attrIndex = 0
	self.attrFlipFlop = true
	self.attrPas = true
	self.dacWriteIndex = 0
	self.dacReadIndex = 0
	self.dacWriteComponent = 0
	self.dacReadComponent = 0
	self.dacMask = 0xFF
	self.statusPhase = false
	self.crtcProtected = band(self.crtc[0x11], 0x80) ~= 0

	for plane = 0, 3 do
		self.latches[plane] = 0
		buffer.fill(self.planes[plane + 1], 0, 0, PLANE_SIZE)
	end
	buffer.fill(self.chain4, 0, 0, PLANE_SIZE)

	self.widthPx = info.width
	self.heightPx = info.height
	self.rgba = buffer.create(info.width * info.height * 4)
	self:resetPalette()
	self:markAllDirty()
	return true
end

-- ------------------------------------------------------------------ palette

local function writeDacEntry(dac: buffer, index: number, red: number, green: number, blue: number)
	const base = index * 3
	buffer.writeu8(dac, base, band(red, 0x3F))
	buffer.writeu8(dac, base + 1, band(green, 0x3F))
	buffer.writeu8(dac, base + 2, band(blue, 0x3F))
end

-- BIOS mode 3/12h palette: the first 64 DAC entries are the EGA gamut. Text
-- mode maps attributes 8..15 to 0x38..0x3F and brown to 0x14, so those entries
-- must be populated even though mode 12h only uses 0x00..0x0F.
function Vga.loadEgaPalette(self: Vga)
	for index = 0, 255 do
		writeDacEntry(self.dac, index, 0, 0, 0)
	end
	for index = 0, 63 do
		if index == 0x14 then
			writeDacEntry(self.dac, index, 42, 21, 0)
		elseif index >= 0x38 then
			const rgb = EGA_RGB[index - 0x38 + 9]
			writeDacEntry(self.dac, index, rgb[1], rgb[2], rgb[3])
		else
			const rgb = EGA_RGB[index % 16 + 1]
			writeDacEntry(self.dac, index, rgb[1], rgb[2], rgb[3])
		end
	end
	self.paletteDirty = true
end

-- Mode 13h/8bpp default: EGA 0..15, 16 grey levels, a 6x6x6 colour cube,
-- then eight black entries (the BIOS 256-colour table).
function Vga.loadVga256Palette(self: Vga)
	for index = 0, 255 do
		if index < 16 then
			const rgb = EGA_RGB[index + 1]
			writeDacEntry(self.dac, index, rgb[1], rgb[2], rgb[3])
		elseif index < 32 then
			const grey = math.floor((index - 16) * 63 / 15 + 0.5)
			writeDacEntry(self.dac, index, grey, grey, grey)
		elseif index < 248 then
			const cube = index - 32
			const red = CUBE_LEVELS[math.floor(cube / 36) + 1]
			const green = CUBE_LEVELS[math.floor(cube / 6) % 6 + 1]
			const blue = CUBE_LEVELS[cube % 6 + 1]
			writeDacEntry(self.dac, index, red, green, blue)
		else
			writeDacEntry(self.dac, index, 0, 0, 0)
		end
	end
	self.paletteDirty = true
end

function Vga.resetPalette(self: Vga)
	if self.info.kind == "linear" then
		self:loadVga256Palette()
	else
		self:loadEgaPalette()
	end
end

function Vga.ensurePalette(self: Vga)
	if not self.paletteDirty then
		return
	end
	for index = 0, 255 do
		const base = index * 3
		const red = dac6To8(buffer.readu8(self.dac, base))
		const green = dac6To8(buffer.readu8(self.dac, base + 1))
		const blue = dac6To8(buffer.readu8(self.dac, base + 2))
		self.paletteRGBA[index + 1] = rgbaWord(red, green, blue)
	end
	for index = 0, 15 do
		const dacIndex = band(band(self.attr[index], 0x3F), self.dacMask)
		self.color16RGBA[index + 1] = self.paletteRGBA[dacIndex + 1]
	end
	self.paletteDirty = false
end

-- 8-bit RGB for a DAC index (the snapshot path uses the same expansion).
function Vga.paletteColor(self: Vga, index: number): (number, number, number)
	const red, green, blue = self:readDac(band(index, self.dacMask))
	return dac6To8(red), dac6To8(green), dac6To8(blue)
end

-- --------------------------------------------------------------- dirty rects

function Vga.markAllDirty(self: Vga)
	self.dirty = true
	self.dirtyX0 = 0
	self.dirtyY0 = 0
	self.dirtyX1 = self.widthPx
	self.dirtyY1 = self.heightPx
end

function Vga.markDirtyRect(self: Vga, x: number, y: number, width: number, height: number)
	if width <= 0 or height <= 0 then
		return
	end
	const x0 = math.max(0, math.floor(x))
	const y0 = math.max(0, math.floor(y))
	const x1 = math.min(self.widthPx, math.floor(x + width))
	const y1 = math.min(self.heightPx, math.floor(y + height))
	if x1 <= x0 or y1 <= y0 then
		return
	end
	if not self.dirty then
		self.dirty = true
		self.dirtyX0 = x0
		self.dirtyY0 = y0
		self.dirtyX1 = x1
		self.dirtyY1 = y1
		return
	end
	self.dirtyX0 = math.min(self.dirtyX0, x0)
	self.dirtyY0 = math.min(self.dirtyY0, y0)
	self.dirtyX1 = math.max(self.dirtyX1, x1)
	self.dirtyY1 = math.max(self.dirtyY1, y1)
end

function Vga.dirtyRect(self: Vga): DirtyRect?
	if not self.dirty then
		return nil
	end
	return {
		x = self.dirtyX0,
		y = self.dirtyY0,
		width = self.dirtyX1 - self.dirtyX0,
		height = self.dirtyY1 - self.dirtyY0,
	}
end

function Vga.consumeDirty(self: Vga): DirtyRect?
	const rect = self:dirtyRect()
	self.dirty = false
	return rect
end

function Vga.clearDirty(self: Vga)
	self.dirty = false
end

-- ------------------------------------------------------------ memory aperture

function Vga.displayStartBytes(self: Vga): number
	const words = bor(lshift(band(self.crtc[0x0C], 0xFF), 8), band(self.crtc[0x0D], 0xFF))
	return band(lshift(words, 1), 0xFFFF)
end

function Vga.planarRowBytes(self: Vga): number
	const offset = band(self.crtc[0x13], 0xFF) * 2
	if offset > 0 then
		return offset
	end
	return math.max(1, math.ceil(self.widthPx / 8))
end

function Vga.loadLatches(self: Vga, offset: number)
	for plane = 0, 3 do
		self.latches[plane] = buffer.readu8(self.planes[plane + 1], band(offset, 0xFFFF))
	end
end

function Vga.read8(self: Vga, addr: number): number
	if band(self.misc, 0x02) == 0 then
		return 0xFF
	end
	const offset = apertureOffset(addr)
	if self.info.kind == "linear" or self:isChain4() then
		return buffer.readu8(self.chain4, band(offset, 0xFFFF))
	end

	self:loadLatches(offset)

	-- Graphics Controller mode bit 3 selects colour-compare reads.
	if band(rshift(self.gfx[5], 3), 0x01) == 1 then
		const compare = band(self.gfx[2], 0x0F)
		const ignore = band(self.gfx[7], 0x0F)
		local value = 0
		for bit = 7, 0, -1 do
			const index = bor(
				band(rshift(self.latches[0], bit), 0x01),
				bor(
					lshift(band(rshift(self.latches[1], bit), 0x01), 1),
					bor(
						lshift(band(rshift(self.latches[2], bit), 0x01), 2),
						lshift(band(rshift(self.latches[3], bit), 0x01), 3)
					)
				)
			)
			if band(bxor(index, compare), band(bnot(ignore), 0x0F)) == 0 then
				value = bor(value, lshift(1, bit))
			end
		end
		return value
	end

	const plane = band(self.gfx[4], 0x03)
	return buffer.readu8(self.planes[plane + 1], band(offset, 0xFFFF))
end

function Vga.write8(self: Vga, addr: number, value: number)
	if band(self.misc, 0x02) == 0 then
		return
	end
	const offset = apertureOffset(addr)
	if self.info.kind == "linear" or self:isChain4() then
		buffer.writeu8(self.chain4, band(offset, 0xFFFF), band(value, 0xFF))
		self:markApertureDirty(offset)
		return
	end

	const data = band(value, 0xFF)
	const mode = band(self.gfx[5], 0x03)
	const mapMask = band(self.seq[2], 0x0F)
	const bitMask = band(self.gfx[8], 0xFF)

	for plane = 0, 3 do
		if band(mapMask, lshift(1, plane)) ~= 0 then
			local written: number
			if mode == 1 then
				-- Write mode 1: copy the latches; CPU data is ignored.
				written = self.latches[plane]
			elseif mode == 2 then
				-- Write mode 2: one data bit expands to a full plane byte.
				const source = band(data, lshift(1, plane)) ~= 0 and 0xFF or 0x00
				written =
					bor(band(source, bitMask), band(self.latches[plane], band(bnot(bitMask), 0xFF)))
			elseif mode == 3 then
				-- Write mode 3: CPU data AND bit mask selects the latched (or
				-- set/reset) source bits; the destination keeps the rest. This
				-- is the transparent/masked blit path most Win16 sprites use.
				const rotated = rotateRight(data, band(self.gfx[3], 0x07))
				const mask = band(rotated, bitMask)
				local source: number
				if band(self.gfx[1], lshift(1, plane)) ~= 0 then
					source = band(self.gfx[0], lshift(1, plane)) ~= 0 and 0xFF or 0x00
				else
					source = self.latches[plane]
				end
				const destination = buffer.readu8(self.planes[plane + 1], band(offset, 0xFFFF))
				written = bor(band(source, mask), band(destination, band(bnot(mask), 0xFF)))
			else
				const rotated = rotateRight(data, band(self.gfx[3], 0x07))
				const fn = band(rshift(self.gfx[3], 3), 0x03)
				local source: number
				if band(self.gfx[1], lshift(1, plane)) ~= 0 then
					-- Set/reset overrides CPU data for this plane.
					source = band(self.gfx[0], lshift(1, plane)) ~= 0 and 0xFF or 0x00
				else
					source = applyDataFunction(rotated, self.latches[plane], fn)
				end
				written =
					bor(band(source, bitMask), band(self.latches[plane], band(bnot(bitMask), 0xFF)))
			end
			buffer.writeu8(self.planes[plane + 1], band(offset, 0xFFFF), band(written, 0xFF))
		end
	end
	self:markApertureDirty(offset)
end

function Vga.read16(self: Vga, addr: number): number
	return bor(self:read8(addr), lshift(self:read8(addr + 1), 8))
end

function Vga.write16(self: Vga, addr: number, value: number)
	self:write8(addr, band(value, 0xFF))
	self:write8(addr + 1, band(rshift(value, 8), 0xFF))
end

function Vga.markApertureDirty(self: Vga, offset: number)
	const start = self:displayStartBytes()
	if offset < start then
		self:markAllDirty()
		return
	end
	const relative = offset - start
	if self.info.kind == "linear" or self:isChain4() then
		const x = relative % self.widthPx
		const y = math.floor(relative / self.widthPx)
		self:markDirtyRect(x, y, 1, 1)
		return
	end
	const rowBytes = self:planarRowBytes()
	const byteX = relative % rowBytes
	const y = math.floor(relative / rowBytes)
	self:markDirtyRect(byteX * 8, y, 8, 1)
end

-- Notify the device that a direct write to the aperture already happened (for
-- example a test writing planes, or a future Memory fast path). Normal guest
-- writes must go through vga:write8 so the write-mode logic runs.
function Vga.noteWrite(self: Vga, addr: number, length: number)
	if length <= 0 then
		return
	end
	const start = self:displayStartBytes()
	const first = apertureOffset(addr)
	if first < start then
		self:markAllDirty()
		return
	end
	const relativeFirst = first - start
	const relativeLast = relativeFirst + length - 1
	if relativeLast > 0xFFFF then
		self:markAllDirty()
		return
	end

	if self.info.kind == "linear" or self:isChain4() then
		const y0 = math.floor(relativeFirst / self.widthPx)
		const y1 = math.floor(relativeLast / self.widthPx)
		if y0 == y1 then
			self:markDirtyRect(relativeFirst % self.widthPx, y0, length, 1)
		else
			self:markDirtyRect(0, y0, self.widthPx, y1 - y0 + 1)
		end
		return
	end

	const rowBytes = self:planarRowBytes()
	const y0 = math.floor(relativeFirst / rowBytes)
	const y1 = math.floor(relativeLast / rowBytes)
	if y0 == y1 then
		const byteX0 = relativeFirst % rowBytes
		const byteX1 = relativeLast % rowBytes
		self:markDirtyRect(byteX0 * 8, y0, (byteX1 - byteX0 + 1) * 8, 1)
	else
		self:markDirtyRect(0, y0, self.widthPx, y1 - y0 + 1)
	end
end

-- ---------------------------------------------------------------- port access

function Vga.in8(self: Vga, port: number): number
	const address = band(port, 0xFFFF)

	if address == 0x3C0 then
		return band(self.attr[self.attrIndex] or 0, 0xFF)
	elseif address == 0x3C1 then
		return band(self.attr[self.attrIndex] or 0, 0xFF)
	elseif address == 0x3C2 or address == 0x3CC then
		return band(self.misc, 0xFF)
	elseif address == 0x3C4 then
		return self.seqIndex
	elseif address == 0x3C5 then
		return band(self.seq[self.seqIndex] or 0, 0xFF)
	elseif address == 0x3C6 then
		return self.dacMask
	elseif address == 0x3C7 then
		return self.dacReadIndex
	elseif address == 0x3C8 then
		return self.dacWriteIndex
	elseif address == 0x3C9 then
		const base = self.dacReadIndex * 3 + self.dacReadComponent
		const value = buffer.readu8(self.dac, base)
		self.dacReadComponent += 1
		if self.dacReadComponent >= 3 then
			self.dacReadComponent = 0
			self.dacReadIndex = band(self.dacReadIndex + 1, 0xFF)
		end
		return value
	elseif address == 0x3CA then
		return self.feature
	elseif address == 0x3CE then
		return self.gfxIndex
	elseif address == 0x3CF then
		return band(self.gfx[self.gfxIndex] or 0, 0xFF)
	elseif address == 0x3D4 or address == 0x3B4 then
		return self.crtcIndex
	elseif address == 0x3D5 or address == 0x3B5 then
		return band(self.crtc[self.crtcIndex] or 0, 0xFF)
	elseif address == 0x3DA or address == 0x3BA then
		-- A toggling retrace bit lets both wait-for-set and wait-for-clear loops
		-- terminate. Attribute reads and writes share this flip-flop.
		self.attrFlipFlop = true
		self.statusPhase = not self.statusPhase
		if self.statusPhase then
			return 0x09
		end
		return 0x00
	end

	return self.latched[address] or 0xFF
end

function Vga.writeCrtc(self: Vga, value: number)
	const index = self.crtcIndex
	if index == 0x11 then
		self.crtcProtected = band(value, 0x80) ~= 0
	elseif index <= 0x07 and self.crtcProtected then
		return
	end
	self.crtc[index] = band(value, 0xFF)
	if index == 0x0C or index == 0x0D or index == 0x13 then
		self:markAllDirty()
	end
end

function Vga.writeDac(self: Vga, value: number)
	const base = self.dacWriteIndex * 3 + self.dacWriteComponent
	buffer.writeu8(self.dac, base, band(value, 0x3F))
	self.dacWriteComponent += 1
	if self.dacWriteComponent >= 3 then
		self.dacWriteComponent = 0
		self.dacWriteIndex = band(self.dacWriteIndex + 1, 0xFF)
	end
	self.paletteDirty = true
	self:markAllDirty()
end

function Vga.out8(self: Vga, port: number, value: number)
	const address = band(port, 0xFFFF)
	const byte = band(value, 0xFF)

	if address == 0x3C0 then
		if self.attrFlipFlop then
			const wasEnabled = self.attrPas
			self.attrIndex = band(byte, 0x1F)
			self.attrPas = band(byte, 0x20) ~= 0
			self.attrFlipFlop = false
			if wasEnabled ~= self.attrPas then
				self:markAllDirty()
			end
		else
			self.attr[self.attrIndex] = byte
			self.attrFlipFlop = true
			self.paletteDirty = true
			self:markAllDirty()
		end
	elseif address == 0x3C2 then
		self.misc = byte
		self:markAllDirty()
	elseif address == 0x3C4 then
		self.seqIndex = band(byte, 0x07)
	elseif address == 0x3C5 then
		self.seq[self.seqIndex] = byte
		if self.seqIndex == 1 or self.seqIndex == 4 then
			self:markAllDirty()
		end
	elseif address == 0x3C6 then
		self.dacMask = byte
		self.paletteDirty = true
		self:markAllDirty()
	elseif address == 0x3C7 then
		self.dacReadIndex = byte
		self.dacReadComponent = 0
	elseif address == 0x3C8 then
		self.dacWriteIndex = byte
		self.dacWriteComponent = 0
	elseif address == 0x3C9 then
		self:writeDac(byte)
	elseif address == 0x3CE then
		self.gfxIndex = band(byte, 0x0F)
	elseif address == 0x3CF then
		self.gfx[self.gfxIndex] = byte
	elseif address == 0x3D4 or address == 0x3B4 then
		self.crtcIndex = band(byte, 0x1F)
	elseif address == 0x3D5 or address == 0x3B5 then
		self:writeCrtc(byte)
	elseif address == 0x3DA or address == 0x3BA then
		self.feature = byte
		self.attrFlipFlop = true
	else
		self.latched[address] = byte
	end
end

-- --------------------------------------------------------------- conversion

function Vga.blankTarget(self: Vga)
	const total = self.widthPx * self.heightPx
	for index = 0, total - 1 do
		buffer.writeu32(self.rgba, index * 4, RGBA_BLACK)
	end
end

-- Convert only [x0, x1) x [y0, y1) into the retained RGBA buffer. The host
-- normally repaints a small dirty rectangle (cursor, menu, typing), so a full
-- 640x480 conversion every frame wastes most of the frame budget.
local function blitPlanar(self: Vga, x0: number, y0: number, x1: number, y1: number)
	self:ensurePalette()
	const target = self.rgba
	const width = self.widthPx
	const bytesPerRow = math.ceil(width / 8)
	const rowBytes = math.max(bytesPerRow, self:planarRowBytes())
	const start = self:displayStartBytes()
	const planeEnable = band(self.attr[18], 0x0F)
	const colors = self.color16RGBA
	const firstByte = math.floor(x0 / 8)
	const lastByte = math.floor((x1 - 1) / 8)

	for y = y0, y1 - 1 do
		const rowBase = band(start + y * rowBytes, 0xFFFF)
		for byteX = firstByte, lastByte do
			const offset = band(rowBase + byteX, 0xFFFF)
			const p0 = band(planeEnable, 0x01) ~= 0 and buffer.readu8(self.planes[1], offset) or 0
			const p1 = band(planeEnable, 0x02) ~= 0 and buffer.readu8(self.planes[2], offset) or 0
			const p2 = band(planeEnable, 0x04) ~= 0 and buffer.readu8(self.planes[3], offset) or 0
			const p3 = band(planeEnable, 0x08) ~= 0 and buffer.readu8(self.planes[4], offset) or 0
			for bit = 7, 0, -1 do
				const x = byteX * 8 + (7 - bit)
				if x >= x0 and x < x1 then
					const index = bor(
						band(rshift(p0, bit), 0x01),
						bor(
							lshift(band(rshift(p1, bit), 0x01), 1),
							bor(
								lshift(band(rshift(p2, bit), 0x01), 2),
								lshift(band(rshift(p3, bit), 0x01), 3)
							)
						)
					)
					buffer.writeu32(target, (y * width + x) * 4, colors[index + 1])
				end
			end
		end
	end
end

local function blitLinear(self: Vga, x0: number, y0: number, x1: number, y1: number)
	self:ensurePalette()
	const target = self.rgba
	const width = self.widthPx
	const start = self:displayStartBytes()
	const colors = self.paletteRGBA
	const mask = self.dacMask

	for y = y0, y1 - 1 do
		const rowBase = start + y * width
		local dest = (y * width + x0) * 4
		for x = x0, x1 - 1 do
			const index = band(buffer.readu8(self.chain4, band(rowBase + x, 0xFFFF)), mask)
			buffer.writeu32(target, dest, colors[index + 1])
			dest += 4
		end
	end
end

function Vga.renderPlanar(self: Vga)
	blitPlanar(self, 0, 0, self.widthPx, self.heightPx)
end

function Vga.renderLinear(self: Vga)
	blitLinear(self, 0, 0, self.widthPx, self.heightPx)
end

function Vga.renderText(self: Vga)
	self:ensurePalette()
	const target = self.rgba
	const width = self.widthPx
	const start = band(self:displayStartBytes(), 0xFFFF)
	const colors = self.color16RGBA
	const blank = FONT[63] :: { number }
	const blink = band(self.attr[16], 0x08) ~= 0

	for row = 0, TEXT_ROWS - 1 do
		const sourceRow = band(start + row * TEXT_COLS * 2, 0xFFFF)
		for col = 0, TEXT_COLS - 1 do
			const cell = band(sourceRow + col * 2, 0xFFFF)
			const code = self.mem:read8(TEXT_BASE + cell)
			const attribute = self.mem:read8(TEXT_BASE + cell + 1)
			const foreground = colors[band(attribute, 0x0F) + 1]
			const backgroundBits = blink and band(rshift(attribute, 4), 0x07)
				or band(rshift(attribute, 4), 0x0F)
			const background = colors[backgroundBits + 1]
			const glyph = FONT[code] or blank
			for glyphRow = 0, 7 do
				const bits = glyph[glyphRow]
				const row0 = (row * TEXT_CELL_HEIGHT + glyphRow * 2) * width * 4
				const row1 = row0 + width * 4
				const column = (col * TEXT_CELL_WIDTH) * 4
				for glyphCol = 0, 7 do
					const set = band(bits, lshift(1, 7 - glyphCol)) ~= 0
					const color = set and foreground or background
					const pixel = column + glyphCol * 4
					buffer.writeu32(target, row0 + pixel, color)
					buffer.writeu32(target, row1 + pixel, color)
				end
			end
		end
	end
end

-- Returns a reusable RGBA8 buffer (R,G,B,A bytes, row-major, top-down). The
-- buffer is overwritten by the next snapshotRGBA call (and replaced by
-- setMode), so copy it before retaining it across frames.
function Vga.snapshotRGBA(self: Vga): buffer
	if self:isBlanked() then
		self:blankTarget()
		return self.rgba
	end
	if self.info.kind == "text" then
		self:renderText()
	elseif self.info.kind == "linear" or self:isChain4() then
		self:renderLinear()
	else
		self:renderPlanar()
	end
	return self.rgba
end

-- Convert only the requested rectangle into the retained RGBA buffer. Hosts
-- that track consumeDirty() can pass that rectangle here; pixels outside it
-- keep the values from the previous snapshot.
function Vga.snapshotRegionRGBA(
	self: Vga,
	x: number,
	y: number,
	width: number,
	height: number
): buffer
	const x0 = math.max(0, math.floor(x))
	const y0 = math.max(0, math.floor(y))
	const x1 = math.min(self.widthPx, math.floor(x + width))
	const y1 = math.min(self.heightPx, math.floor(y + height))
	if x1 <= x0 or y1 <= y0 then
		return self.rgba
	end
	if self:isBlanked() then
		self:blankTarget()
		return self.rgba
	end
	if self.info.kind == "text" then
		-- The text sink reads TextScreen directly; keep the old full-frame
		-- behaviour for callers that use the VGA text fallback.
		return self:snapshotRGBA()
	end
	if self.info.kind == "linear" or self:isChain4() then
		blitLinear(self, x0, y0, x1, y1)
	else
		blitPlanar(self, x0, y0, x1, y1)
	end
	return self.rgba
end

function Vga.snapshot(self: Vga): Snapshot
	return {
		width = self.widthPx,
		height = self.heightPx,
		stride = self.widthPx * 4,
		pixels = self:snapshotRGBA(),
	}
end

-- ------------------------------------------------------------- drawing helpers

function Vga.fillRect(self: Vga, x: number, y: number, width: number, height: number, color: number)
	if self.info.kind == "text" then
		return
	end
	const x0 = math.max(0, math.floor(x))
	const y0 = math.max(0, math.floor(y))
	const x1 = math.min(self.widthPx, math.floor(x + width))
	const y1 = math.min(self.heightPx, math.floor(y + height))
	if x1 <= x0 or y1 <= y0 then
		return
	end
	const index = band(color, 0xFF)

	if self.info.kind == "linear" or self:isChain4() then
		const start = self:displayStartBytes()
		for row = y0, y1 - 1 do
			const rowBase = start + row * self.widthPx
			for column = x0, x1 - 1 do
				buffer.writeu8(self.chain4, band(rowBase + column, 0xFFFF), index)
			end
		end
		self:markDirtyRect(x0, y0, x1 - x0, y1 - y0)
		return
	end

	-- Use write mode 0 with set/reset for all planes: the CPU data is ignored,
	-- and the bit mask carves partial edge bytes out of the latches.
	const savedReset = self.gfx[0]
	const savedEnable = self.gfx[1]
	const savedRotate = self.gfx[3]
	const savedMode = self.gfx[5]
	const savedMask = self.gfx[8]
	const savedMapMask = self.seq[2]
	const savedLatches = table.create(4, 0) :: { number }
	for plane = 0, 3 do
		savedLatches[plane] = self.latches[plane]
	end

	self.gfx[0] = index
	self.gfx[1] = 0x0F
	self.gfx[3] = 0x00
	self.gfx[5] = 0x00
	self.gfx[8] = 0xFF
	self.seq[2] = 0x0F

	const rowBytes = math.max(math.ceil(self.widthPx / 8), self:planarRowBytes())
	const start = self:displayStartBytes()
	const firstByte = math.floor(x0 / 8)
	const lastByte = math.floor((x1 - 1) / 8)
	for row = y0, y1 - 1 do
		const rowBase = band(start + row * rowBytes, 0xFFFF)
		for byteX = firstByte, lastByte do
			local mask = 0
			for bit = 0, 7 do
				const pixelX = byteX * 8 + bit
				if pixelX >= x0 and pixelX < x1 then
					mask = bor(mask, lshift(1, 7 - bit))
				end
			end
			const offset = band(rowBase + byteX, 0xFFFF)
			self.gfx[8] = mask
			self:read8(APERTURE_BASE + offset)
			self:write8(APERTURE_BASE + offset, 0)
		end
	end

	self.gfx[0] = savedReset
	self.gfx[1] = savedEnable
	self.gfx[3] = savedRotate
	self.gfx[5] = savedMode
	self.gfx[8] = savedMask
	self.seq[2] = savedMapMask
	for plane = 0, 3 do
		self.latches[plane] = savedLatches[plane]
	end
	self:markDirtyRect(x0, y0, x1 - x0, y1 - y0)
end

function Vga.writeText(self: Vga, row: number, column: number, text: string, attribute: number)
	if row < 0 or row >= TEXT_ROWS or column < 0 or column >= TEXT_COLS then
		return
	end
	const length = math.min(#text, TEXT_COLS - column)
	for index = 1, length do
		const cell = TEXT_BASE + (row * TEXT_COLS + column + index - 1) * 2
		self.mem:write8(cell, string.byte(text, index) :: number)
		self.mem:write8(cell + 1, band(attribute, 0xFF))
	end
end

function Vga.fillTextPattern(self: Vga)
	-- Disable blink so the diagnostic colour-bar row can show all 16 backgrounds.
	self.attr[16] = band(self.attr[16], band(bnot(0x08), 0xFF))
	for row = 0, TEXT_ROWS - 1 do
		for col = 0, TEXT_COLS - 1 do
			const cell = TEXT_BASE + (row * TEXT_COLS + col) * 2
			self.mem:write8(cell, 32)
			self.mem:write8(cell + 1, 0x07)
		end
	end
	self:writeText(2, 24, "RVPC VGA DIAGNOSTIC", 0x1F)
	self:writeText(4, 16, "MODE 03H TEXT FALLBACK 80X25", 0x0F)
	self:writeText(6, 16, "MODE 12H 640X480X16 PLANAR", 0x0A)
	self:writeText(7, 16, "MODE 13H 320X200X256 LINEAR", 0x0B)
	self:writeText(9, 12, "PLANES 0-3 / DAC 6-BIT / CRTC 3D4", 0x0E)
	self:writeText(11, 16, "C:\\WINDOWS> WIN", 0x0F)
	for col = 0, TEXT_COLS - 1 do
		const cell = TEXT_BASE + (20 * TEXT_COLS + col) * 2
		self.mem:write8(cell, 32)
		self.mem:write8(cell + 1, bor(lshift(col % 16, 4), 0x0F))
	end
	self:markAllDirty()
end

function Vga.fillTestPattern(self: Vga)
	-- Diagnostics should be visible even after a guest left the display blanked.
	self.attrPas = true
	self.seq[1] = band(self.seq[1], band(bnot(0x20), 0xFF))
	self.misc = bor(self.misc, 0x02)

	if self.info.kind == "text" then
		self:fillTextPattern()
		return
	end

	if self.info.kind == "linear" or self:isChain4() then
		const width = self.widthPx
		const height = self.heightPx
		self:fillRect(0, 0, width, height, 0)
		for index = 0, 15 do
			self:fillRect(index * 20, 0, 20, 160, index)
		end
		for x = 0, width - 1 do
			const shade = math.floor(x * 255 / (width - 1))
			self:fillRect(x, 160, 1, 32, shade)
		end
		for cellY = 0, 4 do
			for cellX = 0, width / 8 - 1 do
				const color = (cellX + cellY) % 2 == 0 and 15 or 0
				self:fillRect(cellX * 8, 192 + cellY * 8, 8, 8, color)
			end
		end
		self:fillRect(0, 0, width, 2, 15)
		self:fillRect(0, height - 2, width, 2, 15)
		self:fillRect(0, 0, 2, height, 15)
		self:fillRect(width - 2, 0, 2, height, 15)
		self:markAllDirty()
		return
	end

	const width = self.widthPx
	const height = self.heightPx
	self:fillRect(0, 0, width, height, 0)
	for index = 0, 15 do
		self:fillRect(index * 40, 0, 40, 360, index)
	end
	for row = 360, 471, 8 do
		for col = 0, width / 8 - 1 do
			const color = (math.floor(row / 8) + col) % 2 == 0 and 15 or 0
			self:fillRect(col * 8, row, 8, 8, color)
		end
	end
	for index = 0, 15 do
		self:fillRect(index * 40, 472, 40, 4, index)
	end
	self:fillRect(0, 0, width, 4, 15)
	self:fillRect(0, height - 4, width, 4, 15)
	self:fillRect(0, 0, 4, height, 15)
	self:fillRect(width - 4, 0, 4, height, 15)
	self:markAllDirty()
end

return Vga
