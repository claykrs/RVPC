--!nonstrict
-- VgaMode12Tests.lua -- mode 12h planar register behaviour and VBE banked window.
--
-- Deliberately not added to tools/run.lua yet; the lead wires the suite.

const Memory = require("../core/Memory")
const Vga = require("../core/Vga")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function fresh()
	return Vga.new(Memory.new(16 * 1024 * 1024))
end

local function writeSeq(vga, index, value)
	vga:out8(0x3C4, index)
	vga:out8(0x3C5, value)
end

local function writeGfx(vga, index, value)
	vga:out8(0x3CE, index)
	vga:out8(0x3CF, value)
end

local function writeCrtc(vga, index, value)
	vga:out8(0x3D4, index)
	vga:out8(0x3D5, value)
end

local function writeAttr(vga, index, value)
	-- Bit 5 keeps the attribute-controller video output enabled.
	vga:out8(0x3C0, bit32.bor(index, 0x20))
	vga:out8(0x3C0, value)
end

local function writePlane(vga, plane, offset, value)
	writeSeq(vga, 2, bit32.lshift(1, plane))
	vga:write8(0xA0000 + offset, value)
	writeSeq(vga, 2, 0x0F)
end

local function readPlane(vga, plane, offset)
	writeGfx(vga, 4, plane)
	return vga:read8(0xA0000 + offset)
end

local function pixelRGBA(pixels, x, y, width)
	const offset = (y * width + x) * 4
	return buffer.readu8(pixels, offset),
		buffer.readu8(pixels, offset + 1),
		buffer.readu8(pixels, offset + 2),
		buffer.readu8(pixels, offset + 3)
end

local function expectPixel(expect, pixels, x, y, width, red, green, blue, label)
	const r, g, b, a = pixelRGBA(pixels, x, y, width)
	expect(
		r == red and g == green and b == blue and a == 255,
		("%s got %d,%d,%d,%d"):format(label, r, g, b, a)
	)
end

local function writeVbeReg(vga, index, value)
	vga:out16(0x1CE, index)
	vga:out16(0x1CF, value)
end

local function readVbeReg(vga, index)
	vga:out16(0x1CE, index)
	return vga:in16(0x1CF)
end

local function setVbe(vga, width, height, bpp, flags)
	writeVbeReg(vga, Vga.VBE_DISPI_INDEX_XRES, width)
	writeVbeReg(vga, Vga.VBE_DISPI_INDEX_YRES, height)
	writeVbeReg(vga, Vga.VBE_DISPI_INDEX_BPP, bpp)
	writeVbeReg(vga, Vga.VBE_DISPI_INDEX_ENABLE, flags or 0x41)
end

T("mode12_geometry_and_register_defaults", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")
	expect(vga:width() == 640 and vga:height() == 480, "geometry")
	const info = vga:modeInfo()
	expect(info.kind == "planar" and info.bitsPerPixel == 4, "mode info")
	expect(info.rowBytes == 80, "row bytes " .. tostring(info.rowBytes))

	expect(vga:readSeq(2) == 0x0F, "map mask")
	expect(vga:readSeq(4) == 0x06, "sequencer memory mode")
	expect(not vga:isChain4(), "chain-4 unexpectedly enabled")
	expect(not vga:isOddEven(), "odd/even unexpectedly enabled")
	expect(vga:readGfx(5) == 0x00, "graphics mode")
	expect(vga:readGfx(8) == 0xFF, "bit mask")
	expect(vga:readAttr(0x10) == 0x01, "attribute mode")
	expect(vga:readAttr(0x12) == 0x0F, "plane enable")
	expect(vga:readAttr(0x14) == 0x00, "colour select")
	expect(vga:readAttr(5) == 0x05, "palette entry 5")
	expect(vga:readAttr(6) == 0x14, "palette entry 6 is brown")
	expect(vga:readAttr(7) == 0x07, "palette entry 7")
	expect(vga:readAttr(8) == 0x38 and vga:readAttr(15) == 0x3F, "bright palette entries")

	local red, green, blue = vga:paletteColor(0x14)
	expect(red == 170 and green == 85 and blue == 0, "brown DAC expansion")
	red, green, blue = vga:paletteColor(0x38)
	expect(red == 85 and green == 85 and blue == 85, "dark grey DAC expansion")
	red, green, blue = vga:paletteColor(0x3F)
	expect(red == 255 and green == 255 and blue == 255, "white DAC expansion")

	const initial = vga:consumeDirty()
	expect(initial ~= nil and initial.width == 640 and initial.height == 480, "set-mode dirty")
	const pixels = vga:snapshotRGBA()
	expect(buffer.len(pixels) == 640 * 480 * 4, "RGBA size")
end)

T("mode12_detected_from_guest_ports", function(expect)
	const vga = fresh()
	-- SeaVGABIOS programs controllers through the I/O ports rather than calling
	-- setMode. Reproduce the mode 12h register writes that matter to detection.
	writeCrtc(vga, 0x11, 0x0C) -- unlock CRTC 0..7
	writeSeq(vga, 1, 0x01)
	writeSeq(vga, 2, 0x0F)
	writeSeq(vga, 4, 0x06)
	writeGfx(vga, 5, 0x00)
	writeGfx(vga, 6, 0x05)
	writeGfx(vga, 8, 0xFF)
	writeAttr(vga, 0x10, 0x01)
	writeAttr(vga, 0x12, 0x0F)
	writeCrtc(vga, 0x01, 0x4F)
	writeCrtc(vga, 0x07, 0x3E)
	writeCrtc(vga, 0x09, 0x40)
	writeCrtc(vga, 0x12, 0xDF)
	writeCrtc(vga, 0x13, 0x28)
	writeCrtc(vga, 0x14, 0x00) -- byte addressing
	writeCrtc(vga, 0x17, 0xE3)
	writeCrtc(vga, 0x11, 0x8C) -- restore write protect

	expect(not vga:isTextMode(), "guest mode 12 still text")
	expect(vga:width() == 640 and vga:height() == 480, "guest mode 12 geometry")
	expect(vga:mode() == 0x12, "guest mode 12 number")
	expect(vga:modeInfo().kind == "planar", "guest mode 12 kind")
	expect(vga:modeInfo().rowBytes == 80, "guest mode 12 row bytes")
	vga:consumeDirty()
	vga:write8(0xA0000, 0xFF)
	const pixels = vga:snapshotRGBA()
	expect(buffer.len(pixels) == 640 * 480 * 4, "guest mode 12 RGBA size")
	expectPixel(expect, pixels, 0, 0, 640, 255, 255, 255, "guest mode 12 pixel")
end)

T("mode13_detected_from_guest_ports", function(expect)
	const vga = fresh()
	writeCrtc(vga, 0x11, 0x0C)
	writeSeq(vga, 1, 0x01)
	writeSeq(vga, 2, 0x0F)
	writeSeq(vga, 4, 0x0E) -- chain-4
	writeGfx(vga, 5, 0x40) -- 256-colour shift
	writeGfx(vga, 6, 0x05)
	writeGfx(vga, 8, 0xFF)
	writeAttr(vga, 0x10, 0x41)
	writeAttr(vga, 0x12, 0x0F)
	writeCrtc(vga, 0x01, 0x4F)
	writeCrtc(vga, 0x07, 0x1F)
	writeCrtc(vga, 0x09, 0x41)
	writeCrtc(vga, 0x12, 0x8F)
	writeCrtc(vga, 0x13, 0x28)
	writeCrtc(vga, 0x14, 0x40) -- doubleword addressing
	writeCrtc(vga, 0x17, 0xA3)
	writeCrtc(vga, 0x11, 0x8E)

	expect(not vga:isTextMode(), "guest mode 13 still text")
	expect(vga:width() == 320 and vga:height() == 200, "guest mode 13 geometry")
	expect(vga:mode() == 0x13, "guest mode 13 number")
	expect(vga:isChain4(), "guest mode 13 chain-4")
	vga:consumeDirty()
	vga:write8(0xA0000, 0x0F)
	const pixels = vga:snapshotRGBA()
	expect(buffer.len(pixels) == 320 * 200 * 4, "guest mode 13 RGBA size")
	expectPixel(expect, pixels, 0, 0, 320, 255, 255, 255, "guest mode 13 pixel")

	-- Switching the graphics/alpha bits back reports text mode again.
	writeGfx(vga, 6, 0x0E)
	writeAttr(vga, 0x10, 0x0C)
	expect(vga:isTextMode(), "guest text mode not detected")
	expect(vga:width() == 640 and vga:height() == 400, "guest text geometry")
end)

T("text_font_loading_does_not_switch_mode", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x03), "mode 3 rejected")
	-- SeaVGABIOS get_font_access: plane 2 window at A0000 with alpha enabled.
	writeSeq(vga, 0, 0x01)
	writeSeq(vga, 2, 0x04)
	writeSeq(vga, 4, 0x07)
	writeSeq(vga, 0, 0x03)
	writeGfx(vga, 4, 0x02)
	writeGfx(vga, 5, 0x00)
	writeGfx(vga, 6, 0x04)
	expect(vga:isTextMode(), "font access flipped to graphics")
	vga:write8(0xA0000, 0x5A)
	expect(readPlane(vga, 2, 0) == 0x5A, "font byte not written to plane 2")

	-- release_font_access restores the text register set.
	writeSeq(vga, 2, 0x03)
	writeSeq(vga, 4, 0x02)
	writeGfx(vga, 6, 0x0E)
	writeGfx(vga, 5, 0x10)
	expect(vga:isTextMode(), "text mode lost after font load")
	expect(vga:width() == 640 and vga:height() == 400, "text geometry changed")
end)

T("crtc_write_protect", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")
	-- Mode 12h leaves CRTC 0x11 bit 7 set, protecting registers 0..7.
	const before = vga:readCrtc(0x01)
	writeCrtc(vga, 0x01, 0x00)
	expect(vga:readCrtc(0x01) == before, "protected CRTC write ignored")
	writeCrtc(vga, 0x11, 0x0C)
	writeCrtc(vga, 0x01, 0x00)
	expect(vga:readCrtc(0x01) == 0x00, "unlocked CRTC write accepted")
end)

T("dac_read_state_and_6bit_expansion", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")

	vga:out8(0x3C8, 2)
	vga:out8(0x3C9, 0x3F)
	vga:out8(0x3C9, 0x15)
	vga:out8(0x3C9, 0x00)
	expect(vga:in8(0x3C7) == 0x00, "DAC write state")
	local red, green, blue = vga:paletteColor(2)
	expect(red == 255 and green == 85 and blue == 0, "6-bit DAC expansion")

	vga:out8(0x3C7, 2)
	expect(vga:in8(0x3C7) == 0x03, "DAC read state")
	expect(vga:in8(0x3C9) == 0x3F, "DAC red component")
	expect(vga:in8(0x3C9) == 0x15, "DAC green component")
	expect(vga:in8(0x3C9) == 0x00, "DAC blue component")
	expect(vga:in8(0x3C9) == 0x00, "DAC read index advanced")
end)

T("mode12_plane_writes_palette_and_rows", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")
	vga:consumeDirty()

	-- One pixel per plane at byte zero: bits 7, 6, 5, 4 select colours 1, 2,
	-- 4 and 8 respectively.
	writePlane(vga, 0, 0, 0x80)
	writePlane(vga, 1, 0, 0x40)
	writePlane(vga, 2, 0, 0x20)
	writePlane(vga, 3, 0, 0x10)

	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 0, 640, 0, 0, 170, "plane 0 blue")
	expectPixel(expect, pixels, 1, 0, 640, 0, 170, 0, "plane 1 green")
	expectPixel(expect, pixels, 2, 0, 640, 170, 0, 0, "plane 2 red")
	expectPixel(expect, pixels, 3, 0, 640, 85, 85, 85, "plane 3 dark grey")
	expectPixel(expect, pixels, 4, 0, 640, 0, 0, 0, "unwritten pixel")

	-- A byte on the next scanline uses CRTC offset 0x13 (80 bytes).
	writeSeq(vga, 2, 0x0F)
	vga:write8(0xA0000 + 80, 0xFF)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 1, 640, 255, 255, 255, "row 1 white")
	expectPixel(expect, pixels, 7, 1, 640, 255, 255, 255, "row 1 last bit")
	expectPixel(expect, pixels, 0, 0, 640, 0, 0, 170, "row 0 preserved")

	-- Partial-region conversion writes only the requested rectangle.
	vga:snapshotRegionRGBA(0, 1, 8, 1)
	expectPixel(expect, pixels, 0, 1, 640, 255, 255, 255, "region row 1")
	expectPixel(expect, pixels, 8, 1, 640, 0, 0, 0, "region leaves byte 1 alone")
	expectPixel(expect, pixels, 0, 2, 640, 0, 0, 0, "region leaves row 2 alone")
end)

T("mode12_bit_mask_uses_latches", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")
	expect(vga:read8(0xA0000) == 0, "initial latch")

	-- Low nibble only; the high nibble comes from the zero latches.
	writeGfx(vga, 8, 0x0F)
	vga:write8(0xA0000, 0xFF)
	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 0, 640, 0, 0, 0, "mask leaves pixel 0")
	expectPixel(expect, pixels, 4, 0, 640, 255, 255, 255, "mask sets pixel 4")

	-- No read in between: hardware still holds zero latches, so the high
	-- nibble comes from the latches rather than the just-written destination.
	writeGfx(vga, 8, 0xF0)
	vga:write8(0xA0000, 0xFF)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 0, 640, 255, 255, 255, "high nibble set")
	expectPixel(expect, pixels, 4, 0, 640, 0, 0, 0, "low nibble from latch")

	-- Refresh the latches and check that a zero source preserves the high
	-- nibble while masking the low nibble.
	writeGfx(vga, 8, 0x0F)
	expect(vga:read8(0xA0000) == 0xF0, "latch 0xF0")
	vga:write8(0xA0000, 0x00)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 0, 640, 255, 255, 255, "latch keeps pixel 0")
	expectPixel(expect, pixels, 4, 0, 640, 0, 0, 0, "source zero clears pixel 4")
end)

T("mode12_set_reset_and_logical_ops", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")
	vga:consumeDirty()

	-- Set/reset planes 0 and 2; CPU data is ignored.
	writeGfx(vga, 0, 0x05)
	writeGfx(vga, 1, 0x0F)
	writeGfx(vga, 3, 0x00)
	vga:write8(0xA0000, 0x00)
	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 0, 640, 170, 0, 170, "set/reset magenta")

	-- Write 0xAA into all planes, latch it, then AND with set/reset enabled.
	writeGfx(vga, 1, 0x00)
	vga:write8(0xA0001, 0xAA)
	expect(vga:read8(0xA0001) == 0xAA, "latch 0xAA")
	writeGfx(vga, 0, 0x0F)
	writeGfx(vga, 1, 0x0F)
	writeGfx(vga, 3, 0x08) -- logical AND
	vga:write8(0xA0001, 0x00)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 8, 0, 640, 255, 255, 255, "AND keeps bit 7")
	expectPixel(expect, pixels, 9, 0, 640, 0, 0, 0, "AND clears bit 6")
	expectPixel(expect, pixels, 10, 0, 640, 255, 255, 255, "AND keeps bit 5")

	-- Data rotate right by one moves bit 7 to bit 6.
	writeGfx(vga, 1, 0x00)
	writeGfx(vga, 3, 0x01)
	vga:write8(0xA0002, 0x80)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 16, 0, 640, 0, 0, 0, "rotate leaves bit 7 clear")
	expectPixel(expect, pixels, 17, 0, 640, 255, 255, 255, "rotate moves bit 7 to bit 6")
end)

T("mode12_write_modes_2_and_3", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")
	vga:read8(0xA0000)

	-- Write mode 2 expands host bits 0..3 into planes 0..3. Set/reset must be
	-- ignored in this mode.
	writeGfx(vga, 5, 0x02)
	writeGfx(vga, 0, 0x0F)
	writeGfx(vga, 1, 0x0F)
	vga:write8(0xA0000, 0x05)
	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 0, 640, 170, 0, 170, "write mode 2 magenta")
	vga:write8(0xA0001, 0x02)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 8, 0, 640, 0, 170, 0, "write mode 2 ignores set/reset")

	-- Write mode 2 still runs the logical operation against the latches.
	writeGfx(vga, 5, 0x00)
	writeGfx(vga, 1, 0x00)
	writeGfx(vga, 3, 0x00)
	vga:write8(0xA0002, 0x0F)
	expect(vga:read8(0xA0002) == 0x0F, "latch 0x0F")
	writeGfx(vga, 5, 0x02)
	writeGfx(vga, 3, 0x10) -- logical OR
	vga:write8(0xA0002, 0x01)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 16, 0, 640, 0, 0, 170, "write mode 2 OR plane 0")
	expectPixel(expect, pixels, 20, 0, 640, 255, 255, 255, "write mode 2 OR latch bits")

	-- Write mode 3 uses set/reset regardless of Enable Set/Reset and takes
	-- preserved bits from the latches.
	writeGfx(vga, 5, 0x00)
	writeGfx(vga, 3, 0x00)
	vga:write8(0xA0003, 0x00)
	expect(vga:read8(0xA0003) == 0, "zero latch")
	writeGfx(vga, 0, 0x0A) -- planes 1 and 3
	writeGfx(vga, 1, 0x00) -- must be ignored in mode 3
	writeGfx(vga, 5, 0x03)
	writeGfx(vga, 8, 0xFF)
	vga:write8(0xA0003, 0x0F)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 24, 0, 640, 0, 0, 0, "write mode 3 latch stays black")
	expectPixel(expect, pixels, 28, 0, 640, 85, 255, 85, "write mode 3 bright green")

	-- A second mode-3 write must preserve the latch bits, not the previous
	-- destination bits. Latches are still zero because no read happened.
	writeGfx(vga, 8, 0xF0)
	vga:write8(0xA0003, 0xFF)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 24, 0, 640, 85, 255, 85, "mode 3 high nibble set")
	expectPixel(expect, pixels, 28, 0, 640, 0, 0, 0, "mode 3 low nibble from latch")

	-- Write mode 3 rotates the CPU byte before it becomes the mask.
	writeGfx(vga, 0, 0x0F)
	writeGfx(vga, 3, 0x01)
	writeGfx(vga, 8, 0xFF)
	vga:write8(0xA0004, 0x80) -- rotated to 0x40: bit 6, not bit 7
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 32, 0, 640, 0, 0, 0, "mode 3 rotate clears bit 7")
	expectPixel(expect, pixels, 33, 0, 640, 255, 255, 255, "mode 3 rotate sets bit 6")

	-- Write mode 2 uses the unrotated low nibble (0x01 selects plane 0).
	writeGfx(vga, 5, 0x02)
	writeGfx(vga, 3, 0x01)
	vga:write8(0xA0005, 0x01)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 40, 0, 640, 0, 0, 170, "mode 2 ignores rotate")

	-- Write mode 3 still runs the logical operation (Bochs/QEMU behaviour).
	-- The latches are still zero, so AND with set/reset produces no pixels.
	writeGfx(vga, 5, 0x03)
	writeGfx(vga, 3, 0x08)
	writeGfx(vga, 8, 0xFF)
	vga:write8(0xA0006, 0xFF)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 48, 0, 640, 0, 0, 0, "mode 3 AND with zero latch")
end)

T("mode12_read_mode_0_and_1", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")

	writePlane(vga, 0, 0, 0xAA)
	writePlane(vga, 1, 0, 0xCC)
	writePlane(vga, 2, 0, 0x00)
	writePlane(vga, 3, 0, 0x00)

	expect(readPlane(vga, 0, 0) == 0xAA, "read map 0")
	expect(readPlane(vga, 1, 0) == 0xCC, "read map 1")
	expect(readPlane(vga, 2, 0) == 0x00, "read map 2")
	expect(readPlane(vga, 3, 0) == 0x00, "read map 3")

	-- Read mode 1: colour compare with all planes considered.
	writeGfx(vga, 5, 0x08)
	writeGfx(vga, 2, 0x00)
	writeGfx(vga, 7, 0x0F)
	expect(vga:read8(0xA0000) == 0x11, "colour compare 0x11")

	-- Compare only planes 2 and 3; both are zero so every pixel matches.
	writeGfx(vga, 7, 0x0C)
	expect(vga:read8(0xA0000) == 0xFF, "colour compare plane mask")

	-- Read mode 0 latches all four planes, and write mode 1 copies them.
	writeGfx(vga, 5, 0x00)
	writePlane(vga, 0, 1, 0x12)
	writePlane(vga, 1, 1, 0x34)
	writePlane(vga, 2, 1, 0x56)
	writePlane(vga, 3, 1, 0x78)
	vga:read8(0xA0001)
	writeGfx(vga, 5, 0x01) -- write mode 1
	vga:write8(0xA0002, 0x00)
	expect(readPlane(vga, 0, 2) == 0x12, "write mode 1 plane 0")
	expect(readPlane(vga, 1, 2) == 0x34, "write mode 1 plane 1")
	expect(readPlane(vga, 2, 2) == 0x56, "write mode 1 plane 2")
	expect(readPlane(vga, 3, 2) == 0x78, "write mode 1 plane 3")
end)

T("crtc_latch_readback_alias", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")
	writePlane(vga, 0, 0, 0x12)
	writePlane(vga, 1, 0, 0x34)
	writePlane(vga, 2, 0, 0x56)
	writePlane(vga, 3, 0, 0x78)
	vga:read8(0xA0000) -- load all four latches

	writeGfx(vga, 4, 2)
	vga:out8(0x3D4, 0x22)
	expect(vga:in8(0x3D5) == 0x56, "CRTC 0x22 latch readback")
	expect(vga:readCrtc(0x22) == 0x56, "readCrtc latch alias")
	writeGfx(vga, 4, 3)
	expect(vga:in8(0x3D5) == 0x78, "latch alias follows read map")
end)

T("mode12_odd_even_host_addressing", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")
	-- Clear O/E Disable (bit 2) while keeping extended memory and chain-4 off.
	writeSeq(vga, 4, 0x02)
	expect(vga:isOddEven(), "odd/even mode not enabled")

	-- Even host addresses touch planes 0/2, odd addresses planes 1/3, and the
	-- A0 bit is not part of the plane byte address.
	vga:write8(0xA0002, 0xAA)
	vga:write8(0xA0003, 0xCC)
	expect(vga:read8(0xA0002) == 0xAA, "even read plane 0")
	expect(vga:read8(0xA0003) == 0xCC, "odd read plane 1")
	writeGfx(vga, 4, 2)
	expect(vga:read8(0xA0002) == 0xAA, "even read plane 2")
	expect(vga:read8(0xA0003) == 0xCC, "odd read plane 3")

	-- Writing only one group leaves the other plane group untouched.
	writeSeq(vga, 2, 0x0F)
	writeGfx(vga, 4, 0)
	writeGfx(vga, 5, 0x00)
	vga:write8(0xA0002, 0x00)
	expect(readPlane(vga, 0, 2) == 0x00, "even byte clears plane 0")
	expect(readPlane(vga, 2, 2) == 0x00, "even byte clears plane 2")
	expect(readPlane(vga, 1, 3) == 0xCC, "odd plane 1 preserved")
	expect(readPlane(vga, 3, 3) == 0xCC, "odd plane 3 preserved")
end)

T("mode12_crtc_start_and_offset", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")

	-- 160 bytes per plane row.
	writeCrtc(vga, 0x13, 80)
	vga:write8(0xA0000 + 2 * 160 + 3, 0xFF)
	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 24, 2, 640, 255, 255, 255, "offset row pixel")
	expectPixel(expect, pixels, 0, 2, 640, 0, 0, 0, "offset row starts black")

	-- Start address 0x0140. Mode 12h is CRTC byte-address mode, so this is a
	-- 0x0140-byte offset within each plane (not a word offset like text mode).
	writeCrtc(vga, 0x0C, 0x01)
	writeCrtc(vga, 0x0D, 0x40)
	vga:write8(0xA0000 + 0x140 + 3, 0xFF)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 24, 0, 640, 255, 255, 255, "start address pan")

	-- Dirty rectangles use the same byte-unit start address.
	vga:consumeDirty()
	vga:write8(0xA0000 + 0x140 + 5 * 160 + 2, 0xFF)
	const rect = vga:consumeDirty()
	expect(rect ~= nil, "panned write not dirty")
	if rect then
		expect(rect.x == 16 and rect.y == 5, ("panned rect at %d,%d"):format(rect.x, rect.y))
		expect(rect.width == 8 and rect.height == 1, "panned rect size")
	end
end)

T("mode12_dirty_rects_and_region_snapshot", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")
	local initial = vga:consumeDirty()
	expect(initial ~= nil and initial.width == 640 and initial.height == 480, "initial dirty")

	vga:write8(0xA0000, 0xFF)
	local rect = vga:consumeDirty()
	expect(rect ~= nil, "byte write not dirty")
	if rect then
		expect(rect.x == 0 and rect.y == 0, ("byte rect at %d,%d"):format(rect.x, rect.y))
		expect(rect.width == 8 and rect.height == 1, "byte rect size")
	end

	vga:write8(0xA0000 + 10 * 80 + 5, 0xFF)
	rect = vga:consumeDirty()
	expect(rect ~= nil, "row write not dirty")
	if rect then
		expect(rect.x == 40 and rect.y == 10, ("row rect at %d,%d"):format(rect.x, rect.y))
		expect(rect.width == 8 and rect.height == 1, "row rect size")
	end

	-- Union of a byte at the end of row 0 and a byte at the start of row 1.
	vga:write8(0xA0000 + 79, 0xFF)
	vga:write8(0xA0000 + 80, 0xFF)
	rect = vga:consumeDirty()
	expect(rect ~= nil, "row-crossing write not dirty")
	if rect then
		expect(rect.x == 0 and rect.y == 0, "union origin")
		expect(rect.width == 640 and rect.height == 2, "union size")
	end

	-- DAC writes invalidate the whole frame.
	vga:out8(0x3C8, 1)
	vga:out8(0x3C9, 0x3F)
	vga:out8(0x3C9, 0x00)
	vga:out8(0x3C9, 0x00)
	rect = vga:consumeDirty()
	expect(rect ~= nil and rect.width == 640 and rect.height == 480, "palette dirty")

	-- Full snapshot, then a partial region must leave pixels outside the
	-- rectangle at their previous values.
	vga:snapshotRGBA()
	vga:write8(0xA0000 + 20 * 80, 0xFF)
	vga:consumeDirty()
	const pixels = vga:snapshotRegionRGBA(0, 20, 8, 1)
	expectPixel(expect, pixels, 0, 20, 640, 255, 255, 255, "region written")
	expectPixel(expect, pixels, 8, 20, 640, 0, 0, 0, "outside region untouched")
	expectPixel(expect, pixels, 0, 19, 640, 0, 0, 0, "previous row untouched")
end)

T("mode12_fill_helpers", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")
	vga:fillRect(0, 0, 8, 8, 1)
	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 0, 640, 0, 0, 170, "fillRect blue")
	expectPixel(expect, pixels, 8, 0, 640, 0, 0, 0, "fillRect stops at byte edge")

	vga:fillTestPattern()
	pixels = vga:snapshotRGBA()
	expect(buffer.len(pixels) == 640 * 480 * 4, "test pattern RGBA size")
	expectPixel(expect, pixels, 0, 0, 640, 255, 255, 255, "test pattern border")
	expectPixel(expect, pixels, 10, 100, 640, 0, 0, 0, "test pattern colour bar 0")
	expectPixel(expect, pixels, 40, 100, 640, 0, 0, 170, "test pattern colour bar 1")
end)

T("mode3_text_regression", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x03), "mode 3 rejected")
	expect(vga:isTextMode(), "mode 3 not text")
	expect(vga:width() == 640 and vga:height() == 400, "text geometry")
	vga:writeText(0, 0, "R", 0x0F)
	expect(vga.mem:read8(0xB8000) == string.byte("R"), "text cell")
	local pixels = vga:snapshotRGBA()
	expect(buffer.len(pixels) == 640 * 400 * 4, "text RGBA size")
	-- 'R' row 1 is 0x3C; the renderer converts one glyph row into two scanlines.
	expectPixel(expect, pixels, 2, 2, 640, 255, 255, 255, "text foreground")
	expectPixel(expect, pixels, 0, 2, 640, 0, 0, 0, "text background")

	-- Text-mode CRTC start addresses are in words (2 bytes).
	vga.mem:write8(0xB9000, string.byte("A"))
	vga.mem:write8(0xB9001, 0x0F)
	writeCrtc(vga, 0x0C, 0x08)
	writeCrtc(vga, 0x0D, 0x00)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 3, 2, 640, 255, 255, 255, "text start address")
end)

T("mode13_linear_regression", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x13), "mode 13 rejected")
	expect(vga:width() == 320 and vga:height() == 200, "mode 13 geometry")
	expect(vga:isChain4(), "chain-4 not enabled")
	vga:consumeDirty()

	vga:write8(0xA0000, 0x0F)
	vga:consumeDirty()
	vga:write8(0xA0000 + 100 * 320 + 5, 0x04)
	const rect = vga:consumeDirty()
	expect(rect ~= nil, "linear write not dirty")
	if rect then
		expect(rect.x == 5 and rect.y == 100, "linear rect origin")
		expect(rect.width == 1 and rect.height == 1, "linear rect size")
	end
	local pixels = vga:snapshotRGBA()
	expect(buffer.len(pixels) == 320 * 200 * 4, "linear RGBA size")
	expectPixel(expect, pixels, 0, 0, 320, 255, 255, 255, "linear white")
	expectPixel(expect, pixels, 5, 100, 320, 170, 0, 0, "linear red")
	expectPixel(expect, pixels, 1, 0, 320, 0, 0, 0, "linear black")
	expect(vga:read8(0xA0000) == 0x0F, "linear readback")

	-- Mode 13h uses CRTC doubleword addressing, so start=1 is byte 4.
	writeCrtc(vga, 0x0C, 0x00)
	writeCrtc(vga, 0x0D, 0x01)
	vga:write8(0xA0004, 0x0F)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 0, 320, 255, 255, 255, "mode 13h start address")

	-- Chain-4 writes honour the map mask selected by the low address bits.
	writeSeq(vga, 2, 0x01)
	vga:write8(0xA0008, 0x0F) -- offset 8 is plane 0: allowed
	vga:write8(0xA0009, 0x0F) -- offset 9 is plane 1: masked
	writeSeq(vga, 2, 0x0F)
	expect(vga:read8(0xA0008) == 0x0F, "chain4 map mask allows plane 0")
	expect(vga:read8(0xA0009) == 0x00, "chain4 map mask blocks plane 1")
end)

T("vbe_banked_8bpp_window", function(expect)
	const vga = fresh()
	setVbe(vga, 640, 480, 8, 0x01) -- banked window, no LFB flag
	expect(vga:isVbeEnabled(), "VBE not enabled")
	expect(vga:width() == 640 and vga:height() == 480, "VBE geometry")
	vga:consumeDirty()

	vga:out8(0x3C8, 1)
	vga:out8(0x3C9, 0x3F)
	vga:out8(0x3C9, 0x00)
	vga:out8(0x3C9, 0x00)

	writeVbeReg(vga, Vga.VBE_DISPI_INDEX_BANK, 0)
	vga:write8(0xA0000, 1)
	vga:consumeDirty()
	writeVbeReg(vga, Vga.VBE_DISPI_INDEX_BANK, 1)
	expect(readVbeReg(vga, Vga.VBE_DISPI_INDEX_BANK) == 1, "bank readback")
	-- Bank 1 starts at 0x10000; 0x10000 / 640 = row 102, column 256.
	vga:write8(0xA0000, 1)
	expect(vga:read8(0xA0000) == 1, "banked readback")
	const rect = vga:consumeDirty()
	expect(rect ~= nil, "banked write not dirty")
	if rect then
		expect(rect.x == 256 and rect.y == 102, ("banked rect at %d,%d"):format(rect.x, rect.y))
		expect(rect.width == 1 and rect.height == 1, "banked rect size")
	end
	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 0, 640, 255, 0, 0, "bank 0 pixel")
	expectPixel(expect, pixels, 256, 102, 640, 255, 0, 0, "bank 1 pixel")

	-- The LFB remains independent of the DISPI bank register.
	vga:write8(Vga.FRAMEBUFFER_BASE + 50 * 640 + 10, 1)
	expect(vga:read8(Vga.FRAMEBUFFER_BASE + 50 * 640 + 10) == 1, "LFB readback")
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 10, 50, 640, 255, 0, 0, "LFB pixel")
end)

T("vbe_banked_16bpp_window", function(expect)
	const vga = fresh()
	setVbe(vga, 640, 480, 16, 0x41)
	vga:consumeDirty()

	writeVbeReg(vga, Vga.VBE_DISPI_INDEX_BANK, 0)
	vga:write16(0xA0000, 0xF800) -- red at (0,0)
	vga:consumeDirty()
	writeVbeReg(vga, Vga.VBE_DISPI_INDEX_BANK, 1)
	const offset = 100 * 1280 + 10 * 2 - 0x10000
	vga:write16(0xA0000 + offset, 0x07E0) -- green at (10,100)
	expect(vga:read16(0xA0000 + offset) == 0x07E0, "banked 16bpp readback")
	const rect = vga:consumeDirty()
	expect(rect ~= nil, "banked 16bpp write not dirty")
	if rect then
		expect(rect.x == 10 and rect.y == 100, ("16bpp rect at %d,%d"):format(rect.x, rect.y))
		expect(rect.width == 1 and rect.height == 1, "16bpp rect size")
	end

	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 0, 640, 255, 0, 0, "16bpp bank 0")
	expectPixel(expect, pixels, 10, 100, 640, 0, 255, 0, "16bpp bank 1")

	-- LFB write over the same visible pixel, with bank still 1.
	vga:write16(Vga.FRAMEBUFFER_BASE + 100 * 1280 + 10 * 2, 0x001F)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 10, 100, 640, 0, 0, 255, "16bpp LFB overrides bank")
end)

T("vbe_banked_32bpp_window", function(expect)
	const vga = fresh()
	setVbe(vga, 640, 480, 32, 0x41)
	vga:consumeDirty()

	writeVbeReg(vga, Vga.VBE_DISPI_INDEX_BANK, 0)
	vga:write32(0xA0000 + 10 * 2560 + 5 * 4, 0x00123456)
	writeVbeReg(vga, Vga.VBE_DISPI_INDEX_BANK, 1)
	const offset = 40 * 2560 + 5 * 4 - 0x10000
	vga:write32(0xA0000 + offset, 0x00ABCDEF)
	expect(vga:read32(0xA0000 + offset) == 0x00ABCDEF, "banked 32bpp readback")

	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 5, 10, 640, 0x12, 0x34, 0x56, "32bpp bank 0")
	expectPixel(expect, pixels, 5, 40, 640, 0xAB, 0xCD, 0xEF, "32bpp bank 1")

	vga:write32(Vga.FRAMEBUFFER_BASE + 50 * 2560 + 5 * 4, 0x00FEDCBA)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 5, 50, 640, 0xFE, 0xDC, 0xBA, "32bpp LFB writable")
end)

T("attribute_controller_colour_select", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x12), "mode 12 rejected")

	-- AR14 bits 2-3 add bank bits to the six-bit attribute palette entry.
	vga:out8(0x3C8, 0x41)
	vga:out8(0x3C9, 0x3F)
	vga:out8(0x3C9, 0x00)
	vga:out8(0x3C9, 0x00)
	writeAttr(vga, 0x14, 0x04)
	writeAttr(vga, 1, 0x01) -- colour 1 now selects DAC 0x41
	writePlane(vga, 0, 0, 0x80) -- one pixel of colour 1
	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 0, 640, 255, 0, 0, "AR14 palette bank")

	-- AR10 bit 7 selects the 16-bank mode, where AR14's low nibble is the
	-- bank and the attribute entry supplies the low four bits.
	vga:out8(0x3C8, 0x25)
	vga:out8(0x3C9, 0x00)
	vga:out8(0x3C9, 0x3F)
	vga:out8(0x3C9, 0x00)
	writeAttr(vga, 0x10, 0x81)
	writeAttr(vga, 0x14, 0x02)
	writeAttr(vga, 1, 0x05)
	writePlane(vga, 0, 1, 0x80) -- colour 1 at pixel 8
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 8, 0, 640, 0, 255, 0, "AR10 internal palette bank")

	expect(vga:in8(0x3C0) == 0x21, "attribute index/PAS readback")
	expect(vga:in8(0x3C1) == 0x05, "attribute data readback")
end)

T("text_cursor_shape_location_and_enable", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x03), "mode 3 rejected")
	-- Standard mode-3 underline: scanlines 13..14 at cell 0,0.
	writeCrtc(vga, 0x0A, 0x0D)
	writeCrtc(vga, 0x0B, 0x0E)
	writeCrtc(vga, 0x0E, 0x00)
	writeCrtc(vga, 0x0F, 0x00)
	vga:writeText(0, 0, " ", 0x0F)
	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 13, 640, 255, 255, 255, "cursor scanline 13")
	expectPixel(expect, pixels, 7, 14, 640, 255, 255, 255, "cursor scanline 14")
	expectPixel(expect, pixels, 0, 12, 640, 0, 0, 0, "pixel above cursor")
	pixels = vga:snapshotRegionRGBA(0, 13, 8, 2)
	expectPixel(expect, pixels, 0, 13, 640, 255, 255, 255, "region cursor scanline")

	-- Cursor location 1 moves it to displayed cell 0,1.
	vga:writeText(0, 1, " ", 0x0F)
	writeCrtc(vga, 0x0F, 0x01)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 13, 640, 0, 0, 0, "old cursor cell cleared")
	expectPixel(expect, pixels, 8, 13, 640, 255, 255, 255, "cursor cell 1")

	-- Single-scanline shape.
	writeCrtc(vga, 0x0B, 0x0D)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 8, 13, 640, 255, 255, 255, "single-line cursor top")
	expectPixel(expect, pixels, 8, 14, 640, 0, 0, 0, "single-line cursor bottom")

	-- Cursor disable bit 0x0A bit 5.
	writeCrtc(vga, 0x0A, 0x2D)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 8, 13, 640, 0, 0, 0, "disabled cursor still drawn")
end)

T("text_cursor_respects_crtc_start", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x03), "mode 3 rejected")
	-- Display starts at character word 1, so CRTC cursor word 1 is cell 0,0.
	writeCrtc(vga, 0x0C, 0x00)
	writeCrtc(vga, 0x0D, 0x01)
	writeCrtc(vga, 0x0A, 0x0D)
	writeCrtc(vga, 0x0B, 0x0E)
	writeCrtc(vga, 0x0E, 0x00)
	writeCrtc(vga, 0x0F, 0x01)
	vga:writeText(0, 1, " ", 0x0F)
	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 13, 640, 255, 255, 255, "cursor after start-address rebase")
	expectPixel(expect, pixels, 8, 13, 640, 0, 0, 0, "cursor not shifted by start address")
end)

T("text_blink_attribute_and_phase", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x03), "mode 3 rejected")
	writeAttr(vga, 0x10, 0x0C) -- text blink enabled
	vga:writeText(0, 0, "A", 0x9F) -- blink attribute, white on colour 1
	vga:writeText(0, 1, "A", 0x1F) -- non-blinking attribute

	local function whitePixelsInCell(column: number): number
		const pixels = vga:snapshotRGBA()
		local count = 0
		for y = 0, 15 do
			for x = column * 8, column * 8 + 7 do
				const r, g, b = pixelRGBA(pixels, x, y, 640)
				if r == 255 and g == 255 and b == 255 then
					count += 1
				end
			end
		end
		return count
	end

	expect(whitePixelsInCell(0) > 0, "blink glyph missing in visible phase")
	expect(whitePixelsInCell(1) > 0, "non-blink glyph missing")
	vga:tickBlink(16)
	expect(whitePixelsInCell(0) == 0, "blink glyph not hidden in dark phase")
	expect(whitePixelsInCell(1) > 0, "non-blink glyph changed with blink phase")
	vga:tickBlink(16)
	expect(whitePixelsInCell(0) > 0, "blink glyph did not return in visible phase")

	-- With text blink disabled, attribute bit 7 is background intensity and
	-- must not hide the glyph in the dark phase.
	writeAttr(vga, 0x10, 0x04)
	vga:tickBlink(16)
	expect(whitePixelsInCell(0) > 0, "non-blinking attribute lost glyph")
end)

T("text_cursor_blinks_and_disable_wins", function(expect)
	const vga = fresh()
	expect(vga:setMode(0x03), "mode 3 rejected")
	-- 0x0B bit 5 requests cursor blinking; standard shape 13..14.
	writeCrtc(vga, 0x0A, 0x0D)
	writeCrtc(vga, 0x0B, 0x2E)
	writeCrtc(vga, 0x0E, 0x00)
	writeCrtc(vga, 0x0F, 0x00)
	vga:writeText(0, 0, " ", 0x0F)
	local pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 13, 640, 255, 255, 255, "cursor visible phase")
	vga:tickBlink(16)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 13, 640, 0, 0, 0, "cursor dark phase")
	vga:tickBlink(16)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 13, 640, 255, 255, 255, "cursor visible again")

	writeCrtc(vga, 0x0A, 0x2D)
	pixels = vga:snapshotRGBA()
	expectPixel(expect, pixels, 0, 13, 640, 0, 0, 0, "disabled cursor rendered")
end)

return TESTS
