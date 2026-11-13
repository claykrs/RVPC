--!nonstrict
-- Cpu386Tests.lua -- 386/486 mode transitions, fault restart and 32-bit stacks.

const band, bor, rshift = bit32.band, bit32.bor, bit32.rshift
const VM = 0x20000

const Memory = require("../core/Memory")
const Cpu = require("../core/Cpu")
const Fpu = require("../core/Fpu")
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

local function freshFpuMachine()
	const fpu = Fpu.new()
	const machine = Machine.new({ Memory = Memory, Cpu = Cpu }, {
		memorySize = 16 * 1024 * 1024,
		cpu = { cpuLevel = "486", fpu = fpu },
	})
	return machine, fpu
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

-- Paged fixture: PD at 0x2000. PDE0 is a 4 MiB identity page (code, stack, PD
-- and PT all live below 4 MiB); PDE1 maps 0x400000 through page table 0x5000
-- with PTE0 pointing at frame 0x900000. Paging on, WP off, CPL 0.
local function pagedMachine()
	const m = freshMachine()
	flat32(m)
	m.mem.a20 = true
	m.mem:write32(0x2000, 0x00000083)
	m.mem:write32(0x2004, 0x00005007)
	m.mem:write32(0x5000, 0x00900007)
	const cpu = m.cpu
	cpu.cr3 = 0x2000
	cpu.cr[3] = 0x2000
	cpu.cr0 = bor(1, 0x80000000)
	cpu.cr[0] = cpu.cr0
	return m
end

T("tlb_store_to_page_table_frame_invalidates", function(expect)
	const m = pagedMachine()
	const cpu = m.cpu
	m.mem:write32(0x900000, 0x11111111)
	m.mem:write32(0xA00000, 0x22222222)
	expect(cpu:read32(0x400000) == 0x11111111, "first walk missed PTE frame")
	-- Rewrite PTE0 through the linear mapping of the page-table frame itself:
	-- the store lands in a tracked PT frame and must drop the cached entry.
	cpu:write32(0x5000, 0x00A00007)
	expect(cpu:read32(0x400000) == 0x22222222, "stale TLB entry survived PT store")
end)

T("tlb_flush_on_cr3_reload_and_invlpg", function(expect)
	const m = pagedMachine()
	const cpu = m.cpu
	m.mem:write32(0x900000, 0x11111111)
	m.mem:write32(0xB00000, 0x22222222)
	expect(cpu:read32(0x400000) == 0x11111111, "first walk")
	-- A second directory maps 0x400000 to a different frame.
	m.mem:write32(0x3000, 0x00000083)
	m.mem:write32(0x3004, 0x00006007)
	m.mem:write32(0x6000, 0x00B00007)
	cpu.cr3 = 0x3000
	cpu.cr[3] = 0x3000
	cpu:flushTlb()
	expect(cpu:read32(0x400000) == 0x22222222, "CR3 reload kept stale entries")
	cpu.cr3 = 0x2000
	cpu.cr[3] = 0x2000
	cpu:flushTlb()
	expect(cpu:read32(0x400000) == 0x11111111, "first directory again")
	-- A physical PTE rewrite the TLB never saw, retired by INVLPG.
	m.mem:write32(0x5000, 0x00B00007)
	cpu:flushTlbPage(0x400000)
	expect(cpu:read32(0x400000) == 0x22222222, "INVLPG did not drop the entry")
end)

T("tlb_hit_rechecks_protection_bits", function(expect)
	const m = pagedMachine()
	const cpu = m.cpu
	-- #PF gate so fault delivery does not escalate to a triple fault reset.
	installGate(m, 14, 0x6000, 8, 0x8E)
	putCode(m, 0x6000, { 0xCF }) -- IRETD
	m.mem:write32(0x5000, 0x00900001) -- present, supervisor-only, read-only
	m.mem:write32(0x900000, 0x55555555)
	expect(cpu:read32(0x400000) == 0x55555555, "supervisor read")
	-- Ring 3 must fault on the cached entry with present+user error bits.
	cpu.cs = 0x0B
	local ok = pcall(function()
		cpu:read32(0x400000)
	end)
	expect(not ok, "user read of supervisor page did not fault")
	expect(cpu.pageFaults == 1, "pageFaults=" .. cpu.pageFaults)
	expect(cpu.lastPageFault ~= nil and cpu.lastPageFault.errorCode == 5, "user fault error code")
	-- Supervisor write with CR0.WP set faults on the same cached entry.
	cpu.cs = 8
	cpu.cr0 = bor(cpu.cr0, 0x10000)
	cpu.cr[0] = cpu.cr0
	local okWrite = pcall(function()
		cpu:write32(0x400000, 0x1234)
	end)
	expect(not okWrite, "WP write to read-only page did not fault")
	expect(cpu.pageFaults == 2, "pageFaults=" .. cpu.pageFaults)
	expect(cpu.lastPageFault ~= nil and cpu.lastPageFault.errorCode == 3, "write fault error code")
end)

T("tlb_walk_sets_accessed_and_dirty_bits", function(expect)
	const m = pagedMachine()
	const cpu = m.cpu
	cpu:read32(0x400000)
	local pte = m.mem:read32(0x5000)
	expect(band(pte, 0x20) ~= 0, "PTE accessed bit missing after read")
	expect(band(pte, 0x40) == 0, "PTE dirty bit set by read")
	cpu:write32(0x400004, 0xCAFEBABE)
	expect(m.mem:read32(0x900004) == 0xCAFEBABE, "write missed cached frame")
	pte = m.mem:read32(0x5000)
	expect(band(pte, 0x60) == 0x60, string.format("PTE A/D bits=%X", pte))
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

T("v86_io_bitmap_trap", function(expect)
	const m = freshMachine()
	flat32(m)
	const cpu = m.cpu
	cpu.tr = 0x18
	cpu.trBase = 0x20000
	cpu.trLimit = 0x1FF
	cpu.tr32 = true
	m.mem:write32(0x20004, 0x9000)
	m.mem:write16(0x20008, 0x10)
	m.mem:write16(0x20066, 0x0100) -- I/O bitmap at TSS+0x100
	for index = 0, 0x2F do
		m.mem:write8(0x20100 + index, 0xFF)
	end
	m.mem:write8(0x20110, 0xFE) -- allow port 0x80, deny port 0x81
	installGate(m, 13, 0x6000, 8, 0x8E)
	putCode(m, 0x6000, {
		0x83,
		0x04,
		0x24,
		0x02, -- ADD dword [ESP],2 (skip the IN)
		0xCF, -- IRETD
	})
	putCode(m, 0x10000, {
		0xE4,
		0x80, -- IN AL,80h (allowed)
		0xA2,
		0x00,
		0x04, -- MOV [0400],AL
		0xE4,
		0x81, -- IN AL,81h (denied -> #GP)
		0xB8,
		0x34,
		0x12, -- MOV AX,1234
		0xA2,
		0x10,
		0x04, -- MOV [0410],AL
		0xEB,
		0xFE, -- JMP $
	})
	putCode(m, 0x1000, { 0xCF }) -- IRETD into V86
	cpu:push32(0) -- GS
	cpu:push32(0) -- FS
	cpu:push32(0x1000) -- DS
	cpu:push32(0x1000) -- ES
	cpu:push32(0x2000) -- SS
	cpu:push32(0x800) -- ESP
	cpu:push32(bor(0x202, VM)) -- EFLAGS
	cpu:push32(0x1000) -- CS
	cpu:push32(0) -- EIP
	m:run(80)
	expect(cpu:isV86(), "did not return to V86")
	expect((cpu.intCounts[13] or 0) == 1, "I/O bitmap did not raise #GP")
	expect(m.mem:read8(0x10400) == 0xFF, string.format("allowed IN AL=%02X", m.mem:read8(0x10400)))
	expect(
		m.mem:read8(0x10410) == 0x34,
		string.format("handler did not resume V86 code, AL=%02X", m.mem:read8(0x10410))
	)
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

T("word_writes_preserve_eax_high_half", function(expect)
	const m = freshMachine()
	flat32(m)
	putCode(m, 0x1000, {
		0xB8,
		0x78,
		0x56,
		0x34,
		0x12, -- MOV EAX,0x12345678
		0x66,
		0xB8,
		0xEF,
		0xBE, -- MOV AX,0xBEEF
		0x66,
		0x31,
		0xC0, -- XOR AX,AX
		0xF4,
	})
	m:run(2)
	expect(m.cpu:rr32(0) == 0x1234BEEF, string.format("MOV AX EAX=%08X", m.cpu:rr32(0)))
	m:run(1)
	expect(m.cpu:rr32(0) == 0x12340000, string.format("XOR AX EAX=%08X", m.cpu:rr32(0)))
end)

T("real_mode_word_write_preserves_eax_high", function(expect)
	const m = freshMachine()
	m.cpu.cs = 0
	m.cpu.segBase.cs = 0
	m.cpu.ip = 0x1000
	m.cpu.ds = 0
	m.cpu.segBase.ds = 0
	m.cpu.ss = 0
	m.cpu.segBase.ss = 0
	m.cpu.flags = 2
	m.cpu:setSP(0x8000)
	putCode(m, 0x1000, {
		0x66,
		0xB8,
		0x00,
		0x00,
		0xFE,
		0x01, -- MOV EAX,0x01FE0000
		0x31,
		0xC0, -- XOR AX,AX (must preserve EAX[31:16])
		0x66,
		0xA3,
		0x00,
		0x05, -- MOV [0x0500],EAX
		0xF4,
	})
	m:run(4)
	expect(m.cpu:rr32(0) == 0x01FE0000, string.format("EAX=%08X", m.cpu:rr32(0)))
	expect(m.mem:read32(0x500) == 0x01FE0000, string.format("mem=%08X", m.mem:read32(0x500)))
end)

T("mov_r32_sreg_zero_extends", function(expect)
	const m = freshMachine()
	flat32(m)
	putCode(m, 0x1000, {
		0xBE,
		0xFF,
		0xFF,
		0xFF,
		0xFF, -- MOV ESI,0xFFFFFFFF
		0x8C,
		0xD6, -- MOV ESI,SS (must zero-extend the selector)
		0xF4,
	})
	m:run(2)
	expect(m.cpu:rr32(6) == 0x10, string.format("ESI=%08X want 00000010", m.cpu:rr32(6)))
end)

T("real_mode_mov_r32_sreg_zero_extends", function(expect)
	const m = freshMachine()
	m.cpu.cs = 0
	m.cpu.segBase.cs = 0
	m.cpu.ip = 0x1000
	m.cpu.ss = 0
	m.cpu.segBase.ss = 0
	m.cpu.flags = 2
	m.cpu:setSP(0x8000)
	m.cpu:wr32(6, 0xFFFF0000)
	putCode(m, 0x1000, {
		0x66,
		0x8C,
		0xD6, -- MOV ESI,SS with operand-size prefix
		0xF4,
	})
	m:run(1)
	expect(m.cpu:rr32(6) == 0, string.format("ESI=%08X want 00000000", m.cpu:rr32(6)))
end)

T("x87_mf_idt_vector16_frame", function(expect)
	const m, fpu = freshFpuMachine()
	flat32(m)
	m.mem:write16(0x2000, 0x037B) -- ZE unmasked
	installGate(m, 16, 0x6000, 8, 0x8E)
	putCode(m, 0x6000, {
		0x8B,
		0x04,
		0x24, -- MOV EAX,[ESP] saved EIP
		0xA3,
		0x00,
		0x70,
		0x00,
		0x00, -- MOV [0x7000],EAX
		0x8B,
		0x44,
		0x24,
		0x04, -- MOV EAX,[ESP+4] saved CS
		0xA3,
		0x04,
		0x70,
		0x00,
		0x00, -- MOV [0x7004],EAX
		0x8B,
		0x44,
		0x24,
		0x08, -- MOV EAX,[ESP+8] saved EFLAGS
		0xA3,
		0x08,
		0x70,
		0x00,
		0x00, -- MOV [0x7008],EAX
		0xDB,
		0xE2, -- FNCLEX
		0xCF, -- IRETD
	})
	putCode(m, 0x1000, {
		0xD9,
		0x2E,
		0x00,
		0x20, -- FLDCW [0x2000]
		0xD9,
		0xEE, -- FLDZ
		0xD9,
		0xE8, -- FLD1
		0xD8,
		0xF1, -- FDIV 1/0 -> pending #MF
		0x9B, -- WAIT observes #MF at 0x100A
		0xB8,
		0x34,
		0x12,
		0x00,
		0x00, -- MOV EAX,0x1234
		0xF4, -- HLT
	})
	m:run(40)
	expect((m.cpu.intCounts[16] or 0) == 1, "vector 16 count=" .. (m.cpu.intCounts[16] or 0))
	expect(m.mem:read32(0x7000) == 0x100A, string.format("saved EIP=%08X", m.mem:read32(0x7000)))
	expect(m.mem:read32(0x7004) == 8, string.format("saved CS=%08X", m.mem:read32(0x7004)))
	expect(band(m.mem:read32(0x7008), 0x200) == 0, "interrupt gate did not clear IF")
	expect(not fpu.pendingMf, "handler FNCLEX did not clear #MF")
	expect(m.cpu.r[1] == 0x1234, string.format("EAX=%08X", m.cpu.r[1]))
	expect(m.cpu.halted, "WAIT did not resume after handler IRETD")
end)

-- 16-bit protected-mode fixture in the DOSX/DPMI shape: PE on, 16-bit
-- byte-granular code and data segments from a real GDT (like the LDT entries
-- WIN98 SETUP's DOS phase uses), CPL 0, no paging.
local function pm16Machine(cpuLevel: string?)
	const m = Machine.new({ Memory = Memory, Cpu = Cpu }, {
		memorySize = 16 * 1024 * 1024,
		cpu = { cpuLevel = cpuLevel or "486" },
	})
	const cpu = m.cpu
	cpu.cr0 = 1
	cpu.cr[0] = 1
	writeDescriptor(m, 0x3008, 0, 0xFFFFF, 0x9A, 0x00)
	writeDescriptor(m, 0x3010, 0, 0xFFFFF, 0x92, 0x00)
	cpu.gdtr = { base = 0x3000, limit = 0x1F }
	cpu:loadSeg("cs", 8)
	cpu:loadSeg("ds", 0x10)
	cpu:loadSeg("es", 0x10)
	cpu:loadSeg("ss", 0x10)
	cpu.ip = 0x1000
	cpu.flags = 2
	cpu:setSP(0x8000)
	return m
end

-- Undefined opcodes are #UD (INT 6) in protected mode. WIN98 SETUP's DOS
-- extender deliberately executes 0F FF at 0367:AF59 after registering a #UD
-- handler through DPMI INT 31h AX=0203 BL=06, purely to verify that exception
-- delivery works. The handler must receive the faulting instruction's START
-- address (a fault restarts, it does not skip) so it can resume past the
-- two-byte undefined opcode.
T("pm_ud_0f_ff_delivers_exception_6", function(expect)
	const m = pm16Machine()
	installGate(m, 6, 0x6000, 8, 0x86)
	putCode(m, 0x6000, {
		0x55, -- PUSH BP
		0x89,
		0xE5, -- MOV BP,SP
		0x8B,
		0x46,
		0x02, -- MOV AX,[BP+2]  saved IP
		0xA3,
		0x00,
		0x40, -- MOV [0x4000],AX
		0x83,
		0x46,
		0x02,
		0x02, -- ADD WORD [BP+2],2  skip the 0F FF
		0x5D, -- POP BP
		0xCF, -- IRET
	})
	putCode(m, 0x1000, {
		0x0F,
		0xFF, -- deliberately undefined two-byte opcode
		0xB8,
		0x66,
		0x66, -- MOV AX,0x6666 (must run after the handler resumes)
		0xF4, -- HLT
	})
	m:run(12)
	expect((m.cpu.intCounts[6] or 0) == 1, "vector 6 count=" .. (m.cpu.intCounts[6] or 0))
	expect(m.mem:read16(0x4000) == 0x1000, string.format("saved IP=%04X", m.mem:read16(0x4000)))
	expect(m.cpu.r[1] == 0x6666, string.format("AX=%04X", m.cpu.r[1]))
	expect(m.cpu:getSP() == 0x8000, string.format("SP=%04X", m.cpu:getSP()))
	expect(m.cpu.halted, "execution did not resume past the undefined opcode")
end)

return TESTS
