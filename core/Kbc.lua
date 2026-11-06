--!strict
-- Kbc.lua -- 8042 keyboard controller with PS/2 keyboard and mouse.
--
-- The 8042 exposes status/data at 0x64/0x60. Host input is injected through
-- pressKey/releaseKey/mouseMove; the controller queues set-1 make/break codes
-- (or 3-byte PS/2 mouse packets) and raises IRQ1/IRQ12. Guest commands are
-- acknowledged with 0xFA so SeaBIOS's keyboard self-test and mouse init finish.

const band, bor = bit32.band, bit32.bor

const Kbc = {}
Kbc.__index = Kbc

const STATUS_OBF = 0x01
const STATUS_SYS = 0x04
const STATUS_AUX = 0x20

export type QueueEntry = {
	value: number,
	aux: boolean,
}

export type Kbc = typeof(setmetatable(
	{} :: {
		queue: { QueueEntry },
		config: number,
		command: number?,
		pendingData: number?,
		keyboardEnabled: boolean,
		mouseEnabled: boolean,
		irq1: boolean,
		irq12: boolean,
		irq1Armed: boolean,
		irq12Armed: boolean,
		lastStatus: number,
		trace: { string },
		in8: (self: Kbc, port: number) -> number,
		out8: (self: Kbc, port: number, value: number) -> (),
		pressKey: (self: Kbc, scancode: number) -> (),
		releaseKey: (self: Kbc, scancode: number) -> (),
		mouseMove: (self: Kbc, dx: number, dy: number, buttons: number?) -> (),
		takeIrq1: (self: Kbc) -> boolean,
		takeIrq12: (self: Kbc) -> boolean,
		reset: (self: Kbc) -> (),
	},
	Kbc
))

function Kbc.new(): Kbc
	local self = setmetatable({}, Kbc) :: any
	self.queue = {}
	self.config = 0x45 -- translation, keyboard and mouse IRQs enabled
	self.command = nil
	self.pendingData = nil
	self.keyboardEnabled = true
	self.mouseEnabled = true
	self.irq1 = false
	self.irq12 = false
	self.irq1Armed = false
	self.irq12Armed = false
	self.lastStatus = 0
	self.trace = {}
	return self
end

function Kbc.reset(self: Kbc)
	self.queue = {}
	self.config = 0x45
	self.command = nil
	self.pendingData = nil
	self.keyboardEnabled = true
	self.mouseEnabled = true
	self.irq1 = false
	self.irq12 = false
	self.irq1Armed = false
	self.irq12Armed = false
	self.lastStatus = 0
end

local function status(self: Kbc): number
	local value = STATUS_SYS
	if #self.queue > 0 then
		value = bor(value, STATUS_OBF)
	end
	const first = self.queue[1]
	if first and first.aux then
		value = bor(value, STATUS_AUX)
	end
	-- IBF is a momentary host->controller latch. The controller consumes a
	-- command/parameter before the next status read, so SeaBIOS must not see it
	-- stuck (its i8042_wait_write loop would never issue the parameter byte).
	return value
end

local function queueByte(self: Kbc, value: number, aux: boolean)
	self.queue[#self.queue + 1] = { value = band(value, 0xFF), aux = aux }
	if aux then
		if band(self.config, 0x02) ~= 0 then
			self.irq12 = true
			self.irq12Armed = true
		end
	else
		if band(self.config, 0x01) ~= 0 then
			self.irq1 = true
			self.irq1Armed = true
		end
	end
end

local function mousePacket(self: Kbc, dx: number, dy: number, buttons: number)
	local x = math.max(-128, math.min(127, math.floor(dx)))
	local y = math.max(-128, math.min(127, math.floor(dy)))
	local flags = bor(0x08, band(buttons, 0x07))
	if x < 0 then
		x += 256
		flags = bor(flags, 0x10)
	end
	if y < 0 then
		y += 256
		flags = bor(flags, 0x20)
	end
	queueByte(self, flags, true)
	queueByte(self, x, true)
	queueByte(self, y, true)
end

function Kbc.pressKey(self: Kbc, scancode: number)
	if not self.keyboardEnabled then
		return
	end
	queueByte(self, band(scancode, 0x7F), false)
end

function Kbc.releaseKey(self: Kbc, scancode: number)
	if not self.keyboardEnabled then
		return
	end
	queueByte(self, bor(0x80, band(scancode, 0x7F)), false)
end

function Kbc.mouseMove(self: Kbc, dx: number, dy: number, buttons: number?)
	if not self.mouseEnabled then
		return
	end
	mousePacket(self, dx, dy, buttons or 0)
end

function Kbc.takeIrq1(self: Kbc): boolean
	if band(self.config, 0x01) == 0 or not self.irq1Armed then
		return false
	end
	for _, entry in self.queue do
		if not entry.aux then
			self.irq1Armed = false
			return true
		end
	end
	self.irq1Armed = false
	return false
end

function Kbc.takeIrq12(self: Kbc): boolean
	if band(self.config, 0x02) == 0 or not self.irq12Armed then
		return false
	end
	for _, entry in self.queue do
		if entry.aux then
			self.irq12Armed = false
			return true
		end
	end
	self.irq12Armed = false
	return false
end

function Kbc.in8(self: Kbc, port: number): number
	if port == 0x64 then
		const value = status(self)
		self.lastStatus = value
		return value
	end
	if port == 0x60 then
		const entry = table.remove(self.queue, 1)
		if entry then
			if not entry.aux then
				-- One keyboard byte per IRQ1. If more make/break bytes are
				-- queued, arm the next edge now so it is delivered after EOI.
				for _, queued in self.queue do
					if not queued.aux then
						self.irq1Armed = true
						break
					end
				end
			end
			return entry.value
		end
		return 0xFF
	end
	return 0xFF
end

local function guestKeyboardByte(self: Kbc, value: number)
	if self.pendingData == 0xED then
		self.pendingData = nil
		queueByte(self, 0xFA, false)
		return
	end
	if self.pendingData == 0xF0 then
		self.pendingData = nil
		queueByte(self, 0xFA, false)
		return
	end
	if value == 0xED or value == 0xF0 then
		self.pendingData = value
		queueByte(self, 0xFA, false)
	elseif value == 0xFF then
		queueByte(self, 0xFA, false)
		queueByte(self, 0xAA, false)
		self.keyboardEnabled = true
	else
		queueByte(self, 0xFA, false)
	end
end

local function guestMouseByte(self: Kbc, value: number)
	if value == 0xF4 or value == 0xFF then
		self.mouseEnabled = true
	elseif value == 0xF5 then
		self.mouseEnabled = false
	end
	queueByte(self, 0xFA, true)
end

function Kbc.out8(self: Kbc, port: number, value: number)
	value = band(value, 0xFF)
	if #self.trace < 200 then
		self.trace[#self.trace + 1] = ("W%02X=%02X"):format(port, value)
	end
	if port == 0x60 then
		const command = self.pendingData
		if command == 0x60 then
			self.config = value
			self.pendingData = nil
		elseif command == 0xD4 then
			self.pendingData = nil
			guestMouseByte(self, value)
		elseif self.command == 0xD2 then
			self.command = nil
			queueByte(self, value, false)
		elseif self.command == 0xD3 then
			self.command = nil
			queueByte(self, value, true)
		else
			guestKeyboardByte(self, value)
		end
		return
	end
	if port ~= 0x64 then
		return
	end
	self.command = value
	if value == 0x20 then
		queueByte(self, self.config, false)
		self.command = nil
	elseif value == 0x60 then
		self.pendingData = 0x60
		self.command = nil
	elseif value == 0xAA then
		queueByte(self, 0x55, false)
		self.command = nil
	elseif value == 0xAB then
		queueByte(self, 0x00, false)
		self.command = nil
	elseif value == 0xA9 then
		queueByte(self, 0x00, true)
		self.command = nil
	elseif value == 0xAD then
		self.keyboardEnabled = false
		self.command = nil
	elseif value == 0xAE then
		self.keyboardEnabled = true
		self.command = nil
	elseif value == 0xA7 then
		self.mouseEnabled = false
		self.command = nil
	elseif value == 0xA8 then
		self.mouseEnabled = true
		self.command = nil
	elseif value == 0xD2 or value == 0xD3 then
		self.command = value
	elseif value == 0xD4 then
		self.pendingData = 0xD4
		self.command = nil
	elseif value == 0xFE then
		self:reset()
		queueByte(self, 0xFA, false)
		queueByte(self, 0xAA, false)
	else
		self.command = nil
	end
end

return Kbc
