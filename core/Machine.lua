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
-- The ISP side must not share the guest NIC's default MAC (52:54:00:12:34:56).
const DEFAULT_ISP_MAC = "52:54:00:12:34:57"

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
	Dma: any?,
	Sb16: any?,
	Fdc: any?,
	Ne2000: any?,
	Isp: any?,
	Xms: any?,
	Uart: any?,
	Lpt: any?,
}

export type NetworkConfig = {
	mac: string?,
	ispMac: string?,
	ip: string?,
	enabled: boolean?,
}

export type FloppyConfig = {
	image: buffer?,
	writeProtected: boolean?,
	dirty: ((drive: number, lba: number, count: number) -> ())?,
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
	hdd2: buffer?,
	cdrom2: buffer?,
	floppy: FloppyConfig?,
	floppy1: FloppyConfig?,
	network: NetworkConfig?,
	audioSink: ((samples: buffer) -> ())?,
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
		ide2: any?,
		kbc: any?,
		fpu: any?,
		dma: any?,
		sb16: any?,
		fdc: any?,
		ne2000: any?,
		isp: any?,
		xms: any?,
		uart: any?,
		lpt: any?,
		exitCode: number?,
		config: Config,
		pciAddress: number,
		vgaBar: number,
		vgaCommand: number,
		vgaLatency: number,
		vgaRomBar: number,
		vgaRomBarProbe: boolean,
		vgaInterruptLine: number,
		ideBars: { number },
		ideBarProbe: { boolean },
		ideCommand: number,
		ideLatency: number,
		isaConfig: { [number]: number },
		isaCommand: number,
		elcrMaster: number,
		elcrSlave: number,
		sb16Clock: number,
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
local function configDword(config: { [number]: number }, offset: number): number
	local value = 0
	for index = 0, 3 do
		value = bor(value, lshift(band(config[offset + index] or 0, 0xFF), index * 8))
	end
	return value
end

local function vgaDword(machine: any, offset: number): number
	if offset == 0x00 then
		return 0x11111234 -- Bochs VGA, vendor 1234 device 1111
	elseif offset == 0x04 then
		return bor(band(machine.vgaCommand or 7, 0xFFFF), 0x02000000)
	elseif offset == 0x08 then
		return 0x03000001 -- VGA controller, revision 1
	elseif offset == 0x0C then
		return 0x00000000 -- type 0 header
	elseif offset == 0x10 then
		return machine.vgaBar
	elseif offset == 0x2C then
		return 0x11001AF4
	elseif offset == 0x30 then
		if machine.vgaRomBarProbe then
			return 0xFFFFF800
		end
		return machine.vgaRomBar or 0
	elseif offset == 0x3C then
		-- Route VGA through the slot's INTC link (PIRQD on this PIIX3 table)
		-- so the $PIR link and the VGA interrupt line both resolve to IRQ 11.
		return bor(band(machine.vgaInterruptLine or 11, 0xFF), 0x0300)
	elseif offset == 0x40 then
		return band(machine.vgaLatency or 0, 0xFF)
	end
	return 0
end

-- PIIX3 topology: ISA bridge at 00:01.0 (multifunction), IDE at 00:01.1.
-- The IDE function advertises bus-master capability (prog_if 0x80) while both
-- channels remain in legacy mode, so SeaBIOS and the Win98 PIIX3 driver use
-- 0x1F0/0x3F6/IRQ14 and 0x170/0x376/IRQ15.
const IDE_BAR_DEFAULTS = { 0x1F0, 0x3F6, 0x170, 0x376, 0xC000 }
const IDE_BAR_SIZES = { 8, 2, 8, 2, 16 }

local function isaBridgeDword(machine: any, offset: number): number
	if offset == 0x00 then
		return 0x70008086 -- Intel PIIX3 ISA bridge
	elseif offset == 0x04 then
		return bor(band(machine.isaCommand or 0x0007, 0xFFFF), 0x02000000)
	elseif offset == 0x08 then
		return 0x06010000 -- ISA bridge, revision 0
	elseif offset == 0x0C then
		return 0x00800000 -- header type 0x80: multifunction device
	elseif offset == 0x2C then
		return 0x11001AF4 -- Red Hat/QEMU subsystem
	end
	return configDword(machine.isaConfig or {}, offset)
end

local function ideBarMask(index: number): number
	return bit32.bnot(IDE_BAR_SIZES[index] - 1)
end

local function ideBarDword(machine: any, index: number): number
	const mask = ideBarMask(index)
	if machine.ideBarProbe[index] then
		return bor(mask, 1)
	end
	const base = machine.ideBars[index] or IDE_BAR_DEFAULTS[index]
	return bor(band(base, mask), 1)
end

local function ideDword(machine: any, offset: number): number
	if offset == 0x00 then
		return 0x70108086 -- Intel PIIX3 IDE
	elseif offset == 0x04 then
		return bor(band(machine.ideCommand or 0x00000007, 0xFFFF), 0x02800000)
	elseif offset == 0x08 then
		return 0x01018000 -- IDE controller, bus-master programming interface
	elseif offset == 0x0C then
		return 0x00000000 -- type 0 header, single function
	elseif offset >= 0x10 and offset <= 0x20 and band(offset, 3) == 0 then
		const index = math.floor((offset - 0x10) / 4) + 1
		return ideBarDword(machine, index)
	elseif offset == 0x2C then
		return 0x11001AF4
	elseif offset == 0x3C then
		return 0x0000010E -- interrupt line 14, INTA#
	elseif offset == 0x40 then
		return band(machine.ideLatency or 0, 0xFF)
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
			return isaBridgeDword(machine, offset)
		elseif device == 1 and functionNumber == 1 then
			return ideDword(machine, offset)
		elseif device == 2 and functionNumber == 0 then
			return vgaDword(machine, offset)
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
	if bus == 0 and device == 2 and functionNumber == 0 then
		if offset == 0x04 then
			machine.vgaCommand = band(value, 0xFFFF)
		elseif offset == 0x10 then
			-- VGA LFB BAR0: 4 MiB memory BAR at 0xE0000000.
			if value == 0xFFFFFFFF then
				machine.vgaBar = 0xFFC00000
			else
				machine.vgaBar = band(value, 0xFFC00000)
			end
		elseif offset == 0x30 then
			if value == 0xFFFFFFFF then
				machine.vgaRomBarProbe = true
			else
				machine.vgaRomBarProbe = false
				machine.vgaRomBar = bor(band(value, 0xFFFFF800), band(value, 1))
			end
		elseif offset == 0x3C then
			machine.vgaInterruptLine = band(value, 0xFF)
		elseif offset == 0x40 then
			machine.vgaLatency = band(value, 0xFF)
		end
		return
	end
	if bus == 0 and device == 1 and functionNumber == 0 then
		if offset == 0x04 then
			machine.isaCommand = band(value, 0xFFFF)
		elseif offset == 0x3C then
			machine.isaConfig[0x3C] = band(value, 0xFF)
		elseif offset >= 0x40 then
			for index = 0, 3 do
				machine.isaConfig[offset + index] = band(rshift(value, index * 8), 0xFF)
			end
		end
		return
	end
	if bus == 0 and device == 1 and functionNumber == 1 then
		if offset == 0x04 then
			machine.ideCommand = band(value, 0xFFFFFFFF)
			return
		end
		if offset >= 0x10 and offset <= 0x20 and band(offset, 3) == 0 then
			const index = math.floor((offset - 0x10) / 4) + 1
			const mask = ideBarMask(index)
			if value == 0xFFFFFFFF then
				machine.ideBarProbe[index] = true
				return
			end
			machine.ideBarProbe[index] = false
			const base = band(value, mask)
			machine.ideBars[index] = base
			if index == 5 then
				if machine.ide then
					machine.ide.bmBase = base
				end
				if machine.ide2 then
					machine.ide2.bmBase = base + 8
				end
			end
			return
		end
		if offset == 0x40 then
			machine.ideLatency = band(value, 0xFF)
		end
		return
	end
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
		local floppyType = 0
		if cfg.floppy and cfg.floppy.image then
			floppyType = bor(floppyType, 0x40) -- drive A: 1.44M
		end
		if cfg.floppy1 and cfg.floppy1.image then
			floppyType = bor(floppyType, 0x04) -- drive B: 1.44M
		end
		self.cmos = deps.Cmos.new({ memorySize = self.mem.size, floppyType = floppyType })
	end
	if deps.FwCfg then
		self.fwcfg = deps.FwCfg.new(self.mem.size, cfg.vgaRom)
	end
	if deps.Ide then
		self.ide = deps.Ide.new({
			hdd = cfg.hdd,
			cdrom = cfg.cdrom,
			mem = self.mem,
			bmBase = 0xC000,
		})
		self.ide2 = deps.Ide.new({
			hdd = cfg.hdd2,
			cdrom = cfg.cdrom2,
			base = 0x170,
			altBase = 0x376,
			irq = deps.Ide.IRQ_SECONDARY or 15,
			mem = self.mem,
			bmBase = 0xC008,
		})
	end
	const network = cfg.network
	const networkEnabled = network == nil or network.enabled ~= false
	if deps.Ne2000 and networkEnabled then
		self.ne2000 = deps.Ne2000.new({ mac = if network then network.mac else nil })
	end
	if deps.Isp and networkEnabled then
		local ispMac = if network then network.ispMac else nil
		if not ispMac and self.ne2000 then
			ispMac = DEFAULT_ISP_MAC
		end
		self.isp = deps.Isp.new({ mac = ispMac, ip = if network then network.ip else nil })
		if self.ne2000 then
			self.isp:attach(self.ne2000)
		end
	end
	if deps.Kbc then
		self.kbc = deps.Kbc.new()
	end
	if deps.Fpu then
		self.fpu = deps.Fpu.new()
	end
	if deps.Dma then
		self.dma = deps.Dma.new({
			read8 = function(address: number): number
				return self.mem:read8(address)
			end,
			read16 = function(address: number): number
				return self.mem:read16(address)
			end,
			write8 = function(address: number, value: number)
				self.mem:write8(address, value)
			end,
			write16 = function(address: number, value: number)
				self.mem:write16(address, value)
			end,
		})
	end
	if deps.Fdc then
		self.fdc = deps.Fdc.new({
			floppy = cfg.floppy and cfg.floppy.image,
			floppy1 = cfg.floppy1 and cfg.floppy1.image,
			writeProtected = cfg.floppy and cfg.floppy.writeProtected,
			writeProtected1 = cfg.floppy1 and cfg.floppy1.writeProtected,
			dirty = cfg.floppy and cfg.floppy.dirty,
			dirty1 = cfg.floppy1 and cfg.floppy1.dirty,
			dma = self.dma,
		})
	end
	if deps.Sb16 then
		self.sb16 = deps.Sb16.new({
			dma = self.dma,
			dmaChannel = 1,
			irq = 5,
			sink = cfg.audioSink or function(_samples: buffer) end,
		})
	end
	if deps.Uart then
		self.uart = deps.Uart.new(cfg.serial)
	end
	if deps.Lpt then
		self.lpt = deps.Lpt.new(cfg.printer)
	end
	self.pciAddress = 0
	self.vgaBar = 0xE0000000
	self.ideBars = { 0x1F0, 0x3F6, 0x170, 0x376, 0xC000 }
	self.ideBarProbe = { false, false, false, false, false }
	self.ideCommand = 0x00000007
	self.ideLatency = 0
	self.vgaCommand = 0x00000007
	self.vgaLatency = 0
	self.vgaRomBar = 0x000C0001 -- 32 KiB option ROM in the C0000 shadow window
	self.vgaRomBarProbe = false
	self.vgaInterruptLine = 11
	self.isaCommand = 0x00000007
	self.isaConfig = {}
	for index = 0, 0xFF do
		self.isaConfig[index] = 0
	end
	-- PIIX3 reset defaults: PIRQ[A-D] disabled until the firmware routes them.
	for index = 0x60, 0x63 do
		self.isaConfig[index] = 0x80
	end
	self.isaConfig[0x4E] = 0x03
	self.isaConfig[0x4F] = 0x00
	self.isaConfig[0x69] = 0x02
	self.isaConfig[0x70] = 0x80
	self.elcrMaster = 0
	self.elcrSlave = 0
	self.sb16Clock = 0
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
			if
				self.dma
				and (
					port <= 0x0F
					or (port >= 0xC0 and port <= 0xDF)
					or port == 0x81
					or port == 0x82
					or port == 0x83
					or port == 0x87
					or port == 0x89
					or port == 0x8A
					or port == 0x8B
				)
			then
				return self.dma:in8(port)
			end
			if
				self.sb16
				and ((port >= 0x220 and port <= 0x22F) or port == 0x388 or port == 0x389)
			then
				return self.sb16:in8(port)
			end
			if self.kbc and (port == 0x60 or port == 0x64) then
				return self.kbc:in8(port)
			end
			if self.fdc and ((port >= 0x3F0 and port <= 0x3F5) or port == 0x3F7) then
				return self.fdc:in8(port)
			end
			if self.ide and ((port >= 0x1F0 and port <= 0x1F7) or port == 0x3F6) then
				return self.ide:in8(port)
			end
			if self.ide2 and ((port >= 0x170 and port <= 0x177) or port == 0x376) then
				return self.ide2:in8(port)
			end
			const bmBase = self.ideBars[5]
			if bmBase ~= 0 and self.ide and port >= bmBase and port <= bmBase + 7 then
				return self.ide:bmIn8(port)
			end
			if bmBase ~= 0 and self.ide2 and port >= bmBase + 8 and port <= bmBase + 15 then
				return self.ide2:bmIn8(port)
			end
			if self.ne2000 and port >= self.ne2000.base and port <= self.ne2000.base + 0x1F then
				return self.ne2000:in8(port)
			end
			if self.vga and (port == 0x1CE or port == 0x1CF or port == 0x1D0) then
				return self.vga:in8(port)
			end
			if self.vga and port >= 0x3C0 and port <= 0x3DF then
				return self.vga:in8(port)
			end
			if port == 0x4D0 then
				return self.elcrMaster
			elseif port == 0x4D1 then
				return self.elcrSlave
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
			if self.ide2 and port == 0x170 then
				return self.ide2:in16(port)
			end
			const bmBase = self.ideBars[5]
			if bmBase ~= 0 and self.ide and port >= bmBase and port <= bmBase + 7 then
				return self.ide:bmIn16(port)
			end
			if bmBase ~= 0 and self.ide2 and port >= bmBase + 8 and port <= bmBase + 15 then
				return self.ide2:bmIn16(port)
			end
			if self.ne2000 and port >= self.ne2000.base and port <= self.ne2000.base + 0x1F then
				return self.ne2000:in16(port)
			end
			if self.vga and (port == 0x1CE or port == 0x1CF) then
				return self.vga:in16(port)
			end
			if port == PCI_ADDRESS then
				return band(self.pciAddress, 0xFFFF)
			elseif port >= PCI_DATA and port <= PCI_DATA + 2 then
				const lane = port - PCI_DATA
				return band(
					rshift(pciRead(self, band(self.pciAddress, 0xFFFFFFFC)), lane * 8),
					0xFFFF
				)
			end
			return bor(io.in8(port), lshift(io.in8(band(port + 1, 0xFFFF)), 8))
		end,
		in32 = function(port: number): number
			if port == PCI_ADDRESS then
				return self.pciAddress
			elseif port == PCI_DATA then
				return pciRead(self, self.pciAddress)
			end
			if self.ide and port == 0x1F0 then
				return bor(self.ide:in16(port), lshift(self.ide:in16(port), 16))
			end
			if self.ide2 and port == 0x170 then
				return bor(self.ide2:in16(port), lshift(self.ide2:in16(port), 16))
			end
			const bmBase = self.ideBars[5]
			if bmBase ~= 0 and self.ide and port >= bmBase and port <= bmBase + 7 then
				return self.ide:bmIn32(port)
			end
			if bmBase ~= 0 and self.ide2 and port >= bmBase + 8 and port <= bmBase + 15 then
				return self.ide2:bmIn32(port)
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
			if
				self.dma
				and (
					port <= 0x0F
					or (port >= 0xC0 and port <= 0xDF)
					or port == 0x81
					or port == 0x82
					or port == 0x83
					or port == 0x87
					or port == 0x89
					or port == 0x8A
					or port == 0x8B
				)
			then
				self.dma:out8(port, value)
				return
			end
			if
				self.sb16
				and ((port >= 0x220 and port <= 0x22F) or port == 0x388 or port == 0x389)
			then
				self.sb16:out8(port, value)
				return
			end
			if self.kbc and (port == 0x60 or port == 0x64) then
				self.kbc:out8(port, value)
				return
			end
			if self.fdc and ((port >= 0x3F0 and port <= 0x3F5) or port == 0x3F7) then
				self.fdc:out8(port, value)
				return
			end
			if self.ide and ((port >= 0x1F0 and port <= 0x1F7) or port == 0x3F6) then
				self.ide:out8(port, value)
				return
			end
			if self.ide2 and ((port >= 0x170 and port <= 0x177) or port == 0x376) then
				self.ide2:out8(port, value)
				return
			end
			const bmBase = self.ideBars[5]
			if bmBase ~= 0 and self.ide and port >= bmBase and port <= bmBase + 7 then
				self.ide:bmOut8(port, value)
				return
			end
			if bmBase ~= 0 and self.ide2 and port >= bmBase + 8 and port <= bmBase + 15 then
				self.ide2:bmOut8(port, value)
				return
			end
			if self.ne2000 and port >= self.ne2000.base and port <= self.ne2000.base + 0x1F then
				self.ne2000:out8(port, value)
				return
			end
			if self.vga and (port == 0x1CE or port == 0x1CF or port == 0x1D0) then
				self.vga:out8(port, value)
				return
			end
			if self.vga and port >= 0x3C0 and port <= 0x3DF then
				self.vga:out8(port, value)
				return
			end
			if port == 0x4D0 then
				self.elcrMaster = band(value, 0xFF)
				return
			elseif port == 0x4D1 then
				self.elcrSlave = band(value, 0xFF)
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
				const lane = port - PCI_DATA
				const address = band(self.pciAddress, 0xFFFFFFFC)
				const old = pciRead(self, address)
				const shift = lane * 8
				const mask = lshift(0xFF, shift)
				const updated = bor(band(old, bit32.bnot(mask)), lshift(band(value, 0xFF), shift))
				pciWrite(self, address, updated)
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
			if self.ide2 and port == 0x170 then
				self.ide2:out16(port, value)
				return
			end
			const bmBase = self.ideBars[5]
			if bmBase ~= 0 and self.ide and port >= bmBase and port <= bmBase + 7 then
				self.ide:bmOut16(port, value)
				return
			end
			if bmBase ~= 0 and self.ide2 and port >= bmBase + 8 and port <= bmBase + 15 then
				self.ide2:bmOut16(port, value)
				return
			end
			if self.ne2000 and port >= self.ne2000.base and port <= self.ne2000.base + 0x1F then
				self.ne2000:out16(port, value)
				return
			end
			if self.vga and (port == 0x1CE or port == 0x1CF) then
				self.vga:out16(port, value)
				return
			end
			if port == PCI_ADDRESS then
				self.pciAddress = bor(band(self.pciAddress, 0xFFFF0000), band(value, 0xFFFF))
				return
			elseif port >= PCI_DATA and port <= PCI_DATA + 2 then
				const lane = port - PCI_DATA
				const address = band(self.pciAddress, 0xFFFFFFFC)
				const old = pciRead(self, address)
				const shift = lane * 8
				const mask = lshift(0xFFFF, shift)
				pciWrite(
					self,
					address,
					bor(band(old, bit32.bnot(mask)), lshift(band(value, 0xFFFF), shift))
				)
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
			if self.ide and port == 0x1F0 then
				self.ide:out16(port, band(value, 0xFFFF))
				self.ide:out16(port, band(rshift(value, 16), 0xFFFF))
				return
			end
			if self.ide2 and port == 0x170 then
				self.ide2:out16(port, band(value, 0xFFFF))
				self.ide2:out16(port, band(rshift(value, 16), 0xFFFF))
				return
			end
			const bmBase = self.ideBars[5]
			if bmBase ~= 0 and self.ide and port >= bmBase and port <= bmBase + 7 then
				self.ide:bmOut32(port, value)
				return
			end
			if bmBase ~= 0 and self.ide2 and port >= bmBase + 8 and port <= bmBase + 15 then
				self.ide2:bmOut32(port, value)
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
	if self.ide2 then
		self.ide2:reset()
	end
	if self.ne2000 then
		self.ne2000:reset()
	end
	if self.kbc then
		self.kbc:reset()
	end
	if self.dma then
		self.dma:reset()
	end
	if self.fdc then
		self.fdc:reset()
	end
	if self.sb16 then
		self.sb16:resetDsp()
	end
	self.sb16Clock = 0
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
	const cpu = self.cpu
	const pic = self.pic
	const pit = self.pit
	const kbc = self.kbc
	const ide = self.ide
	const ide2 = self.ide2
	const ne2000 = self.ne2000
	const sb16 = self.sb16
	const fdc = self.fdc
	while steps < budget and not self.exitCode do
		if pit then
			if pit:advance(1) and pic then
				pic:raise(0)
			end
		end
		if pic then
			-- Each takeIrq is side-effect free unless its own pending/armed
			-- field is set, so those fields are a cheap equivalent gate.
			if kbc then
				if kbc.irq1Armed and kbc:takeIrq1() then
					pic:raise(1)
				end
				if kbc.irq12Armed and kbc:takeIrq12() then
					pic:raise(12)
				end
			end
			if ide and ide.irqPending and ide:takeIrq() then
				pic:raise(14)
			end
			if ide2 and ide2.irqPending and ide2:takeIrq() then
				pic:raise(15)
			end
			if ne2000 and (ne2000.irqLine or band(ne2000.isr, ne2000.imr) ~= 0) then
				if ne2000:takeIrq() then
					pic:raise(10)
				end
			end
			if sb16 and sb16.irqPending and sb16:takeIrq() then
				pic:raise(5)
			end
			if fdc and fdc.irqPending and fdc:takeIrq() then
				pic:raise(6)
			end
			self.sb16Clock += 1
			if sb16 and self.sb16Clock % 1024 == 0 then
				sb16:tick()
			end
		end
		if cpu.halted then
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
			if pic and band(cpu.flags, 0x200) ~= 0 and cpu.irqDelay == 0 then
				self:deliverInterrupt()
			end
			-- step() only wraps executeStep in tracing/paging support; skip the
			-- extra call in the common unpaged, untraced case.
			if not cpu.traceEnabled and band(cpu.cr0, 0x80000000) == 0 then
				cpu:executeStep()
			else
				cpu:step()
			end
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
