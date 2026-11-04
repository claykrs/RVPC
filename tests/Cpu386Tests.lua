--!nonstrict
-- Cpu386Tests.lua -- 386/486 mode transitions, fault restart and 32-bit stacks.

const band, bor, rshift = bit32.band, bit32.bor, bit32.rshift
const VM = 0x20000

const Memory = require("../core/Memory")
const Cpu = require("../core/Cpu")
const Machine = require("../core/Machine")
const Pic = require("../core/Pic")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function freshMachine()
	return Machine.new({ Memory = Memory, Cpu = Cpu }, {
		memorySize = 16 * 1024 * 1024,
		cpu = { cpuLevel = "486" },
	})
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
	cpu.ip = 0x1000
	cpu.flags = 2
	cpu:setSP(0x8000)
	writeDescriptor(m, 0x3000 + 8, 0, 0xFFFFF, 0x9A, 0xCF)
	writeDescriptor(m, 0x3000 + 16, 0, 0xFFFFF, 0x92, 0xCF)
	writeDescriptor(m, 0x3000 + 24, 0x4000, 0x67, 0x89, 0x00)
	cpu.gdtr = { base = 0x3000, limit = 0x1F }
end

local function installGate(m, vector, offset, selector, access)
	const gate = 0x5000 + vector * 8
	m.mem:write16(gate, band(offset, 0xFFFF))
	m.mem:write16(gate + 2, selector)
	m.mem:write8(gate + 4, 0)
	m.mem:write8(gate + 5, access)
	m.mem:write16(gate + 6, band(rshift(offset, 16), 0xFFFF))
	m.cpu.idtr = { base = 0x5000, limit = 0x7FF }
end

T("test_eax_imm32", function(expect)
	const m = freshMachine()
	flat32(m)
	putCode(m, 0x1000, {
		0xB8,
		0xF0,
		0xF0,
		0xF0,
		0xF0, -- MOV EAX,0xF0F0F0F0
		0xA9,
		0x0F,
		0x0F,
		0x0F,
		0x0F, -- TEST EAX,0x0F0F0F0F
		0xF4,
	})
	m:run(3)
	expect(m.cpu:rr32(0) == 0xF0F0F0F0, string.format("EAX=%08X", m.cpu:rr32(0)))
	expect(m.cpu:getF(64), "ZF not set by 32-bit TEST")
end)

T("far_call_retf_32_balances_stack", function(expect)
	const m = freshMachine()
	flat32(m)
	const before = m.cpu:getSP()
	putCode(m, 0x1000, {
		0x9A,
		0x00,
		0x20,
		0x00,
		0x00,
		0x08,
		0x00, -- CALL FAR 0008:00002000
		0xB8,
		0x34,
		0x12,
		0x00,
		0x00, -- MOV EAX,0x1234
		0xF4,
	})
	putCode(m, 0x2000, { 0xCB }) -- RETF
	m:run(4)
	expect(m.cpu:rr32(0) == 0x1234, string.format("EAX=%08X", m.cpu:rr32(0)))
	expect(m.cpu:getSP() == before, string.format("ESP=%08X want %08X", m.cpu:getSP(), before))
end)

T("page_fault_restarts_faulting_instruction", function(expect)
	const m = freshMachine()
	flat32(m)
	m.mem.a20 = true
	-- PDE0 is a 4 MiB identity page; PDE2 (virtual 0x800000) starts absent.
	m.mem:write32(0x2000, 0x00000083)
	m.mem:write32(0x2008, 0)
	m.mem:write32(0x00800000, 0xAABBCCDD)
	const cpu = m.cpu
	cpu.cr3 = 0x2000
	cpu.cr[3] = 0x2000
	cpu.cr0 = bor(1, 0x80000000)
	cpu.cr[0] = cpu.cr0
	installGate(m, 14, 0x6000, 8, 0x8E)
	-- Handler records the #PF error code, installs the missing 4 MiB page,
	-- discards the error code and retries the faulting MOV.
	putCode(m, 0x6000, {
		0x58, -- POP EAX
		0xA3,
		0x00,
		0x40,
		0x00,
		0x00, -- MOV [0x4000],EAX
		0xC7,
		0x05,
		0x08,
		0x20,
		0x00,
		0x00,
		0x83,
		0x00,
		0x80,
		0x00, -- MOV DWORD [0x2008],0x00800083
		0xCF, -- IRETD
	})
	putCode(m, 0x1000, {
		0xA1,
		0x00,
		0x00,
		0x80,
		0x00, -- MOV EAX,[0x800000]
		0xA3,
		0x04,
		0x00,
		0x80,
		0x00, -- MOV [0x800004],EAX
		0xF4,
	})
	m:run(12)
	expect(cpu.pageFaults == 1, "pageFaults=" .. cpu.pageFaults)
	expect(m.mem:read32(0x4000) == 0, "PF error code")
	expect(cpu:rr32(0) == 0xAABBCCDD, string.format("EAX=%08X", cpu:rr32(0)))
	expect(m.mem:read32(0x00800004) == 0xAABBCCDD, "instruction did not restart")
end)

T("page_fault_write_protection_error_code", function(expect)
	const m = freshMachine()
	flat32(m)
	m.mem.a20 = true
	-- PDE0 is a writable 4 MiB identity page for code/stack/handler data.
	-- PDE1 maps virtual 0x400000 through page table 0x4000, whose first PTE is
	-- present but read-only. CR0.WP makes supervisor writes fault too.
	m.mem:write32(0x2000, 0x00000083)
	m.mem:write32(0x2004, 0x00004003)
	m.mem:write32(0x4000, 0x00800001)
	const cpu = m.cpu
	cpu.cr3 = 0x2000
	cpu.cr[3] = 0x2000
	cpu.cr0 = bor(1, 0x80000000, 0x10000)
	cpu.cr[0] = cpu.cr0
	installGate(m, 14, 0x6000, 8, 0x8E)
	putCode(m, 0x6000, {
		0x58, -- POP EAX: error code
		0xA3,
		0x00,
		0x41,
		0x00,
		0x00, -- MOV [0x4100],EAX
		0xCF, -- IRETD: re-fault (page stays read-only)
	})
	putCode(m, 0x1000, {
		0xA3,
		0x00,
		0x00,
		0x40,
		0x00, -- MOV [0x400000],EAX
		0xF4,
	})
	m:run(3) -- fault delivery, POP error code, store it
	expect(cpu.pageFaults == 1, "pageFaults=" .. cpu.pageFaults)
	expect(m.mem:read32(0x4100) == 3, string.format("error code=%X", m.mem:read32(0x4100)))
end)

T("v86_interrupt_frame_and_iret", function(expect)
	const m = freshMachine()
	flat32(m)
	const cpu = m.cpu
	-- 32-bit ring-0 TSS with ESP0:SS0 for the V86 monitor.
	cpu.tr = 0x18
	cpu.trBase = 0x4000
	cpu.trLimit = 0x67
	cpu.tr32 = true
	m.mem:write32(0x4004, 0x9000)
	m.mem:write16(0x4008, 0x10)
	installGate(m, 0x21, 0x6000, 8, 0xEE) -- DPL 3 so V86 software INT is legal
	putCode(m, 0x6000, {
		0x8B,
		0x04,
		0x24, -- MOV EAX,[ESP] saved EIP
		0xA3,
		0x00,
		0x70,
		0x00,
		0x00,
		0x8B,
		0x44,
		0x24,
		0x04, -- MOV EAX,[ESP+4] saved CS
		0xA3,
		0x04,
		0x70,
		0x00,
		0x00,
		0x8B,
		0x44,
		0x24,
		0x08, -- MOV EAX,[ESP+8] saved EFLAGS
		0xA3,
		0x08,
		0x70,
		0x00,
		0x00,
		0x8B,
		0x44,
		0x24,
		0x0C, -- MOV EAX,[ESP+12] saved ESP
		0xA3,
		0x0C,
		0x70,
		0x00,
		0x00,
		0x8B,
		0x44,
		0x24,
		0x10, -- MOV EAX,[ESP+16] saved SS
		0xA3,
		0x10,
		0x70,
		0x00,
		0x00,
		0x8B,
		0x44,
		0x24,
		0x14, -- MOV EAX,[ESP+20] saved ES
		0xA3,
		0x14,
		0x70,
		0x00,
		0x00,
		0xCF, -- IRETD back to V86
	})
	-- V86 code at 1000:0000: MOV AX,1234; INT 21h; MOV BX,5678; MOV [0400],BX; JMP $
	putCode(m, 0x10000, {
		0xB8,
		0x34,
		0x12,
		0xCD,
		0x21,
		0xBB,
		0x78,
		0x56,
		0x89,
		0x1E,
		0x00,
		0x04,
		0xEB,
		0xFE,
	})
	putCode(m, 0x1000, { 0xCF })
	-- IRETD into V86: GS FS DS ES SS ESP EFLAGS CS EIP
	cpu:push32(0)
	cpu:push32(0)
	cpu:push32(0)
	cpu:push32(0)
	cpu:push32(0x2000)
	cpu:push32(0x800)
	cpu:push32(bor(0x202, VM))
	cpu:push32(0x1000)
	cpu:push32(0)
	m:run(40)
	expect(cpu:isV86(), "returned to V86")
	expect(cpu.cs == 0x1000 and cpu.segBase.cs == 0x10000, "V86 CS/base")
	expect(cpu.ss == 0x2000 and cpu.segBase.ss == 0x20000, "V86 SS/base")
	expect(cpu:getSP() == 0x800, string.format("V86 ESP=%X", cpu:getSP()))
	expect(cpu.r[4] == 0x5678, string.format("BX=%04X", cpu.r[4]))
	expect(m.mem:read16(0x400) == 0x5678, "V86 code did not resume")
	expect(m.mem:read32(0x7000) == 5, string.format("saved EIP=%X", m.mem:read32(0x7000)))
	expect(m.mem:read32(0x7004) == 0x1000, string.format("saved CS=%X", m.mem:read32(0x7004)))
	expect(band(m.mem:read32(0x7008), VM) ~= 0, "saved EFLAGS lost VM")
	expect(m.mem:read32(0x700C) == 0x800, string.format("saved ESP=%X", m.mem:read32(0x700C)))
	expect(m.mem:read32(0x7010) == 0x2000, string.format("saved SS=%X", m.mem:read32(0x7010)))
	expect(m.mem:read32(0x7014) == 0, string.format("saved ES=%X", m.mem:read32(0x7014)))
	expect(cpu.pageFaults == 0, "unexpected page fault")
end)

T("pic_priority_and_slave_eoi", function(expect)
	const pic = Pic.new()
	pic.master.imr = 0xFC -- unmask IRQ0/IRQ1
	pic.master.vectorBase = 0x20
	pic.slave.imr = 0xFE -- unmask slave IRQ0 (IRQ8)
	pic.slave.vectorBase = 0x28
	pic.master.imr = band(pic.master.imr, bit32.bnot(0x04)) -- cascade IRQ2
	pic:raise(1)
	pic:raise(0)
	expect(pic:nextPending() == 0x20, "IRQ0 should win priority")
	const vector = pic:acknowledge()
	expect(vector == 0x20, "ack vector")
	expect(pic.master.isr == 0x01, "master ISR")
	pic:raise(1)
	expect(pic:nextPending() == nil, "lower-priority IRQ1 preempted IRQ0")
	pic:eoi(nil)
	expect(pic:nextPending() == 0x21, "IRQ1 not delivered after EOI")
	pic:acknowledge()
	pic:eoi(nil)
	-- Slave non-specific EOI must clear the slave, then release the cascade.
	pic:raise(8)
	expect(pic:nextPending() == 0x28, "slave vector")
	pic:acknowledge()
	expect(pic.slave.isr == 1 and pic.master.isr == 4, "slave/cascade in service")
	pic:out8(0xA0, 0x20)
	expect(pic.slave.isr == 0, "slave EOI left ISR set")
	expect(pic.master.isr == 0, "slave EOI did not release cascade")
end)

T("sib_index_with_disp32", function(expect)
	const m = freshMachine()
	flat32(m)
	putCode(m, 0x1000, {
		0xB8,
		0x01,
		0x00,
		0x00,
		0x00, -- MOV EAX,1
		0xC7,
		0x04,
		0xC5,
		0x00,
		0x06,
		0x00,
		0x00,
		0x44,
		0x33,
		0x22,
		0x11, -- MOV DWORD [EAX*8+0x600],0x11223344
		0xB8,
		0x02,
		0x00,
		0x00,
		0x00, -- MOV EAX,2
		0xC7,
		0x04,
		0xC5,
		0x00,
		0x06,
		0x00,
		0x00,
		0x88,
		0x77,
		0x66,
		0x55, -- MOV DWORD [EAX*8+0x600],0x55667788
		0xF4,
	})
	m:run(10)
	expect(m.mem:read32(0x608) == 0x11223344, "EAX*8+600")
	expect(m.mem:read32(0x610) == 0x55667788, "EAX*8+600 page 2")
	expect(m.mem:read32(0x600) == 0, "index was dropped into slot 0")
end)

T("lldt_null_is_legal", function(expect)
	const m = freshMachine()
	flat32(m)
	putCode(m, 0x1000, {
		0x31,
		0xC0, -- XOR EAX,EAX
		0x0F,
		0x00,
		0xD0, -- LLDT AX
		0xF4,
	})
	m:run(4)
	expect(m.cpu.ldtr == 0, "LDTR=" .. m.cpu.ldtr)
	expect(m.cpu.tripleFaults == 0, "null LLDT faulted")
	expect(m.cpu.halted, "LLDT did not complete")
end)

return TESTS
