--!nonstrict
-- Sb16Tests.lua -- DSP reset/version, mixer, FM, and 8-bit DMA playback.

const band, rshift = bit32.band, bit32.rshift
const Dma = require("../core/Dma")
const Sb16 = require("../core/Sb16")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function newDma()
	const memory = buffer.create(0x40000)
	const dma = Dma.new({
		read8 = function(address)
			if address < buffer.len(memory) then
				return buffer.readu8(memory, address)
			end
			return 0xFF
		end,
		write8 = function(address, value)
			if address < buffer.len(memory) then
				buffer.writeu8(memory, address, band(value, 0xFF))
			end
		end,
	})
	return dma, memory
end

local function programPlayback(dma, address, count, page, mode)
	dma:out8(0x0C, 0)
	dma:out8(0x02, band(address, 0xFF))
	dma:out8(0x02, band(rshift(address, 8), 0xFF))
	dma:out8(0x03, band(count, 0xFF))
	dma:out8(0x03, band(rshift(count, 8), 0xFF))
	dma:out8(0x83, page)
	dma:out8(0x0B, mode)
	dma:out8(0x0A, 0x01) -- unmask channel 1
end

local function collectSink()
	const frames = {}
	const sink = function(samples)
		const copy = buffer.create(buffer.len(samples))
		buffer.copy(copy, 0, samples, 0, buffer.len(samples))
		frames[#frames + 1] = copy
	end
	return frames, sink
end

local function resetDsp(sb)
	sb:out8(0x226, 1)
	sb:out8(0x226, 0)
end

local function writeCommand(sb, command, params)
	sb:out8(0x22C, command)
	for _, value in ipairs(params or {}) do
		sb:out8(0x22C, value)
	end
end

T("sb16_reset_signature_and_version", function(expect)
	const sb = Sb16.new()
	resetDsp(sb)
	expect(band(sb:in8(0x22E), 0x80) ~= 0, "DSP status did not report data")
	expect(sb:in8(0x22A) == 0xAA, "DSP reset signature")
	expect(band(sb:in8(0x22E), 0x80) == 0, "DSP status did not clear")
	writeCommand(sb, 0xE1)
	expect(band(sb:in8(0x22E), 0x80) ~= 0, "version data not available")
	expect(sb:in8(0x22A) == 4, "DSP major version")
	expect(sb:in8(0x22A) == 5, "DSP minor version")
end)

T("sb16_mixer", function(expect)
	const sb = Sb16.new()
	sb:out8(0x224, 0x22)
	sb:out8(0x225, 0x1F)
	expect(sb:in8(0x224) == 0x22, "mixer address readback")
	expect(sb:in8(0x225) == 0x1F, "mixer data readback")
	sb:out8(0x224, 0x04)
	sb:out8(0x225, 0x77)
	expect(sb:in8(0x225) == 0x77, "second mixer register")
	sb:out8(0x224, 0x00)
	sb:out8(0x225, 0x00)
	expect(sb:in8(0x225) == 0, "mixer reset register")
end)

T("sb16_fm_latches", function(expect)
	const sb = Sb16.new()
	sb:out8(0x388, 0x20)
	sb:out8(0x389, 0x55)
	expect(sb:in8(0x389) == 0x55, "FM data latch")
	expect(sb:in8(0x388) == 0, "FM timer status")
	sb:out8(0x228, 0x21)
	sb:out8(0x229, 0x66)
	expect(sb:in8(0x229) == 0x66, "base FM data latch")
end)

T("sb16_single_cycle_dma", function(expect)
	const dma, memory = newDma()
	const frames, sink = collectSink()
	const sb = Sb16.new({ dma = dma, sink = sink })
	resetDsp(sb)
	for index = 0, 3 do
		buffer.writeu8(memory, 0x010100 + index, 0x10 + index)
	end
	programPlayback(dma, 0x0100, 3, 0x01, 0x49) -- single, read, channel 1
	writeCommand(sb, 0xD1) -- speaker on
	writeCommand(sb, 0x14, { 0x03, 0x00 })
	expect(#frames == 1, "no playback frame")
	expect(buffer.len(frames[1]) == 4, "playback length=" .. buffer.len(frames[1]))
	expect(
		buffer.readu8(frames[1], 0) == 0x10 and buffer.readu8(frames[1], 3) == 0x13,
		"playback data"
	)
	expect(sb.irqPending, "playback IRQ not pending")
	expect(sb:takeIrq(), "IRQ not taken")
	expect(not sb:takeIrq(), "IRQ was not cleared")
	expect(not sb.active, "single-cycle playback stayed active")
	expect(dma:read(1, 1) == nil, "DMA request survived single-cycle playback")
end)

T("sb16_autoinit_dma", function(expect)
	const dma, memory = newDma()
	const frames, sink = collectSink()
	const sb = Sb16.new({ dma = dma, sink = sink })
	resetDsp(sb)
	for index = 0, 3 do
		buffer.writeu8(memory, 0x020100 + index, 0x20 + index)
	end
	programPlayback(dma, 0x0100, 3, 0x02, 0x59) -- autoinit, read, channel 1
	writeCommand(sb, 0xD1)
	writeCommand(sb, 0x1C, { 0x03, 0x00 })
	expect(#frames == 1 and buffer.len(frames[1]) == 4, "autoinit first block")
	expect(sb:takeIrq(), "autoinit first IRQ")
	expect(sb.active, "autoinit stopped after first block")
	expect(sb:pump() == 4, "autoinit second pump")
	expect(#frames == 2 and buffer.len(frames[2]) == 4, "autoinit second block")
	expect(buffer.readu8(frames[2], 0) == 0x20, "autoinit second data")
	expect(sb:takeIrq(), "autoinit second IRQ")
end)

T("sb16_rates_block_and_speaker", function(expect)
	const frames, sink = collectSink()
	const sb = Sb16.new({ sink = sink })
	resetDsp(sb)
	writeCommand(sb, 0x40, { 0xD3 }) -- time constant for ~22.2 kHz
	expect(sb.sampleRate > 22000 and sb.sampleRate < 22500, "time constant rate=" .. sb.sampleRate)
	writeCommand(sb, 0x41, { 0x56, 0x22 }) -- 22050
	expect(sb.sampleRate == 22050, "sample rate=" .. sb.sampleRate)
	writeCommand(sb, 0x48, { 0xFF, 0x00 })
	expect(sb.blockSize == 256, "block size=" .. sb.blockSize)
	writeCommand(sb, 0xD1)
	expect(sb.speakerOn, "speaker did not turn on")
	writeCommand(sb, 0x10, { 0x80 })
	expect(#frames == 1 and buffer.readu8(frames[1], 0) == 0x80, "direct DAC")
	writeCommand(sb, 0xD3)
	expect(not sb.speakerOn, "speaker did not turn off")
	writeCommand(sb, 0x10, { 0x81 })
	expect(#frames == 1, "speaker off still emitted audio")
end)

return TESTS
