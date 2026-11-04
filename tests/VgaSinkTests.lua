--!nonstrict
-- VgaSinkTests.lua -- dirty-region presentation for text, linear and planar VGA.

const Memory = require("../core/Memory")
const Vga = require("../core/Vga")
const VgaSink = require("../core/VgaSink")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function fresh()
	const mem = Memory.new(16 * 1024 * 1024)
	const vga = Vga.new(mem)
	const presented = {}
	const sink = VgaSink.new(vga, function(pixels, width, height, rect)
		presented[#presented + 1] = { pixels = pixels, width = width, height = height, rect = rect }
	end)
	return vga, sink, presented
end

T("text_mode_present", function(expect)
	const vga, sink, presented = fresh()
	expect(vga:setMode(0x03), "mode 3")
	vga:writeText(0, 0, "RVPC", 0x0F)
	expect(sink:poll(), "text frame not presented")
	expect(#presented == 1, "present count")
	if #presented == 1 then
		expect(presented[1].width == 640 and presented[1].height == 400, "text geometry")
		expect(buffer.len(presented[1].pixels) == 640 * 400 * 4, "text RGBA size")
	end
	expect(not sink:poll(), "clean frame presented twice")
end)

T("mode13_dirty_pixel_and_force", function(expect)
	const vga, sink, presented = fresh()
	expect(vga:setMode(0x13), "mode 13")
	sink.vga:markAllDirty()
	expect(sink:poll(), "mode 13 full frame")
	vga:write8(0xA0000, 0x0F)
	expect(sink:poll(), "pixel did not dirty")
	const rect = presented[#presented].rect
	expect(rect.width == 1 and rect.height == 1, "dirty rect")
	expect(not sink:poll(), "clean pixel repeated")
	expect(sink:poll(true), "forced present")
	expect(sink.frames == 3, "frame count=" .. sink.frames)
end)

T("mode12_planar_region", function(expect)
	const vga, sink, presented = fresh()
	expect(vga:setMode(0x12), "mode 12")
	vga:write8(0xA0000, 0xFF)
	expect(sink:poll(), "planar frame not presented")
	if #presented > 0 then
		const frame = presented[#presented]
		expect(frame.width == 640 and frame.height == 480, "planar geometry")
		expect(buffer.len(frame.pixels) == 640 * 480 * 4, "planar RGBA size")
	end
end)

return TESTS
