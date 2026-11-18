--!nonstrict
-- DmaTests.lua -- 8237 register map, transfer modes, autoinit and TC.

const band = bit32.band
const Dma = require("../core/Dma")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local PAGE_PORT = {
	[0] = 0x87,
	[1] = 0x83,
	[2] = 0x81,
	[3] = 0x82,
	[5] = 0x8B,
	[6] = 0x89,
	[7] = 0x8A,
}

local function channelPorts(channel)
	if channel < 4 then
		return 0x00 + channel * 2, 0x00 + channel * 2 + 1, 0x0C, 0x0B, 0x0A, 0x09
	end
	local index = channel - 4
	return 0xC0 + index * 4, 0xC0 + index * 4 + 2, 0xD8, 0xD6, 0xD4, 0xD2
end

local function programChannel(dma, channel, address, count, page, mode)
	const addressPort, countPort, clearPort, modePort, maskPort, requestPort = channelPorts(channel)
	dma:out8(clearPort, 0)
	dma:out8(addressPort, band(address, 0xFF))
	dma:out8(addressPort, band(bit32.rshift(address, 8), 0xFF))
	dma:out8(countPort, band(count, 0xFF))
	dma:out8(countPort, band(bit32.rshift(count, 8), 0xFF))
	dma:out8(PAGE_PORT[channel], page)
	dma:out8(modePort, mode)
	dma:out8(maskPort, channel % 4) -- clear mask bit
	return requestPort
end

local function newMemory(size)
	const memory = buffer.create(size)
	return memory,
		{
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
		}
end

T("dma_register_map_and_flipflop", function(expect)
	const dma = Dma.new()
	dma:out8(0x0C, 0)
	dma:out8(0x02, 0x34)
	dma:out8(0x02, 0x12)
	dma:out8(0x03, 0xFF)
	dma:out8(0x03, 0x00)
	dma:out8(0x83, 0x02)
	dma:out8(0x0B, 0x49)
	dma:out8(0x0A, 0x01)
	const channel = dma:getChannel(1)
	expect(channel.currentAddress == 0x1234, string.format("addr=%04X", channel.currentAddress))
	expect(channel.currentCount == 0x00FF, string.format("count=%04X", channel.currentCount))
	expect(channel.page == 0x02, string.format("page=%02X", channel.page))
	expect(channel.transferType == 2 and channel.modeType == 1, "mode decode")
	expect(not dma:isMasked(1), "channel 1 still masked")

	dma:out8(0x0C, 0)
	expect(dma:in8(0x02) == 0x34, "address low readback")
	expect(dma:in8(0x02) == 0x12, "address high readback")
	expect(dma:in8(0x03) == 0xFF, "count low readback")
	expect(dma:in8(0x03) == 0x00, "count high readback")
	expect(dma:in8(0x83) == 0x02, "page readback")

	-- PC/AT master controller: word-spaced ports and separate page register.
	dma:out8(0xD8, 0)
	dma:out8(0xC4, 0x78)
	dma:out8(0xC4, 0x56)
	dma:out8(0xC6, 0x10)
	dma:out8(0xC6, 0x00)
	dma:out8(0x8B, 0x03)
	dma:out8(0xD6, 0x49)
	dma:out8(0xD4, 0x01)
	const master = dma:getChannel(5)
	expect(
		master.currentAddress == 0x5678,
		string.format("master addr=%04X", master.currentAddress)
	)
	expect(master.currentCount == 0x0010, string.format("master count=%04X", master.currentCount))
	expect(master.page == 0x03, string.format("master page=%02X", master.page))
	expect(not dma:isMasked(5), "master channel 5 masked")
	dma:out8(0xD8, 0)
	expect(dma:in8(0xC4) == 0x78 and dma:in8(0xC4) == 0x56, "master address readback")
end)

T("dma_master_16bit_transfer", function(expect)
	const memory = buffer.create(0x40000)
	buffer.writeu16(memory, 0x21000, 0x1234)
	buffer.writeu16(memory, 0x21002, 0xABCD)
	const reads = {}
	const dma = Dma.new({
		read8 = function(address)
			return buffer.readu8(memory, address)
		end,
		read16 = function(address)
			reads[#reads + 1] = address
			return buffer.readu16(memory, address)
		end,
		write8 = function(address, value)
			buffer.writeu8(memory, address, value)
		end,
	})
	programChannel(dma, 5, 0x0800, 1, 0x01, 0x49) -- word address, 2 words
	dma:out8(0xD2, 0x05)
	const data = dma:read(5, 4)
	expect(data ~= nil and buffer.len(data) == 4, "16-bit read length")
	expect(buffer.readu8(data, 0) == 0x34 and buffer.readu8(data, 1) == 0x12, "16-bit low word")
	expect(buffer.readu8(data, 2) == 0xCD and buffer.readu8(data, 3) == 0xAB, "16-bit high word")
	expect(#reads == 2, "read16 callback count=" .. #reads)
	expect(reads[1] == 0x21000 and reads[2] == 0x21002, "16-bit physical addresses")
	expect(dma:takeTerminalCount(5), "master TC")
end)

T("dma_read_single_cycle_and_tc", function(expect)
	const memory, hooks = newMemory(0x40000)
	for index = 0, 3 do
		buffer.writeu8(memory, 0x020100 + index, 0x10 + index)
	end
	const dma = Dma.new(hooks)
	programChannel(dma, 1, 0x0100, 3, 0x02, 0x49)
	dma:out8(0x09, 0x05) -- software request channel 1
	const data = dma:read(1, 4)
	expect(data ~= nil and buffer.len(data) == 4, "read length")
	expect(buffer.readu8(data, 0) == 0x10 and buffer.readu8(data, 3) == 0x13, "read data")
	expect(dma:takeTerminalCount(1), "TC not raised")
	expect(not dma:takeTerminalCount(1), "TC was not cleared")
	expect(dma:read(1, 1) == nil, "read continued after TC")
	const channel = dma:getChannel(1)
	expect(
		channel.currentAddress == 0x0104,
		string.format("final addr=%04X", channel.currentAddress)
	)
end)

T("dma_write_autoinit", function(expect)
	const memory, hooks = newMemory(0x40000)
	const dma = Dma.new(hooks)
	programChannel(dma, 1, 0x0200, 1, 0x01, 0x45)
	dma:out8(0x09, 0x05)
	const out = buffer.create(2)
	buffer.writeu8(out, 0, 0xAA)
	buffer.writeu8(out, 1, 0x55)
	expect(dma:write(1, out) == 2, "write count")
	expect(
		buffer.readu8(memory, 0x010200) == 0xAA and buffer.readu8(memory, 0x010201) == 0x55,
		"write memory"
	)

	for index = 0, 2 do
		buffer.writeu8(memory, 0x020300 + index, 0x30 + index)
	end
	programChannel(dma, 1, 0x0300, 2, 0x02, 0x59) -- autoinit, read, single
	dma:out8(0x09, 0x05)
	const first = dma:read(1, 3)
	expect(first ~= nil and buffer.len(first) == 3, "autoinit first length")
	expect(dma:takeTerminalCount(1), "autoinit TC")
	const channel = dma:getChannel(1)
	expect(
		channel.currentAddress == 0x0300,
		string.format("autoinit reload addr=%04X", channel.currentAddress)
	)
	expect(
		channel.currentCount == 2,
		string.format("autoinit reload count=%04X", channel.currentCount)
	)
	const second = dma:read(1, 3)
	expect(second ~= nil and buffer.len(second) == 3, "autoinit second length")
	expect(
		buffer.readu8(second, 0) == 0x30 and buffer.readu8(second, 2) == 0x32,
		"autoinit second data"
	)
end)

T("dma_memory_to_memory_and_verify", function(expect)
	const memory, hooks = newMemory(0x40000)
	for index = 0, 3 do
		buffer.writeu8(memory, 0x010500 + index, 0x40 + index)
	end
	const dma = Dma.new(hooks)
	dma:out8(0x08, 0x01) -- memory-to-memory enable
	programChannel(dma, 0, 0x0500, 3, 0x01, 0x48)
	programChannel(dma, 1, 0x0600, 3, 0x01, 0x49)
	expect(dma:memoryToMemory() == 4, "memory-to-memory count")
	for index = 0, 3 do
		expect(
			buffer.readu8(memory, 0x010600 + index) == 0x40 + index,
			"memory-to-memory byte " .. index
		)
	end
	expect(dma:takeTerminalCount(1), "memory-to-memory TC")

	local reads = 0
	const verifyDma = Dma.new({
		read8 = function()
			reads += 1
			return 0xEE
		end,
		write8 = function() end,
	})
	programChannel(verifyDma, 1, 0x0700, 3, 0x00, 0x41) -- verify, single, increment
	verifyDma:out8(0x09, 0x05)
	const data = verifyDma:read(1, 4)
	expect(data ~= nil and buffer.len(data) == 4, "verify length")
	expect(buffer.readu8(data, 0) == 0 and buffer.readu8(data, 3) == 0, "verify data")
	expect(reads == 0, "verify touched memory")
end)

T("dma_status_mask_and_clear", function(expect)
	const dma = Dma.new()
	dma:out8(0x09, 0x05) -- request channel 1
	const status = dma:in8(0x08)
	expect(band(status, 0x20) ~= 0, string.format("status request bits=%02X", status))
	expect(band(dma:in8(0x08), 0x20) ~= 0, "request bit not sticky")
	dma:out8(0x0A, 0x05) -- mask channel 1
	expect(dma:isMasked(1), "single mask did not mask")
	dma:out8(0x0A, 0x01) -- unmask channel 1
	expect(not dma:isMasked(1), "single mask did not unmask")
	dma:out8(0x0F, 0x0A) -- mask channels 1 and 3
	expect(dma:isMasked(1) and dma:isMasked(3), "write mask")
	dma:out8(0x0E, 0)
	expect(not dma:isMasked(1) and not dma:isMasked(3), "clear mask")
	dma:out8(0x0D, 0)
	expect(dma:isMasked(0) and dma:isMasked(3), "master clear did not mask all")
end)

return TESTS
