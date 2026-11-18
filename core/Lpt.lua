--!strict
-- Lpt.lua -- parallel port LPT1 at 0x378-0x37A with an injected print backend.
--
-- Data written to 0x378 is latched and emitted when the guest pulses STROBE
-- (control bit 0 high-to-low), matching how BIOS INT 17h and Windows' printer
-- drivers drive a Centronics port. INT 17h uses writeByte() directly.

const band, bor = bit32.band, bit32.bor

const Lpt = {}
Lpt.__index = Lpt

Lpt.BASE = 0x378

export type Backend = {
	write: ((backend: any, text: string) -> ())?,
}

export type Lpt = {
	backend: Backend?,
	data: number,
	control: number,
	bytes: number,
	new: (backend: Backend?) -> Lpt,
	reset: (self: Lpt) -> (),
	status: (self: Lpt) -> number,
	intStatus: (self: Lpt) -> number,
	emit: (self: Lpt, text: string) -> (),
	writeByte: (self: Lpt, value: number) -> (),
	writeText: (self: Lpt, text: string) -> (),
	initialize: (self: Lpt) -> (),
	strobe: (self: Lpt) -> (),
	in8: (self: Lpt, port: number) -> number,
	out8: (self: Lpt, port: number, value: number) -> (),
}

function Lpt.new(backend: Backend?): Lpt
	const self = setmetatable({}, Lpt) :: any
	self.backend = backend
	self:reset()
	return self
end

function Lpt.reset(self: Lpt)
	self.data = 0
	self.control = 0x0C -- SELECT and INIT asserted, STROBE low
	self.bytes = 0
end

-- Parallel-port status byte: ~BUSY, ~ACK, PE, SELECT, ~ERROR.
function Lpt.status(_self: Lpt): number
	return 0xDF -- ready, selected, no paper error
end

-- INT 17h AH status: not busy, selected, no error/timeout.
function Lpt.intStatus(_self: Lpt): number
	return 0x90
end

function Lpt.emit(self: Lpt, text: string)
	const backend = self.backend
	if backend and backend.write then
		backend.write(backend, text)
	end
	self.bytes += #text
end

-- INT 17h AH=00 prints a byte without a guest-visible strobe.
function Lpt.writeByte(self: Lpt, value: number)
	self.data = band(value, 0xFF)
	self:emit(string.char(self.data))
end

function Lpt.writeText(self: Lpt, text: string)
	for index = 1, #text do
		self.data = string.byte(text, index) :: number
	end
	if #text > 0 then
		self:emit(text)
	end
end

function Lpt.initialize(self: Lpt)
	-- INIT is active low; pulse it and leave the port selected.
	self.control = 0x08
	self.control = bor(self.control, 0x04)
end

function Lpt.strobe(self: Lpt)
	self:emit(string.char(self.data))
end

function Lpt.in8(self: Lpt, port: number): number
	const offset = band(port - Lpt.BASE, 0xFF)
	if offset == 0 then
		return self.data
	elseif offset == 1 then
		return self:status()
	elseif offset == 2 then
		return self.control
	end
	return 0xFF
end

function Lpt.out8(self: Lpt, port: number, value: number)
	const byte = band(value, 0xFF)
	const offset = band(port - Lpt.BASE, 0xFF)
	if offset == 0 then
		self.data = byte
	elseif offset == 2 then
		const previous = self.control
		self.control = byte
		-- Centronics latches on the falling edge of STROBE.
		if band(previous, 0x01) ~= 0 and band(byte, 0x01) == 0 then
			self:strobe()
		end
	end
end

return Lpt
