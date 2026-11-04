--!strict
-- Machine.lua -- 486/Pentium-class PC skeleton for RVPC.
--
-- Owns 32-bit physical memory, the CPU, VGA, the 8259/8254/CMOS chipset and
-- optional serial/parallel ports. Host services are injected through deps; this
-- module never requires Roblox or the filesystem.

const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift

const Machine = {}
Machine.__index = Machine

const PIC_MASTER_CMD = 0x20
const PIC_MASTER_DATA = 0x21
const PIC_SLAVE_CMD = 0xA0
const PIC_SLAVE_DATA = 0xA1
const PIT_BASE = 0x40
const CMOS_INDEX = 0x70
const CMOS_DATA = 0x71
const PORT_A20 = 0x92
const PCI_ADDRESS = 0xCF8
const PCI_DATA = 0xCFC

export type Deps = {
	Memory: any,
	Cpu: any,
	Vga: any?,
	Pic: any?,
	Pit: any?,
	Cmos: any?,
	FwCfg: any?,
	Ide: any?,
	Kbc: any?,
	Fpu: any?,
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
	rom: buffer?,
	vgaRom: buffer?,
	hdd: buffer?,
	cdrom: buffer?,
}

export type Machine = typeof(setmetatable(
	{} :: {
		mem: any,
		cpu: any,
		vga: any?,
		pic: any?,
		pit: any?,
		cmos: any?,
		fwcfg: any?,
		ide: any?,
		kbc: any?,
		fpu: any?,
		xms: any?,
		uart: any?,
		lpt: any?,
		exitCode: number?,
		config: Config,
		pciAddress: number,
		lastInPort: number,
		lastOutPort: number,
		lastOutValue: number,
		irqCount: number,
		debugLog: { string },
		run: (self: Machine, maxSteps: number?) -> number,
		reset: (self: Machine) -> (),
		outputText: (self: Machine) -> string,
		debugText: (self: Machine) -> string,
		bootPc: (self: Machine) -> string,
		deliverInterrupt: (self: Machine) -> boolean,
		pressKey: (self: Machine, scancode: number) -> (),
		releaseKey: (self: Machine, scancode: number) -> (),
		mouseMove: (self: Machine, dx: number, dy: number, buttons: number?) -> (),
		injectBdaKey: (self: Machine, scan: number, ascii: number) -> boolean,
	},
	Machine
))

-- A tiny 440FX host bridge so SeaBIOS's northbridge probe finds something
-- plausible. There is no real PCI device behind it yet; absent devices read as
-- all-ones, which is what the configuration mechanism reports on an empty bus.
local function hostBridgeDword(machine: any, offset: number): number
	if offset == 0x00 then
		return 0x12378086 -- Intel 440FX, vendor 8086 device 1237
	elseif offset == 0x04 then
		return 0x00000006 -- I/O + memory space enabled
	elseif offset == 0x08 then
		return 0x06000002 -- host bridge, revision 2
	elseif offset == 0x0C then
		return 0x00000000 -- type 0 header
	elseif offset == 0x2C then
		return 0x11001AF4 -- Red Hat/QEMU subsystem, as SeaBIOS expects
	end
	-- PAM/PAM shadow-control bytes are written by SeaBIOS's
	-- make_bios_writable/make_bios_readonly paths.
	return machine.hostConfig[offset] or 0
end

-- Bochs/QEMU stdvga-compatible PCI VGA device at 00:02.0. The VGA BIOS option
-- ROM at C0000 is what installs INT 10h; the legacy VGA register model lives in
-- core/Vga.lua. BAR0 is intentionally absent (no linear framebuffer yet).
local function vgaDword(offset: number): number
	if offset == 0x00 then
		return 0x11111234 -- Bochs VGA, vendor 1234 device 1111
	elseif offset == 0x04 then
		return 0x00000007 -- I/O + memory + bus master enabled
	elseif offset == 0x08 then
		return 0x03000001 -- VGA controller, revision 1
	elseif offset == 0x0C then
		return 0x00000000 -- type 0 header
	elseif offset == 0x2C then
		return 0x11001AF4
	elseif offset == 0x30 then
		return 0x00000000 -- ROM is scanned from the C0000 shadow window
	elseif offset == 0x3C then
		return 0x00000B00 -- IRQ 11
	end
	return 0
end

-- PIIX3-style IDE function at 00:01.1. prog_if=0 makes SeaBIOS use the legacy
-- 0x1F0/0x3F6 task file instead of PCI BARs.
local function ideDword(offset: number): number
	if offset == 0x00 then
		return 0x70108086 -- Intel PIIX3 IDE
	elseif offset == 0x04 then
		return 0x00000007
	elseif offset == 0x08 then
		return 0x01010000 -- IDE controller, legacy programming interface
	elseif offset == 0x0C then
		return 0x00000000
	elseif offset == 0x2C then
		return 0x11001AF4
	elseif offset == 0x3C then
		return 0x00000E00 -- IRQ14
	end
	return 0
end

local function pciRead(machine: any, address: number): number
	if band(address, 0x80000000) == 0 then
		return 0xFFFFFFFF
	end
	const bus = band(rshift(address, 16), 0xFF)
	const device = band(rshift(address, 11), 0x1F)
	const functionNumber = band(rshift(address, 8), 0x07)
	const offset = band(address, 0xFC)
	if bus == 0 then
		if device == 0 and functionNumber == 0 then
			return hostBridgeDword(machine, offset)
		elseif device == 1 and functionNumber == 0 then
			return ideDword(offset)
		elseif device == 2 and functionNumber == 0 then
			return vgaDword(offset)
		end
	end
	return 0xFFFFFFFF
end

local function pciWrite(machine: any, address: number, value: number)
	if band(address, 0x80000000) == 0 then
		return
	end
	const bus = band(rshift(address, 16), 0xFF)
	const device = band(rshift(address, 11), 0x1F)
	const functionNumber = band(rshift(address, 8), 0x07)
	const offset = band(address, 0xFC)
	if bus ~= 0 or device ~= 0 or functionNumber ~= 0 then
		return
	end
	if offset == 0x58 or offset == 0x5C then
		machine.hostConfig[offset] = band(value, 0xFFFFFFFF)
		-- PAM0 bit 4 set with read-only encoding (0x10/0x11) is SeaBIOS's
		-- "make_bios_readonly" state for F0000-FFFFF.
		const pam0 = band(rshift(machine.hostConfig[0x58] or 0, 8), 0xFF)
		machine.mem:lockLowRom(band(pam0, 0x30) == 0x10)
	end
end

function Machine.new(deps: Deps, config: Config?): Machine
	const cfg: Config = config or {}
	local self = setmetatable({}, Machine) :: any
	self.config = cfg
	self.mem = deps.Memory.new(cfg.memorySize or (16 * 1024 * 1024))
	if cfg.rom then
		self.mem:loadRom(cfg.rom)
	end
	if cfg.vgaRom then
		self.mem:loadOptionRom(cfg.vgaRom, 0xC0000)
	end
	if deps.Vga then
		self.vga = deps.Vga.new(self.mem)
		self.mem.aperture = self.vga
	end
	if deps.Pic then
		self.pic = deps.Pic.new()
	end
	if deps.Pit then
		self.pit = deps.Pit.new()
	end
	if deps.Cmos then
		self.cmos = deps.Cmos.new({ memorySize = self.mem.size })
	end
	if deps.FwCfg then
		self.fwcfg = deps.FwCfg.new(self.mem.size, cfg.vgaRom)
	end
	if deps.Ide then
		self.ide = deps.Ide.new({ hdd = cfg.hdd, cdrom = cfg.cdrom })
	end
	if deps.Kbc then
		self.kbc = deps.Kbc.new()
	end
	if deps.Fpu then
		self.fpu = deps.Fpu.new()
	end
	if deps.Uart then
		self.uart = deps.Uart.new(cfg.serial)
	end
	if deps.Lpt then
		self.lpt = deps.Lpt.new(cfg.printer)
	end
	self.pciAddress = 0
	self.hostConfig = {}
	self.lastInPort = 0
	self.lastOutPort = 0
	self.lastOutValue = 0
	self.irqCount = 0
	self.debugLog = {}

	local function pciAddressByte(index: number): number
		return band(rshift(self.pciAddress, index * 8), 0xFF)
	end
	local function pciDataByte(index: number): number
		return band(rshift(pciRead(self, self.pciAddress), index * 8), 0xFF)
	end

	local io: any
	io = {
		in8 = function(port: number): number
			self.lastInPort = port
			if self.fwcfg and (port == 0x510 or port == 0x511) then
				return self.fwcfg:in8(port)
			end
			if self.kbc and (port == 0x60 or port == 0x64) then
				return self.kbc:in8(port)
			end
			if self.ide and ((port >= 0x1F0 and port <= 0x1F7) or port == 0x3F6) then
				return self.ide:in8(port)
			end
			if self.vga and port >= 0x3C0 and port <= 0x3DF then
				return self.vga:in8(port)
			end
			if
				self.pic
				and (
					port == PIC_MASTER_CMD
					or port == PIC_MASTER_DATA
					or port == PIC_SLAVE_CMD
					or port == PIC_SLAVE_DATA
				)
			then
				return self.pic:in8(port)
			end
			if self.pit and port >= PIT_BASE and port <= PIT_BASE + 3 then
				return self.pit:in8(port)
			end
			if self.cmos and (port == CMOS_INDEX or port == CMOS_DATA) then
				return self.cmos:in8(port)
			end
			if port == PORT_A20 then
				return if self.mem.a20 then 0x02 else 0x00
			end
			if port >= PCI_ADDRESS and port <= PCI_ADDRESS + 3 then
				return pciAddressByte(port - PCI_ADDRESS)
			end
			if port >= PCI_DATA and port <= PCI_DATA + 3 then
				return pciDataByte(port - PCI_DATA)
			end
			if self.uart and port >= 0x3F8 and port <= 0x3FF then
				return self.uart:in8(port)
			end
			if self.lpt and port >= 0x378 and port <= 0x37A then
				return self.lpt:in8(port)
			end
			return 0xFF
		end,
		in16 = function(port: number): number
			if self.fwcfg and port == 0x510 then
				return self.fwcfg:in16(port)
			end
			if self.ide and port == 0x1F0 then
				return self.ide:in16(port)
			end
			if port == PCI_ADDRESS then
				return band(self.pciAddress, 0xFFFF)
			elseif port == PCI_DATA then
				return band(pciRead(self, self.pciAddress), 0xFFFF)
			end
			return bor(io.in8(port), lshift(io.in8(band(port + 1, 0xFFFF)), 8))
		end,
		in32 = function(port: number): number
			if port == PCI_ADDRESS then
				return self.pciAddress
			elseif port == PCI_DATA then
				return pciRead(self, self.pciAddress)
			end
			return bor(
				io.in8(port),
				lshift(io.in8(band(port + 1, 0xFFFF)), 8),
				lshift(io.in8(band(port + 2, 0xFFFF)), 16),
				lshift(io.in8(band(port + 3, 0xFFFF)), 24)
			)
		end,
		out8 = function(port: number, value: number)
			self.lastOutPort = port
			self.lastOutValue = value
			if port == 0x402 then
				-- QEMU/SeaBIOS debug console (CONFIG_DEBUG_PORT).
				self.debugLog[#self.debugLog + 1] = string.char(band(value, 0xFF))
				return
			end
			if self.fwcfg and (port == 0x510 or port == 0x511) then
				self.fwcfg:out8(port, value)
				return
			end
			if self.kbc and (port == 0x60 or port == 0x64) then
				self.kbc:out8(port, value)
				return
			end
			if self.ide and ((port >= 0x1F0 and port <= 0x1F7) or port == 0x3F6) then
				self.ide:out8(port, value)
				return
			end
			if self.vga and port >= 0x3C0 and port <= 0x3DF then
				self.vga:out8(port, value)
				return
			end
			if
				self.pic
				and (
					port == PIC_MASTER_CMD
					or port == PIC_MASTER_DATA
					or port == PIC_SLAVE_CMD
					or port == PIC_SLAVE_DATA
				)
			then
				self.pic:out8(port, value)
				return
			end
			if self.pit and port >= PIT_BASE and port <= PIT_BASE + 3 then
				self.pit:out8(port, value)
				return
			end
			if self.cmos and (port == CMOS_INDEX or port == CMOS_DATA) then
				self.cmos:out8(port, value)
				return
			end
			if port == PORT_A20 then
				self.mem:setA20(band(value, 0x02) ~= 0)
				if band(value, 0x01) ~= 0 then
					self:reset()
				end
				return
			end
			if port >= PCI_ADDRESS and port <= PCI_ADDRESS + 3 then
				return
			end
			if port >= PCI_DATA and port <= PCI_DATA + 3 then
				-- Byte writes to config space are not used by SeaBIOS; DWORD
				-- writes are handled by out32.
				return
			end
			if self.uart and port >= 0x3F8 and port <= 0x3FF then
				self.uart:out8(port, value)
				return
			end
			if self.lpt and port >= 0x378 and port <= 0x37A then
				self.lpt:out8(port, value)
			end
		end,
		out16 = function(port: number, value: number)
			if self.fwcfg and port == 0x510 then
				self.fwcfg:out16(port, value)
				return
			end
			if self.ide and port == 0x1F0 then
				self.ide:out16(port, value)
				return
			end
			if port == PCI_ADDRESS then
				self.pciAddress = bor(band(self.pciAddress, 0xFFFF0000), band(value, 0xFFFF))
				return
			elseif port == PCI_DATA then
				return
			end
			io.out8(port, band(value, 0xFF))
			io.out8(band(port + 1, 0xFFFF), band(rshift(value, 8), 0xFF))
		end,
		out32 = function(port: number, value: number)
			if port == PCI_ADDRESS then
				self.pciAddress = band(value, 0xFFFFFFFF)
				return
			elseif port == PCI_DATA then
				pciWrite(self, self.pciAddress, value)
				return
			end
			io.out8(port, band(value, 0xFF))
			io.out8(band(port + 1, 0xFFFF), band(rshift(value, 8), 0xFF))
			io.out8(band(port + 2, 0xFFFF), band(rshift(value, 16), 0xFF))
			io.out8(band(port + 3, 0xFFFF), band(rshift(value, 24), 0xFF))
		end,
	}
	const cpuConfig = cfg.cpu or { cpuLevel = "486" }
	if self.fpu then
		cpuConfig.fpu = self.fpu
	end
	self.cpu = deps.Cpu.new(self.mem, io, cpuConfig)
	self.cpu:reset()
	if not self.mem:hasRom() then
		-- Hypervisor fallback for the DOS-era unit tests: every vector returns
		-- until the guest installs its own handler, and XMS can hook INT 2Fh.
		self.mem:write8(0xF0000 + 0x100, 0xCF)
		for vector = 0, 255 do
			self.mem:write16(vector * 4, 0x0100)
			self.mem:write16(vector * 4 + 2, 0xF000)
		end
		if deps.Xms then
			self.xms = deps.Xms.new(self)
		end
	end
	self.exitCode = nil
	return self
end

function Machine.reset(self: Machine)
	self.cpu:reset()
	self.mem:setA20(false)
	self.mem:lockLowRom(false)
	if self.pic then
		self.pic:reset()
	end
	if self.pit then
		self.pit:reset()
	end
	if self.ide then
		self.ide:reset()
	end
	if self.kbc then
		self.kbc:reset()
	end
	self.exitCode = nil
end

function Machine.deliverInterrupt(self: Machine): boolean
	if not self.pic then
		return false
	end
	if band(self.cpu.flags, 0x200) == 0 or self.cpu.irqDelay > 0 then
		return false
	end
	const vector = self.pic:nextPending()
	if vector == nil then
		return false
	end
	self.pic:acknowledge()
	self.cpu.halted = false
	self.irqCount += 1
	self.cpu:interrupt(vector, nil, false)
	return true
end

function Machine.run(self: Machine, maxSteps: number?): number
	local steps = 0
	local idle = 0
	const budget = maxSteps or math.huge
	while steps < budget and not self.exitCode do
		if self.pit then
			const irq = self.pit:advance(1)
			if irq and self.pic then
				self.pic:raise(0)
			end
		end
		if self.pic then
			if self.kbc then
				if self.kbc:takeIrq1() then
					self.pic:raise(1)
				end
				if self.kbc:takeIrq12() then
					self.pic:raise(12)
				end
			end
			if self.ide and self.ide:takeIrq() then
				self.pic:raise(14)
			end
		end
		if self.cpu.halted then
			if not self:deliverInterrupt() then
				idle += 1
				-- A halted CPU waits for the next timer tick; give a full 8254
				-- period (up to 65536 counts) before declaring the machine dead.
				if idle > 200000 then
					break
				end
			else
				idle = 0
			end
		else
			self:deliverInterrupt()
			self.cpu:step()
			idle = 0
		end
		steps += 1
	end
	return steps
end

function Machine.bootPc(self: Machine): string
	return ("%04X:%08X"):format(self.cpu.cs, self.cpu.ip)
end

function Machine.debugText(self: Machine): string
	return table.concat(self.debugLog)
end

function Machine.pressKey(self: Machine, scancode: number)
	if self.kbc then
		self.kbc:pressKey(scancode)
	end
end

function Machine.releaseKey(self: Machine, scancode: number)
	if self.kbc then
		self.kbc:releaseKey(scancode)
	end
end

function Machine.mouseMove(self: Machine, dx: number, dy: number, buttons: number?)
	if self.kbc then
		self.kbc:mouseMove(dx, dy, buttons)
	end
end

-- Diagnostic input path for harnesses that need to drive SeaBIOS before its
-- own PS/2 IRQ handler is installed. Real host input should use pressKey.
function Machine.injectBdaKey(self: Machine, scan: number, ascii: number): boolean
	const head = self.mem:read16(0x41A)
	const tail = self.mem:read16(0x41C)
	local next = tail + 2
	if next > 0x3D then
		next = 0x1E
	end
	if next == head then
		return false
	end
	self.mem:write16(0x400 + tail, bor(band(ascii, 0xFF), lshift(band(scan, 0xFF), 8)))
	self.mem:write16(0x41C, next)
	return true
end

function Machine.outputText(self: Machine): string
	const vga = self.vga
	if not vga or not vga:isTextMode() then
		return ""
	end
	const rows: { string } = {}
	local lastNonEmpty = 0
	for row = 0, 24 do
		const chars: { string } = {}
		for column = 0, 79 do
			const cell = 0xB8000 + (row * 80 + column) * 2
			const code = self.mem:read8(cell)
			chars[column + 1] = string.char(if code >= 32 and code < 127 then code else 32)
		end
		local line = table.concat(chars)
		line = string.gsub(line, "%s+$", "")
		rows[row + 1] = line
		if #line > 0 then
			lastNonEmpty = row + 1
		end
	end
	local out: { string } = {}
	for row = 1, lastNonEmpty do
		out[#out + 1] = rows[row]
	end
	return table.concat(out, "\n")
end

return Machine
