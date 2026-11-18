--!strict
-- Sb16.lua -- practical ISA Sound Blaster 16 subset.
--
-- DSP reset/commands, mixer registers, FM register latches and 8-bit DMA
-- playback are modelled. FM synthesis and audio mixing are host concerns; the
-- injected sink receives the raw unsigned 8-bit sample block. Playback is
-- pumped synchronously or by the machine's periodic tick.

const band, bor, lshift = bit32.band, bit32.bor, bit32.lshift

const DEFAULT_BASE = 0x220
const DEFAULT_IRQ = 5
const DEFAULT_DMA = 1

const PARAM_COUNTS: { [number]: number } = {
	[0x10] = 1, -- direct DAC
	[0x14] = 2, -- single-cycle 8-bit DMA
	[0x1C] = 2, -- auto-init 8-bit DMA
	[0x40] = 1, -- time constant
	[0x41] = 2, -- sample rate
	[0x48] = 2, -- block size
}

export type Config = {
	base: number?,
	irq: number?,
	dma: any?,
	dmaChannel: number?,
	sink: ((samples: buffer) -> ())?,
}

const Sb16 = {}
Sb16.__index = Sb16

export type Sb16 = typeof(setmetatable(
	{} :: {
		base: number,
		irq: number,
		dma: any?,
		dmaChannel: number,
		sink: (samples: buffer) -> (),
		resetHeld: boolean,
		readQueue: { number },
		readHead: number,
		pendingCommand: number?,
		pendingParams: { number },
		pendingNeeded: number,
		versionMajor: number,
		versionMinor: number,
		mixerAddress: number,
		mixerRegs: { [number]: number },
		fmAddress: number,
		fmRegs: { [number]: number },
		speakerOn: boolean,
		timeConstant: number,
		sampleRate: number,
		blockSize: number,
		remaining: number,
		active: boolean,
		autoinit: boolean,
		paused: boolean,
		irqPending: boolean,
		lastCommand: number,
		lastDac: number,
		in8: (self: Sb16, port: number) -> number,
		out8: (self: Sb16, port: number, value: number) -> (),
		resetDsp: (self: Sb16) -> (),
		executeCommand: (self: Sb16, command: number, params: { number }) -> (),
		takeIrq: (self: Sb16) -> boolean,
		pump: (self: Sb16) -> number,
		tick: (self: Sb16) -> number,
	},
	Sb16
))

local function clearQueue(self: Sb16)
	self.readQueue = {}
	self.readHead = 1
end

local function queueByte(self: Sb16, value: number)
	self.readQueue[#self.readQueue + 1] = band(value, 0xFF)
end

local function hasData(self: Sb16): boolean
	return self.readHead <= #self.readQueue
end

local function dspRead(self: Sb16): number
	if not hasData(self) then
		return 0xFF
	end
	const value = self.readQueue[self.readHead]
	self.readHead += 1
	if self.readHead > #self.readQueue then
		clearQueue(self)
	end
	return value
end

local function resetMixer(self: Sb16)
	self.mixerRegs = {}
	self.mixerAddress = 0
end

function Sb16.new(config: Config?): Sb16
	const cfg = (config or {}) :: Config
	local self = setmetatable({}, Sb16) :: any
	self.base = cfg.base or DEFAULT_BASE
	self.irq = cfg.irq or DEFAULT_IRQ
	self.dma = cfg.dma
	self.dmaChannel = cfg.dmaChannel or DEFAULT_DMA
	self.sink = cfg.sink or function() end
	self.versionMajor = 4
	self.versionMinor = 5
	self.mixerRegs = {}
	self.mixerAddress = 0
	self.fmRegs = {}
	self.fmAddress = 0
	self.lastCommand = 0
	self.lastDac = 0
	self:resetDsp()
	return self
end

function Sb16.resetDsp(self: Sb16)
	clearQueue(self)
	self.resetHeld = false
	self.pendingCommand = nil
	self.pendingParams = {}
	self.pendingNeeded = 0
	self.speakerOn = false
	self.timeConstant = 0
	self.sampleRate = 0
	self.blockSize = 0
	self.remaining = 0
	self.active = false
	self.autoinit = false
	self.paused = false
	self.irqPending = false
	self.lastDac = 0
	if self.dma then
		self.dma:request(self.dmaChannel, false)
	end
	queueByte(self, 0xAA)
end

function Sb16.takeIrq(self: Sb16): boolean
	if not self.irqPending then
		return false
	end
	self.irqPending = false
	return true
end

local function dspWrite(self: Sb16, value: number)
	value = band(value, 0xFF)
	if self.pendingNeeded > 0 then
		self.pendingParams[#self.pendingParams + 1] = value
		self.pendingNeeded -= 1
		if self.pendingNeeded == 0 then
			const command = self.pendingCommand
			const params = self.pendingParams
			self.pendingCommand = nil
			self.pendingParams = {}
			if command ~= nil then
				self:executeCommand(command, params)
			end
		end
		return
	end
	self.lastCommand = value
	const needed = PARAM_COUNTS[value] or 0
	if needed == 0 then
		self:executeCommand(value, {})
	else
		self.pendingCommand = value
		self.pendingParams = {}
		self.pendingNeeded = needed
	end
end

function Sb16.executeCommand(self: Sb16, command: number, params: { number })
	if command == 0xE1 then
		queueByte(self, self.versionMajor)
		queueByte(self, self.versionMinor)
	elseif command == 0x10 then
		self.lastDac = params[1] or 0
		if self.speakerOn then
			const sample = buffer.create(1)
			buffer.writeu8(sample, 0, self.lastDac)
			self.sink(sample)
		end
	elseif command == 0x14 or command == 0x1C then
		const length = bor(params[1] or 0, lshift(params[2] or 0, 8))
		self.blockSize = length + 1
		self.autoinit = command == 0x1C
		self.remaining = self.blockSize
		self.active = true
		self.paused = false
		self.irqPending = false
		if self.dma then
			self.dma:request(self.dmaChannel, true)
		end
		self:pump()
	elseif command == 0x40 then
		self.timeConstant = params[1] or 0
		if self.timeConstant < 256 then
			self.sampleRate = math.floor(1000000 / (256 - self.timeConstant) + 0.5)
		else
			self.sampleRate = 0
		end
	elseif command == 0x41 then
		self.sampleRate = bor(lshift(params[1] or 0, 8), params[2] or 0)
	elseif command == 0x48 then
		self.blockSize = bor(params[1] or 0, lshift(params[2] or 0, 8)) + 1
	elseif command == 0xD0 then
		self.paused = true
	elseif command == 0xD1 then
		self.speakerOn = true
	elseif command == 0xD3 then
		self.speakerOn = false
	elseif command == 0xD4 then
		self.paused = false
	elseif command == 0xDA then
		self.autoinit = false
		self.active = false
		if self.dma then
			self.dma:request(self.dmaChannel, false)
		end
	end
end

function Sb16.pump(self: Sb16): number
	if not self.active or self.paused or not self.dma then
		return 0
	end
	if self.remaining <= 0 then
		return 0
	end
	const samples = self.dma:read(self.dmaChannel, self.remaining)
	if not samples or buffer.len(samples) == 0 then
		if not self.autoinit then
			self.active = false
			self.dma:request(self.dmaChannel, false)
		end
		return 0
	end
	const count = buffer.len(samples)
	if self.speakerOn then
		self.sink(samples)
	end
	self.remaining -= count
	if self.remaining <= 0 then
		self.irqPending = true
		if self.autoinit then
			self.remaining = self.blockSize
			self.dma:request(self.dmaChannel, true)
		else
			self.active = false
			self.dma:request(self.dmaChannel, false)
		end
	end
	return count
end

function Sb16.tick(self: Sb16): number
	return self:pump()
end

function Sb16.in8(self: Sb16, port: number): number
	if port == self.base + 4 then
		return self.mixerAddress
	elseif port == self.base + 5 then
		return self.mixerRegs[self.mixerAddress] or 0
	elseif port == self.base + 6 then
		return 0xFF
	elseif port == self.base + 8 or port == 0x388 then
		return 0 -- FM timer status: no expired timers
	elseif port == self.base + 9 or port == 0x389 then
		return self.fmRegs[self.fmAddress] or 0
	elseif port == self.base + 0x0A then
		return dspRead(self)
	elseif port == self.base + 0x0E then
		return if hasData(self) then 0x80 else 0x00
	end
	return 0xFF
end

function Sb16.out8(self: Sb16, port: number, value: number)
	value = band(value, 0xFF)
	if port == self.base + 4 then
		self.mixerAddress = value
	elseif port == self.base + 5 then
		if self.mixerAddress == 0 then
			resetMixer(self)
		else
			self.mixerRegs[self.mixerAddress] = value
		end
	elseif port == self.base + 6 then
		if band(value, 1) ~= 0 then
			self.resetHeld = true
			clearQueue(self)
			self.pendingCommand = nil
			self.pendingParams = {}
			self.pendingNeeded = 0
			self.active = false
			if self.dma then
				self.dma:request(self.dmaChannel, false)
			end
		elseif self.resetHeld then
			self:resetDsp()
		end
	elseif port == self.base + 8 or port == 0x388 then
		self.fmAddress = value
	elseif port == self.base + 9 or port == 0x389 then
		self.fmRegs[self.fmAddress] = value
	elseif port == self.base + 0x0C then
		dspWrite(self, value)
	end
end

return Sb16
