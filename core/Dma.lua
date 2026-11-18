--!strict
-- Dma.lua -- two PC/AT 8237 DMA controllers.
--
-- The master controller (channels 4-7) uses the PC/AT word-spaced register
-- window at 0xC0-0xDF; the slave controller (channels 0-3) uses 0x00-0x0F.
-- Page registers are the standard ISA ports. Memory access is injectable so
-- the machine can wire RAM later; an unwired controller reads 0xFF and writes
-- nowhere.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const CMD_MEMORY_TO_MEMORY = 0x01
const CMD_CH0_ADDRESS_HOLD = 0x02

const MODE_VERIFY = 0
const MODE_WRITE = 1
const MODE_READ = 2
const MODE_ILLEGAL = 3

const PAGE_PORTS: { [number]: number } = {
	[0x87] = 0,
	[0x83] = 1,
	[0x81] = 2,
	[0x82] = 3,
	[0x8B] = 5,
	[0x89] = 6,
	[0x8A] = 7,
}

export type Channel = {
	index: number,
	baseAddress: number,
	currentAddress: number,
	baseCount: number,
	currentCount: number,
	page: number,
	mode: number,
	transferType: number,
	modeType: number,
	autoinit: boolean,
	decrement: boolean,
	terminalCount: boolean,
}

export type Controller = {
	channels: { Channel },
	flipFlop: boolean,
	command: number,
	status: number,
	request: number,
	mask: number,
	master: boolean,
}

export type Config = {
	read8: ((address: number) -> number)?,
	read16: ((address: number) -> number)?,
	write8: ((address: number, value: number) -> ())?,
	write16: ((address: number, value: number) -> ())?,
}

const Dma = {}
Dma.__index = Dma

export type Dma = typeof(setmetatable(
	{} :: {
		slave: Controller,
		master: Controller,
		pages: { [number]: number },
		read8: (address: number) -> number,
		read16: ((address: number) -> number)?,
		write8: (address: number, value: number) -> (),
		write16: ((address: number, value: number) -> ())?,
		in8: (self: Dma, port: number) -> number,
		out8: (self: Dma, port: number, value: number) -> (),
		reset: (self: Dma) -> (),
		request: (self: Dma, channel: number, asserted: boolean?) -> (),
		isMasked: (self: Dma, channel: number) -> boolean,
		getChannel: (self: Dma, channel: number) -> Channel?,
		read: (self: Dma, channel: number, byteCount: number) -> buffer?,
		write: (self: Dma, channel: number, data: buffer) -> number,
		memoryToMemory: (self: Dma, maxBytes: number?) -> number,
		takeTerminalCount: (self: Dma, channel: number) -> boolean,
		setMemory: (self: Dma, config: Config) -> (),
	},
	Dma
))

local function newChannel(index: number): Channel
	return {
		index = index,
		baseAddress = 0,
		currentAddress = 0,
		baseCount = 0,
		currentCount = 0,
		page = 0,
		mode = 0,
		transferType = MODE_VERIFY,
		modeType = 0,
		autoinit = false,
		decrement = false,
		terminalCount = false,
	}
end

local function newController(master: boolean): Controller
	local channels = {}
	for index = 0, 3 do
		channels[index] = newChannel(index)
	end
	return {
		channels = channels,
		flipFlop = false,
		command = 0,
		status = 0,
		request = 0,
		mask = 0x0F,
		master = master,
	}
end

local function resetController(controller: Controller)
	controller.flipFlop = false
	controller.command = 0
	controller.status = 0
	controller.request = 0
	controller.mask = 0x0F
	for index = 0, 3 do
		const channel = controller.channels[index]
		channel.currentAddress = channel.baseAddress
		channel.currentCount = channel.baseCount
		channel.terminalCount = false
		channel.mode = 0
		channel.transferType = MODE_VERIFY
		channel.modeType = 0
		channel.autoinit = false
		channel.decrement = false
	end
end

local function controllerFor(self: Dma, channel: number): (Controller?, number?)
	if channel < 0 or channel > 7 then
		return nil, nil
	end
	if channel < 4 then
		return self.slave, channel
	end
	return self.master, channel - 4
end

local function physicalAddress(controller: Controller, channel: Channel): number
	local address = bor(lshift(channel.page, 16), channel.currentAddress)
	if controller.master then
		address = lshift(address, 1)
	end
	return band(address, 0xFFFFFF)
end

local function readWord(self: Dma, address: number): number
	if self.read16 then
		return self.read16(address)
	end
	return bor(self.read8(address), lshift(self.read8(address + 1), 8))
end

local function writeWord(self: Dma, address: number, value: number)
	if self.write16 then
		self.write16(address, value)
	else
		self.write8(address, band(value, 0xFF))
		self.write8(address + 1, band(rshift(value, 8), 0xFF))
	end
end

local function setTerminalCount(controller: Controller, channel: Channel, index: number)
	channel.terminalCount = true
	controller.status = bor(controller.status, lshift(1, index))
	if channel.autoinit then
		channel.currentAddress = channel.baseAddress
		channel.currentCount = channel.baseCount
	else
		controller.request = band(controller.request, bit32.bnot(lshift(1, index)))
		channel.currentCount = 0xFFFF
	end
end

local function consumeUnit(channel: Channel)
	channel.currentAddress =
		band(channel.currentAddress + (if channel.decrement then -1 else 1), 0xFFFF)
	if channel.currentCount == 0 then
		return true
	end
	channel.currentCount -= 1
	return false
end

local function canTransfer(controller: Controller, index: number): boolean
	const bit = lshift(1, index)
	return band(controller.mask, bit) == 0 and band(controller.request, bit) ~= 0
end

function Dma.new(config: Config?): Dma
	local self = setmetatable({}, Dma) :: any
	self.slave = newController(false)
	self.master = newController(true)
	self.pages = {}
	for index = 0, 7 do
		self.pages[index] = 0
	end
	self.read8 = function()
		return 0xFF
	end
	self.write8 = function() end
	self.read16 = nil
	self.write16 = nil
	if config then
		self:setMemory(config)
	end
	self:reset()
	return self
end

function Dma.setMemory(self: Dma, config: Config)
	if config.read8 then
		self.read8 = config.read8
	end
	self.read16 = config.read16
	if config.write8 then
		self.write8 = config.write8
	end
	self.write16 = config.write16
end

function Dma.reset(self: Dma)
	for index = 0, 7 do
		self.pages[index] = 0
		const controller, channelIndex = controllerFor(self, index)
		if controller and channelIndex ~= nil then
			controller.channels[channelIndex].page = 0
		end
	end
	resetController(self.slave)
	resetController(self.master)
end

function Dma.getChannel(self: Dma, channel: number): Channel?
	const controller, index = controllerFor(self, channel)
	if not controller or index == nil then
		return nil
	end
	return controller.channels[index]
end

function Dma.isMasked(self: Dma, channel: number): boolean
	const controller, index = controllerFor(self, channel)
	if not controller or index == nil then
		return true
	end
	return band(controller.mask, lshift(1, index)) ~= 0
end

function Dma.request(self: Dma, channel: number, asserted: boolean?)
	const controller, index = controllerFor(self, channel)
	if not controller or index == nil then
		return
	end
	const bit = lshift(1, index)
	const on = if asserted == nil then true else asserted
	if on then
		controller.request = bor(controller.request, bit)
	else
		controller.request = band(controller.request, bit32.bnot(bit))
	end
end

function Dma.takeTerminalCount(self: Dma, channel: number): boolean
	const controller, index = controllerFor(self, channel)
	if not controller or index == nil then
		return false
	end
	const value = controller.channels[index].terminalCount
	controller.channels[index].terminalCount = false
	controller.status = band(controller.status, bit32.bnot(lshift(1, index)))
	return value
end

local function readChannelRegister(controller: Controller, offset: number): number
	const index = rshift(offset, 1)
	if index > 3 then
		return 0xFF
	end
	const channel = controller.channels[index]
	const value = if band(offset, 1) ~= 0 then channel.currentCount else channel.currentAddress
	const result = if controller.flipFlop then rshift(value, 8) else band(value, 0xFF)
	controller.flipFlop = not controller.flipFlop
	return band(result, 0xFF)
end

local function writeChannelRegister(controller: Controller, offset: number, value: number)
	const index = rshift(offset, 1)
	if index > 3 then
		return
	end
	const channel = controller.channels[index]
	const isCount = band(offset, 1) ~= 0
	if not controller.flipFlop then
		if isCount then
			channel.baseCount = band(bor(band(channel.baseCount, 0xFF00), value), 0xFFFF)
		else
			channel.baseAddress = band(bor(band(channel.baseAddress, 0xFF00), value), 0xFFFF)
		end
		controller.flipFlop = true
	else
		if isCount then
			channel.baseCount = bor(band(channel.baseCount, 0x00FF), lshift(value, 8))
			channel.currentCount = channel.baseCount
		else
			channel.baseAddress = bor(band(channel.baseAddress, 0x00FF), lshift(value, 8))
			channel.currentAddress = channel.baseAddress
		end
		controller.flipFlop = false
	end
end

local function writeMode(controller: Controller, value: number)
	const index = band(value, 3)
	const channel = controller.channels[index]
	channel.mode = value
	channel.transferType = band(rshift(value, 2), 3)
	channel.modeType = band(rshift(value, 6), 3)
	channel.autoinit = band(value, 0x10) ~= 0
	channel.decrement = band(value, 0x20) ~= 0
end

local function writeControl(controller: Controller, offset: number, value: number)
	if offset == 8 then
		controller.command = value
	elseif offset == 9 then
		const index = band(value, 3)
		const bit = lshift(1, index)
		if band(value, 4) ~= 0 then
			controller.request = bor(controller.request, bit)
		else
			controller.request = band(controller.request, bit32.bnot(bit))
		end
	elseif offset == 10 then
		const index = band(value, 3)
		const bit = lshift(1, index)
		if band(value, 4) ~= 0 then
			controller.mask = bor(controller.mask, bit)
		else
			controller.mask = band(controller.mask, bit32.bnot(bit))
		end
	elseif offset == 11 then
		writeMode(controller, value)
	elseif offset == 12 then
		controller.flipFlop = false
	elseif offset == 13 then
		resetController(controller)
	elseif offset == 14 then
		controller.mask = 0
	elseif offset == 15 then
		controller.mask = band(value, 0x0F)
	end
end

function Dma.in8(self: Dma, port: number): number
	const pageChannel = PAGE_PORTS[port]
	if pageChannel ~= nil then
		return self.pages[pageChannel]
	end
	local controller: Controller? = nil
	local offset = 0
	if port >= 0x00 and port <= 0x0F then
		controller = self.slave
		offset = port
	elseif port >= 0xC0 and port <= 0xDF then
		controller = self.master
		offset = rshift(port - 0xC0, 1)
	end
	if not controller then
		return 0xFF
	end
	if offset < 8 then
		return readChannelRegister(controller, offset)
	elseif offset == 8 then
		const status = bor(band(controller.status, 0x0F), lshift(controller.request, 4))
		controller.status = band(controller.status, 0xF0)
		return status
	end
	return 0xFF
end

function Dma.out8(self: Dma, port: number, value: number)
	value = band(value, 0xFF)
	const pageChannel = PAGE_PORTS[port]
	if pageChannel ~= nil then
		self.pages[pageChannel] = value
		const pageController, pageIndex = controllerFor(self, pageChannel)
		if pageController and pageIndex ~= nil then
			pageController.channels[pageIndex].page = value
		end
		return
	end
	local controller: Controller? = nil
	local offset = 0
	if port >= 0x00 and port <= 0x0F then
		controller = self.slave
		offset = port
	elseif port >= 0xC0 and port <= 0xDF then
		controller = self.master
		offset = rshift(port - 0xC0, 1)
	end
	if not controller then
		return
	end
	if offset < 8 then
		writeChannelRegister(controller, offset, value)
	else
		writeControl(controller, offset, value)
	end
end

function Dma.read(self: Dma, channel: number, byteCount: number): buffer?
	const controller, index = controllerFor(self, channel)
	if not controller or index == nil or byteCount <= 0 then
		return nil
	end
	if not canTransfer(controller, index) then
		return nil
	end
	const state = controller.channels[index]
	if state.transferType == MODE_WRITE or state.transferType == MODE_ILLEGAL then
		return nil
	end
	const unitBytes = if controller.master then 2 else 1
	const available = state.currentCount + 1
	const units = math.min(math.floor(byteCount / unitBytes), available)
	if units <= 0 then
		return nil
	end
	const data = buffer.create(units * unitBytes)
	local cursor = 0
	for _ = 1, units do
		const address = physicalAddress(controller, state)
		if state.transferType == MODE_READ then
			if controller.master then
				const word = readWord(self, address)
				buffer.writeu8(data, cursor, band(word, 0xFF))
				buffer.writeu8(data, cursor + 1, band(rshift(word, 8), 0xFF))
			else
				buffer.writeu8(data, cursor, band(self.read8(address), 0xFF))
			end
		end
		cursor += unitBytes
		if consumeUnit(state) then
			setTerminalCount(controller, state, index)
		end
	end
	return data
end

function Dma.write(self: Dma, channel: number, data: buffer): number
	const controller, index = controllerFor(self, channel)
	if not controller or index == nil then
		return 0
	end
	if not canTransfer(controller, index) then
		return 0
	end
	const state = controller.channels[index]
	if state.transferType == MODE_READ or state.transferType == MODE_ILLEGAL then
		return 0
	end
	const unitBytes = if controller.master then 2 else 1
	const available = state.currentCount + 1
	const units = math.min(math.floor(buffer.len(data) / unitBytes), available)
	for unit = 0, units - 1 do
		const address = physicalAddress(controller, state)
		if state.transferType == MODE_WRITE then
			if controller.master then
				const offset = unit * 2
				const word =
					bor(buffer.readu8(data, offset), lshift(buffer.readu8(data, offset + 1), 8))
				writeWord(self, address, word)
			else
				self.write8(address, buffer.readu8(data, unit))
			end
		end
		if consumeUnit(state) then
			setTerminalCount(controller, state, index)
		end
	end
	return units * unitBytes
end

function Dma.memoryToMemory(self: Dma, maxBytes: number?): number
	const controller = self.slave
	if band(controller.command, CMD_MEMORY_TO_MEMORY) == 0 then
		return 0
	end
	const source = controller.channels[0]
	const destination = controller.channels[1]
	const available = destination.currentCount + 1
	const units = if maxBytes
		then math.min(available, math.max(0, math.floor(maxBytes)))
		else available
	for _ = 1, units do
		const value = band(self.read8(physicalAddress(controller, source)), 0xFF)
		self.write8(physicalAddress(controller, destination), value)
		if band(controller.command, CMD_CH0_ADDRESS_HOLD) == 0 then
			source.currentAddress =
				band(source.currentAddress + (if source.decrement then -1 else 1), 0xFFFF)
		end
		if consumeUnit(destination) then
			setTerminalCount(controller, destination, 1)
		end
	end
	return units
end

return Dma
