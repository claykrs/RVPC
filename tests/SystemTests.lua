--!nonstrict
-- SystemTests.lua -- 386/486 flat protected mode, paging, V86 and chipset state.

const band, bor, rshift = bit32.band, bit32.bor, bit32.rshift

const Memory = require("../core/Memory")
const Cpu = require("../core/Cpu")
const Vga = require("../core/Vga")
const Pic = require("../core/Pic")
const Pit = require("../core/Pit")
const Cmos = require("../core/Cmos")
const Machine = require("../core/Machine")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function freshMachine()
	return Machine.new({
		Memory = Memory,
		Cpu = Cpu,
		Vga = Vga,
		Pic = Pic,
		Pit = Pit,
		Cmos = Cmos,
	}, { memorySize = 16 * 1024 * 1024, cpu = { cpuLevel = "486" } })
end

local function putCode(m, addr, bytes)
	for index = 1, #bytes do
		m.mem:write8(addr + index - 1, bytes[index])
	end
end

local function writeDescriptor(m, addr, base, limit, access, flags)
	m.mem:write16(addr, band(limit, 0xFFFF))
	m.mem:write16(addr + 2, band(base, 0xFFFF))
	m.mem:write8(addr + 4, band(rshift(base, 16), 0xFF))
	m.mem:write8(addr + 5, access)
	m.mem:write8(addr + 6, bor(band(rshift(limit, 16), 0x0F), band(flags, 0xF0)))
	m.mem:write8(addr + 7, band(rshift(base, 24), 0xFF))
end

local function flat32(m)
	const cpu = m.cpu
	cpu.cr0 = 1
	cpu.cr[0] = 1
	cpu.cs, cpu.ds, cpu.es, cpu.ss = 8, 0x10, 0x10, 0x10
	for _, reg in ipairs({ "cs", "ds", "es", "ss" }) do
		cpu.segBase[reg] = 0
		cpu.segSel[reg] = cpu[reg]
		cpu.segLimit[reg] = 0xFFFFFFFF
		cpu.segFlags[reg] = 0x40
	end
	cpu.segSel.cs = 8
	cpu.segFlags.cs = 0x40
	cpu.ip = 0x1000
	cpu.flags = 2
	cpu:setSP(0x8000)
	-- GDT with null, flat code and flat data descriptors at 0x3000.
	writeDescriptor(m, 0x3000 + 8, 0, 0xFFFFF, 0x9A, 0xCF)
	writeDescriptor(m, 0x3000 + 16, 0, 0xFFFFF, 0x92, 0xCF)
	cpu.gdtr = { base = 0x3000, limit = 0x1F }
end

T("flat32_alu_addressing", function(expect)
	const m = freshMachine()
	flat32(m)
	putCode(m, 0x1000, {
		0xB8,
		0x00,
		0x00,
		0x01,
		0x00, -- MOV EAX,0x10000
		0x05,
		0x56,
		0x34,
		0x02,
		0x00, -- ADD EAX,0x23456
		0xC1,
		0xE0,
		0x04, -- SHL EAX,4
		0xBB,
		0x03,
		0x00,
		0x00,
		0x00, -- MOV EBX,3
		0xF7,
		0xE3, -- MUL EBX
		0x89,
		0x43,
		0x04, -- MOV [EBX+4],EAX
		0x8B,
		0x4B,
		0x04, -- MOV ECX,[EBX+4]
		0xF4,
	})
	m:run(8)
	expect(m.cpu:rr32(0) == 0x99D020, string.format("EAX=%08X", m.cpu:rr32(0)))
	expect(m.cpu:rr32(2) == 0, string.format("EDX=%08X", m.cpu:rr32(2)))
	expect(m.cpu:rr32(1) == 0x99D020, string.format("ECX=%08X", m.cpu:rr32(1)))
	expect(m.mem:read32(7) == 0x99D020, "SIB/displacement store")
end)

T("paging_translation", function(expect)
	const m = freshMachine()
	flat32(m)
	m.mem.a20 = true
	-- PDE0: 4 MiB identity page for code/stack/GDT.
	-- PDE1: virtual 0x400000 -> physical 0x800000 (both 4 MiB aligned).
	m.mem:write32(0x2000, 0x00000083)
	m.mem:write32(0x2004, 0x00800083)
	m.mem:write32(0x00800000, 0xAABBCCDD)
	const cpu = m.cpu
	cpu.cr3 = 0x2000
	cpu.cr[3] = 0x2000
	cpu.cr0 = bor(1, 0x80000000)
	cpu.cr[0] = cpu.cr0
	putCode(m, 0x1000, {
		0xA1,
		0x00,
		0x00,
		0x40,
		0x00, -- MOV EAX,[0x400000]
		0xA3,
		0x04,
		0x00,
		0x40,
		0x00, -- MOV [0x400004],EAX
		0x8B,
		0x0D,
		0x04,
		0x00,
		0x40,
		0x00, -- MOV ECX,[0x400004]
		0xF4,
	})
	m:run(5)
	expect(m.cpu:rr32(0) == 0xAABBCCDD, string.format("EAX=%08X", m.cpu:rr32(0)))
	expect(m.cpu:rr32(1) == 0xAABBCCDD, string.format("ECX=%08X", m.cpu:rr32(1)))
	expect(m.mem:read32(0x00800004) == 0xAABBCCDD, "physical alias write")
	expect(m.cpu.pageFaults == 0, "unexpected page fault")
end)

T("paging_page_fault", function(expect)
	const m = freshMachine()
	flat32(m)
	m.mem.a20 = true
	m.mem:write32(0x2000, 0x00000083) -- PDE0 identity
	m.mem:write32(0x2008, 0x00000000) -- PDE2 (virtual 0x800000) not present
	const cpu = m.cpu
	cpu.cr3 = 0x2000
	cpu.cr[3] = 0x2000
	cpu.cr0 = bor(1, 0x80000000)
	cpu.cr[0] = cpu.cr0
	-- IDT gate 14 -> 32-bit interrupt gate, selector 8, offset 0x6000.
	cpu.idtr = { base = 0x5000, limit = 0x7FF }
	const gate = 0x5000 + 14 * 8
	m.mem:write16(gate, 0x6000)
	m.mem:write16(gate + 2, 8)
	m.mem:write8(gate + 4, 0)
	m.mem:write8(gate + 5, 0x8E)
	m.mem:write16(gate + 6, 0)
	-- Handler records delivery then returns.
	putCode(m, 0x6000, {
		0xC7,
		0x05,
		0x00,
		0x40,
		0x00,
		0x00,
		0x34,
		0x12,
		0x00,
		0x00, -- MOV DWORD [0x4000],0x1234
		0x58, -- POP EAX: discard the #PF error code
		0xCF, -- IRETD
	})
	putCode(m, 0x1000, {
		0xA1,
		0x00,
		0x00,
		0x80,
		0x00, -- MOV EAX,[0x800000]
		0xF4,
	})
	m.cpu:step() -- fault delivery
	expect(cpu.pageFaults == 1, "pageFaults=" .. cpu.pageFaults)
	expect(cpu.lastPageFault ~= nil, "no lastPageFault")
	expect(cpu.lastPageFault and cpu.lastPageFault.errorCode == 0, "errorCode")
	expect(cpu.ip == 0x6000, string.format("handler ip=%X", cpu.ip))
	m.cpu:step() -- handler MOV
	expect(m.mem:read32(0x4000) == 0x1234, "handler did not run")
	m.cpu:step() -- POP error code
	m.cpu:step() -- IRETD
	expect(cpu.ip == 0x1000 or cpu.ip == 0x1005, string.format("return ip=%X", cpu.ip))
end)

T("v86_entry_and_execution", function(expect)
	const m = freshMachine()
	flat32(m)
	const cpu = m.cpu
	-- IRETD frame: GS FS DS ES SS ESP EFLAGS CS EIP
	cpu:push32(0) -- GS
	cpu:push32(0) -- FS
	cpu:push32(0) -- DS
	cpu:push32(0) -- ES
	cpu:push32(0x2000) -- SS
	cpu:push32(0xFFFE) -- ESP
	cpu:push32(0x00020202) -- EFLAGS, VM=1, IF=1
	cpu:push32(0x1000) -- CS
	cpu:push32(0x00000000) -- EIP
	putCode(m, 0x1000, { 0xCF }) -- IRETD
	putCode(m, 0x10000, { 0xB8, 0x34, 0x12, 0xF4 }) -- MOV AX,0x1234; HLT
	m.cpu:step()
	expect(cpu:isV86(), "not in V86")
	expect(cpu:cpl() == 3, "CPL=" .. cpu:cpl())
	expect(cpu.cs == 0x1000, string.format("CS=%04X", cpu.cs))
	expect(cpu.segBase.cs == 0x10000, string.format("CS base=%X", cpu.segBase.cs))
	expect(cpu.ip == 0, string.format("EIP=%X", cpu.ip))
	m.cpu:step()
	expect(cpu.r[1] == 0x1234, string.format("AX=%04X", cpu.r[1]))
end)

T("vga_modes_12_13_and_text", function(expect)
	const m = freshMachine()
	const vga = m.vga
	expect(vga:setMode(0x12), "mode 12 rejected")
	expect(vga:width() == 640 and vga:height() == 480, "mode 12 geometry")
	vga:write8(0xA0000, 0x0F)
	expect(vga:read8(0xA0000) == 0x0F, "planar write/read")
	const planar = vga:snapshotRGBA()
	expect(buffer.len(planar) == 640 * 480 * 4, "mode 12 RGBA size")

	expect(vga:setMode(0x13), "mode 13 rejected")
	expect(vga:width() == 320 and vga:height() == 200, "mode 13 geometry")
	vga:write8(0xA0000, 0x0F)
	expect(vga:read8(0xA0000) == 0x0F, "linear write/read")
	const linear = vga:snapshotRGBA()
	expect(buffer.len(linear) == 320 * 200 * 4, "mode 13 RGBA size")

	expect(vga:setMode(0x03), "mode 3 rejected")
	expect(vga:isTextMode(), "mode 3 not text")
	vga:writeText(0, 0, "RVPC", 0x0F)
	expect(m.mem:read8(0xB8000) == string.byte("R"), "text cell")
end)

T("pic_program_and_eoi", function(expect)
	const pic = Pic.new()
	-- Master: ICW1 edge, ICW2 base 0x20, ICW3 cascade IRQ2, ICW4 8086 mode.
	pic:out8(0x20, 0x11)
	pic:out8(0x21, 0x20)
	pic:out8(0x21, 0x04)
	pic:out8(0x21, 0x01)
	pic:out8(0xA0, 0x11)
	pic:out8(0xA1, 0x28)
	pic:out8(0xA1, 0x02)
	pic:out8(0xA1, 0x01)
	expect(pic.master.vectorBase == 0x20, "master base")
	expect(pic.slave.vectorBase == 0x28, "slave base")
	pic:out8(0x21, 0xFA) -- unmask IRQ0 and the IRQ2 cascade, mask IRQ1
	pic:raise(0)
	expect(pic:nextPending() == 0x20, "IRQ0 vector")
	const vector, irq = pic:acknowledge()
	expect(vector == 0x20 and irq == 0, "ack IRQ0")
	expect(pic.master.isr == 0x01, "ISR")
	pic:eoi(nil)
	expect(pic.master.isr == 0, "EOI did not clear ISR")
	pic:raise(1)
	expect(pic:nextPending() == nil, "masked IRQ1 delivered")
	pic:out8(0xA1, 0xFE) -- unmask slave IRQ0
	pic:raise(8)
	expect(pic:nextPending() == 0x28, "slave IRQ8 vector")
	const v2 = pic:acknowledge()
	expect(v2 == 0x28, "ack IRQ8")
	pic:eoi(8)
	expect(pic.slave.isr == 0 and pic.master.isr == 0, "slave EOI")
end)

T("pit_counter_and_irq", function(expect)
	const pit = Pit.new()
	pit:out8(0x43, 0x34) -- channel 0, LSB/MSB, mode 2, binary
	pit:out8(0x40, 0xE8)
	pit:out8(0x40, 0x03) -- divisor 1000
	expect(pit.channels[1].reload == 1000, "reload")
	const before = pit.channels[1].counter
	pit:advance(10)
	const after = pit.channels[1].counter
	expect(after ~= before, "counter did not advance")
	expect(not pit:advance(100), "IRQ before wrap")
	expect(pit:advance(2000), "IRQ on wrap")
	expect(pit.irqPending, "irqPending")
end)

T("cmos_memory_and_shutdown", function(expect)
	const cmos = Cmos.new({ memorySize = 32 * 1024 * 1024 })
	cmos:out8(0x70, 0x30)
	const low = cmos:in8(0x71)
	cmos:out8(0x70, 0x31)
	const high = cmos:in8(0x71)
	expect(low == 0x00 and high == 0x7C, string.format("extmem=%02X%02X", high, low))
	cmos:out8(0x70, 0x0F)
	cmos:out8(0x71, 0x0A)
	cmos:out8(0x70, 0x0F)
	expect(cmos:in8(0x71) == 0x0A, "shutdown byte")
	cmos:out8(0x70, 0x0B)
	expect(cmos:in8(0x71) == 0x02, "status B")
end)

T("rtc_periodic_irq8_status_c", function(expect)
	const m = freshMachine()
	const io = m.cpu.io
	-- SeaBIOS programs status A=0x26 (1024 Hz periodic) and then enables
	-- PIE in status B when INT 15h/AH=86h arms a user timer.
	io.out8(0x70, 0x0A)
	io.out8(0x71, 0x26)
	io.out8(0x70, 0x0B)
	io.out8(0x71, 0x42) -- 24-hour + periodic interrupt enable
	io.out8(0x70, 0x0B)
	expect(io.in8(0x71) == 0x42, "status B readback")
	io.out8(0x70, 0x0C)
	expect(io.in8(0x71) == 0x00, "status C initially clear")
	-- IF=0 so the IRQ stays pending in the PIC and is observable.
	putCode(m, 0x1000, { 0x90, 0xEB, 0xFD }) -- NOP; JMP $
	m.cpu.cs = 0
	m.cpu.segBase.cs = 0
	m.cpu.segSel.cs = 0
	m.cpu.segLimit.cs = 0xFFFF
	m.cpu.segFlags.cs = 0
	m.cpu.ip = 0x1000
	m.cpu.flags = 2
	m:run(1300)
	expect(band(m.pic.slave.irr, 1) ~= 0, "RTC periodic did not set slave IRQ0")
	io.out8(0x70, 0x0C)
	expect(band(io.in8(0x71), 0x40) ~= 0, "status C PF not set")
	expect(io.in8(0x71) == 0x00, "status C did not clear on read")
end)

-- Hardware task switches: task A runs flat-32 at selector 8 with its TSS
-- pre-loaded into TR (LTR ran earlier in a real guest). Task B's TSS holds a
-- register image; the tests verify save/restore, back-link/NT nesting and the
-- busy-bit bookkeeping in both directions.
const NT_FLAG = 0x4000

local function taskSwitchSetup(m)
	flat32(m)
	const cpu = m.cpu
	-- Task A TSS at 0x4000 (selector 0x28, busy like LTR leaves it), task B
	-- TSS at 0x5000 (selector 0x20, available).
	writeDescriptor(m, 0x3028, 0x4000, 0x67, 0x8B, 0)
	writeDescriptor(m, 0x3020, 0x5000, 0x67, 0x89, 0)
	cpu.gdtr = { base = 0x3000, limit = 0x37 }
	-- B's register image: resume at 0x2000 with EAX=0xBEEF, stack at 0x7000.
	m.mem:write32(0x5000 + 0x1C, 0)
	m.mem:write32(0x5000 + 0x20, 0x2000)
	m.mem:write32(0x5000 + 0x24, 2)
	m.mem:write32(0x5000 + 0x28, 0xBEEF)
	m.mem:write32(0x5000 + 0x38, 0x7000)
	m.mem:write32(0x5000 + 0x48, 0x10)
	m.mem:write32(0x5000 + 0x4C, 8)
	m.mem:write32(0x5000 + 0x50, 0x10)
	m.mem:write32(0x5000 + 0x54, 0x10)
	m.mem:write32(0x5000 + 0x58, 0)
	m.mem:write32(0x5000 + 0x5C, 0)
	cpu.tr = 0x28
	cpu.trBase = 0x4000
	cpu.trLimit = 0x67
	cpu.tr32 = true
	-- IDT with one task gate for INT 0x80 pointing at B's TSS.
	cpu.idtr = { base = 0x6000, limit = 0x7FF }
	writeDescriptor(m, 0x6400, 0, 0x20, 0x85, 0)
	m.mem:write16(0x6400 + 2, 0x20)
	putCode(m, 0x1000, {
		0xB8,
		0x11,
		0x11,
		0x00,
		0x00, -- MOV EAX,0x1111
	})
	putCode(m, 0x2000, {
		0xBB,
		0x22,
		0x22,
		0x00,
		0x00, -- MOV EBX,0x2222
		0xF4, -- HLT
	})
	return cpu
end

T("task_gate_interrupt", function(expect)
	const m = freshMachine()
	const cpu = taskSwitchSetup(m)
	putCode(m, 0x1005, { 0xCD, 0x80, 0xF4 }) -- INT 0x80; HLT
	m:run(40)
	expect(cpu:rr32(3) == 0x2222, string.format("EBX=%08X", cpu:rr32(3)))
	expect(cpu:rr32(0) == 0xBEEF, string.format("EAX=%08X", cpu:rr32(0)))
	expect(cpu.tr == 0x20, string.format("TR=%04X", cpu.tr))
	expect(band(cpu.flags, NT_FLAG) ~= 0, "NT set in the new task")
	expect(m.mem:read16(0x5000) == 0x28, string.format("back-link=%04X", m.mem:read16(0x5000)))
	expect(m.mem:read32(0x4000 + 0x20) == 0x1007, "A saved EIP after INT")
	expect(m.mem:read32(0x4000 + 0x28) == 0x1111, "A saved EAX")
	expect(m.mem:read32(0x4000 + 0x4C) == 8, "A saved CS")
	expect(m.mem:read8(0x3020 + 5) == 0x8B, "B marked busy")
	expect(m.mem:read8(0x3028 + 5) == 0x8B, "A stays busy on a nested switch")
end)

T("task_switch_iret_backlink", function(expect)
	const m = freshMachine()
	const cpu = taskSwitchSetup(m)
	putCode(m, 0x1005, { 0xCD, 0x80, 0xB9, 0x33, 0x33, 0x00, 0x00, 0xF4 }) -- INT 0x80; MOV ECX,0x3333; HLT
	putCode(m, 0x2000, { 0xCF, 0xF4 }) -- IRET (task switch); HLT
	m:run(60)
	expect(cpu:rr32(1) == 0x3333, string.format("ECX=%08X", cpu:rr32(1)))
	expect(cpu:rr32(0) == 0x1111, string.format("EAX=%08X", cpu:rr32(0)))
	expect(cpu.tr == 0x28, string.format("TR=%04X", cpu.tr))
	expect(cpu.ip == 0x100D, string.format("EIP=%04X", cpu.ip))
	expect(m.mem:read8(0x3028 + 5) == 0x8B, "resumed task stays busy")
	expect(m.mem:read8(0x3020 + 5) == 0x89, "returning task unbusies")
end)

T("task_switch_far_jmp", function(expect)
	const m = freshMachine()
	const cpu = taskSwitchSetup(m)
	-- Far JMP to the TSS: no nesting, so no back-link, no NT, and A unbusies.
	putCode(m, 0x1005, { 0xEA, 0x00, 0x00, 0x00, 0x00, 0x20, 0x00, 0xF4 })
	m:run(40)
	expect(cpu:rr32(3) == 0x2222, string.format("EBX=%08X", cpu:rr32(3)))
	expect(cpu:rr32(0) == 0xBEEF, string.format("EAX=%08X", cpu:rr32(0)))
	expect(cpu.tr == 0x20, string.format("TR=%04X", cpu.tr))
	expect(band(cpu.flags, NT_FLAG) == 0, "no NT on a JMP switch")
	expect(m.mem:read16(0x5000) == 0, "no back-link on a JMP switch")
	expect(m.mem:read8(0x3020 + 5) == 0x8B, "B marked busy")
	expect(m.mem:read8(0x3028 + 5) == 0x89, "A unbusies on a JMP switch")
end)

T("ppi_timer2_output_drives_bit5", function(expect)
	const m = freshMachine()
	const pit = m.pit
	pit:out8(0x43, 0xB0) -- channel 2, LSB/MSB, mode 0, binary
	pit:out8(0x42, 0x00)
	pit:out8(0x42, 0x08) -- divisor 0x0800
	expect(band(m.cpu.io.in8(0x61), 0x20) == 0, "PPI bit5 high before terminal count")
	pit:advance(0x7FF)
	expect(band(m.cpu.io.in8(0x61), 0x20) == 0, "PPI bit5 high one count early")
	pit:advance(1)
	expect(band(m.cpu.io.in8(0x61), 0x20) ~= 0, "PPI bit5 did not follow PIT2 terminal count")
	pit:advance(0x800)
	expect(band(m.cpu.io.in8(0x61), 0x20) ~= 0, "mode 0 output did not stay high")
end)

T("halted_cpu_advances_tsc", function(expect)
	const m = freshMachine()
	m.cpu.flags = 2 -- IF=0: no interrupt delivery while we measure idle time
	m.cpu.halted = true
	const before = m.cpu.tsc
	const steps = m:run(100_000)
	expect(steps == 100_000, string.format("steps=%d", steps))
	expect(m.cpu.tsc - before >= 100_000, string.format("tsc=%d before=%d", m.cpu.tsc, before))
	expect(m.cpu.halted, "idle CPU unexpectedly woke without an interrupt")
end)

local function cmosRead(cmos, index)
	cmos:out8(0x70, band(index, 0x7F))
	return cmos:in8(0x71)
end

local function cmosWrite(cmos, index, value)
	cmos:out8(0x70, band(index, 0x7F))
	cmos:out8(0x71, band(value, 0xFF))
end

local function toBcd(value)
	return math.floor(value / 10) * 16 + value % 10
end

local function fromBcd(value)
	return math.floor(value / 16) * 10 + value % 16
end

T("rtc_bcd_binary_and_12_24_hour", function(expect)
	const cmos = Cmos.new()
	-- Deterministic epoch: 2026-01-01 12:00:00, Thursday (Sunday = 1).
	expect(cmosRead(cmos, 0x00) == 0x00, "seconds")
	expect(cmosRead(cmos, 0x02) == 0x00, "minutes")
	expect(cmosRead(cmos, 0x04) == 0x12, "noon in BCD 24-hour")
	expect(cmosRead(cmos, 0x06) == 0x05, "day of week")
	expect(cmosRead(cmos, 0x07) == 0x01, "day")
	expect(cmosRead(cmos, 0x08) == 0x01, "month")
	expect(cmosRead(cmos, 0x09) == 0x26, "year")
	expect(cmosRead(cmos, 0x32) == 0x20, "century")

	cmosWrite(cmos, 0x0B, 0x06) -- binary, 24-hour
	expect(cmosRead(cmos, 0x04) == 12, "binary hour")
	expect(cmosRead(cmos, 0x06) == 5, "binary day of week")
	expect(cmosRead(cmos, 0x09) == 26, "binary year")
	expect(cmosRead(cmos, 0x32) == 20, "binary century")

	cmosWrite(cmos, 0x0B, 0x00) -- BCD, 12-hour
	expect(cmosRead(cmos, 0x04) == 0x92, "BCD 12-hour noon carries PM")
	cmosWrite(cmos, 0x0B, 0x04) -- binary, 12-hour
	expect(cmosRead(cmos, 0x04) == 0x8C, "binary 12-hour noon carries PM")

	-- Midnight is 12 AM in 12-hour mode.
	cmosWrite(cmos, 0x04, 0x0C)
	cmosWrite(cmos, 0x0B, 0x00)
	expect(cmosRead(cmos, 0x04) == 0x12, "BCD midnight is 12 AM")
	cmosWrite(cmos, 0x0B, 0x04)
	expect(cmosRead(cmos, 0x04) == 0x0C, "binary midnight is 12 AM")

	-- 1 PM round-trips through the 12-hour and 24-hour views.
	cmosWrite(cmos, 0x04, 0x81)
	cmosWrite(cmos, 0x0B, 0x02)
	expect(cmosRead(cmos, 0x04) == 0x13, "1 PM in BCD 24-hour")

	-- Invalid values are ignored rather than corrupting the fields.
	cmosWrite(cmos, 0x00, 0x6A)
	expect(cmosRead(cmos, 0x00) == 0x00, "invalid BCD seconds ignored")
	cmosWrite(cmos, 0x00, 0x07)
	expect(cmosRead(cmos, 0x00) == 0x07, "valid seconds accepted")
end)

T("rtc_set_time_date_rollover_and_leap", function(expect)
	const cmos = Cmos.new()
	cmosWrite(cmos, 0x0B, 0x02) -- BCD, 24-hour
	-- 1999-12-31 23:59:59, Friday.
	cmosWrite(cmos, 0x00, 0x59)
	cmosWrite(cmos, 0x02, 0x59)
	cmosWrite(cmos, 0x04, 0x23)
	cmosWrite(cmos, 0x06, 0x05)
	cmosWrite(cmos, 0x07, 0x31)
	cmosWrite(cmos, 0x08, 0x12)
	cmosWrite(cmos, 0x09, 0x99)
	cmosWrite(cmos, 0x32, 0x19)
	expect(cmosRead(cmos, 0x09) == 0x99 and cmosRead(cmos, 0x32) == 0x19, "1999 readback")

	cmos:advanceSeconds(1)
	expect(cmosRead(cmos, 0x00) == 0x00 and cmosRead(cmos, 0x02) == 0x00, "midnight time")
	expect(cmosRead(cmos, 0x04) == 0x00, "midnight hour")
	expect(cmosRead(cmos, 0x07) == 0x01 and cmosRead(cmos, 0x08) == 0x01, "year rollover date")
	expect(cmosRead(cmos, 0x09) == 0x00 and cmosRead(cmos, 0x32) == 0x20, "century rollover")
	expect(cmosRead(cmos, 0x06) == 0x06, "day of week rolls forward")

	-- 30-day month rollover.
	cmosWrite(cmos, 0x07, 0x30)
	cmosWrite(cmos, 0x08, 0x04)
	cmosWrite(cmos, 0x09, 0x26)
	cmosWrite(cmos, 0x32, 0x20)
	cmosWrite(cmos, 0x04, 0x23)
	cmosWrite(cmos, 0x02, 0x59)
	cmosWrite(cmos, 0x00, 0x59)
	cmos:advanceSeconds(1)
	expect(cmosRead(cmos, 0x07) == 0x01 and cmosRead(cmos, 0x08) == 0x05, "April 30 -> May 1")

	-- 2000 is a leap year: February 29 exists.
	cmosWrite(cmos, 0x07, 0x28)
	cmosWrite(cmos, 0x08, 0x02)
	cmosWrite(cmos, 0x09, 0x00)
	cmosWrite(cmos, 0x32, 0x20)
	cmosWrite(cmos, 0x04, 0x23)
	cmosWrite(cmos, 0x02, 0x59)
	cmosWrite(cmos, 0x00, 0x59)
	cmos:advanceSeconds(1)
	expect(cmosRead(cmos, 0x07) == 0x29 and cmosRead(cmos, 0x08) == 0x02, "2000 leap day")
	cmos:advanceSeconds(86400)
	expect(cmosRead(cmos, 0x07) == 0x01 and cmosRead(cmos, 0x08) == 0x03, "February 29 -> March 1")

	-- 1900 is not a leap year.
	cmosWrite(cmos, 0x07, 0x28)
	cmosWrite(cmos, 0x08, 0x02)
	cmosWrite(cmos, 0x09, 0x00)
	cmosWrite(cmos, 0x32, 0x19)
	cmosWrite(cmos, 0x04, 0x23)
	cmosWrite(cmos, 0x02, 0x59)
	cmosWrite(cmos, 0x00, 0x59)
	cmos:advanceSeconds(1)
	expect(cmosRead(cmos, 0x07) == 0x01 and cmosRead(cmos, 0x08) == 0x03, "1900 is not leap")
end)

T("rtc_uip_and_set_bit", function(expect)
	const cmos = Cmos.new()
	expect(band(cmosRead(cmos, 0x0A), 0x7F) == 0x26, "status A divider/rate")
	cmos:advance(cmos.stepsPerSecond - cmos.uipSteps - 1)
	expect(band(cmosRead(cmos, 0x0A), 0x80) == 0, "UIP before update window")
	cmos:advance(1)
	expect(band(cmosRead(cmos, 0x0A), 0x80) ~= 0, "UIP inside update window")
	cmos:advance(cmos.uipSteps)
	expect(cmosRead(cmos, 0x00) == 0x01, "second advanced at update")
	expect(band(cmosRead(cmos, 0x0A), 0x80) == 0, "UIP cleared after update")

	cmosWrite(cmos, 0x0B, 0x82) -- SET, 24-hour, BCD
	expect(band(cmosRead(cmos, 0x0A), 0x80) == 0, "SET suppresses UIP")
	const before = cmosRead(cmos, 0x00)
	cmos:advance(cmos.stepsPerSecond * 2)
	expect(cmosRead(cmos, 0x00) == before, "SET froze the clock")
	cmosWrite(cmos, 0x0B, 0x02) -- clear SET
	cmos:advance(cmos.stepsPerSecond)
	expect(cmosRead(cmos, 0x00) == toBcd(2), "clock resumed after SET")
end)

T("rtc_status_c_periodic_update_alarm", function(expect)
	const cmos = Cmos.new()
	expect(cmos.rtc.period == 1165, "default 1024 Hz periodic period")
	cmosWrite(cmos, 0x0A, 0x36) -- divider bits are stored
	expect(band(cmosRead(cmos, 0x0A), 0x70) == 0x30, "divider readback")
	cmosWrite(cmos, 0x0A, 0x20) -- rate zero disables the periodic timer
	expect(cmos.rtc.period == 0, "rate zero period")
	cmosWrite(cmos, 0x0A, 0x26)
	cmosWrite(cmos, 0x0B, 0x42) -- 24-hour, BCD, PIE
	expect(cmosRead(cmos, 0x0C) == 0x00, "status C initially clear")
	cmos:advance(cmos.rtc.period)
	expect(cmosRead(cmos, 0x0C) == 0xC0, "periodic PF and IRQF")
	cmosWrite(cmos, 0x0B, 0x02) -- PIE off
	cmos:advance(cmos.rtc.period * 2)
	expect(cmosRead(cmos, 0x0C) == 0x00, "periodic PF while PIE off")

	cmosWrite(cmos, 0x0B, 0x12) -- UIE
	cmos.rtc.clockTicks = cmos.stepsPerSecond - 1
	cmos:advance(1)
	expect(cmosRead(cmos, 0x0C) == 0x90, "update UF and IRQF")
	cmosWrite(cmos, 0x0B, 0x02) -- UIE off
	cmos.rtc.clockTicks = cmos.stepsPerSecond - 1
	cmos:advance(1)
	expect(cmosRead(cmos, 0x0C) == 0x10, "update UF without IRQF")

	-- Alarm seconds matching with minute/hour wildcards.
	local second = fromBcd(cmosRead(cmos, 0x00))
	cmosWrite(cmos, 0x01, toBcd((second + 1) % 60))
	cmosWrite(cmos, 0x03, 0xC0)
	cmosWrite(cmos, 0x05, 0xC0)
	cmosWrite(cmos, 0x0B, 0x22) -- AIE
	cmos:advanceSeconds(1)
	expect(cmosRead(cmos, 0x0C) == 0xB0, "alarm AF, UF and IRQF")
	second = fromBcd(cmosRead(cmos, 0x00))
	cmosWrite(cmos, 0x01, toBcd((second + 1) % 60))
	cmosWrite(cmos, 0x0B, 0x02) -- AIE off
	cmos:advanceSeconds(1)
	expect(cmosRead(cmos, 0x0C) == 0x30, "alarm AF without IRQF")
end)

T("rtc_update_and_alarm_raise_irq8", function(expect)
	const m = freshMachine()
	const io = m.cpu.io
	putCode(m, 0x1000, { 0x90, 0xEB, 0xFD }) -- NOP; JMP $
	m.cpu.cs = 0
	m.cpu.segBase.cs = 0
	m.cpu.segSel.cs = 0
	m.cpu.segLimit.cs = 0xFFFF
	m.cpu.segFlags.cs = 0
	m.cpu.ip = 0x1000
	m.cpu.flags = 2
	m.cpu:setSP(0x8000)

	-- An update sets UF even with UIE off and must not raise IRQ8.
	io.out8(0x70, 0x0B)
	io.out8(0x71, 0x02) -- UIE off
	m.cmos.rtc.clockTicks = m.cmos.stepsPerSecond - 1
	m:run(1)
	expect(band(m.pic.slave.irr, 1) == 0, "UF without UIE raised IRQ8")
	-- Enabling UIE with UF already pending raises IRQ8 immediately.
	io.out8(0x70, 0x0B)
	io.out8(0x71, 0x12) -- UIE
	expect(band(m.pic.slave.irr, 1) ~= 0, "enabling UIE with UF pending did not raise IRQ8")
	io.out8(0x70, 0x0C)
	expect(band(io.in8(0x71), 0x10) ~= 0, "status C UF")
	m.pic.slave.irr = 0
	m.pic:syncCascade()

	-- Alarm interrupt at the next second.
	io.out8(0x70, 0x00)
	const second = fromBcd(io.in8(0x71))
	io.out8(0x70, 0x01)
	io.out8(0x71, toBcd((second + 1) % 60))
	io.out8(0x70, 0x03)
	io.out8(0x71, 0xC0)
	io.out8(0x70, 0x05)
	io.out8(0x71, 0xC0)
	io.out8(0x70, 0x0B)
	io.out8(0x71, 0x22) -- AIE
	m.cmos.rtc.clockTicks = m.cmos.stepsPerSecond - 1
	m:run(1)
	expect(band(m.pic.slave.irr, 1) ~= 0, "alarm did not raise IRQ8")
	io.out8(0x70, 0x0C)
	const flags = io.in8(0x71)
	expect(band(flags, 0x20) ~= 0, "status C AF")
	expect(band(flags, 0x10) ~= 0, "status C UF with alarm")
end)

T("rtc_periodic_wait_terminates_like_int15_ah86", function(expect)
	const m = freshMachine()
	const cpu = m.cpu
	-- Unmask the IRQ2 cascade and slave IRQ0; default vectors are 08h/70h.
	m.pic:out8(0x21, 0xFA)
	m.pic:out8(0xA1, 0xFE)
	-- INT 70h: bump [2000], acknowledge status C, EOI both PICs, IRET.
	putCode(m, 0x1200, {
		0xFE,
		0x06,
		0x00,
		0x20, -- INC byte [2000]
		0x50, -- PUSH AX
		0xB0,
		0x0C,
		0xE6,
		0x70, -- MOV AL,0Ch; OUT 70h,AL
		0xE4,
		0x71, -- IN AL,71h (clear status C)
		0xB0,
		0x20,
		0xE6,
		0xA0, -- MOV AL,20h; OUT A0h,AL
		0xE6,
		0x20, -- OUT 20h,AL
		0x58, -- POP AX
		0xCF, -- IRET
	})
	m.mem:write16(0x70 * 4, 0x0200)
	m.mem:write16(0x70 * 4 + 2, 0x0100)
	-- Wait for three RTC ticks, then stop.
	putCode(m, 0x1000, {
		0xFB, -- STI
		0x80,
		0x3E,
		0x00,
		0x20,
		0x03, -- CMP byte [2000],3
		0x72,
		0xF8, -- JB 1000
		0xFA, -- CLI
		0xF4, -- HLT
		0xEB,
		0xFD, -- JMP $
	})
	cpu:loadSeg("cs", 0x0100)
	cpu:loadSeg("ds", 0x0100)
	cpu:loadSeg("ss", 0x0100)
	cpu.ip = 0
	cpu.r[5] = 0xFFFE
	cpu.flags = 2
	cpu.halted = false

	const io = m.cpu.io
	io.out8(0x70, 0x0A)
	io.out8(0x71, 0x26) -- 1024 Hz periodic
	io.out8(0x70, 0x0B)
	io.out8(0x71, 0x42) -- PIE
	m:run(10000)
	expect(m.mem:read8(0x3000) >= 3, "periodic IRQ8 did not drive the wait")
	expect(cpu.halted, "periodic wait did not terminate")
end)

return TESTS
