--!nonstrict
-- cpu_tests.lua -- table-driven 8086 unit tests with exact hand encodings.
-- Each test runs in a fresh Machine; code is loaded COM-style at 0x0600:0x0100.
-- Test data lives at 0x0600:0x0300+ to avoid the code page.
-- check(m, cpu, expect) where expect(cond, detailMsg).

const band = bit32.band

local TESTS = {}

local function T(name, spec)
	TESTS[#TESTS + 1] = {
		name = name,
		setup = spec.setup,
		steps = spec.steps or 200,
		check = spec.check,
	}
end

-- write machine-code bytes at 0x0600:0x0100, HLT-terminated so the run budget
-- never spills into executing zero bytes past the program
local function putCode(m, bytes)
	local full = table.create(#bytes + 1)
	for i = 1, #bytes do
		full[i] = bytes[i]
	end
	full[#bytes + 1] = 0xF4
	local buf = buffer.create(#full)
	for i = 1, #full do
		buffer.writeu8(buf, i - 1, full[i])
	end
	m.mem:copyFrom(0x6000 + 0x100, buf)
end

-- write raw bytes at 0x0600:addr
local function putData(m, addr, bytes)
	local buf = buffer.create(#bytes)
	for i = 1, #bytes do
		buffer.writeu8(buf, i - 1, bytes[i])
	end
	m.mem:copyFrom(0x6000 + addr, buf)
end

local function fresh(m)
	local cpu = m.cpu
	cpu.cs, cpu.ds, cpu.es, cpu.ss = 0x600, 0x600, 0x600, 0x600
	cpu.ip = 0x100
	cpu.r[5] = 0xFFFE -- SP is r[5]; r[4] is BX
end

-- MOV
T("mov_imm16", {
	setup = function(m)
		putCode(m, { 0xB8, 0x34, 0x12, 0xBB, 0x78, 0x56 })
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0x1234, "AX=" .. cpu.r[1])
		expect(cpu.r[4] == 0x5678, "BX=" .. cpu.r[4])
	end,
})

T("mov_rm16_r16", {
	setup = function(m)
		putCode(m, { 0xB8, 0xAD, 0xDE, 0xBB, 0x00, 0x05, 0x89, 0x07 }) -- AX,BX=0x500, MOV [BX],AX
		fresh(m)
	end,
	check = function(m, _cpu, expect)
		expect(m.mem:read16(0x6000 + 0x500) == 0xDEAD, "mem=" .. m.mem:read16(0x6000 + 0x500))
	end,
})

T("mov_moffs", {
	setup = function(m)
		putCode(m, { 0xB0, 0x5A, 0xA2, 0x00, 0x03 }) -- MOV AL,0x5A; MOV [0x300],AL
		fresh(m)
	end,
	check = function(m, _cpu, expect)
		expect(m.mem:read8(0x6000 + 0x300) == 0x5A, "mem=" .. m.mem:read8(0x6000 + 0x300))
	end,
})

-- ALU flag corners
T("add_overflow", {
	setup = function(m)
		putCode(m, { 0xB0, 0x7F, 0x04, 0x01 }) -- MOV AL,0x7F; ADD AL,1
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x80, "AL=" .. cpu:rb(0))
		expect(cpu:getF(2048), "OF not set")
		expect(cpu:getF(128), "SF not set")
		expect(cpu:getF(16), "AF not set")
		expect(not cpu:getF(64), "ZF set")
		expect(not cpu:getF(1), "CF set")
		expect(not cpu:getF(4), "PF set") -- 0x80 has odd popcount
	end,
})

T("add_carry_zero", {
	setup = function(m)
		putCode(m, { 0xB0, 0xFF, 0x04, 0x01 }) -- MOV AL,0xFF; ADD AL,1
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0, "AL=" .. cpu:rb(0))
		expect(cpu:getF(1), "CF not set")
		expect(cpu:getF(64), "ZF not set")
		expect(cpu:getF(16), "AF not set")
		expect(cpu:getF(4), "PF not set")
		expect(not cpu:getF(2048), "OF set")
	end,
})

T("adc_with_carry", {
	setup = function(m)
		putCode(m, { 0xF9, 0xB0, 0x01, 0x14, 0x01 }) -- STC; MOV AL,1; ADC AL,1
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 3, "AL=" .. cpu:rb(0))
	end,
})

T("sub_borrow", {
	setup = function(m)
		putCode(m, { 0xB0, 0x05, 0x2C, 0x0A }) -- MOV AL,5; SUB AL,10
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0xFB, "AL=" .. cpu:rb(0))
		expect(cpu:getF(1), "CF not set")
		expect(cpu:getF(128), "SF not set")
		expect(cpu:getF(16), "AF not set")
		expect(not cpu:getF(2048), "OF set (in-range signed result)")
	end,
})

T("cmp_equal", {
	setup = function(m)
		putCode(m, { 0xB0, 0x42, 0x3C, 0x42 }) -- MOV AL,0x42; CMP AL,0x42
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:getF(64), "ZF not set")
		expect(not cpu:getF(1), "CF set")
		expect(cpu:rb(0) == 0x42, "AL modified by CMP")
	end,
})

T("cmp_unsigned_below", {
	setup = function(m)
		putCode(m, { 0xBB, 0x00, 0x00, 0x83, 0xFB, 0x10 }) -- MOV BX,0; CMP BX,0x10
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:getF(1), "CF not set (0 < 16)")
		expect(cpu:getF(128), "SF not set after 0-16")
		expect(not cpu:getF(64), "ZF set")
		expect(cpu.r[4] == 0, "BX modified by CMP")
	end,
})

T("cmp_ax_imm_borrow", {
	setup = function(m)
		putCode(m, { 0xB8, 0x05, 0x00, 0x3D, 0x10, 0x00 }) -- MOV AX,5; CMP AX,0x10
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:getF(1), "CF not set (5 < 16)")
		expect(cpu:getF(128), "SF not set after 5-16")
		expect(not cpu:getF(16), "AF set (no borrow from bit 3)")
		expect(cpu.r[1] == 5, "AX modified by CMP")
	end,
})

T("cmp_reg8_reg8_preserves", {
	setup = function(m)
		putCode(m, { 0xB0, 0x10, 0xB3, 0x20, 0x3A, 0xC3 }) -- MOV AL,0x10; MOV BL,0x20; CMP AL,BL
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:getF(1), "CF not set (0x10 < 0x20)")
		expect(cpu:rb(0) == 0x10, "AL modified by CMP: " .. cpu:rb(0))
		expect(cpu:rb(3) == 0x20, "BL modified by CMP")
	end,
})

T("cmp_reg16_reg16_preserves", {
	setup = function(m)
		putCode(m, { 0xB8, 0x34, 0x12, 0xBB, 0x78, 0x56, 0x39, 0xD8 }) -- MOV AX,0x1234; MOV BX,0x5678; CMP AX,BX
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:getF(1), "CF not set (0x1234 < 0x5678)")
		expect(cpu.r[1] == 0x1234, "AX modified by CMP: " .. cpu.r[1])
		expect(cpu.r[4] == 0x5678, "BX modified by CMP")
	end,
})

T("inc_preserves_cf", {
	setup = function(m)
		putCode(m, { 0xF9, 0xB0, 0x09, 0xFE, 0xC0 }) -- STC; MOV AL,9; INC AL
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x0A, "AL=" .. cpu:rb(0))
		expect(cpu:getF(1), "CF clobbered by INC")
	end,
})

T("neg", {
	setup = function(m)
		putCode(m, { 0xB0, 0x05, 0xF6, 0xD8 }) -- MOV AL,5; NEG AL
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0xFB, "AL=" .. cpu:rb(0))
		expect(cpu:getF(1), "CF not set")
	end,
})

T("neg_min_int", {
	setup = function(m)
		putCode(m, { 0xB0, 0x80, 0xF6, 0xD8 }) -- MOV AL,0x80; NEG AL
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x80, "AL=" .. cpu:rb(0))
		expect(cpu:getF(2048), "OF not set for NEG 0x80")
	end,
})

-- MUL/DIV
T("mul_byte", {
	setup = function(m)
		putCode(m, { 0xB0, 0x10, 0xB3, 0x10, 0xF6, 0xE3 }) -- AL=16, BL=16, MUL BL
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0x0100, "AX=" .. cpu.r[1])
		expect(cpu:getF(1), "CF not set")
		expect(cpu:getF(2048), "OF not set")
	end,
})

T("mul_word", {
	setup = function(m)
		putCode(m, { 0xB8, 0x64, 0x00, 0xBB, 0x64, 0x00, 0xF7, 0xE3 }) -- AX=100,BX=100,MUL BX
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0x2710, "AX=" .. cpu.r[1])
		expect(cpu.r[3] == 0, "DX=" .. cpu.r[3])
		expect(not cpu:getF(1), "CF set")
	end,
})

T("imul_byte_negative", {
	setup = function(m)
		putCode(m, { 0xB0, 0xFF, 0xB3, 0x03, 0xF6, 0xEB }) -- AL=-1, BL=3, IMUL BL
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0xFFFD, "AX=" .. cpu.r[1])
		expect(not cpu:getF(1), "CF set (in-range product)")
	end,
})

T("div_byte", {
	setup = function(m)
		putCode(m, { 0xB8, 0x64, 0x00, 0xB3, 0x09, 0xF6, 0xF3 }) -- AX=100, BL=9, DIV BL
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 11, "AL=" .. cpu:rb(0)) -- quotient
		expect(cpu:rb(4) == 1, "AH=" .. cpu:rb(4)) -- remainder
	end,
})

T("div_byte_overflow_interrupt0", {
	setup = function(m)
		putCode(m, { 0xB8, 0x00, 0x04, 0xB3, 0x01, 0xF6, 0xF3 }) -- AX=1024, BL=1, DIV BL
		-- Vector 0 -> 0600:0500. The handler records dispatch and halts.
		putData(m, 0x500, { 0xC6, 0x06, 0x00, 0x03, 0xAA, 0xF4 }) -- MOV BYTE [0300],AA; HLT
		m.mem:write16(0, 0x0500)
		m.mem:write16(2, 0x0600)
		fresh(m)
	end,
	steps = 50,
	check = function(m, _cpu, expect)
		expect(m.cpu.halted, "machine did not halt in #DE handler")
		expect(m.cpu.intCounts[0] == 1, "INT0 count=" .. tostring(m.cpu.intCounts[0]))
		expect(m.mem:read8(0x6300) == 0xAA, "divide-overflow handler did not run")
	end,
})

T("idiv_word_negative", {
	setup = function(m)
		putCode(m, { 0xBA, 0xFF, 0xFF, 0xB8, 0x9C, 0xFF, 0xBB, 0x07, 0x00, 0xF7, 0xFB }) -- DX=-1,AX=-100, BX=7, IDIV BX
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0xFFF2, "AX=" .. cpu.r[1]) -- -14
		expect(cpu.r[3] == 0xFFFE, "DX=" .. cpu.r[3]) -- -2
	end,
})

-- shifts/rotates
T("shl1", {
	setup = function(m)
		putCode(m, { 0xB0, 0xC0, 0xD0, 0xE0 }) -- MOV AL,0xC0; SHL AL,1
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x80, "AL=" .. cpu:rb(0))
		expect(cpu:getF(1), "CF not set")
		expect(not cpu:getF(2048), "OF set")
	end,
})

T("shr1", {
	setup = function(m)
		putCode(m, { 0xB0, 0x03, 0xD0, 0xE8 }) -- MOV AL,3; SHR AL,1
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 1, "AL=" .. cpu:rb(0))
		expect(cpu:getF(1), "CF not set")
		expect(not cpu:getF(2048), "OF set")
	end,
})

T("sar1", {
	setup = function(m)
		putCode(m, { 0xB0, 0xC0, 0xD0, 0xF8 }) -- MOV AL,0xC0; SAR AL,1
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0xE0, "AL=" .. cpu:rb(0))
		expect(not cpu:getF(1), "CF set")
		-- NOTE: shifts/rotates only affect CF and OF; SZP untouched by design
	end,
})

T("shl_cl4", {
	setup = function(m)
		putCode(m, { 0xB0, 0x01, 0xB1, 0x04, 0xD2, 0xE0 }) -- AL=1; CL=4; SHL AL,CL
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x10, "AL=" .. cpu:rb(0))
	end,
})

T("rol8", {
	setup = function(m)
		putCode(m, { 0xB0, 0x81, 0xD0, 0xC0 }) -- MOV AL,0x81; ROL AL,1
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x03, "AL=" .. cpu:rb(0))
		expect(cpu:getF(1), "CF not set")
		expect(cpu:getF(2048), "OF not set")
	end,
})

T("ror1", {
	setup = function(m)
		putCode(m, { 0xB0, 0x01, 0xD0, 0xC8 }) -- MOV AL,1; ROR AL,1
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x80, "AL=" .. cpu:rb(0))
		expect(cpu:getF(1), "CF not set")
		expect(cpu:getF(2048), "OF not set")
	end,
})

T("rcl1", {
	setup = function(m)
		putCode(m, { 0xF9, 0xB0, 0x01, 0xD0, 0xD0 }) -- STC; MOV AL,1; RCL AL,1
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		-- hardware truth: AL<<1 | CF = 0b10 | 1 = 3; new CF = old MSB = 0
		expect(cpu:rb(0) == 0x03, "AL=" .. cpu:rb(0))
		expect(not cpu:getF(1), "CF set")
	end,
})

T("rcr1", {
	setup = function(m)
		putCode(m, { 0xF9, 0xB0, 0x01, 0xD0, 0xD8 }) -- STC; MOV AL,1; RCR AL,1
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x80, "AL=" .. cpu:rb(0))
		expect(cpu:getF(1), "CF not set")
		expect(cpu:getF(2048), "OF not set")
	end,
})

-- stack
T("push_sp_quirk", {
	setup = function(m)
		putCode(m, { 0x54, 0x58 }) -- PUSH SP; POP AX
		fresh(m)
		m.cpu.r[5] = 0x1234
	end,
	check = function(_m, cpu, expect)
		-- 386/486 PUSH SP stores the value before the decrement; the decremented
		-- form is the 8086 quirk only.
		expect(cpu.r[1] == 0x1234, "AX=" .. cpu.r[1])
		expect(cpu.r[5] == 0x1234, "SP=" .. cpu.r[5])
	end,
})

T("pushf_popf", {
	setup = function(m)
		putCode(m, { 0xF9, 0x9C, 0xF8, 0x9D }) -- STC; PUSHF; CLC; POPF
		fresh(m)
		m.cpu.r[5] = 0x0800
	end,
	check = function(m, cpu, expect)
		expect(cpu:getF(1), "CF not restored by POPF")
		local pushed = m.mem:read16(0x6000 + 0x7FE)
		-- 386+ real-mode FLAGS: reserved bits 12-15 read zero, bit 1 is set,
		-- and STC set CF.
		expect(band(pushed, 0xF003) == 0x0003, "pushed flags=" .. string.format("%04X", pushed))
	end,
})

T("sahf_lahf", {
	setup = function(m)
		putCode(m, { 0xB4, 0xFF, 0x9E, 0x9F }) -- MOV AH,0xFF; SAHF; LAHF
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(4) == 0xD7, "AH=" .. cpu:rb(4)) -- flags low byte = 0xD5 + always bit
		expect(cpu:getF(1), "CF not set via SAHF")
		expect(cpu:getF(64), "ZF not set via SAHF")
	end,
})

-- control flow
T("jcc_taken_skips", {
	setup = function(m)
		putCode(m, { 0xB0, 0x01, 0x3C, 0x01, 0x74, 0x02, 0xB3, 0xFF, 0xB8, 0xCD, 0xAB })
		-- MOV AL,1; CMP AL,1; JE +2; MOV BL,0xFF (skipped); MOV AX,0xABCD
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[4] == 0, "BL skipped, BX=" .. cpu.r[4]) -- MOV BL,0xFF must not run
		expect(cpu.r[1] == 0xABCD, "AX=" .. cpu.r[1]) -- continuation ran
	end,
})

T("loop_3x", {
	setup = function(m)
		putCode(m, { 0x42, 0xE2, 0xFD }) -- INC DX; LOOP -3
		fresh(m)
		m.cpu.r[2] = 3 -- CX
	end,
	steps = 20,
	check = function(_m, cpu, expect)
		expect(cpu.r[3] == 3, "DX=" .. cpu.r[3])
		expect(cpu.r[2] == 0, "CX=" .. cpu.r[2])
	end,
})

T("call_ret", {
	setup = function(m)
		putCode(m, {
			0xE8,
			0x06,
			0x00, -- CALL +6 -> offset 9
			0xB8,
			0xAD,
			0x0B, -- MOV AX, 0x0BAD
			0xF4, -- HLT
			0x90,
			0x90, -- padding
			0xBB,
			0xBE,
			0xBA, -- [sub] MOV BX, 0xBABE
			0xC3, -- RET
		})
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[4] == 0xBABE, "BX=" .. cpu.r[4]) -- sub ran
		expect(cpu.r[1] == 0x0BAD, "AX=" .. cpu.r[1]) -- return resumed main
		expect(cpu.r[5] == 0xFFFE, "SP=" .. cpu.r[5]) -- stack balanced
		expect(cpu.halted, "did not reach HLT")
	end,
})

T("callf_retf", {
	setup = function(m)
		putCode(m, { 0x9A, 0x10, 0x00, 0x00, 0x20, 0xF4 }) -- CALL 0x2000:0x0010; HLT
		fresh(m)
		putData(m, 0x10 + 0x100, { 0xBB, 0xBE, 0xBA, 0xCB }) -- far sub at 0x2000:0x0010
		-- note: putData writes in DS=0x600 segment; place far code manually:
		local buf = buffer.create(4)
		buffer.writeu8(buf, 0, 0xBB)
		buffer.writeu8(buf, 1, 0xBE)
		buffer.writeu8(buf, 2, 0xBA)
		buffer.writeu8(buf, 3, 0xCB)
		m.mem:copyFrom(0x20000 + 0x10, buf)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[4] == 0xBABE, "BX=" .. cpu.r[4])
		expect(cpu.cs == 0x600, "CS=" .. cpu.cs)
		expect(cpu.r[5] == 0xFFFE, "SP=" .. cpu.r[5])
	end,
})

T("int_iret_program_handler", {
	setup = function(m)
		putCode(m, { 0xB8, 0x05, 0x00, 0xCD, 0x40, 0xF4 }) -- MOV AX,5; INT 40h; HLT
		fresh(m)
		m.mem:write16(0x40 * 4, 0x0010) -- IVT vector 40h
		m.mem:write16(0x40 * 4 + 2, 0x2000)
		local buf = buffer.create(4)
		buffer.writeu8(buf, 0, 0xBB)
		buffer.writeu8(buf, 1, 0x07)
		buffer.writeu8(buf, 2, 0x00)
		buffer.writeu8(buf, 3, 0xCF) -- MOV BX,7; IRET
		m.mem:copyFrom(0x20000 + 0x10, buf)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[4] == 7, "BX=" .. cpu.r[4]) -- handler ran
		expect(cpu.r[1] == 5, "AX=" .. cpu.r[1]) -- preserved across INT
		expect(cpu.r[5] == 0xFFFE, "SP=" .. cpu.r[5])
	end,
})

T("int21_dispatch_and_iret", {
	setup = function(m)
		putCode(m, { 0xB4, 0x02, 0xB2, 0x41, 0xCD, 0x21, 0xB8, 0x34, 0x12, 0xF4 })
		-- Vector 21h -> 0600:0500. Handler saves AH/DL then IRETs.
		putData(m, 0x500, {
			0x88,
			0x26,
			0x00,
			0x03, -- MOV [0300],AH
			0x88,
			0x16,
			0x01,
			0x03, -- MOV [0301],DL
			0xCF, -- IRET
		})
		m.mem:write16(0x21 * 4, 0x0500)
		m.mem:write16(0x21 * 4 + 2, 0x0600)
		fresh(m)
	end,
	steps = 20,
	check = function(m, cpu, expect)
		expect(m.mem:read8(0x6300) == 0x02, "AH not visible in INT 21 handler")
		expect(m.mem:read8(0x6301) == 0x41, "DL not visible in INT 21 handler")
		expect(cpu.r[1] == 0x1234, string.format("AX after IRET=%04X", cpu.r[1]))
		expect(cpu.halted, "IRET did not return to caller")
	end,
})

-- string ops
T("rep_movsw", {
	setup = function(m)
		putCode(m, {
			0xBE,
			0x00,
			0x03, -- MOV SI, 0x300
			0xBF,
			0x00,
			0x04, -- MOV DI, 0x400
			0xB9,
			0x03,
			0x00, -- MOV CX, 3
			0xFC, -- CLD
			0xF3,
			0xA5, -- REP MOVSW
		})
		fresh(m)
		putData(m, 0x300, { 0x11, 0x11, 0x22, 0x22, 0x33, 0x33 })
	end,
	check = function(m, cpu, expect)
		expect(m.mem:read16(0x6000 + 0x400) == 0x1111, "w1")
		expect(m.mem:read16(0x6000 + 0x402) == 0x2222, "w2")
		expect(m.mem:read16(0x6000 + 0x404) == 0x3333, "w3")
		expect(cpu.r[7] == 0x306, "SI=" .. cpu.r[7])
		expect(cpu.r[8] == 0x406, "DI=" .. cpu.r[8])
		expect(cpu.r[2] == 0, "CX=" .. cpu.r[2])
	end,
})

T("rep_movsb_backward", {
	setup = function(m)
		putCode(m, {
			0xFD, -- STD
			0xBE,
			0x03,
			0x03, -- MOV SI, 0x303
			0xBF,
			0x03,
			0x04, -- MOV DI, 0x403
			0xB9,
			0x04,
			0x00, -- MOV CX, 4
			0xF3,
			0xA4, -- REP MOVSB
		})
		fresh(m)
		putData(m, 0x300, { 0x41, 0x42, 0x43, 0x44 }) -- "ABCD"
	end,
	check = function(m, cpu, expect)
		local s = m.mem:readString(0x6000 + 0x400, 4)
		expect(s == "ABCD", "mem=" .. s)
		expect(cpu.r[7] == 0x2FF, "SI=" .. cpu.r[7])
		expect(cpu.r[8] == 0x3FF, "DI=" .. cpu.r[8])
	end,
})

T("repe_cmpsb_mismatch", {
	setup = function(m)
		putCode(m, {
			0xFC, -- CLD
			0xBE,
			0x00,
			0x03, -- MOV SI, 0x300
			0xBF,
			0x00,
			0x04, -- MOV DI, 0x400
			0xB9,
			0x04,
			0x00, -- MOV CX, 4
			0xF3,
			0xA6, -- REPE CMPSB
		})
		fresh(m)
		putData(m, 0x300, { 0x41, 0x42, 0x43, 0x44 }) -- ABCD
		putData(m, 0x400, { 0x41, 0x42, 0x58, 0x44 }) -- ABXD
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[7] == 0x303, "SI=" .. cpu.r[7])
		expect(cpu.r[8] == 0x403, "DI=" .. cpu.r[8])
		expect(cpu.r[2] == 1, "CX=" .. cpu.r[2])
		expect(not cpu:getF(64), "ZF set at mismatch")
	end,
})

T("repne_scasb_find", {
	setup = function(m)
		putCode(m, {
			0xB0,
			0x58, -- MOV AL, 'X'
			0xBF,
			0x00,
			0x04, -- MOV DI, 0x400
			0xB9,
			0x08,
			0x00, -- MOV CX, 8
			0xF2,
			0xAE, -- REPNE SCASB
		})
		fresh(m)
		putData(m, 0x400, { 0x31, 0x32, 0x33, 0x34, 0x35, 0x58, 0x37, 0x38 }) -- 12345X78
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[8] == 0x406, "DI=" .. cpu.r[8])
		expect(cpu.r[2] == 2, "CX=" .. cpu.r[2])
		expect(cpu:getF(64), "ZF not set on match")
	end,
})

T("lodsb_stosb", {
	setup = function(m)
		putCode(m, {
			0xBE,
			0x00,
			0x03, -- MOV SI, 0x300
			0xBF,
			0x00,
			0x05, -- MOV DI, 0x500
			0xFC, -- CLD
			0xAC, -- LODSB
			0xAA, -- STOSB
		})
		fresh(m)
		putData(m, 0x300, { 0x51 }) -- "Q"
	end,
	check = function(m, cpu, expect)
		expect(m.mem:read8(0x6000 + 0x500) == 0x51, "mem")
		expect(cpu:rb(0) == 0x51, "AL")
		expect(cpu.r[7] == 0x301 and cpu.r[8] == 0x501, "pointers advanced")
	end,
})

-- misc
T("xlat", {
	setup = function(m)
		putCode(m, { 0xBB, 0x00, 0x03, 0xB0, 0x03, 0xD7 }) -- MOV BX,0x300; MOV AL,3; XLAT
		fresh(m)
		putData(m, 0x300, { 0x10, 0x20, 0x30, 0x44 })
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x44, "AL=" .. cpu:rb(0))
	end,
})

T("lea_bx_si", {
	setup = function(m)
		putCode(m, { 0xBB, 0x05, 0x00, 0xBE, 0x03, 0x00, 0x8D, 0x00 }) -- BX=5; SI=3; LEA AX,[BX+SI]
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 8, "AX=" .. cpu.r[1])
	end,
})

T("lds", {
	setup = function(m)
		putCode(m, { 0xC5, 0x06, 0x00, 0x03 }) -- LDS AX, [0x300]
		fresh(m)
		m.mem:write16(0x6000 + 0x300, 0xBABE)
		m.mem:write16(0x6000 + 0x302, 0x1234)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0xBABE, "AX=" .. cpu.r[1])
		expect(cpu.ds == 0x1234, "DS=" .. cpu.ds)
	end,
})

T("cbw_cwd", {
	setup = function(m)
		putCode(m, { 0xB0, 0xFF, 0x98, 0x99 }) -- MOV AL,-1; CBW; CWD
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0xFFFF, "AX=" .. cpu.r[1])
		expect(cpu.r[3] == 0xFFFF, "DX=" .. cpu.r[3])
	end,
})

T("seg_override_es", {
	setup = function(m)
		putCode(m, { 0xB0, 0x5A, 0x26, 0xA2, 0x00, 0x10 }) -- MOV AL,0x5A; MOV ES:[0x1000],AL
		fresh(m)
		m.cpu.es = 0x2000
	end,
	check = function(m, _cpu, expect)
		expect(m.mem:read8(0x21000) == 0x5A, "ES-relative write failed")
		expect(m.mem:read8(0x6000 + 0x1000) == 0, "wrote to wrong segment")
	end,
})

T("xchg_rm8_r8", {
	setup = function(m)
		putCode(m, { 0xB0, 0x01, 0xB3, 0x02, 0x86, 0xD8 }) -- AL=1, BL=2, XCHG AL,BL
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 2, "AL=" .. cpu:rb(0))
		expect(cpu:rb(3) == 1, "BL=" .. cpu:rb(3))
	end,
})

T("jcxz_zero", {
	setup = function(m)
		-- JCXZ +4 -> lands at offset 6 (past the not-taken path and its HLT)
		putCode(m, { 0xE3, 0x04, 0xB0, 0x22, 0xF4, 0x90, 0xB0, 0x11 })
		fresh(m)
		m.cpu.r[2] = 0
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x11, "AL=" .. cpu:rb(0))
		expect(cpu.halted, "did not halt on taken path")
	end,
})

T("jcxz_nonzero", {
	setup = function(m)
		putCode(m, { 0xE3, 0x04, 0xB0, 0x22, 0xF4, 0x90, 0xB0, 0x11 })
		fresh(m)
		m.cpu.r[2] = 1
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x22, "AL=" .. cpu:rb(0))
		expect(cpu.halted, "did not halt on fall-through path")
	end,
})

T("daa", {
	setup = function(m)
		putCode(m, { 0xB0, 0x1F, 0x27 }) -- MOV AL,0x1F; DAA
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x25, "AL=" .. cpu:rb(0))
		expect(cpu:getF(16), "AF not set")
	end,
})

T("aam", {
	setup = function(m)
		putCode(m, { 0xB0, 0x41, 0xD4, 0x0A }) -- MOV AL,65; AAM
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0x0605, "AX=" .. string.format("%04X", cpu.r[1])) -- AH=6, AL=5
	end,
})

T("aad", {
	setup = function(m)
		putCode(m, { 0xD5, 0x0A }) -- AAD
		fresh(m)
		m.cpu:wb(4, 6) -- AH=6
		m.cpu:wb(0, 5) -- AL=5
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 65, "AL=" .. cpu:rb(0))
		expect(cpu:rb(4) == 0, "AH=" .. cpu:rb(4))
	end,
})

T("hlt_halts", {
	setup = function(m)
		putCode(m, { 0xF4 })
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.halted, "CPU not halted")
	end,
})

T("shl8_imm8", {
	setup = function(m)
		putCode(m, { 0xB0, 0x01, 0xC0, 0xE0, 0x03 }) -- MOV AL,1; SHL AL,3
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x08, "AL=" .. cpu:rb(0))
		expect(not cpu:getF(64), "ZF set for nonzero result")
	end,
})

T("shr16_imm8", {
	setup = function(m)
		putCode(m, { 0xBA, 0x20, 0x00, 0xC1, 0xEA, 0x03 }) -- MOV DX,0x20; SHR DX,3
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[3] == 0x0004, "DX=" .. cpu.r[3])
		expect(not cpu:getF(64), "ZF set for nonzero result")
	end,
})

T("shr_imm8_zero_flag", {
	setup = function(m)
		putCode(m, { 0xB8, 0x08, 0x00, 0xC1, 0xE8, 0x04 }) -- MOV AX,8; SHR AX,4
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0, "AX=" .. cpu.r[1])
		expect(cpu:getF(64), "ZF not set for a zero result")
	end,
})

T("ror8_imm8", {
	setup = function(m)
		putCode(m, { 0xB0, 0x01, 0xC0, 0xC8, 0x01 }) -- MOV AL,1; ROR AL,1
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x80, "AL=" .. cpu:rb(0))
		expect(cpu:getF(1), "CF not set")
	end,
})

T("signed_jle_sf_of", {
	setup = function(m)
		-- CMP 00F8,8001 sets SF=OF=1, ZF=0. 0xF8 is greater than -32767,
		-- so JLE must not be taken.  This is GDI's empty-clip fast path.
		putCode(m, {
			0xB9,
			0xF8,
			0x00, -- MOV CX,00F8
			0xBA,
			0x01,
			0x80, -- MOV DX,8001
			0x39,
			0xD1, -- CMP CX,DX
			0x7E,
			0x05, -- JLE +5
			0xB8,
			0x02,
			0x00, -- MOV AX,2
			0xEB,
			0x03, -- JMP +3
			0xB8,
			0x01,
			0x00, -- MOV AX,1
		})
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 2, "JLE taken with SF=OF=1; AX=" .. cpu.r[1])
	end,
})

T("signed_jl_jge_jg_sf_of", {
	setup = function(m)
		putCode(m, {
			0xB9,
			0xF8,
			0x00, -- MOV CX,00F8
			0xBA,
			0x01,
			0x80, -- MOV DX,8001
			0x39,
			0xD1, -- CMP CX,DX
			0x7C,
			0x02, -- JL +2 (must not be taken)
			0x7D,
			0x04, -- JGE +4 (taken)
			0xB8,
			0x01,
			0x00, -- MOV AX,1
			0xF4, -- HLT
			0x7F,
			0x04, -- JG +4 (taken, ZF=0)
			0xB8,
			0x02,
			0x00, -- MOV AX,2
			0xF4, -- HLT
			0xB8,
			0x03,
			0x00, -- MOV AX,3
		})
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 3, "signed JL/JGE/JG wrong with SF=OF=1; AX=" .. cpu.r[1])
	end,
})

-- 0F B0 CMPXCHG r/m8, r8 (486+): equal case stores the source into r/m.
T("cmpxchg8_eq", {
	setup = function(m)
		putCode(m, {
			0xB0,
			0x42, -- MOV AL,0x42
			0xBB,
			0x00,
			0x03, -- MOV BX,0x300
			0xC6,
			0x07,
			0x42, -- MOV BYTE [BX],0x42
			0xB1,
			0x99, -- MOV CL,0x99
			0x0F,
			0xB0,
			0x0F, -- CMPXCHG [BX],CL
			0xF4,
		})
		fresh(m)
	end,
	check = function(m, cpu, expect)
		expect(band(cpu.flags, 0x40) ~= 0, "ZF clear on equal compare")
		expect(m.mem:read8(0x6000 + 0x300) == 0x99, "dest not updated with source")
	end,
})

-- 0F B0 CMPXCHG r/m8, r8: unequal case loads r/m into the accumulator and
-- leaves r/m alone.
T("cmpxchg8_ne", {
	setup = function(m)
		putCode(m, {
			0xB0,
			0x41, -- MOV AL,0x41
			0xBB,
			0x00,
			0x03, -- MOV BX,0x300
			0xC6,
			0x07,
			0x42, -- MOV BYTE [BX],0x42
			0xB1,
			0x99, -- MOV CL,0x99
			0x0F,
			0xB0,
			0x0F, -- CMPXCHG [BX],CL
			0xF4,
		})
		fresh(m)
	end,
	check = function(m, cpu, expect)
		expect(band(cpu.flags, 0x40) == 0, "ZF set on unequal compare")
		expect(cpu:rb(0) == 0x42, "AL not loaded from dest")
		expect(m.mem:read8(0x6000 + 0x300) == 0x42, "dest modified on unequal compare")
	end,
})

-- 0F B1 CMPXCHG r/m16, r16: equal case, memory dest.
T("cmpxchg16_eq", {
	setup = function(m)
		putCode(m, {
			0xB8,
			0x34,
			0x12, -- MOV AX,0x1234
			0xBB,
			0x00,
			0x03, -- MOV BX,0x300
			0xC7,
			0x07,
			0x34,
			0x12, -- MOV WORD [BX],0x1234
			0xBE,
			0xEF,
			0xBE, -- MOV SI,0xBEEF
			0x0F,
			0xB1,
			0x37, -- CMPXCHG [BX],SI
			0xF4,
		})
		fresh(m)
	end,
	check = function(m, cpu, expect)
		expect(band(cpu.flags, 0x40) ~= 0, "ZF clear on equal compare")
		expect(m.mem:read16(0x6000 + 0x300) == 0xBEEF, "dest not updated with source")
	end,
})

-- 66 0F B1 CMPXCHG r/m32, r32: validates the 66-prefixed two-byte dispatch.
T("cmpxchg32_66", {
	setup = function(m)
		putCode(m, {
			0x66,
			0xB8,
			0x44,
			0x33,
			0x22,
			0x11, -- MOV EAX,0x11223344
			0xBB,
			0x00,
			0x03, -- MOV BX,0x300
			0x66,
			0xC7,
			0x07,
			0x44,
			0x33,
			0x22,
			0x11, -- MOV DWORD [BX],0x11223344
			0x66,
			0xBE,
			0x55,
			0x66,
			0x77,
			0x88, -- MOV ESI,0x88776655
			0x66,
			0x0F,
			0xB1,
			0x37, -- CMPXCHG DWORD [BX],ESI
			0xF4,
		})
		fresh(m)
	end,
	check = function(m, cpu, expect)
		expect(band(cpu.flags, 0x40) ~= 0, "ZF clear on equal compare")
		expect(m.mem:read32(0x6000 + 0x300) == 0x88776655, "dest not updated with source")
	end,
})

-- 0F 1F /0 multi-byte NOP (hintable-NOP family): consumes its modrm operand
-- and falls through, so newer toolchains' long NOPs run on this CPU.
T("hint_nop_0f1f", {
	setup = function(m)
		putCode(m, {
			0xB8,
			0x01,
			0x00, -- MOV AX,1
			0x0F,
			0x1F,
			0xC0, -- NOP AX (mod=11)
			0xB8,
			0x02,
			0x00, -- MOV AX,2
			0xF4,
		})
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 2, "0F 1F did not fall through; AX=" .. cpu.r[1])
	end,
})

-- REPE CMPSW: 16-bit strings that differ at a word whose LOW byte is equal
-- ("M1" vs "MM": res=0xE400, low byte 0x00). The compare must judge the full
-- word, not the low byte: ZF=0 at word 1 stops the repeat with CX=2.
T("repz_cmpsw_word_flags", {
	setup = function(m)
		putCode(m, {
			0xBE,
			0x00,
			0x03, -- MOV SI,0x300
			0xBF,
			0x20,
			0x03, -- MOV DI,0x320
			0xB9,
			0x04,
			0x00, -- MOV CX,4
			0xFC, -- CLD
			0xF3,
			0xA7, -- REPE CMPSW
			0xF4,
		})
		fresh(m)
		putData(m, 0x300, { 0x43, 0x4F, 0x4D, 0x31, 0x20, 0x20, 0x20, 0x20 }) -- "COM1    "
		putData(m, 0x320, { 0x43, 0x4F, 0x4D, 0x4D, 0x20, 0x20, 0x20, 0x20 }) -- "COMM    "
	end,
	check = function(_m, cpu, expect)
		expect(
			bit32.band(cpu.flags, 0x40) == 0,
			"REPE CMPSW saw a low-byte-only difference as equal"
		)
		expect(cpu.r[2] == 2, "CX=" .. cpu.r[2] .. " (stop after the differing word)")
		expect(cpu.r[7] == 0x304, "SI=" .. cpu.r[7])
		expect(cpu.r[8] == 0x324, "DI=" .. cpu.r[8])
		expect(bit32.band(cpu.flags, 1) ~= 0, "CF set (source < destination)")
	end,
})

-- REPE CMPSW over equal strings: all words equal, CX drains to zero, ZF=1.
T("repz_cmpsw_equal", {
	setup = function(m)
		putCode(m, {
			0xBE,
			0x00,
			0x03, -- MOV SI,0x300
			0xBF,
			0x20,
			0x03, -- MOV DI,0x320
			0xB9,
			0x02,
			0x00, -- MOV CX,2
			0xFC, -- CLD
			0xF3,
			0xA7, -- REPE CMPSW
			0xF4,
		})
		fresh(m)
		putData(m, 0x300, { 0x43, 0x4F, 0x4D, 0x31, 0x20, 0x20, 0x20, 0x20 }) -- "COM1    "
		putData(m, 0x320, { 0x43, 0x4F, 0x4D, 0x31, 0x20, 0x20, 0x20, 0x20 })
	end,
	check = function(_m, cpu, expect)
		expect(bit32.band(cpu.flags, 0x40) ~= 0, "equal strings must leave ZF set")
		expect(cpu.r[2] == 0, "CX=" .. cpu.r[2])
	end,
})

-- REPNE CMPSW: stops on the first EQUAL word (ZF=1) with the rest of CX left.
T("repne_cmpsw_stop_on_equal", {
	setup = function(m)
		putCode(m, {
			0xBE,
			0x00,
			0x03, -- MOV SI,0x300
			0xBF,
			0x20,
			0x03, -- MOV DI,0x320
			0xB9,
			0x04,
			0x00, -- MOV CX,4
			0xFC, -- CLD
			0xF2,
			0xA7, -- REPNE CMPSW
			0xF4,
		})
		fresh(m)
		putData(m, 0x300, { 0x11, 0x11, 0x22, 0x22, 0x33, 0x33, 0x33, 0x33 })
		putData(m, 0x320, { 0xAA, 0xAA, 0x22, 0x22, 0x44, 0x44, 0x44, 0x44 })
	end,
	check = function(_m, cpu, expect)
		expect(bit32.band(cpu.flags, 0x40) ~= 0, "REPNE must stop at the equal word")
		expect(cpu.r[2] == 2, "CX=" .. cpu.r[2])
		expect(cpu.r[7] == 0x304, "SI=" .. cpu.r[7])
	end,
})

-- 32-bit REPE CMPSD (66 prefix): a difference confined to the high word of a
-- dword (0x20000000 vs 0x10000000) must not read as equal.
T("repz_cmpsd_32bit_flags", {
	setup = function(m)
		putCode(m, {
			0x66,
			0xBE,
			0x00,
			0x03,
			0x00,
			0x00, -- MOV SI,0x300
			0x66,
			0xBF,
			0x20,
			0x03,
			0x00,
			0x00, -- MOV DI,0x320
			0x66,
			0xB9,
			0x01,
			0x00,
			0x00,
			0x00, -- MOV ECX,1
			0xFC, -- CLD
			0x66,
			0xF3,
			0xA7, -- REPE CMPSD
			0xF4,
		})
		fresh(m)
		putData(m, 0x300, { 0x78, 0x56, 0x34, 0x12 }) -- 0x12345678
		putData(m, 0x320, { 0x78, 0x56, 0x34, 0x21 }) -- 0x21345678
	end,
	check = function(_m, cpu, expect)
		expect(bit32.band(cpu.flags, 0x40) == 0, "CMPSD judged a dword by its low 16 bits")
		expect(cpu:rr32(1) == 0, "ECX=" .. cpu:rr32(1))
	end,
})

-- REPE SCASW: scanning for a word that differs only in the high byte of the
-- accumulator word (AX=0x4D31 vs memory 0x4D4D) must not report a match.
T("repz_scasw_word_flags", {
	setup = function(m)
		putCode(m, {
			0xB8,
			0x4D,
			0x31, -- MOV AX,0x314D
			0xBF,
			0x20,
			0x03, -- MOV DI,0x320
			0xB9,
			0x02,
			0x00, -- MOV CX,2
			0xFC, -- CLD
			0xF3,
			0xAF, -- REPE SCASW
			0xF4,
		})
		fresh(m)
		putData(m, 0x320, { 0x4D, 0x4D, 0x4D, 0x4D })
	end,
	check = function(_m, cpu, expect)
		-- word 0 (0x314D vs 0x4D4D) differs by its high byte only; the old
		-- low-byte-only flags judged it equal (ZF=1) and scanned on. The fixed
		-- compare reports the mismatch and REPE stops after word 0.
		expect(bit32.band(cpu.flags, 0x40) == 0, "SCASW judged a 16-bit compare by its low byte")
		expect(cpu.r[2] == 1, "CX=" .. cpu.r[2])
		expect(cpu.r[8] == 0x322, "DI=" .. cpu.r[8])
	end,
})

return TESTS
