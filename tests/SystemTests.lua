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

return TESTS
