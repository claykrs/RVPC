--!strict
-- Pic.lua -- 8259A master/slave pair.
--
-- The PC's two 8259s are initialized by the BIOS with ICW1-ICW4, remapped away
-- from the 8086 vectors, then driven by the PIT/RTC/keyboard. This model keeps
-- the architectural IRR/ISR/IMR state and the master/slave cascade (IRQ2), but
-- does not simulate interrupt-acknowledge bus timing: Machine takes a pending
-- vector, delivers it to the CPU, and the guest's EOI clears the ISR bit.

const band, bor, bnot, lshift = bit32.band, bit32.bor, bit32.bnot, bit32.lshift

const Pic = {}
Pic.__index = Pic

type Chip = {
	irr: number,
	isr: number,
	imr: number,
	vectorBase: number,
	initStep: number,
	icw4: boolean,
	single: boolean,
	readIsr: boolean,
	level: boolean,
}

export type Pic = typeof(setmetatable(
	{} :: {
		master: Chip,
		slave: Chip,
		pendingVector: number?,
		in8: (self: Pic, port: number) -> number,
		out8: (self: Pic, port: number, value: number) -> (),
		raise: (self: Pic, irq: number) -> (),
		syncCascade: (self: Pic) -> (),
		acknowledge: (self: Pic) -> (number?, number?),
		eoi: (self: Pic, irq: number?) -> (),
		nextPending: (self: Pic) -> number?,
		reset: (self: Pic) -> (),
	},
	Pic
))

local function newChip(vectorBase: number): Chip
	return {
		irr = 0,
		isr = 0,
		imr = 0xFF,
		vectorBase = vectorBase,
		initStep = 0,
		icw4 = false,
		single = false,
		readIsr = false,
		level = false,
	}
end

function Pic.new(): Pic
	local self = setmetatable({}, Pic) :: any
	self.master = newChip(0x08)
	self.slave = newChip(0x70)
	self.pendingVector = nil
	return self
end

function Pic.reset(self: Pic)
	self.master = newChip(0x08)
	self.slave = newChip(0x70)
	self.pendingVector = nil
end

local function highestIsr(chip: Chip): number?
	for bit = 0, 7 do
		if band(chip.isr, lshift(1, bit)) ~= 0 then
			return bit
		end
	end
	return nil
end

-- The 8259 fixed-priority resolver: an in-service IRQ blocks itself and all
-- lower-priority IRQs. Only a higher-priority request may preempt it. Ignoring
-- ISR here would redeliver the same level and nest handlers incorrectly.
local function bestIrq(chip: Chip): number?
	local eligible = band(chip.irr, bnot(chip.imr))
	const inService = highestIsr(chip)
	if inService ~= nil then
		eligible = band(eligible, lshift(1, inService) - 1)
	end
	if eligible == 0 then
		return nil
	end
	for bit = 0, 7 do
		if band(eligible, lshift(1, bit)) ~= 0 then
			return bit
		end
	end
	return nil
end

local function setBit(mask: number, bit: number, on: boolean): number
	if on then
		return bor(mask, lshift(1, bit))
	end
	return band(mask, bnot(lshift(1, bit)))
end

function Pic.raise(self: Pic, irq: number)
	if irq < 0 or irq > 15 then
		return
	end
	if irq < 8 then
		self.master.irr = setBit(self.master.irr, irq, true)
		return
	end
	const slaveIrq = irq - 8
	self.slave.irr = setBit(self.slave.irr, slaveIrq, true)
	self:syncCascade()
end

-- The master's IR2 input is wired to the slave's INT output, which is high
-- exactly while the slave holds an unmasked request. Derive it instead of
-- latching it at raise time: a request raised while the slave is masked must
-- surface when the guest unmasks the slave (the Win9x ATAPI drivers mask
-- IRQ14 around data phases and unmask afterwards).
function Pic.syncCascade(self: Pic)
	const request = band(self.slave.irr, bnot(self.slave.imr))
	self.master.irr = setBit(self.master.irr, 2, request ~= 0)
end

function Pic.nextPending(self: Pic): number?
	const masterIrq = bestIrq(self.master)
	if masterIrq == nil then
		return nil
	end
	if masterIrq == 2 then
		const slaveIrq = bestIrq(self.slave)
		if slaveIrq ~= nil then
			return self.slave.vectorBase + slaveIrq
		end
	end
	return self.master.vectorBase + masterIrq
end

function Pic.acknowledge(self: Pic): (number?, number?)
	const masterIrq = bestIrq(self.master)
	if masterIrq == nil then
		return nil, nil
	end
	if masterIrq == 2 then
		const slaveIrq = bestIrq(self.slave)
		if slaveIrq ~= nil then
			self.slave.irr = setBit(self.slave.irr, slaveIrq, false)
			self.slave.isr = setBit(self.slave.isr, slaveIrq, true)
			-- The slave's INT output may stay high when another request is
			-- already queued behind the one being acknowledged.
			self:syncCascade()
			self.master.isr = setBit(self.master.isr, 2, true)
			return self.slave.vectorBase + slaveIrq, 8 + slaveIrq
		end
	end
	self.master.irr = setBit(self.master.irr, masterIrq, false)
	self.master.isr = setBit(self.master.isr, masterIrq, true)
	return self.master.vectorBase + masterIrq, masterIrq
end

function Pic.eoi(self: Pic, irq: number?)
	if irq ~= nil then
		if irq >= 8 then
			self.slave.isr = setBit(self.slave.isr, irq - 8, false)
			-- Only release the cascade line once the slave has no in-service
			-- interrupts left.
			if self.slave.isr == 0 then
				self.master.isr = setBit(self.master.isr, 2, false)
			end
			self:syncCascade()
		else
			self.master.isr = setBit(self.master.isr, irq, false)
		end
		return
	end
	-- Non-specific EOI clears the highest-priority in-service bit.
	const masterBit = highestIsr(self.master)
	if masterBit == nil then
		return
	end
	self.master.isr = setBit(self.master.isr, masterBit, false)
	if masterBit == 2 then
		const slaveBit = highestIsr(self.slave)
		if slaveBit ~= nil then
			self.slave.isr = setBit(self.slave.isr, slaveBit, false)
		end
	end
	self:syncCascade()
end

-- A non-specific EOI written to the slave command port clears the slave, not
-- the master. This is the normal end of an IRQ8-15 handler sequence.
local function eoiSlave(self: Pic)
	const slaveBit = highestIsr(self.slave)
	if slaveBit == nil then
		return
	end
	self.slave.isr = setBit(self.slave.isr, slaveBit, false)
	if self.slave.isr == 0 then
		self.master.isr = setBit(self.master.isr, 2, false)
	end
	self:syncCascade()
end

local function writeChip(self: Pic, chip: Chip, port: number, value: number)
	if port == 0 then
		if band(value, 0x10) ~= 0 then
			chip.initStep = 1
			chip.icw4 = band(value, 0x01) ~= 0
			chip.single = band(value, 0x02) ~= 0
			chip.level = band(value, 0x08) ~= 0
			chip.irr = 0
			chip.isr = 0
			self:syncCascade()
			return
		end
		if band(value, 0x08) ~= 0 then
			-- OCW3: select the next read register, poll mode is not modelled.
			chip.readIsr = band(value, 0x02) ~= 0
			return
		end
		-- OCW2: end-of-interrupt (specific when bit 6 is set).
		if band(value, 0x20) ~= 0 then
			if band(value, 0x40) ~= 0 then
				self:eoi(band(value, 7) + (if chip == self.slave then 8 else 0))
			elseif chip == self.slave then
				eoiSlave(self)
			else
				self:eoi(nil)
			end
		end
		return
	end
	if chip.initStep == 1 then
		chip.vectorBase = band(value, 0xF8)
		chip.initStep = if chip.single then (if chip.icw4 then 4 else 0) else 2
		return
	end
	if chip.initStep == 2 then
		-- ICW3: master cascade mask / slave cascade identity. The single bit in
		-- IRQ2 is the only cascade route this machine exposes.
		chip.initStep = if chip.icw4 then 4 else 0
		return
	end
	if chip.initStep == 4 then
		chip.initStep = 0
		return
	end
	chip.imr = band(value, 0xFF)
	self:syncCascade()
end

function Pic.out8(self: Pic, port: number, value: number)
	if port == 0x20 or port == 0x21 then
		writeChip(self, self.master, port - 0x20, value)
	elseif port == 0xA0 or port == 0xA1 then
		writeChip(self, self.slave, port - 0xA0, value)
	end
end

function Pic.in8(self: Pic, port: number): number
	local chip, isCommand
	if port == 0x20 then
		chip, isCommand = self.master, true
	elseif port == 0x21 then
		chip, isCommand = self.master, false
	elseif port == 0xA0 then
		chip, isCommand = self.slave, true
	elseif port == 0xA1 then
		chip, isCommand = self.slave, false
	else
		return 0xFF
	end
	if not isCommand then
		return chip.imr
	end
	return if chip.readIsr then chip.isr else chip.irr
end

return Pic
