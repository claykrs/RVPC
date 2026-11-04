--!nonstrict
-- VbeTests.lua -- Bochs/QEMU DISPI VBE interface and linear-framebuffer rendering.
--
-- Deliberately not added to tools/run.lua yet; the lead wires the suite.

const Memory = require("../core/Memory")
const Vga = require("../core/Vga")
const VgaSink = require("../core/VgaSink")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function fresh()
	return Vga.new(Memory.new(16 * 1024 * 1024))
end

local function writeReg(vga, index, value)
	vga:out16(0x1CE, index)
	vga:out16(0x1CF, value)
end

local function readReg(vga, index)
	vga:out16(0x1CE, index)
	return vga:in16(0x1CF)
end

local function setVbe(vga, width, height, bpp, flags)
	writeReg(vga, Vga.VBE_DISPI_INDEX_XRES, width)
	writeReg(vga, Vga.VBE_DISPI_INDEX_YRES, height)
	writeReg(vga, Vga.VBE_DISPI_INDEX_BPP, bpp)
	writeReg(vga, Vga.VBE_DISPI_INDEX_ENABLE, flags or 0x41)
end

local function pixelBytes(pixels, x, y, width)
	const offset = (y * width + x) * 4
	return buffer.readu8(pixels, offset),
		buffer.readu8(pixels, offset + 1),
		buffer.readu8(pixels, offset + 2),
		buffer.readu8(pixels, offset + 3)
end

T("dispi_id_and_ports", function(expect)
	const vga = fresh()
	expect(vga:in8(0x1CE) == 0, "index reset")
	expect(vga:in8(0x1CF) == 0xC5 and vga:in8(0x1D0) == 0xB0, "default ID5")
	expect(vga:in16(0x1CF) == 0xB0C5, "default ID word")

	writeReg(vga, Vga.VBE_DISPI_INDEX_ID, Vga.VBE_DISPI_ID0)
	expect(vga:in16(0x1CF) == 0xB0C0, "ID0 write")
	writeReg(vga, Vga.VBE_DISPI_INDEX_ID, Vga.VBE_DISPI_ID5)
	expect(vga:in16(0x1CF) == 0xB0C5, "ID5 write")
	writeReg(vga, Vga.VBE_DISPI_INDEX_ID, 0x1234)
	expect(vga:in16(0x1CF) == 0xB0C5, "invalid ID ignored")

	vga:out8(0x1CE, Vga.VBE_DISPI_INDEX_BPP)
	expect(vga:in8(0x1CE) == Vga.VBE_DISPI_INDEX_BPP, "byte index")
	expect(vga:in8(0x1CF) == 0 and vga:in8(0x1D0) == 0, "BPP initially zero")
end)

T("dispi_byte_split_sequence", function(expect)
	const vga = fresh()
	local function writeWordSplit(port, value)
		vga:out8(port, value % 256)
		vga:out8(port + 1, math.floor(value / 256))
	end

	-- This is what Machine.out16's default byte split does: the index word's
	-- high byte lands on 0x1CF (data low) and the data word's high byte lands
	-- on 0x1D0.
	writeWordSplit(0x1CE, Vga.VBE_DISPI_INDEX_ID)
	writeWordSplit(0x1CF, Vga.VBE_DISPI_ID0)
	expect(vga:in16(0x1CF) == 0xB0C0, "byte-split ID0")
	writeWordSplit(0x1CF, Vga.VBE_DISPI_ID5)
	expect(vga:in16(0x1CF) == 0xB0C5, "byte-split ID5")

	writeWordSplit(0x1CE, Vga.VBE_DISPI_INDEX_XRES)
	writeWordSplit(0x1CF, 640)
	expect(readReg(vga, Vga.VBE_DISPI_INDEX_XRES) == 640, "byte-split XRES")
	writeWordSplit(0x1CE, Vga.VBE_DISPI_INDEX_YRES)
	writeWordSplit(0x1CF, 480)
	writeWordSplit(0x1CE, Vga.VBE_DISPI_INDEX_BPP)
	writeWordSplit(0x1CF, 16)
	writeWordSplit(0x1CE, Vga.VBE_DISPI_INDEX_ENABLE)
	writeWordSplit(0x1CF, 0x41)
	expect(vga:isVbeEnabled(), "byte-split enable")
	expect(vga:width() == 640 and vga:height() == 480, "byte-split geometry")
end)

T("dispi_mode_list", function(expect)
	const expected = {
		{ 0x101, 640, 480, 8 },
		{ 0x111, 640, 480, 16 },
		{ 0x142, 640, 480, 32 },
		{ 0x103, 800, 600, 8 },
		{ 0x114, 800, 600, 16 },
		{ 0x143, 800, 600, 32 },
		{ 0x105, 1024, 768, 8 },
		{ 0x117, 1024, 768, 16 },
		{ 0x144, 1024, 768, 32 },
	}
	for _, item in expected do
		const info = Vga.vbeModeInfo(item[1])
		expect(info ~= nil, ("mode %X missing"):format(item[1]))
		if info then
			expect(
				info.width == item[2] and info.height == item[3] and info.bpp == item[4],
				("mode %X geometry"):format(item[1])
			)
		end
		expect(Vga.vbeModeInfo(item[1] + 0x4000) == info, "LFB-bit mode lookup")
	end
	expect(#Vga.VBE_MODES == #expected, "mode list count")
end)

T("dispi_caps_and_video_memory", function(expect)
	const vga = fresh()
	writeReg(vga, Vga.VBE_DISPI_INDEX_ENABLE, Vga.VBE_DISPI_GETCAPS)
	expect(readReg(vga, Vga.VBE_DISPI_INDEX_XRES) == 2560, "max XRES")
	expect(readReg(vga, Vga.VBE_DISPI_INDEX_YRES) == 1600, "max YRES")
	expect(readReg(vga, Vga.VBE_DISPI_INDEX_BPP) == 32, "max BPP")
	expect(readReg(vga, Vga.VBE_DISPI_INDEX_ID) == 0xB0C5, "ID during GETCAPS")

	writeReg(vga, Vga.VBE_DISPI_INDEX_ENABLE, 0)
	expect(readReg(vga, Vga.VBE_DISPI_INDEX_XRES) == 0, "XRES after caps")
	expect(readReg(vga, Vga.VBE_DISPI_INDEX_VIDEO_MEMORY_64K) == 64, "4 MiB video memory")
	expect(Vga.FRAMEBUFFER_BASE == 0xE0000000, "framebuffer base")
	expect(Vga.FRAMEBUFFER_SIZE == 0x400000, "framebuffer size")
	expect(Vga.containsAddress(Vga.FRAMEBUFFER_BASE), "LFB start mapped")
	expect(Vga.containsAddress(Vga.FRAMEBUFFER_END - 1), "LFB end mapped")
	expect(not Vga.containsAddress(Vga.FRAMEBUFFER_END), "LFB end exclusive")
end)

T("enable_640x480_16bpp", function(expect)
	const vga = fresh()
	setVbe(vga, 640, 480, 16)
	expect(vga:isVbeEnabled(), "VBE not enabled")
	expect(not vga:isTextMode(), "VBE reported as text")
	expect(vga:width() == 640 and vga:height() == 480, "geometry")
	const info = vga:modeInfo()
	expect(info.kind == "vbe" and info.bitsPerPixel == 16, "VBE mode info")
	expect(vga:mode() == 0x111, "mode number " .. tostring(vga:mode()))

	const initial = vga:consumeDirty()
	expect(initial ~= nil, "enable did not dirty")
	if initial then
		expect(initial.width == 640 and initial.height == 480, "enable dirty rect")
	end

	const x, y = 50, 100
	const lineBytes = 640 * 2
	vga:write16(Vga.FRAMEBUFFER_BASE + y * lineBytes + x * 2, 0xF800)
	const rect = vga:consumeDirty()
	expect(rect ~= nil, "pixel write not dirty")
	if rect then
		expect(rect.x == x and rect.y == y, ("rect at %d,%d"):format(rect.x, rect.y))
		expect(rect.width == 1 and rect.height == 1, "rect size")
	end

	const pixels = vga:snapshotRGBA()
	expect(buffer.len(pixels) == 640 * 480 * 4, "RGBA size")
	const r, g, b, a = pixelBytes(pixels, x, y, 640)
	expect(
		r == 255 and g == 0 and b == 0 and a == 255,
		("RGB565 red %d,%d,%d,%d"):format(r, g, b, a)
	)
end)

T("16bpp_565_green_and_blue", function(expect)
	const vga = fresh()
	setVbe(vga, 640, 480, 16)
	const pixels = vga:snapshotRGBA()
	vga:write16(Vga.FRAMEBUFFER_BASE + 0, 0x07E0)
	vga:write16(Vga.FRAMEBUFFER_BASE + 2, 0x001F)
	const shown = vga:snapshotRGBA()
	local r, g, b = pixelBytes(shown, 0, 0, 640)
	expect(r == 0 and g == 255 and b == 0, ("green %d,%d,%d"):format(r, g, b))
	r, g, b = pixelBytes(shown, 1, 0, 640)
	expect(r == 0 and g == 0 and b == 255, ("blue %d,%d,%d"):format(r, g, b))
	expect(buffer.len(pixels) == 640 * 480 * 4, "snapshot size")
end)

T("32bpp_bgrx", function(expect)
	const vga = fresh()
	setVbe(vga, 800, 600, 32)
	expect(vga:width() == 800 and vga:height() == 600, "geometry")
	const x, y = 10, 20
	const lineBytes = 800 * 4
	vga:write32(Vga.FRAMEBUFFER_BASE + y * lineBytes + x * 4, 0x00123456)
	const shown = vga:snapshotRGBA()
	const r, g, b, a = pixelBytes(shown, x, y, 800)
	expect(r == 0x12 and g == 0x34 and b == 0x56, ("BGRX %02X%02X%02X"):format(r, g, b))
	expect(a == 255, "alpha")
	expect(buffer.len(shown) == 800 * 600 * 4, "RGBA size")
end)

T("15bpp_rgb555", function(expect)
	const vga = fresh()
	setVbe(vga, 640, 480, 15)
	vga:write16(Vga.FRAMEBUFFER_BASE, 0x7C00)
	const shown = vga:snapshotRGBA()
	const r, g, b = pixelBytes(shown, 0, 0, 640)
	expect(r == 255 and g == 0 and b == 0, ("RGB555 red %d,%d,%d"):format(r, g, b))
end)

T("24bpp_bgr", function(expect)
	const vga = fresh()
	setVbe(vga, 640, 480, 24)
	const x, y = 4, 5
	const lineBytes = 640 * 3
	const offset = Vga.FRAMEBUFFER_BASE + y * lineBytes + x * 3
	vga:write8(offset, 0x11)
	vga:write8(offset + 1, 0x22)
	vga:write8(offset + 2, 0x33)
	const shown = vga:snapshotRGBA()
	const r, g, b = pixelBytes(shown, x, y, 640)
	expect(r == 0x33 and g == 0x22 and b == 0x11, ("BGR %02X%02X%02X"):format(r, g, b))
end)

T("8bpp_palette_and_palette_dirty", function(expect)
	const vga = fresh()
	setVbe(vga, 640, 480, 8, 0x41)
	vga:consumeDirty()

	vga:out8(0x3C8, 1)
	vga:out8(0x3C9, 0x3F)
	vga:out8(0x3C9, 0x00)
	vga:out8(0x3C9, 0x00)
	vga:consumeDirty()

	const x, y = 12, 34
	vga:write8(Vga.FRAMEBUFFER_BASE + y * 640 + x, 1)
	const rect = vga:consumeDirty()
	expect(rect ~= nil, "8bpp pixel dirty")
	if rect then
		expect(rect.x == x and rect.y == y and rect.width == 1, "8bpp rect")
	end
	local shown = vga:snapshotRGBA()
	local r, g, b = pixelBytes(shown, x, y, 640)
	expect(r == 255 and g == 0 and b == 0, ("palette red %d,%d,%d"):format(r, g, b))

	-- Palette component writes redraw the whole screen.
	vga:out8(0x3C8, 1)
	vga:out8(0x3C9, 0x00)
	vga:out8(0x3C9, 0x3F)
	vga:out8(0x3C9, 0x00)
	const paletteRect = vga:consumeDirty()
	expect(paletteRect ~= nil, "palette write not dirty")
	if paletteRect then
		expect(paletteRect.width == 640 and paletteRect.height == 480, "palette dirty full")
	end
	shown = vga:snapshotRGBA()
	r, g, b = pixelBytes(shown, x, y, 640)
	expect(r == 0 and g == 255 and b == 0, ("palette green %d,%d,%d"):format(r, g, b))
end)

T("8bit_dac", function(expect)
	const vga = fresh()
	setVbe(vga, 640, 480, 8, 0x61)
	expect(vga.dac8, "8-bit DAC flag")
	vga:consumeDirty()
	vga:out8(0x3C8, 2)
	vga:out8(0x3C9, 0x80)
	vga:out8(0x3C9, 0x00)
	vga:out8(0x3C9, 0x00)
	vga:write8(Vga.FRAMEBUFFER_BASE, 2)
	const shown = vga:snapshotRGBA()
	const r, g, b = pixelBytes(shown, 0, 0, 640)
	expect(r == 0x80 and g == 0 and b == 0, ("8-bit DAC red %d,%d,%d"):format(r, g, b))
end)

T("virt_width_and_offsets", function(expect)
	const vga = fresh()
	setVbe(vga, 640, 480, 16)
	writeReg(vga, Vga.VBE_DISPI_INDEX_VIRT_WIDTH, 800)
	writeReg(vga, Vga.VBE_DISPI_INDEX_X_OFFSET, 4)
	writeReg(vga, Vga.VBE_DISPI_INDEX_Y_OFFSET, 2)
	vga:consumeDirty()

	expect(vga:width() == 640 and vga:height() == 480, "visible geometry")
	const lineBytes = 800 * 2
	const start = 4 * 2 + 2 * lineBytes
	const x, y = 10, 20
	vga:write16(Vga.FRAMEBUFFER_BASE + start + y * lineBytes + x * 2, 0x07E0)
	const shown = vga:snapshotRGBA()
	const r, g, b = pixelBytes(shown, x, y, 640)
	expect(r == 0 and g == 255 and b == 0, ("offset pixel %d,%d,%d"):format(r, g, b))
end)

T("banked_aperture", function(expect)
	const vga = fresh()
	setVbe(vga, 640, 480, 8)
	writeReg(vga, Vga.VBE_DISPI_INDEX_BANK, 1)
	expect(readReg(vga, Vga.VBE_DISPI_INDEX_BANK) == 1, "bank readback")
	expect(vga.vbeBankOffset == 0x10000, "bank offset")
	vga:write8(0xA0000, 7)
	expect(buffer.readu8(vga.vbeFramebuffer, 0x10000) == 7, "banked framebuffer")
	expect(vga:read8(0xA0000) == 7, "banked readback")

	writeReg(vga, Vga.VBE_DISPI_INDEX_BANK, 0)
	vga:write8(0xA0000, 9)
	expect(buffer.readu8(vga.vbeFramebuffer, 0) == 9, "bank 0 framebuffer")
	expect(vga:read8(0xA0000) == 9, "bank 0 readback")
end)

T("set_mode_vbe_and_legacy_return", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x101), "setMode 0x101")
	expect(vga:isVbeEnabled(), "setMode did not enable VBE")
	expect(vga:width() == 640 and vga:height() == 480, "VBE geometry")
	expect(vga:mode() == 0x101 and vga:modeInfo().bitsPerPixel == 8, "VBE mode state")

	expect(vga:setMode(0x103), "setMode 0x103")
	expect(vga:width() == 800 and vga:height() == 600, "800x600x8 geometry")
	expect(vga:mode() == 0x103, "800x600x8 mode number")
	expect(not vga:setMode(0x112), "unknown VBE number aliased mode 12h")

	expect(vga:setMode(0x03), "mode 3 regression")
	expect(not vga:isVbeEnabled(), "VBE still enabled after mode 3")
	expect(vga:isTextMode(), "mode 3 not text")
	expect(vga:width() == 640 and vga:height() == 400, "mode 3 geometry")
	expect(vga:mode() == 0x03, "mode 3 number")
	expect(vga:modeInfo().kind == "text", "mode 3 info")
end)

T("mode3_regression", function(expect)
	const vga = fresh()
	vga:writeText(1, 2, "VBE", 0x0F)
	const pixels = vga:snapshotRGBA()
	expect(vga:width() == 640 and vga:height() == 400, "text geometry")
	expect(buffer.len(pixels) == 640 * 400 * 4, "text RGBA size")
	local lit = 0
	for index = 0, 640 * 400 - 1 do
		if buffer.readu8(pixels, index * 4) ~= 0 then
			lit += 1
		end
	end
	expect(lit > 0, "text pixels not rendered")
end)

T("vbe_sink_region", function(expect)
	const vga = fresh()
	setVbe(vga, 800, 600, 16)
	const presented = {}
	const sink = VgaSink.new(vga, function(pixels, width, height, rect)
		presented[#presented + 1] = {
			pixels = pixels,
			width = width,
			height = height,
			rect = rect,
		}
	end)
	expect(sink:poll(true), "forced VBE frame")
	expect(#presented == 1, "present count")
	if presented[1] then
		expect(presented[1].width == 800 and presented[1].height == 600, "VBE sink geometry")
		expect(buffer.len(presented[1].pixels) == 800 * 600 * 4, "VBE sink RGBA size")
	end

	vga:write16(Vga.FRAMEBUFFER_BASE + 3 * 800 * 2 + 2 * 2, 0x07E0)
	expect(sink:poll(), "VBE dirty poll")
	const frame = presented[#presented]
	expect(frame ~= nil and frame.rect.x == 2 and frame.rect.y == 3, "VBE sink rect")
	expect(frame ~= nil and frame.rect.width == 1 and frame.rect.height == 1, "VBE sink rect size")
end)

T("legacy_ports_still_work", function(expect)
	const vga = fresh()
	vga:out8(0x3C4, 1)
	vga:out8(0x3C5, 0x0F)
	expect(vga:in8(0x3C5) == 0x0F, "sequencer write")
	writeReg(vga, Vga.VBE_DISPI_INDEX_ID, Vga.VBE_DISPI_ID0)
	expect(vga:in8(0x3C5) == 0x0F, "sequencer survived DISPI")
end)

return TESTS
