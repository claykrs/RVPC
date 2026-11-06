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
-- text mode 3 fallback, write modes 0/1/2/3, read modes 0/1, set/reset,
-- enable set/reset, data rotate, logical operations, read map select, colour
-- compare/don't-care, bit mask, map mask, odd/even host addressing, CRTC
-- start/offset, attribute-controller palette selection (including AR14 colour
-- select), and DAC writes. Text mode 3 reads B8000 directly through mem and
-- does not use odd/even plane addressing. Mode 13h collapses chain-4 address
-- decode to a linear 64 KiB buffer; its write modes and bit mask are not
-- applied.
--
-- Mode 12h reads and writes decode the four planes at the same byte address.
-- Latches load on every aperture read. Write mode 3 always uses GC0 set/reset
-- (GC1 is ignored) and preserves bit-mask-zero bits from the latches, matching
-- VGA hardware. Odd/even host addressing is implemented for CPU reads/writes;
-- the CGA/EGA shift-register display formats are not. The CRTC 0x22 alias
-- exposes the four latches, as on real VGA hardware.
--
-- A guest VGA BIOS programs the controllers through I/O ports instead of
-- calling setMode, so syncLegacyMode infers text/planar/linear and the visible
-- geometry from GC6/AR10 and the CRTC registers. INT 10h AX=0012 therefore
-- reaches the planar renderer on its own.
--
-- Not implemented: sync timing, interlace/double-scan timing, CGA/EGA 2bpp
-- shift-register output, chain-2 memory, horizontal pel/byte panning,
-- split-screen line compare, hardware text cursor, the GC6 memory-map windows
-- at B0000/B8000, and the 256 KiB VGA memory map beyond the first 64 KiB.

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

-- Bochs/QEMU DISPI VBE interface. The LFB sits at the Bochs default physical
-- address (also what SeaVGABIOS uses when the PCI BAR is zero) and is 4 MiB so
-- 1024x768x32 plus virtual-row headroom fit. Memory must route this range to
-- Vga:read8/write8 (and ideally read16/32/write16/32).
const VBE_FRAMEBUFFER_BASE = 0xE0000000
const VBE_VRAM_SIZE = 0x400000
const VBE_FRAMEBUFFER_END = VBE_FRAMEBUFFER_BASE + VBE_VRAM_SIZE
const VBE_MAX_XRES = 2560
const VBE_MAX_YRES = 1600
const VBE_MAX_BPP = 32

const VBE_DISPI_INDEX_ID = 0x0
const VBE_DISPI_INDEX_XRES = 0x1
const VBE_DISPI_INDEX_YRES = 0x2
const VBE_DISPI_INDEX_BPP = 0x3
const VBE_DISPI_INDEX_ENABLE = 0x4
const VBE_DISPI_INDEX_BANK = 0x5
const VBE_DISPI_INDEX_VIRT_WIDTH = 0x6
const VBE_DISPI_INDEX_VIRT_HEIGHT = 0x7
const VBE_DISPI_INDEX_X_OFFSET = 0x8
const VBE_DISPI_INDEX_Y_OFFSET = 0x9
const VBE_DISPI_INDEX_VIDEO_MEMORY_64K = 0xA

const VBE_DISPI_ID0 = 0xB0C0
const VBE_DISPI_ID1 = 0xB0C1
const VBE_DISPI_ID2 = 0xB0C2
const VBE_DISPI_ID3 = 0xB0C3
const VBE_DISPI_ID4 = 0xB0C4
const VBE_DISPI_ID5 = 0xB0C5

const VBE_DISPI_DISABLED = 0x00
const VBE_DISPI_ENABLED = 0x01
const VBE_DISPI_GETCAPS = 0x02
const VBE_DISPI_8BIT_DAC = 0x20
const VBE_DISPI_LFB_ENABLED = 0x40
const VBE_DISPI_NOCLEARMEM = 0x80

type ModeKind = "text" | "planar" | "linear" | "vbe"

export type ModeInfo = {
	mode: number,
	kind: ModeKind,
	width: number,
	height: number,
	rowBytes: number,
	bitsPerPixel: number,
	label: string,
}

export type VbeMode = {
	mode: number,
	width: number,
	height: number,
	bpp: number,
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

-- Standard VBE mode numbers from SeaVGABIOS's svga_modes table. The LFB bit
-- (0x4000) is supplied by the caller when setting a linear mode.
const VBE_MODES: { VbeMode } = {
	{ mode = 0x101, width = 640, height = 480, bpp = 8, label = "640x480x8" },
	{ mode = 0x111, width = 640, height = 480, bpp = 16, label = "640x480x16" },
	{ mode = 0x142, width = 640, height = 480, bpp = 32, label = "640x480x32" },
	{ mode = 0x103, width = 800, height = 600, bpp = 8, label = "800x600x8" },
	{ mode = 0x114, width = 800, height = 600, bpp = 16, label = "800x600x16" },
	{ mode = 0x143, width = 800, height = 600, bpp = 32, label = "800x600x32" },
	{ mode = 0x105, width = 1024, height = 768, bpp = 8, label = "1024x768x8" },
	{ mode = 0x117, width = 1024, height = 768, bpp = 16, label = "1024x768x16" },
	{ mode = 0x144, width = 1024, height = 768, bpp = 32, label = "1024x768x32" },
}

const VBE_MODE_BY_NUMBER: { [number]: VbeMode } = {}
for _, vbeMode in VBE_MODES do
	VBE_MODE_BY_NUMBER[vbeMode.mode] = vbeMode
end

local function vbeMatchMode(width: number, height: number, bpp: number): number?
	for _, vbeMode in VBE_MODES do
		if vbeMode.width == width and vbeMode.height == height and vbeMode.bpp == bpp then
			return vbeMode.mode
		end
	end
	return nil
end

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
		gfx = { 0x00, 0x00, 0x00, 0x00, 0x00, 0x10, 0x0E, 0x0F, 0xFF },
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
		-- SeaVGABIOS mode 12h palette: the EGA gamut with brown at 0x14 and
		-- the bright colours at 0x38..0x3F. The resulting RGB matches direct
		-- 0..15 entries, but the register values are what real mode-set code
		-- leaves behind (and what a driver may read back).
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

Vga.VBE_FRAMEBUFFER_BASE = VBE_FRAMEBUFFER_BASE
Vga.FRAMEBUFFER_BASE = VBE_FRAMEBUFFER_BASE
Vga.VBE_VRAM_SIZE = VBE_VRAM_SIZE
Vga.FRAMEBUFFER_SIZE = VBE_VRAM_SIZE
Vga.VBE_FRAMEBUFFER_END = VBE_FRAMEBUFFER_END
Vga.FRAMEBUFFER_END = VBE_FRAMEBUFFER_END
Vga.VBE_MAX_XRES = VBE_MAX_XRES
Vga.VBE_MAX_YRES = VBE_MAX_YRES
Vga.VBE_MAX_BPP = VBE_MAX_BPP
Vga.VBE_MODES = VBE_MODES

Vga.VBE_DISPI_INDEX = {
	ID = VBE_DISPI_INDEX_ID,
	XRES = VBE_DISPI_INDEX_XRES,
	YRES = VBE_DISPI_INDEX_YRES,
	BPP = VBE_DISPI_INDEX_BPP,
	ENABLE = VBE_DISPI_INDEX_ENABLE,
	BANK = VBE_DISPI_INDEX_BANK,
	VIRT_WIDTH = VBE_DISPI_INDEX_VIRT_WIDTH,
	VIRT_HEIGHT = VBE_DISPI_INDEX_VIRT_HEIGHT,
	X_OFFSET = VBE_DISPI_INDEX_X_OFFSET,
	Y_OFFSET = VBE_DISPI_INDEX_Y_OFFSET,
	VIDEO_MEMORY_64K = VBE_DISPI_INDEX_VIDEO_MEMORY_64K,
}

Vga.VBE_DISPI_INDEX_ID = VBE_DISPI_INDEX_ID
Vga.VBE_DISPI_INDEX_XRES = VBE_DISPI_INDEX_XRES
Vga.VBE_DISPI_INDEX_YRES = VBE_DISPI_INDEX_YRES
Vga.VBE_DISPI_INDEX_BPP = VBE_DISPI_INDEX_BPP
Vga.VBE_DISPI_INDEX_ENABLE = VBE_DISPI_INDEX_ENABLE
Vga.VBE_DISPI_INDEX_BANK = VBE_DISPI_INDEX_BANK
Vga.VBE_DISPI_INDEX_VIRT_WIDTH = VBE_DISPI_INDEX_VIRT_WIDTH
Vga.VBE_DISPI_INDEX_VIRT_HEIGHT = VBE_DISPI_INDEX_VIRT_HEIGHT
Vga.VBE_DISPI_INDEX_X_OFFSET = VBE_DISPI_INDEX_X_OFFSET
Vga.VBE_DISPI_INDEX_Y_OFFSET = VBE_DISPI_INDEX_Y_OFFSET
Vga.VBE_DISPI_INDEX_VIDEO_MEMORY_64K = VBE_DISPI_INDEX_VIDEO_MEMORY_64K

Vga.VBE_DISPI_ID0 = VBE_DISPI_ID0
Vga.VBE_DISPI_ID1 = VBE_DISPI_ID1
Vga.VBE_DISPI_ID2 = VBE_DISPI_ID2
Vga.VBE_DISPI_ID3 = VBE_DISPI_ID3
Vga.VBE_DISPI_ID4 = VBE_DISPI_ID4
Vga.VBE_DISPI_ID5 = VBE_DISPI_ID5
Vga.VBE_DISPI_DISABLED = VBE_DISPI_DISABLED
Vga.VBE_DISPI_ENABLED = VBE_DISPI_ENABLED
Vga.VBE_DISPI_GETCAPS = VBE_DISPI_GETCAPS
Vga.VBE_DISPI_8BIT_DAC = VBE_DISPI_8BIT_DAC
Vga.VBE_DISPI_LFB_ENABLED = VBE_DISPI_LFB_ENABLED
Vga.VBE_DISPI_NOCLEARMEM = VBE_DISPI_NOCLEARMEM
Vga.VBE_DISPI_LFB_PHYSICAL_ADDRESS = VBE_FRAMEBUFFER_BASE

-- Cheap routing predicate for a Memory/CPU aperture hook. The low VGA aperture
-- is still reported for compatibility; the high LFB is the SVGA addition.
function Vga.containsAddress(addr: number): boolean
	if addr >= VBE_FRAMEBUFFER_BASE and addr < VBE_FRAMEBUFFER_END then
		return true
	end
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
		dacState: number,
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
		vbeIndex: number,
		vbeRegs: { number },
		vbeFramebuffer: buffer,
		vbeLineOffset: number,
		vbeStartAddr: number,
		vbeBankOffset: number,
		vbeInfo: ModeInfo?,
		dac8: boolean,
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
	self.dacState = 0x00
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
	self.vbeIndex = VBE_DISPI_INDEX_ID
	self.vbeRegs = table.create(16, 0) :: { number }
	self.vbeRegs[VBE_DISPI_INDEX_ID] = VBE_DISPI_ID5
	self.vbeFramebuffer = buffer.create(VBE_VRAM_SIZE)
	self.vbeLineOffset = 0
	self.vbeStartAddr = 0
	self.vbeBankOffset = 0
	self.vbeInfo = nil
	self.dac8 = false
	self:resetPalette()
	self:setMode(0x03)
	return self
end

-- ---------------------------------------------------------------- mode state

function Vga.mode(self: Vga): number
	self:syncLegacyMode()
	return self.modeNumber
end

function Vga.modeInfo(self: Vga): ModeInfo
	self:syncLegacyMode()
	const vbe = self.vbeInfo
	if vbe then
		return vbe
	end
	return self.info
end

function Vga.width(self: Vga): number
	self:syncLegacyMode()
	return self.widthPx
end

function Vga.height(self: Vga): number
	self:syncLegacyMode()
	return self.heightPx
end

function Vga.stride(self: Vga): number
	self:syncLegacyMode()
	return self.widthPx * 4
end

function Vga.isVbeEnabled(self: Vga): boolean
	return band(self.vbeRegs[VBE_DISPI_INDEX_ENABLE], VBE_DISPI_ENABLED) ~= 0
end

function Vga.vbeModes(): { VbeMode }
	return VBE_MODES
end

-- Accepts either Vga.vbeModeInfo(mode) or vga:vbeModeInfo(mode); the second form
-- checks the first argument so both call styles work in tests.
function Vga.vbeModeInfo(mode: any, maybeMode: number?): VbeMode?
	const value = if maybeMode ~= nil then maybeMode else mode
	if type(value) ~= "number" then
		return nil
	end
	return VBE_MODE_BY_NUMBER[band(value, 0x3FFF)]
end

function Vga.isTextMode(self: Vga): boolean
	self:syncLegacyMode()
	if self:isVbeEnabled() then
		return false
	end
	return self.info.kind == "text"
end

function Vga.isChain4(self: Vga): boolean
	return band(self.seq[4], 0x08) ~= 0
end

function Vga.isOddEven(self: Vga): boolean
	return not self:isChain4() and band(self.seq[4], 0x04) == 0
end

function Vga.isBlanked(self: Vga): boolean
	if self:isVbeEnabled() then
		-- VBE owns its own enable state; the legacy sequencer/misc blanking
		-- bits are not used by the DISPI path.
		return false
	end
	return not self.attrPas or band(self.seq[1], 0x20) ~= 0 or band(self.misc, 0x02) == 0
end

function Vga.readCrtc(self: Vga, index: number): number
	if band(index, 0x3F) == 0x22 then
		-- Undocumented CRTC 0x22 alias: the graphics-controller latches.
		return self.latches[band(self.gfx[4], 0x03)]
	end
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

-- ----------------------------------------------------------- Bochs VBE DISPI

function Vga.vbeReadRegister(self: Vga, index: number): number
	if index == VBE_DISPI_INDEX_VIDEO_MEMORY_64K then
		return math.floor(VBE_VRAM_SIZE / 0x10000)
	end
	return band(self.vbeRegs[index] or 0, 0xFFFF)
end

function Vga.vbeReadData(self: Vga): number
	const index = self.vbeIndex
	if band(self.vbeRegs[VBE_DISPI_INDEX_ENABLE], VBE_DISPI_GETCAPS) ~= 0 then
		if index == VBE_DISPI_INDEX_XRES then
			return VBE_MAX_XRES
		elseif index == VBE_DISPI_INDEX_YRES then
			return VBE_MAX_YRES
		elseif index == VBE_DISPI_INDEX_BPP then
			return VBE_MAX_BPP
		end
	end
	return self:vbeReadRegister(index)
end

-- Clamp the DISPI registers the way QEMU does. XRES is eight-pixel aligned,
-- VIRT_WIDTH cannot be narrower than the visible width, and the visible
-- rectangle must fit in VRAM after the start offset.
function Vga.fixupVbe(self: Vga)
	if not self:isVbeEnabled() then
		return
	end
	const regs = self.vbeRegs
	local bpp = regs[VBE_DISPI_INDEX_BPP]
	if bpp == 15 or bpp == 16 or bpp == 24 or bpp == 32 or bpp == 8 or bpp == 4 then
		-- supported
	else
		bpp = 8
		regs[VBE_DISPI_INDEX_BPP] = bpp
	end

	local xres = band(regs[VBE_DISPI_INDEX_XRES], 0xFFF8)
	if xres == 0 then
		xres = 8
	elseif xres > VBE_MAX_XRES then
		xres = VBE_MAX_XRES
	end
	regs[VBE_DISPI_INDEX_XRES] = xres

	local virtWidth = band(regs[VBE_DISPI_INDEX_VIRT_WIDTH], 0xFFF8)
	if virtWidth > VBE_MAX_XRES then
		virtWidth = VBE_MAX_XRES
	end
	if virtWidth < xres then
		virtWidth = xres
	end
	regs[VBE_DISPI_INDEX_VIRT_WIDTH] = virtWidth

	local rowBytes: number
	if bpp == 4 then
		rowBytes = math.ceil(virtWidth / 2)
	elseif bpp == 15 or bpp == 16 then
		rowBytes = virtWidth * 2
	elseif bpp == 24 then
		rowBytes = virtWidth * 3
	elseif bpp == 32 then
		rowBytes = virtWidth * 4
	else
		rowBytes = virtWidth
	end

	const maxY = math.max(1, math.floor(VBE_VRAM_SIZE / rowBytes))
	local yres = regs[VBE_DISPI_INDEX_YRES]
	if yres == 0 then
		yres = 1
	elseif yres > VBE_MAX_YRES then
		yres = VBE_MAX_YRES
	end
	if yres > maxY then
		yres = maxY
	end
	regs[VBE_DISPI_INDEX_YRES] = yres
	regs[VBE_DISPI_INDEX_VIRT_HEIGHT] = maxY

	local xOffset = math.min(regs[VBE_DISPI_INDEX_X_OFFSET], VBE_MAX_XRES)
	local yOffset = math.min(regs[VBE_DISPI_INDEX_Y_OFFSET], VBE_MAX_YRES)
	local xBytes = if bpp == 4
		then math.floor(xOffset / 2)
		elseif bpp == 15 or bpp == 16 then xOffset * 2
		elseif bpp == 24 then xOffset * 3
		elseif bpp == 32 then xOffset * 4
		else xOffset
	local start = xBytes + yOffset * rowBytes
	if start + yres * rowBytes > VBE_VRAM_SIZE then
		yOffset = 0
		start = xBytes
		if start + yres * rowBytes > VBE_VRAM_SIZE then
			xOffset = 0
			start = 0
		end
	end
	regs[VBE_DISPI_INDEX_X_OFFSET] = xOffset
	regs[VBE_DISPI_INDEX_Y_OFFSET] = yOffset
	self.vbeLineOffset = rowBytes
	self.vbeStartAddr = start
end

function Vga.syncVbe(self: Vga)
	if not self:isVbeEnabled() then
		return
	end
	const regs = self.vbeRegs
	const width = regs[VBE_DISPI_INDEX_XRES]
	const height = regs[VBE_DISPI_INDEX_YRES]
	const bpp = regs[VBE_DISPI_INDEX_BPP]
	self.modeNumber = vbeMatchMode(width, height, bpp) or 0x1FF
	self.vbeBankOffset = lshift(band(regs[VBE_DISPI_INDEX_BANK], 0x3F), 16)
	self.widthPx = width
	self.heightPx = height
	if buffer.len(self.rgba) ~= width * height * 4 then
		self.rgba = buffer.create(width * height * 4)
	end
	self.vbeInfo = {
		mode = self.modeNumber,
		kind = "vbe",
		width = width,
		height = height,
		rowBytes = self.vbeLineOffset,
		bitsPerPixel = bpp,
		label = string.format("VBE %dx%d %dbpp", width, height, bpp),
	}
end

local function restoreLegacyGeometry(self: Vga)
	self.vbeInfo = nil
	self.modeNumber = self.info.mode
	self.widthPx = self.info.width
	self.heightPx = self.info.height
	self.rgba = buffer.create(self.widthPx * self.heightPx * 4)
	self:markAllDirty()
end

function Vga.writeVbeEnable(self: Vga, value: number)
	const wasEnabled = self:isVbeEnabled()
	const oldDac8 = self.dac8
	self.vbeRegs[VBE_DISPI_INDEX_ENABLE] = band(value, 0xFFFF)
	self.dac8 = band(value, VBE_DISPI_8BIT_DAC) ~= 0
	if self.dac8 ~= oldDac8 then
		self.paletteDirty = true
		self:markAllDirty()
	end

	if band(value, VBE_DISPI_ENABLED) ~= 0 then
		if not wasEnabled then
			-- A real DISPI discards the virtual width/offset until enabled.
			self.vbeRegs[VBE_DISPI_INDEX_VIRT_WIDTH] = 0
			self.vbeRegs[VBE_DISPI_INDEX_X_OFFSET] = 0
			self.vbeRegs[VBE_DISPI_INDEX_Y_OFFSET] = 0
		end
		self:fixupVbe()
		self:syncVbe()
		if not wasEnabled and band(value, VBE_DISPI_NOCLEARMEM) == 0 then
			const clearBytes = math.min(self.heightPx * self.vbeLineOffset, VBE_VRAM_SIZE)
			if clearBytes > 0 then
				buffer.fill(self.vbeFramebuffer, 0, 0, clearBytes)
			end
		end
		self:markAllDirty()
	elseif wasEnabled then
		restoreLegacyGeometry(self)
	end
end

function Vga.vbeWriteRegister(self: Vga, index: number, value: number)
	value = band(value, 0xFFFF)
	const regs = self.vbeRegs
	if index == VBE_DISPI_INDEX_ID then
		if value >= VBE_DISPI_ID0 and value <= VBE_DISPI_ID5 then
			regs[VBE_DISPI_INDEX_ID] = value
		end
	elseif index == VBE_DISPI_INDEX_ENABLE then
		self:writeVbeEnable(value)
	elseif index == VBE_DISPI_INDEX_BANK then
		regs[VBE_DISPI_INDEX_BANK] = band(value, 0x3F)
		self.vbeBankOffset = lshift(regs[VBE_DISPI_INDEX_BANK], 16)
	elseif
		index == VBE_DISPI_INDEX_XRES
		or index == VBE_DISPI_INDEX_YRES
		or index == VBE_DISPI_INDEX_BPP
		or index == VBE_DISPI_INDEX_VIRT_WIDTH
		or index == VBE_DISPI_INDEX_X_OFFSET
		or index == VBE_DISPI_INDEX_Y_OFFSET
	then
		regs[index] = value
		if self:isVbeEnabled() then
			self:fixupVbe()
			self:syncVbe()
			self:markAllDirty()
		end
	end
end

function Vga.setVbeMode(self: Vga, width: number, height: number, bpp: number, lfb: boolean?)
	const regs = self.vbeRegs
	regs[VBE_DISPI_INDEX_ENABLE] = 0
	regs[VBE_DISPI_INDEX_XRES] = band(width, 0xFFFF)
	regs[VBE_DISPI_INDEX_YRES] = band(height, 0xFFFF)
	regs[VBE_DISPI_INDEX_BPP] = band(bpp, 0xFF)
	regs[VBE_DISPI_INDEX_BANK] = 0
	regs[VBE_DISPI_INDEX_VIRT_WIDTH] = 0
	regs[VBE_DISPI_INDEX_X_OFFSET] = 0
	regs[VBE_DISPI_INDEX_Y_OFFSET] = 0
	const flags = bor(VBE_DISPI_ENABLED, if lfb then VBE_DISPI_LFB_ENABLED else VBE_DISPI_DISABLED)
	self:writeVbeEnable(flags)
end

function Vga.setMode(self: Vga, mode: number): boolean
	const fullMode = band(mode, 0x7FFF)
	const vbeNumber = band(fullMode, 0x3FFF)
	const vbeMode = VBE_MODE_BY_NUMBER[vbeNumber]
	if vbeMode then
		self:setVbeMode(vbeMode.width, vbeMode.height, vbeMode.bpp, band(fullMode, 0x4000) ~= 0)
		return true
	end
	-- Do not let VBE numbers alias legacy modes through the low byte (0x103
	-- would otherwise land on text mode 3, 0x112 on planar 12h, and so on).
	if vbeNumber >= 0x100 then
		return false
	end

	const key = band(mode, 0xFF)
	const info = MODES[key]
	const registers = MODE_REGISTERS[key]
	if info == nil or registers == nil then
		return false
	end

	-- A standard VGA set-mode leaves DISPI and restores the legacy geometry.
	self.vbeRegs[VBE_DISPI_INDEX_ENABLE] = 0
	self.vbeInfo = nil
	self.dac8 = false
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
	self.dacState = 0x00
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
		local red = buffer.readu8(self.dac, base)
		local green = buffer.readu8(self.dac, base + 1)
		local blue = buffer.readu8(self.dac, base + 2)
		if not self.dac8 then
			red = dac6To8(red)
			green = dac6To8(green)
			blue = dac6To8(blue)
		end
		self.paletteRGBA[index + 1] = rgbaWord(red, green, blue)
	end
	-- 16-colour palette selection: AR10 bit 7 picks the 16-bank/4-bit mode,
	-- otherwise the attribute entry supplies six bits and AR14 bits 2-3 add
	-- the two bank bits. This mirrors Bochs' get_vga_pixel path. AR14 is zero
	-- in the standard modes, so the common case stays a direct 0..63 lookup.
	const modeControl = self.attr[0x10]
	const colorSelect = band(self.attr[0x14], 0x0F)
	for index = 0, 15 do
		const paletteValue = band(self.attr[index], 0x3F)
		local dacIndex: number
		if band(modeControl, 0x80) ~= 0 then
			dacIndex = bor(band(paletteValue, 0x0F), lshift(band(colorSelect, 0x0F), 4))
		else
			dacIndex = bor(band(paletteValue, 0x3F), lshift(band(colorSelect, 0x0C), 4))
		end
		dacIndex = band(dacIndex, self.dacMask)
		self.color16RGBA[index + 1] = self.paletteRGBA[dacIndex + 1]
	end
	self.paletteDirty = false
end

-- 8-bit RGB for a DAC index (the snapshot path uses the same expansion).
function Vga.paletteColor(self: Vga, index: number): (number, number, number)
	const red, green, blue = self:readDac(band(index, self.dacMask))
	if self.dac8 then
		return red, green, blue
	end
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
	self:syncLegacyMode()
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

-- Bytes between consecutive scanlines in the legacy framebuffer. CRTC 0x13
-- counts words of the active addressing size: 2 bytes in byte mode, 4 in word
-- mode, 8 in doubleword mode. The fallback keeps malformed offset-0 modes
-- usable.
local function legacyLineStride(self: Vga, fallbackWidth: number): number
	local offset = band(self.crtc[0x13], 0xFF) * 2
	if band(self.crtc[0x14], 0x40) ~= 0 then
		offset *= 4
	elseif band(self.crtc[0x17], 0x40) == 0 then
		offset *= 2
	end
	if offset > 0 then
		return offset
	end
	return math.max(1, math.ceil(fallbackWidth / 8))
end

-- A real VGA BIOS programs the controllers through the I/O ports; it does not
-- call setMode. Infer the legacy mode from the register state so a guest mode
-- set (notably INT 10h AX=0012) reaches the planar renderer. This is also the
-- reason the standard-mode register tables above mirror SeaVGABIOS.
--
-- Only the geometry and kind are refreshed. Plane contents, latches, the DAC
-- and the chain4 buffer survive, because the BIOS has already programmed them
-- (and may have written font/pixel data) by the time the host presents a frame.
function Vga.syncLegacyMode(self: Vga)
	if self:isVbeEnabled() then
		return
	end

	-- GC6 bit 0 (alpha disable) and AR10 bit 0 (graphics mode) both report
	-- graphics. Require agreement: font loading in text mode briefly changes
	-- GC6 for the A0000 plane-2 window while AR10 stays alphanumeric, and that
	-- must not flip the host to a 640x480 planar frame.
	const graphics = band(self.gfx[6], 0x01) ~= 0 and band(self.attr[0x10], 0x01) ~= 0
	if not graphics then
		const textInfo = MODES[0x03] :: ModeInfo
		if
			self.info.kind == "text"
			and self.info.width == textInfo.width
			and self.info.height == textInfo.height
			and self.modeNumber == textInfo.mode
		then
			return
		end
		self.info = textInfo
		self.modeNumber = textInfo.mode
		self.widthPx = textInfo.width
		self.heightPx = textInfo.height
		self.rgba = buffer.create(textInfo.width * textInfo.height * 4)
		self:markAllDirty()
		return
	end

	const chain4 = self:isChain4()
	local width = (band(self.crtc[0x01], 0xFF) + 1) * 8
	if chain4 and band(self.gfx[5], 0x40) ~= 0 then
		-- 256-colour shift mode clocks two pixels per dot clock, so the CRTC
		-- horizontal display count is twice the visible pixel width.
		width = math.floor(width / 2)
	end
	const verticalDisplay = (
		band(self.crtc[0x12], 0xFF)
		+ lshift(band(self.crtc[0x07], 0x02), 7)
		+ lshift(band(self.crtc[0x07], 0x40), 3)
	) + 1
	const scanLines = band(self.crtc[0x09], 0x1F) + 1
	local height = math.floor(verticalDisplay / scanLines)
	if band(self.crtc[0x09], 0x80) ~= 0 then
		-- Scan doubling repeats each source line twice.
		height = math.floor(height / 2)
	end
	-- A half-programmed mode-set sequence can momentarily look like a
	-- 640x25 planar mode (text CRTC values with the graphics bits already
	-- set). Every supported VGA graphics mode is at least 200 lines; ignore
	-- implausible geometry until the CRTC writes catch up.
	if width < 8 or height < 100 then
		return
	end
	width = math.min(width, VBE_MAX_XRES)
	height = math.min(height, VBE_MAX_YRES)

	local kind: ModeKind = if chain4 then "linear" else "planar"
	const bitsPerPixel = if chain4 then 8 else 4
	const lineStride = legacyLineStride(self, width)
	const rowBytes = if chain4 then math.max(width, lineStride) else lineStride

	-- Name the standard planar modes when the geometry matches. AR12 tells
	-- the 1bpp variants (0x0F/0x11) apart from the 16-colour ones
	-- (0x10/0x12); both use the same four-plane renderer with plane masking.
	local modeNumber = 0x1FF
	if kind == "planar" then
		const planeEnable = band(self.attr[0x12], 0x0F)
		if width == 320 and height == 200 then
			modeNumber = 0x0D
		elseif width == 640 and height == 200 then
			modeNumber = 0x0E
		elseif width == 640 and height == 350 then
			modeNumber = if planeEnable == 0x01 then 0x0F else 0x10
		elseif width == 640 and height == 480 then
			modeNumber = if planeEnable == 0x01 then 0x11 else 0x12
		elseif width == 800 and height == 600 then
			modeNumber = 0x6A
		end
	elseif kind == "linear" and width == 320 and height == 200 then
		modeNumber = 0x13
	end

	if
		self.info.kind == kind
		and self.info.width == width
		and self.info.height == height
		and self.info.rowBytes == rowBytes
		and self.info.bitsPerPixel == bitsPerPixel
		and self.modeNumber == modeNumber
	then
		return
	end

	self.info = {
		mode = modeNumber,
		kind = kind,
		width = width,
		height = height,
		rowBytes = rowBytes,
		bitsPerPixel = bitsPerPixel,
		label = if kind == "planar"
			then string.format("%dx%d planar", width, height)
			else string.format("%dx%d linear", width, height),
	}
	self.modeNumber = modeNumber
	self.widthPx = width
	self.heightPx = height
	self.rgba = buffer.create(width * height * 4)
	self:markAllDirty()
end

-- ------------------------------------------------------------ memory aperture

local function vbeOffsetForAddress(self: Vga, addr: number): number?
	if addr >= VBE_FRAMEBUFFER_BASE and addr < VBE_FRAMEBUFFER_END then
		return addr - VBE_FRAMEBUFFER_BASE
	end
	if self:isVbeEnabled() and addr >= APERTURE_BASE and addr < APERTURE_BASE + APERTURE_SIZE then
		return self.vbeBankOffset + (addr - APERTURE_BASE)
	end
	return nil
end

function Vga.markVbeWrite(self: Vga, offset: number, length: number)
	if not self:isVbeEnabled() or length <= 0 then
		return
	end
	const lineBytes = self.vbeLineOffset
	if lineBytes <= 0 or self.vbeInfo == nil then
		self:markAllDirty()
		return
	end
	const visibleBytes = self.heightPx * lineBytes
	local first = offset - self.vbeStartAddr
	local last = first + length - 1
	if last < 0 or first >= visibleBytes then
		return
	end
	first = math.max(0, first)
	last = math.min(last, visibleBytes - 1)

	const bpp = self.vbeInfo.bitsPerPixel
	const bytesPerPixel = if bpp == 4
		then 1
		elseif bpp == 15 or bpp == 16 then 2
		elseif bpp == 24 then 3
		elseif bpp == 32 then 4
		else 1
	const y0 = math.floor(first / lineBytes)
	const y1 = math.floor(last / lineBytes)
	if y0 == y1 then
		const x0 = math.floor((first % lineBytes) / bytesPerPixel)
		const x1 = math.floor((last % lineBytes) / bytesPerPixel)
		self:markDirtyRect(x0, y0, math.max(1, x1 - x0 + 1), 1)
	else
		self:markDirtyRect(0, y0, self.widthPx, y1 - y0 + 1)
	end
end

-- The CRTC start address is a memory-address counter. Its unit depends on the
-- addressing mode: CRTC 0x14 bit 6 selects doubleword (x4), otherwise CRTC
-- 0x17 bit 6 selects byte (x1) or word (x2). Mode 12h is byte mode, mode 13h
-- is doubleword mode, and text mode is word mode. Getting this wrong makes
-- page flipping and hardware panning show the wrong scanlines.
function Vga.displayStartBytes(self: Vga): number
	const words = bor(lshift(band(self.crtc[0x0C], 0xFF), 8), band(self.crtc[0x0D], 0xFF))
	local shift = 1
	if band(self.crtc[0x14], 0x40) ~= 0 then
		shift = 2
	elseif band(self.crtc[0x17], 0x40) ~= 0 then
		shift = 0
	end
	return band(lshift(words, shift), 0xFFFF)
end

function Vga.planarRowBytes(self: Vga): number
	return legacyLineStride(self, self.widthPx)
end

function Vga.loadLatches(self: Vga, offset: number)
	for plane = 0, 3 do
		self.latches[plane] = buffer.readu8(self.planes[plane + 1], band(offset, 0xFFFF))
	end
end

-- Chain-4 reads select one plane per host byte. The retained chain4 buffer is
-- the same byte sequence the guest sees, so the four latches for a host byte
-- come from the aligned group of four entries.
function Vga.loadChain4Latches(self: Vga, offset: number)
	const base = band(offset, 0xFFFC)
	for plane = 0, 3 do
		self.latches[plane] = buffer.readu8(self.chain4, band(base + plane, 0xFFFF))
	end
end

-- Resolve a planar host address to (plane byte offset, plane group mask). In
-- odd/even mode host A0 selects the even (0/2) or odd (1/3) plane group and is
-- not part of the byte address. The standard planar modes disable odd/even
-- (sequencer memory-mode bit 2 set), so the common path is a direct map.
local function planarAddress(self: Vga, offset: number): (number, number)
	const masked = band(offset, 0xFFFF)
	if self:isOddEven() then
		const group = if band(masked, 0x01) ~= 0 then 0x0A else 0x05
		return band(masked, 0xFFFE), group
	end
	return masked, 0x0F
end

local function planarReadPlane(self: Vga, offset: number): number
	if self:isOddEven() then
		return bor(band(self.gfx[4], 0x02), band(offset, 0x01))
	end
	return band(self.gfx[4], 0x03)
end

function Vga.read8(self: Vga, addr: number): number
	const vbeOffset = vbeOffsetForAddress(self, addr)
	if vbeOffset then
		if vbeOffset >= VBE_VRAM_SIZE then
			return 0xFF
		end
		return buffer.readu8(self.vbeFramebuffer, vbeOffset)
	end
	if addr >= VBE_FRAMEBUFFER_BASE and addr < 0x100000000 then
		return 0xFF
	end
	if band(self.misc, 0x02) == 0 then
		return 0xFF
	end
	const offset = apertureOffset(addr)
	if self.info.kind == "linear" or self:isChain4() then
		self:loadChain4Latches(offset)
		return buffer.readu8(self.chain4, band(offset, 0xFFFF))
	end

	const planeOffset = planarAddress(self, offset)
	self:loadLatches(planeOffset)

	-- Graphics Controller mode bit 3 selects colour-compare reads. Despite its
	-- name, GC7 is a compare-enable mask: a set bit means that plane takes part
	-- in the comparison, a clear bit is ignored (Bochs and FreeVGA agree).
	if band(rshift(self.gfx[5], 3), 0x01) == 1 then
		const compare = band(self.gfx[2], 0x0F)
		const compareMask = band(self.gfx[7], 0x0F)
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
			if band(bxor(index, compare), compareMask) == 0 then
				value = bor(value, lshift(1, bit))
			end
		end
		return value
	end

	return self.latches[planarReadPlane(self, offset)]
end

function Vga.write8(self: Vga, addr: number, value: number)
	const vbeOffset = vbeOffsetForAddress(self, addr)
	if vbeOffset then
		if vbeOffset < VBE_VRAM_SIZE then
			buffer.writeu8(self.vbeFramebuffer, vbeOffset, band(value, 0xFF))
			self:markVbeWrite(vbeOffset, 1)
		end
		return
	end
	if addr >= VBE_FRAMEBUFFER_BASE and addr < 0x100000000 then
		return
	end
	if band(self.misc, 0x02) == 0 then
		return
	end
	const offset = apertureOffset(addr)
	if self.info.kind == "linear" or self:isChain4() then
		-- In chain-4 the low address bits select the plane, so the map mask
		-- applies per host byte (QEMU behaves this way; mode 13h enables all
		-- four planes).
		if self:isChain4() and band(self.seq[2], lshift(1, band(offset, 0x03))) == 0 then
			return
		end
		buffer.writeu8(self.chain4, band(offset, 0xFFFF), band(value, 0xFF))
		self:markApertureDirty(offset)
		return
	end

	const data = band(value, 0xFF)
	const writeMode = band(self.gfx[5], 0x03)
	const fn = band(rshift(self.gfx[3], 3), 0x03)
	const rotated = rotateRight(data, band(self.gfx[3], 0x07))
	const bitMask = band(self.gfx[8], 0xFF)
	const setReset = band(self.gfx[0], 0x0F)
	const setResetEnable = band(self.gfx[1], 0x0F)
	const planeOffset, groupMask = planarAddress(self, offset)
	const mapMask = band(band(self.seq[2], 0x0F), groupMask)

	for plane = 0, 3 do
		if band(mapMask, lshift(1, plane)) ~= 0 then
			const latch = self.latches[plane]
			local written: number
			if writeMode == 1 then
				-- Write mode 1: copy the latches; CPU data is ignored.
				written = latch
			elseif writeMode == 2 then
				-- Write mode 2: one data bit expands to a full plane byte, then
				-- the logical-operation stage runs against the latches.
				const source = if band(data, lshift(1, plane)) ~= 0 then 0xFF else 0x00
				const result = applyDataFunction(source, latch, fn)
				written = bor(band(result, bitMask), band(latch, band(bnot(bitMask), 0xFF)))
			elseif writeMode == 3 then
				-- Write mode 3: set/reset is always the source (Enable
				-- Set/Reset is ignored), the rotated CPU byte AND bit mask
				-- selects source bits, and the latches supply the rest. Bochs
				-- and QEMU both run the logical-operation stage here even
				-- though FreeVGA only documents it for modes 0 and 2.
				const mask = band(rotated, bitMask)
				const source = if band(setReset, lshift(1, plane)) ~= 0 then 0xFF else 0x00
				const result = applyDataFunction(source, latch, fn)
				written = bor(band(result, mask), band(latch, band(bnot(mask), 0xFF)))
			else
				-- Write mode 0: rotate, choose set/reset or CPU data per plane,
				-- pass through the logical-operation stage, then the bit mask
				-- selects between the result and the latches.
				const source = if band(setResetEnable, lshift(1, plane)) ~= 0
					then (if band(setReset, lshift(1, plane)) ~= 0 then 0xFF else 0x00)
					else rotated
				const result = applyDataFunction(source, latch, fn)
				written = bor(band(result, bitMask), band(latch, band(bnot(bitMask), 0xFF)))
			end
			buffer.writeu8(self.planes[plane + 1], planeOffset, band(written, 0xFF))
		end
	end
	self:markApertureDirty(offset)
end

function Vga.read16(self: Vga, addr: number): number
	if addr >= VBE_FRAMEBUFFER_BASE and addr + 1 < VBE_FRAMEBUFFER_END then
		return buffer.readu16(self.vbeFramebuffer, addr - VBE_FRAMEBUFFER_BASE)
	end
	return bor(self:read8(addr), lshift(self:read8(addr + 1), 8))
end

function Vga.write16(self: Vga, addr: number, value: number)
	if addr >= VBE_FRAMEBUFFER_BASE and addr + 1 < VBE_FRAMEBUFFER_END then
		const offset = addr - VBE_FRAMEBUFFER_BASE
		buffer.writeu16(self.vbeFramebuffer, offset, band(value, 0xFFFF))
		self:markVbeWrite(offset, 2)
		return
	end
	self:write8(addr, band(value, 0xFF))
	self:write8(addr + 1, band(rshift(value, 8), 0xFF))
end

function Vga.read32(self: Vga, addr: number): number
	if addr >= VBE_FRAMEBUFFER_BASE and addr + 3 < VBE_FRAMEBUFFER_END then
		return buffer.readu32(self.vbeFramebuffer, addr - VBE_FRAMEBUFFER_BASE)
	end
	return bor(self:read16(addr), lshift(self:read16(addr + 2), 16))
end

function Vga.write32(self: Vga, addr: number, value: number)
	if addr >= VBE_FRAMEBUFFER_BASE and addr + 3 < VBE_FRAMEBUFFER_END then
		const offset = addr - VBE_FRAMEBUFFER_BASE
		buffer.writeu32(self.vbeFramebuffer, offset, band(value, 0xFFFFFFFF))
		self:markVbeWrite(offset, 4)
		return
	end
	self:write16(addr, band(value, 0xFFFF))
	self:write16(addr + 2, band(rshift(value, 16), 0xFFFF))
end

function Vga.markApertureDirty(self: Vga, offset: number)
	const start = self:displayStartBytes()
	if offset < start then
		self:markAllDirty()
		return
	end
	const relative = offset - start
	if self.info.kind == "linear" or self:isChain4() then
		const rowBytes = math.max(self.widthPx, self:planarRowBytes())
		const x = relative % rowBytes
		const y = math.floor(relative / rowBytes)
		self:markDirtyRect(x, y, 1, 1)
		return
	end
	if self:isOddEven() then
		-- Odd/even host addresses fold two host bytes into one plane byte and
		-- the display uses a CGA/EGA shift format; a conservative full-frame
		-- invalidation keeps the sink correct without modelling that format.
		self:markAllDirty()
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
	const vbeOffset = vbeOffsetForAddress(self, addr)
	if vbeOffset then
		self:markVbeWrite(vbeOffset, length)
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
		const rowBytes = math.max(self.widthPx, self:planarRowBytes())
		const y0 = math.floor(relativeFirst / rowBytes)
		const y1 = math.floor(relativeLast / rowBytes)
		if y0 == y1 then
			self:markDirtyRect(relativeFirst % rowBytes, y0, length, 1)
		else
			self:markDirtyRect(0, y0, self.widthPx, y1 - y0 + 1)
		end
		return
	end
	if self:isOddEven() then
		self:markAllDirty()
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

	if address == 0x1CE then
		return band(self.vbeIndex, 0xFF)
	elseif address == 0x1CF then
		return band(self:vbeReadData(), 0xFF)
	elseif address == 0x1D0 then
		return band(rshift(self:vbeReadData(), 8), 0xFF)
	elseif address == 0x3C0 then
		-- Address/read flip-flop: in address mode 0x3C0 returns the index plus
		-- the video-enable bit; in data mode it returns the selected register.
		if self.attrFlipFlop then
			return bor(if self.attrPas then 0x20 else 0x00, band(self.attrIndex, 0x1F))
		end
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
		-- DAC state: 11b after a read-address write, 00b after a write-address
		-- write. The read index itself is not visible through this port.
		return self.dacState
	elseif address == 0x3C8 then
		return self.dacWriteIndex
	elseif address == 0x3C9 then
		if self.dacState ~= 0x03 then
			return 0x3F
		end
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
		if self.crtcIndex == 0x22 then
			return self.latches[band(self.gfx[4], 0x03)]
		end
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
	if index == 0x22 then
		-- CRTC 0x22 is the read-only latch alias.
		return
	end
	if index == 0x11 then
		self.crtcProtected = band(value, 0x80) ~= 0
	elseif index <= 0x07 and self.crtcProtected then
		return
	end
	self.crtc[index] = band(value, 0xFF)
	if index == 0x0C or index == 0x0D or index == 0x13 or index == 0x14 or index == 0x17 then
		self:markAllDirty()
	end
end

function Vga.writeDac(self: Vga, value: number)
	const base = self.dacWriteIndex * 3 + self.dacWriteComponent
	const component = if self.dac8 then band(value, 0xFF) else band(value, 0x3F)
	buffer.writeu8(self.dac, base, component)
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

	if address == 0x1CE then
		self.vbeIndex = bor(band(self.vbeIndex, 0xFF00), byte)
		return
	elseif address == 0x1CF then
		const current = self:vbeReadRegister(self.vbeIndex)
		self:vbeWriteRegister(self.vbeIndex, bor(band(current, 0xFF00), byte))
		self:syncLegacyMode()
		return
	elseif address == 0x1D0 then
		const current = self:vbeReadRegister(self.vbeIndex)
		self:vbeWriteRegister(self.vbeIndex, bor(band(current, 0x00FF), lshift(byte, 8)))
		self:syncLegacyMode()
		return
	elseif address == 0x3C0 then
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
		self.dacState = 0x03
	elseif address == 0x3C8 then
		self.dacWriteIndex = byte
		self.dacWriteComponent = 0
		self.dacState = 0x00
	elseif address == 0x3C9 then
		self:writeDac(byte)
	elseif address == 0x3CE then
		self.gfxIndex = band(byte, 0x0F)
	elseif address == 0x3CF then
		self.gfx[self.gfxIndex] = byte
	elseif address == 0x3D4 or address == 0x3B4 then
		-- 0x22 is the latch readback alias, so allow the full 6-bit index.
		self.crtcIndex = band(byte, 0x3F)
	elseif address == 0x3D5 or address == 0x3B5 then
		self:writeCrtc(byte)
	elseif address == 0x3DA or address == 0x3BA then
		self.feature = byte
		self.attrFlipFlop = true
	else
		self.latched[address] = byte
	end
	self:syncLegacyMode()
end

-- Word access for the DISPI pair. Machine should call these for 16-bit I/O at
-- 0x1CE/0x1CF; the byte handlers above also support 0x1D0 as the data high byte.
function Vga.in16(self: Vga, port: number): number
	const address = band(port, 0xFFFF)
	if address == 0x1CE then
		return band(self.vbeIndex, 0xFFFF)
	elseif address == 0x1CF then
		return band(self:vbeReadData(), 0xFFFF)
	end
	return bor(self:in8(address), lshift(self:in8(address + 1), 8))
end

function Vga.out16(self: Vga, port: number, value: number)
	const address = band(port, 0xFFFF)
	if address == 0x1CE then
		self.vbeIndex = band(value, 0xFFFF)
		return
	elseif address == 0x1CF then
		self:vbeWriteRegister(self.vbeIndex, band(value, 0xFFFF))
		self:syncLegacyMode()
		return
	end
	self:out8(address, band(value, 0xFF))
	self:out8(address + 1, band(rshift(value, 8), 0xFF))
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
	const rowBytes = math.max(width, self:planarRowBytes())
	const colors = self.paletteRGBA
	const mask = self.dacMask

	for y = y0, y1 - 1 do
		const rowBase = start + y * rowBytes
		local dest = (y * width + x0) * 4
		for x = x0, x1 - 1 do
			const index = band(buffer.readu8(self.chain4, band(rowBase + x, 0xFFFF)), mask)
			buffer.writeu32(target, dest, colors[index + 1])
			dest += 4
		end
	end
end

-- VBE direct/linear framebuffer conversion. Direct modes use the VBE 3.0
-- colour layout SeaVGABIOS reports: 16bpp RGB565, 32bpp BGRX with red at bit
-- 16, and 24bpp stored as B,G,R bytes. 8bpp indexes the current DAC palette.
local function renderVbe(self: Vga, x0: number, y0: number, x1: number, y1: number)
	const bpp = self.vbeInfo and self.vbeInfo.bitsPerPixel or 8
	const start = self.vbeStartAddr
	const lineBytes = self.vbeLineOffset
	const framebuffer = self.vbeFramebuffer
	const target = self.rgba

	if bpp == 8 or bpp == 4 then
		self:ensurePalette()
		const colors = self.paletteRGBA
		for y = y0, y1 - 1 do
			const rowBase = start + y * lineBytes
			local dest = (y * self.widthPx + x0) * 4
			for x = x0, x1 - 1 do
				local index = 0
				if bpp == 4 then
					const byte = buffer.readu8(framebuffer, rowBase + math.floor(x / 2))
					index = if x % 2 == 0 then rshift(byte, 4) else band(byte, 0x0F)
				else
					index = band(buffer.readu8(framebuffer, rowBase + x), 0xFF)
				end
				buffer.writeu32(target, dest, colors[index + 1] or RGBA_BLACK)
				dest += 4
			end
		end
		return
	end

	if bpp == 15 or bpp == 16 then
		for y = y0, y1 - 1 do
			const rowBase = start + y * lineBytes
			local dest = (y * self.widthPx + x0) * 4
			for x = x0, x1 - 1 do
				const value = buffer.readu16(framebuffer, rowBase + x * 2)
				local red, green, blue
				if bpp == 15 then
					const r5 = band(rshift(value, 10), 0x1F)
					const g5 = band(rshift(value, 5), 0x1F)
					const b5 = band(value, 0x1F)
					red = bor(lshift(r5, 3), rshift(r5, 2))
					green = bor(lshift(g5, 3), rshift(g5, 2))
					blue = bor(lshift(b5, 3), rshift(b5, 2))
				else
					const r5 = band(rshift(value, 11), 0x1F)
					const g6 = band(rshift(value, 5), 0x3F)
					const b5 = band(value, 0x1F)
					red = bor(lshift(r5, 3), rshift(r5, 2))
					green = bor(lshift(g6, 2), rshift(g6, 4))
					blue = bor(lshift(b5, 3), rshift(b5, 2))
				end
				buffer.writeu32(target, dest, rgbaWord(red, green, blue))
				dest += 4
			end
		end
		return
	end

	if bpp == 24 or bpp == 32 then
		const bytesPerPixel = if bpp == 24 then 3 else 4
		for y = y0, y1 - 1 do
			const rowBase = start + y * lineBytes
			local dest = (y * self.widthPx + x0) * 4
			for x = x0, x1 - 1 do
				const source = rowBase + x * bytesPerPixel
				const blue = buffer.readu8(framebuffer, source)
				const green = buffer.readu8(framebuffer, source + 1)
				const red = buffer.readu8(framebuffer, source + 2)
				buffer.writeu32(target, dest, rgbaWord(red, green, blue))
				dest += 4
			end
		end
		return
	end

	-- Unsupported format: leave the retained buffer black for this region.
	for y = y0, y1 - 1 do
		local dest = (y * self.widthPx + x0) * 4
		for _ = x0, x1 - 1 do
			buffer.writeu32(target, dest, RGBA_BLACK)
			dest += 4
		end
	end
end

function Vga.renderPlanar(self: Vga)
	self:syncLegacyMode()
	blitPlanar(self, 0, 0, self.widthPx, self.heightPx)
end

function Vga.renderLinear(self: Vga)
	self:syncLegacyMode()
	blitLinear(self, 0, 0, self.widthPx, self.heightPx)
end

function Vga.renderText(self: Vga)
	self:syncLegacyMode()
	self:ensurePalette()
	const target = self.rgba
	const width = self.widthPx
	-- The colour text aperture is B8000-BFFFF (32 KiB); wrap the CRTC start
	-- address inside that window instead of reading past it into option ROM.
	const start = band(self:displayStartBytes(), 0x7FFF)
	const colors = self.color16RGBA
	const blank = FONT[63] :: { number }
	const blink = band(self.attr[16], 0x08) ~= 0

	for row = 0, TEXT_ROWS - 1 do
		const sourceRow = band(start + row * TEXT_COLS * 2, 0x7FFF)
		for col = 0, TEXT_COLS - 1 do
			const cell = band(sourceRow + col * 2, 0x7FFF)
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
	self:syncLegacyMode()
	if self:isVbeEnabled() then
		renderVbe(self, 0, 0, self.widthPx, self.heightPx)
		return self.rgba
	end
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
	self:syncLegacyMode()
	const x0 = math.max(0, math.floor(x))
	const y0 = math.max(0, math.floor(y))
	const x1 = math.min(self.widthPx, math.floor(x + width))
	const y1 = math.min(self.heightPx, math.floor(y + height))
	if x1 <= x0 or y1 <= y0 then
		return self.rgba
	end
	if self:isVbeEnabled() then
		renderVbe(self, x0, y0, x1, y1)
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

-- Cheap change detector for the visible text plane (80x25 cells = 4000 bytes
-- at the CRTC start). Text-mode writes land in B8000 RAM outside the dirty
-- tracking, so presenters poll this every frame and only snapshot/upload when
-- the plane (or its start address) actually moved.
function Vga.textChecksum(self: Vga): number
	const start = band(self:displayStartBytes(), 0x7FFF)
	const plane = self.mem:copyTo(TEXT_BASE + start, 4096)
	local hash = 0
	for i = 0, 4095 do
		hash = band(hash * 31 + buffer.readu8(plane, i), 0xFFFFFFFF)
	end
	return band(hash + start, 0xFFFFFFFF)
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
		const rowBytes = math.max(self.widthPx, self:planarRowBytes())
		for row = y0, y1 - 1 do
			const rowBase = start + row * rowBytes
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
	self:syncLegacyMode()
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
