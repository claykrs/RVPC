--!strict
-- Pit.lua -- 8254 programmable interval timer.
--
-- Machine advances all three counters once per emulated instruction. Channel 0
-- raises IRQ0 every reload; channel 1 is the refresh timer and channel 2 drives
-- the PC speaker. The BIOS uses channel 0 both for the system tick and as a
-- calibrated delay source, so reads must return a changing count.

const band, lshift, rshift = bit32.band, bit32.lshift, bit32.rshift

const Pit = {}
Pit.__index = Pit

const CHANNELS = 3

type Channel = {
	reload: number,
	counter: number,
	access: number, -- 1 LSB, 2 MSB, 3 LSB-then-MSB
	mode: number,
	bcd: boolean,
	flipFlop: number,
	latched: number?,
	output: boolean,
}

export type Pit = typeof(setmetatable(
	{} :: {
		channels: { Channel },
		irqPending: boolean,
		in8: (self: Pit, port: number) -> number,
		out8: (self: Pit, port: number, value: number) -> (),
		advance: (self: Pit, cycles: number) -> boolean,
		reset: (self: Pit) -> (),
	},
	Pit
))

local function newChannel(): Channel
	return {
		reload = 0,
		counter = 0x10000,
		access = 3,
		mode = 3,
		bcd = false,
		flipFlop = 0,
		latched = nil,
		output = false,
	}
end

function Pit.new(): Pit
	local self = setmetatable({}, Pit) :: any
	self.channels = { newChannel(), newChannel(), newChannel() }
	self.irqPending = false
	return self
end

function Pit.reset(self: Pit)
	self.channels = { newChannel(), newChannel(), newChannel() }
	self.irqPending = false
end

local function reloadValue(channel: Channel): number
	return if channel.reload == 0 then 0x10000 else channel.reload
end

function Pit.advance(self: Pit, cycles: number): boolean
	local irq = false
	const channels = self.channels
	for index = 0, CHANNELS - 1 do
		const channel = channels[index + 1]
		-- Inline reloadValue: advance runs once per guest instruction.
		const period = if channel.reload == 0 then 0x10000 else channel.reload
		local remaining = channel.counter - cycles
		while remaining <= 0 do
			remaining += period
			channel.output = not channel.output
			if index == 0 then
				irq = true
			end
		end
		channel.counter = remaining
	end
	if irq then
		self.irqPending = true
	end
	return irq
end

function Pit.out8(self: Pit, port: number, value: number)
	value = band(value, 0xFF)
	if port == 0x43 then
		const channelIndex = rshift(value, 6)
		if channelIndex == 3 then
			-- Read-back command: latch the selected counters' current values.
			for index = 0, 2 do
				if band(value, lshift(1, index)) == 0 then
					self.channels[index + 1].latched = self.channels[index + 1].counter
				end
			end
			return
		end
		const channel = self.channels[channelIndex + 1]
		channel.access = band(rshift(value, 4), 3)
		channel.mode = band(rshift(value, 1), 7)
		channel.bcd = band(value, 1) ~= 0
		channel.flipFlop = 0
		if channel.access == 0 then
			channel.latched = channel.counter
		end
		return
	end
	if port >= 0x40 and port <= 0x42 then
		const channel = self.channels[port - 0x40 + 1]
		if channel.access == 1 then
			channel.reload = band(value, 0xFF)
		elseif channel.access == 2 then
			channel.reload = lshift(band(value, 0xFF), 8)
		else
			if channel.flipFlop == 0 then
				channel.reload = band(channel.reload, 0xFF00) + band(value, 0xFF)
				channel.flipFlop = 1
			else
				channel.reload = band(value, 0xFF) * 0x100 + band(channel.reload, 0xFF)
				channel.flipFlop = 0
			end
		end
		channel.counter = reloadValue(channel)
		channel.output = false
	end
end

function Pit.in8(self: Pit, port: number): number
	if port < 0x40 or port > 0x42 then
		return 0xFF
	end
	const channel = self.channels[port - 0x40 + 1]
	local value
	if channel.latched ~= nil then
		value = channel.latched :: number
	else
		value = channel.counter
	end
	local result
	if channel.access == 1 then
		result = band(value, 0xFF)
	elseif channel.access == 2 then
		result = band(rshift(value, 8), 0xFF)
	else
		if channel.flipFlop == 0 then
			result = band(value, 0xFF)
			channel.flipFlop = 1
		else
			result = band(rshift(value, 8), 0xFF)
			channel.flipFlop = 0
			channel.latched = nil
		end
	end
	return result
end

return Pit
