--!strict
-- Uart.lua -- 8250/16450 COM1 at 0x3F8-0x3FF.
--
-- The core only models the registers a DOS/Windows serial driver touches. Byte
-- I/O goes through an injected host backend so the module stays environment
-- pure: the Roblox client can wire a terminal, Lune tests use a loopback.

const band, bor, lshift = bit32.band, bit32.bor, bit32.lshift

const Uart = {}
Uart.__index = Uart

Uart.BASE = 0x3F8
Uart.RX_CAPACITY = 16

export type Backend = {
	writeByte: ((backend: any, value: number) -> ())?,
	readByte: ((backend: any) -> number?)?,
}

export type Uart = {
	backend: Backend?,
	rx: { number },
	overrun: boolean,
	threPending: boolean,
	ier: number,
	lcr: number,
	mcr: number,
	fcr: number,
	divisorLow: number,
	divisorHigh: number,
	scratch: number,
	new: (backend: Backend?) -> Uart,
	reset: (self: Uart) -> (),
	poll: (self: Uart) -> (),
	pushByte: (self: Uart, value: number) -> (),
	rxAvailable: (self: Uart) -> boolean,
	readByte: (self: Uart) -> number?,
	writeByte: (self: Uart, value: number) -> (),
	writeText: (self: Uart, text: string) -> (),
	irqPending: (self: Uart) -> boolean,
	interruptId: (self: Uart) -> number,
	lineStatus: (self: Uart) -> number,
	modemStatus: (self: Uart) -> number,
	in8: (self: Uart, port: number) -> number,
	out8: (self: Uart, port: number, value: number) -> (),
}

function Uart.new(backend: Backend?): Uart
	const self = setmetatable({}, Uart) :: any
	self.backend = backend
	self:reset()
	return self
end

function Uart.reset(self: Uart)
	self.rx = {}
	self.overrun = false
	self.threPending = true -- THR starts empty
	self.ier = 0
	self.lcr = 0x03 -- 8N1
	self.mcr = 0
	self.fcr = 0
	self.divisorLow = 12 -- 9600 with a 1.8432 MHz clock
	self.divisorHigh = 0
	self.scratch = 0
end

-- Pull one byte from the host backend. Called from the IRQ pump and on a
-- register read so polled and interrupt-driven guests both see input.
function Uart.poll(self: Uart)
	if #self.rx >= Uart.RX_CAPACITY then
		return
	end
	const backend = self.backend
	if not backend or not backend.readByte then
		return
	end
	const value = backend.readByte(backend)
	if value ~= nil then
		self.rx[#self.rx + 1] = band(value, 0xFF)
	end
end

function Uart.pushByte(self: Uart, value: number)
	self:poll()
	if #self.rx >= Uart.RX_CAPACITY then
		self.overrun = true
		return
	end
	self.rx[#self.rx + 1] = band(value, 0xFF)
end

function Uart.rxAvailable(self: Uart): boolean
	self:poll()
	return #self.rx > 0
end

function Uart.readByte(self: Uart): number?
	self:poll()
	if #self.rx == 0 then
		return nil
	end
	return table.remove(self.rx, 1)
end

-- A real 8250 in loopback returns TX to RX without touching the line. The
-- backend is only called for normal (non-loopback) transmission.
function Uart.writeByte(self: Uart, value: number)
	const byte = band(value, 0xFF)
	if band(self.mcr, 0x10) ~= 0 then
		self:pushByte(byte)
	else
		const backend = self.backend
		if backend and backend.writeByte then
			backend.writeByte(backend, byte)
		end
	end
	self.threPending = true
end

function Uart.writeText(self: Uart, text: string)
	for index = 1, #text do
		self:writeByte(string.byte(text, index) :: number)
	end
end

-- OUT2 (MCR bit 3) gates the card's IRQ line on a real PC.
function Uart.irqPending(self: Uart): boolean
	if band(self.mcr, 0x08) == 0 then
		return false
	end
	if band(self.ier, 0x01) ~= 0 then
		self:poll()
		if #self.rx > 0 then
			return true
		end
	end
	if band(self.ier, 0x02) ~= 0 and self.threPending then
		return true
	end
	return false
end

-- IIR: bit 0 = 0 means pending; bits 3-1 are the highest-priority source.
-- Reading IIR acknowledges a pending THRE interrupt.
function Uart.interruptId(self: Uart): number
	const fifo = if band(self.fcr, 0x01) ~= 0 then 0xC0 else 0
	const value = (function(): number
		if band(self.ier, 0x01) ~= 0 then
			self:poll()
			if #self.rx > 0 then
				return bor(fifo, 0x04) -- received data available
			end
		end
		if band(self.ier, 0x02) ~= 0 and self.threPending then
			return bor(fifo, 0x02) -- transmitter holding register empty
		end
		return 0x01
	end)()
	if band(value, 0x0E) == 0x02 then
		self.threPending = false
	end
	return value
end

function Uart.lineStatus(self: Uart): number
	self:poll()
	local status = 0x60 -- THRE and TEMT
	if #self.rx > 0 then
		status = bor(status, 0x01)
	end
	if self.overrun then
		status = bor(status, 0x02)
	end
	return status
end

function Uart.modemStatus(self: Uart): number
	if band(self.mcr, 0x10) ~= 0 then
		-- Loopback: CTS/DSR/RI/DCD mirror RTS/DTR/OUT1/OUT2.
		return lshift(band(self.mcr, 0x0F), 4)
	end
	return 0xB0 -- DCD, DSR and CTS asserted; no delta bits
end

function Uart.in8(self: Uart, port: number): number
	const offset = band(port - Uart.BASE, 0xFF)
	if offset == 0 then
		if band(self.lcr, 0x80) ~= 0 then
			return self.divisorLow
		end
		return self:readByte() or 0
	elseif offset == 1 then
		if band(self.lcr, 0x80) ~= 0 then
			return self.divisorHigh
		end
		return self.ier
	elseif offset == 2 then
		return self:interruptId()
	elseif offset == 3 then
		return self.lcr
	elseif offset == 4 then
		return self.mcr
	elseif offset == 5 then
		const status = self:lineStatus()
		self.overrun = false
		return status
	elseif offset == 6 then
		return self:modemStatus()
	elseif offset == 7 then
		return self.scratch
	end
	return 0
end

function Uart.out8(self: Uart, port: number, value: number)
	const byte = band(value, 0xFF)
	const offset = band(port - Uart.BASE, 0xFF)
	if offset == 0 then
		if band(self.lcr, 0x80) ~= 0 then
			self.divisorLow = byte
		else
			self:writeByte(byte) -- THR
		end
	elseif offset == 1 then
		if band(self.lcr, 0x80) ~= 0 then
			self.divisorHigh = byte
		else
			self.ier = band(byte, 0x0F)
		end
	elseif offset == 2 then
		self.fcr = byte
		if band(byte, 0x02) ~= 0 then -- clear receive FIFO
			self.rx = {}
			self.overrun = false
		end
	elseif offset == 3 then
		self.lcr = byte
	elseif offset == 4 then
		self.mcr = byte
	elseif offset == 7 then
		self.scratch = byte
	end
end

-- In-memory loopback backend: transmitted bytes come back as received bytes.
-- Tests use this, and it is a useful default for a host with no terminal.
function Uart.loopbackBackend(): Backend
	const queue: { number } = {}
	return {
		writeByte = function(_backend: any, value: number)
			queue[#queue + 1] = band(value, 0xFF)
		end,
		readByte = function(_backend: any): number?
			return table.remove(queue, 1)
		end,
	}
end

return Uart
