--!strict
-- Machine.lua -- minimal 386/486 machine skeleton for RVDM98.
--
-- This is deliberately not the RVDM DOS/Windows host. It owns 32-bit physical
-- memory, the CPU, VGA, XMS/A20 and optional serial/parallel ports. The PC
-- chipset (PIC/PIT/CMOS/IDE/PCI/NE2000) lands next.

const Machine = {}
Machine.__index = Machine

export type Deps = {
	Memory: any,
	Cpu: any,
	Vga: any?,
	Xms: any?,
	Uart: any?,
	Lpt: any?,
}

export type Config = {
	memorySize: number?,
	cpu: any?,
	serial: any?,
	printer: any?,
	timerInterval: number?,
}

export type Machine = typeof(setmetatable(
	{} :: {
		mem: any,
		cpu: any,
		vga: any?,
		xms: any?,
		uart: any?,
		lpt: any?,
		exitCode: number?,
		config: Config,
		run: (self: Machine, maxSteps: number?) -> number,
		reset: (self: Machine) -> (),
		outputText: (self: Machine) -> string,
	},
	Machine
))

function Machine.new(deps: Deps, config: Config?): Machine
	const cfg: Config = config or {}
	const self = setmetatable({}, Machine) :: any
	self.config = cfg
	self.mem = deps.Memory.new(cfg.memorySize or 4 * 1024 * 1024)
	if deps.Vga then
		self.vga = deps.Vga.new(self.mem)
		self.mem.aperture = self.vga
	end
	if deps.Uart then
		self.uart = deps.Uart.new(cfg.serial)
	end
	if deps.Lpt then
		self.lpt = deps.Lpt.new(cfg.printer)
	end
	const io = {
		in8 = function(port: number): number
			if self.uart and port >= 0x3F8 and port <= 0x3FF then
				return self.uart:in8(port)
			end
			if self.lpt and port >= 0x378 and port <= 0x37A then
				return self.lpt:in8(port)
			end
			return 0xFF
		end,
		out8 = function(port: number, value: number)
			if self.uart and port >= 0x3F8 and port <= 0x3FF then
				self.uart:out8(port, value)
				return
			end
			if self.lpt and port >= 0x378 and port <= 0x37A then
				self.lpt:out8(port, value)
			end
		end,
	}
	self.cpu = deps.Cpu.new(self.mem, io, cfg.cpu or { cpuLevel = "386" })
	-- Minimal real-mode interrupt table: every vector returns until a real
	-- BIOS/OS installs its own handlers.
	self.mem:write8(0xF0000 + 0x100, 0xCF)
	for vector = 0, 255 do
		self.mem:write16(vector * 4, 0x0100)
		self.mem:write16(vector * 4 + 2, 0xF000)
	end
	if deps.Xms then
		self.xms = deps.Xms.new(self)
	end
	self.exitCode = nil
	return self
end

function Machine.reset(self: Machine)
	self.cpu:reset()
	self.exitCode = nil
end

function Machine.outputText(_self: Machine): string
	return ""
end

function Machine.run(self: Machine, maxSteps: number?): number
	local steps = 0
	const budget = maxSteps or math.huge
	while steps < budget and not self.cpu.halted and not self.exitCode do
		self.cpu:step()
		steps += 1
	end
	return steps
end

return Machine
