--!strict
-- Ne2000.lua -- DP8390-compatible NE2000 Ethernet controller.
--
-- The guest sees the classic 16-bit ISA card at 0x300/IRQ10: 16 register
-- bytes, a remote-DMA data port, a reset port, and 32 KiB of packet memory
-- (the top 16 KiB is the receive/transmit ring). The host injects and receives
-- Ethernet frames through callbacks, so the core stays environment-pure.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const Ne2000 = {}
Ne2000.__index = Ne2000

Ne2000.BASE = 0x300
Ne2000.IRQ = 10
Ne2000.DATA_OFFSET = 0x10
Ne2000.RESET_OFFSET = 0x1F
Ne2000.MEM_SIZE = 0x8000
Ne2000.PMEM_START = 0x4000
Ne2000.MAX_FRAME = 1514

-- Page-0 command bits.
const CR_STOP = 0x01
const CR_TXP = 0x04
const CR_RREAD = 0x08
const CR_RWRITE = 0x10
const CR_NODMA = 0x20
const CR_PAGE1 = 0x40
const CR_PAGE2 = 0x80

const ISR_RX = 0x01
const ISR_TX = 0x02
const ISR_TX_ERR = 0x08
const ISR_OVER = 0x10
const ISR_RDC = 0x40
const ISR_RESET = 0x80

const TSR_PTX = 0x01

export type Config = {
	mac: string?,
	base: number?,
	irq: number?,
	transmit: ((frame: buffer) -> ())?,
}

export type Ne2000 = typeof(setmetatable(
	{} :: {
		base: number,
		irq: number,
		mem: buffer,
		cmd: number,
		start: number,
		stop: number,
		boundary: number,
		curpag: number,
		tsr: number,
		tpsr: number,
		tcnt: number,
		rsar: number,
		rcnt: number,
		rsr: number,
		rxcr: number,
		isr: number,
		dcfg: number,
		imr: number,
		phys: { number },
		mult: { number },
		transmit: ((frame: buffer) -> ())?,
		irqLine: boolean,
		new: (config: Config?) -> Ne2000,
		reset: (self: Ne2000) -> (),
		in8: (self: Ne2000, port: number) -> number,
		out8: (self: Ne2000, port: number, value: number) -> (),
		in16: (self: Ne2000, port: number) -> number,
		out16: (self: Ne2000, port: number, value: number) -> (),
		irqPending: (self: Ne2000) -> boolean,
		takeIrq: (self: Ne2000) -> boolean,
		receive: (self: Ne2000, frame: buffer) -> boolean,
		macString: (self: Ne2000) -> string,
	},
	Ne2000
))

local function parseMac(text: string?): { number }
	const source = text or "52:54:00:12:34:56"
	const out = { 0x52, 0x54, 0, 0x12, 0x34, 0x56 }
	local index = 0
	for part in string.gmatch(source, "[^:%-]+") do
		if index < 6 then
			out[index + 1] = band(tonumber(part, 16) or 0, 0xFF)
			index += 1
		end
	end
	return out
end

local function macText(phys: { number }): string
	return string.format(
		"%02X:%02X:%02X:%02X:%02X:%02X",
		phys[1],
		phys[2],
		phys[3],
		phys[4],
		phys[5],
		phys[6]
	)
end

function Ne2000.new(config: Config?): Ne2000
	const cfg: Config = config or {}
	local self = setmetatable({}, Ne2000) :: any
	self.base = cfg.base or Ne2000.BASE
	self.irq = cfg.irq or Ne2000.IRQ
	self.mem = buffer.create(Ne2000.MEM_SIZE)
	self.phys = parseMac(cfg.mac)
	self.mult = { 0, 0, 0, 0, 0, 0, 0, 0 }
	self.transmit = cfg.transmit
	self.irqLine = false
	self:reset()
	return self
end

function Ne2000.reset(self: Ne2000)
	self.cmd = bor(CR_STOP, CR_NODMA)
	self.start = 0x46 * 256
	self.stop = 0x80 * 256
	self.boundary = 0x46
	self.curpag = 0x46
	self.tsr = 0
	self.tpsr = 0
	self.tcnt = 0
	self.rsar = 0
	self.rcnt = 0
	self.rsr = 0
	self.rxcr = 0
	self.dcfg = 0
	self.imr = 0
	self.isr = ISR_RESET
	buffer.fill(self.mem, 0, Ne2000.MEM_SIZE, 0)
	for index = 1, 6 do
		buffer.writeu8(self.mem, index - 1, self.phys[index])
		buffer.writeu8(self.mem, (index - 1) * 2, self.phys[index])
		buffer.writeu8(self.mem, (index - 1) * 2 + 1, self.phys[index])
	end
	buffer.writeu8(self.mem, 14, 0x57)
	buffer.writeu8(self.mem, 15, 0x57)
	self.irqLine = false
end

function Ne2000.macString(self: Ne2000): string
	return macText(self.phys)
end

local function updateIrq(self: Ne2000)
	-- irqLine is the edge/latched state consumed by Machine.takeIrq. A new
	-- pending bit does not set it; takeIrq raises it once, and clearing ISR
	-- through the mask arms it for the next interrupt.
	if band(self.isr, self.imr) == 0 then
		self.irqLine = false
	end
end

function Ne2000.irqPending(self: Ne2000): boolean
	return band(self.isr, self.imr) ~= 0
end

-- One-shot line read for a machine that raises IRQ10 on a rising edge.
function Ne2000.takeIrq(self: Ne2000): boolean
	if not self:irqPending() then
		self.irqLine = false
		return false
	end
	if self.irqLine then
		return false
	end
	self.irqLine = true
	return true
end

local function page(self: Ne2000): number
	return band(self.cmd, 0xC0)
end

local function localIndex(pageNumber: number): number
	return band(pageNumber, 0x7F) * 256
end

local function ringNext(self: Ne2000, pageNumber: number): number
	local nextPage = pageNumber + 1
	if nextPage >= rshift(self.stop, 8) then
		nextPage = rshift(self.start, 8)
	end
	return nextPage
end

local function transmitPacket(self: Ne2000)
	const index = localIndex(self.tpsr)
	if self.tcnt == 0 or self.tcnt > Ne2000.MAX_FRAME then
		self.tsr = 0x20 -- FIFO underrun
		self.isr = bor(self.isr, ISR_TX_ERR)
		updateIrq(self)
		return
	end
	local frame = buffer.create(self.tcnt)
	buffer.copy(frame, 0, self.mem, index, self.tcnt)
	self.tsr = TSR_PTX
	self.isr = bor(self.isr, ISR_TX)
	self.cmd = band(self.cmd, bit32.bnot(CR_TXP))
	if self.transmit then
		self.transmit(frame)
	end
	updateIrq(self)
end

function Ne2000.receive(self: Ne2000, frame: buffer): boolean
	const length = buffer.len(frame)
	if length < 14 or length > Ne2000.MAX_FRAME then
		return false
	end
	local target = self.curpag
	local address = localIndex(target)
	local nextPage = ringNext(self, target)
	while true do
		const needed = 4 + length
		const room = if nextPage > target
			then localIndex(nextPage) - address
			else self.stop - address + self.start - localIndex(rshift(self.start, 8))
		if needed + 4 <= room then
			break
		end
		target = nextPage
		address = localIndex(target)
		nextPage = ringNext(self, target)
		if target == self.curpag then
			self.isr = bor(self.isr, ISR_OVER)
			updateIrq(self)
			return false
		end
	end
	buffer.writeu8(self.mem, address, ISR_RX)
	buffer.writeu8(self.mem, address + 1, nextPage)
	buffer.writeu16(self.mem, address + 2, length)
	buffer.copy(self.mem, address + 4, frame, 0, length)
	self.curpag = nextPage
	self.isr = bor(self.isr, ISR_RX)
	updateIrq(self)
	return true
end

local function dmaReadByte(self: Ne2000): number
	if band(self.cmd, CR_RREAD) == 0 or self.rcnt == 0 then
		return 0xFF
	end
	local value = 0xFF
	if self.rsar >= Ne2000.PMEM_START and self.rsar < Ne2000.MEM_SIZE then
		value = buffer.readu8(self.mem, self.rsar)
	end
	self.rsar = band(self.rsar + 1, 0xFFFF)
	self.rcnt = if self.rcnt > 0 then self.rcnt - 1 else 0
	if self.rcnt == 0 then
		self.isr = bor(self.isr, ISR_RDC)
		updateIrq(self)
	end
	return value
end

local function dmaWriteByte(self: Ne2000, value: number)
	if band(self.cmd, CR_RWRITE) == 0 or self.rcnt == 0 then
		return
	end
	if self.rsar >= Ne2000.PMEM_START and self.rsar < Ne2000.MEM_SIZE then
		buffer.writeu8(self.mem, self.rsar, band(value, 0xFF))
	end
	self.rsar = band(self.rsar + 1, 0xFFFF)
	self.rcnt = if self.rcnt > 0 then self.rcnt - 1 else 0
	if self.rcnt == 0 then
		self.isr = bor(self.isr, ISR_RDC)
		updateIrq(self)
	end
end

local function readRegister(self: Ne2000, offset: number): number
	const current = page(self)
	if offset == 0 then
		return self.cmd
	end
	if current == 0 then
		if offset == 1 then
			return band(self.rsar, 0xFF)
		elseif offset == 2 then
			return band(rshift(self.rsar, 8), 0xFF)
		elseif offset == 3 then
			return self.boundary
		elseif offset == 4 then
			return self.tsr
		elseif offset == 5 then
			return 0
		elseif offset == 6 then
			return 0
		elseif offset == 7 then
			return self.isr
		elseif offset == 8 then
			return band(self.rsar, 0xFF)
		elseif offset == 9 then
			return band(rshift(self.rsar, 8), 0xFF)
		elseif offset == 10 then
			return band(self.rcnt, 0xFF)
		elseif offset == 11 then
			return band(rshift(self.rcnt, 8), 0xFF)
		elseif offset == 12 then
			return self.rsr
		elseif offset == 13 or offset == 14 or offset == 15 then
			return 0
		end
	elseif current == CR_PAGE1 then
		if offset >= 1 and offset <= 6 then
			return self.phys[offset]
		elseif offset == 7 then
			return self.curpag
		elseif offset >= 8 and offset <= 15 then
			return self.mult[offset - 7]
		end
	elseif current == CR_PAGE2 then
		if offset == 1 then
			return band(rshift(self.start, 8), 0xFF)
		elseif offset == 2 then
			return band(rshift(self.stop, 8), 0xFF)
		end
	end
	return 0
end

local function writeRegister(self: Ne2000, offset: number, value: number)
	value = band(value, 0xFF)
	if offset == 0 then
		self.cmd = value
		if band(value, CR_STOP) ~= 0 then
			-- Stop/reset the chip without clearing the packet RAM.
			self.tsr = 0
		end
		if band(value, CR_TXP) ~= 0 then
			transmitPacket(self)
		end
		return
	end
	const current = page(self)
	if current == 0 then
		if offset == 1 then
			self.start = value * 256
		elseif offset == 2 then
			self.stop = value * 256
		elseif offset == 3 then
			self.boundary = value
		elseif offset == 4 then
			self.tpsr = value
		elseif offset == 5 then
			self.tcnt = bor(band(self.tcnt, 0xFF00), value)
		elseif offset == 6 then
			self.tcnt = bor(band(self.tcnt, 0x00FF), lshift(value, 8))
		elseif offset == 7 then
			self.isr = band(self.isr, bit32.bnot(value))
			updateIrq(self)
		elseif offset == 8 then
			self.rsar = bor(band(self.rsar, 0xFF00), value)
		elseif offset == 9 then
			self.rsar = bor(band(self.rsar, 0x00FF), lshift(value, 8))
		elseif offset == 10 then
			self.rcnt = bor(band(self.rcnt, 0xFF00), value)
		elseif offset == 11 then
			self.rcnt = bor(band(self.rcnt, 0x00FF), lshift(value, 8))
		elseif offset == 12 then
			self.rxcr = value
		elseif offset == 13 then
			-- transmit configuration: loopback is not modelled
		elseif offset == 14 then
			self.dcfg = value
		elseif offset == 15 then
			self.imr = value
			updateIrq(self)
		end
	elseif current == CR_PAGE1 then
		if offset >= 1 and offset <= 6 then
			self.phys[offset] = value
			buffer.writeu8(self.mem, (offset - 1) * 2, value)
			buffer.writeu8(self.mem, (offset - 1) * 2 + 1, value)
		elseif offset == 7 then
			self.curpag = value
		elseif offset >= 8 and offset <= 15 then
			self.mult[offset - 7] = value
		end
	end
end

function Ne2000.in8(self: Ne2000, port: number): number
	const offset = band(port - self.base, 0xFF)
	if offset == Ne2000.DATA_OFFSET then
		return dmaReadByte(self)
	elseif offset == Ne2000.RESET_OFFSET then
		return 0
	elseif offset < Ne2000.DATA_OFFSET then
		return readRegister(self, offset)
	end
	return 0xFF
end

function Ne2000.out8(self: Ne2000, port: number, value: number)
	const offset = band(port - self.base, 0xFF)
	if offset == Ne2000.DATA_OFFSET then
		dmaWriteByte(self, value)
	elseif offset == Ne2000.RESET_OFFSET then
		self:reset()
	elseif offset < Ne2000.DATA_OFFSET then
		writeRegister(self, offset, value)
	end
end

function Ne2000.in16(self: Ne2000, port: number): number
	const offset = band(port - self.base, 0xFF)
	if offset == Ne2000.DATA_OFFSET then
		if band(self.dcfg, 0x01) == 0 then
			return self:in8(port)
		end
		const low = dmaReadByte(self)
		const high = dmaReadByte(self)
		return bor(low, lshift(high, 8))
	end
	return self:in8(port)
end

function Ne2000.out16(self: Ne2000, port: number, value: number)
	const offset = band(port - self.base, 0xFF)
	if offset == Ne2000.DATA_OFFSET and band(self.dcfg, 0x01) ~= 0 then
		dmaWriteByte(self, band(value, 0xFF))
		dmaWriteByte(self, band(rshift(value, 8), 0xFF))
		return
	end
	self:out8(port, band(value, 0xFF))
end

return Ne2000
