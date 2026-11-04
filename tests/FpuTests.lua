--!nonstrict
-- FpuTests.lua -- x87 subset through Machine.new with a real 486 CPU config.

const band, bor = bit32.band, bit32.bor
const Memory = require("../core/Memory")
const Cpu = require("../core/Cpu")
const Fpu = require("../core/Fpu")
const Machine = require("../core/Machine")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

local function newMachine(enableFpu)
	const fpu = if enableFpu == false then nil else Fpu.new()
	const m = Machine.new({ Memory = Memory, Cpu = Cpu }, {
		memorySize = 1024 * 1024,
		cpu = { cpuLevel = "486", fpu = fpu },
	})
	const cpu = m.cpu
	cpu.cs, cpu.ds, cpu.es, cpu.ss = 0x600, 0x600, 0x600, 0x600
	cpu.ip = 0x100
	cpu.r[5] = 0xFFFE
	return m, fpu
end

local function putCode(m, bytes)
	const full = table.create(#bytes + 1)
	for index = 1, #bytes do
		full[index] = bytes[index]
	end
	full[#bytes + 1] = 0xF4 -- HLT
	const buf = buffer.create(#full)
	for index = 1, #full do
		buffer.writeu8(buf, index - 1, full[index])
	end
	m.mem:copyFrom(0x6000 + 0x100, buf)
end

local function putData(m, address, bytes)
	const buf = buffer.create(#bytes)
	for index = 1, #bytes do
		buffer.writeu8(buf, index - 1, bytes[index])
	end
	m.mem:copyFrom(0x6000 + address, buf)
end

local function putF32(m, address, value)
	const buf = buffer.create(4)
	buffer.writef32(buf, 0, value)
	m.mem:copyFrom(0x6000 + address, buf)
end

local function putF64(m, address, value)
	const buf = buffer.create(8)
	buffer.writef64(buf, 0, value)
	m.mem:copyFrom(0x6000 + address, buf)
end

local function readF32(m, address)
	const buf = buffer.create(4)
	buffer.writeu32(buf, 0, m.mem:read32(0x6000 + address))
	return buffer.readf32(buf, 0)
end

local function readF64(m, address)
	const buf = buffer.create(8)
	buffer.writeu32(buf, 0, m.mem:read32(0x6000 + address))
	buffer.writeu32(buf, 4, m.mem:read32(0x6000 + address + 4))
	return buffer.readf64(buf, 0)
end

local function closeTo(expect, got, want, name)
	expect(math.abs(got - want) < 1e-6, string.format("%s got=%g want=%g", name, got, want))
end

T("fpu_m32_m64_stack", function(expect)
	const m, fpu = newMachine()
	putF32(m, 0x300, 1.5)
	putF32(m, 0x304, 2.75)
	putF64(m, 0x308, 1.25)
	putF64(m, 0x310, 2.5)
	putCode(m, {
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD dword [0x300]
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD dword [0x304]
		0xD9,
		0x1E,
		0x20,
		0x03, -- FSTP dword [0x320]
		0xD9,
		0x1E,
		0x24,
		0x03, -- FSTP dword [0x324]
		0xDD,
		0x06,
		0x08,
		0x03, -- FLD qword [0x308]
		0xDD,
		0x06,
		0x10,
		0x03, -- FLD qword [0x310]
		0xDD,
		0x1E,
		0x28,
		0x03, -- FSTP qword [0x328]
		0xDD,
		0x1E,
		0x30,
		0x03, -- FSTP qword [0x330]
	})
	m:run(100)
	closeTo(expect, readF32(m, 0x320), 2.75, "first m32")
	closeTo(expect, readF32(m, 0x324), 1.5, "second m32")
	closeTo(expect, readF64(m, 0x328), 2.5, "first m64")
	closeTo(expect, readF64(m, 0x330), 1.25, "second m64")
	expect(fpu.top == 0, "TOP after pops=" .. fpu.top)
	expect(fpu:tagWord() == 0xFFFF, string.format("tag word=%04X", fpu:tagWord()))
end)

T("fpu_fild_fistp", function(expect)
	const m, fpu = newMachine()
	putData(m, 0x300, { 0x2E, 0xFB }) -- -1234
	putData(m, 0x304, { 0x40, 0xE2, 0x01, 0x00 }) -- 123456
	putCode(m, {
		0xDF,
		0x06,
		0x00,
		0x03, -- FILD word [0x300]
		0xDF,
		0x1E,
		0x10,
		0x03, -- FISTP word [0x310]
		0xDB,
		0x06,
		0x04,
		0x03, -- FILD dword [0x304]
		0xDB,
		0x1E,
		0x14,
		0x03, -- FISTP dword [0x314]
	})
	m:run(100)
	expect(
		m.mem:read16(0x6000 + 0x310) == 0xFB2E,
		string.format("word=%04X", m.mem:read16(0x6000 + 0x310))
	)
	expect(m.mem:read32(0x6000 + 0x314) == 123456, "dword=" .. m.mem:read32(0x6000 + 0x314))
	expect(fpu.top == 0 and fpu:tagWord() == 0xFFFF, "stack not empty")
end)

T("fpu_arith", function(expect)
	const m, fpu = newMachine()
	putF32(m, 0x300, 2.5)
	putF32(m, 0x304, 4.0)
	putCode(m, {
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 2.5
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 4.0
		0xD8,
		0xC1, -- FADD ST0,ST1
		0xD9,
		0x1E,
		0x20,
		0x03, -- FSTP [0x320]
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 4.0
		0xD8,
		0xC9, -- FMUL ST0,ST1
		0xD9,
		0x1E,
		0x24,
		0x03, -- FSTP [0x324]
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 4.0
		0xD8,
		0xF1, -- FDIV ST0,ST1
		0xD9,
		0x1E,
		0x28,
		0x03, -- FSTP [0x328]
		0xD9,
		0x1E,
		0x2C,
		0x03, -- FSTP [0x32C] (drain 2.5)
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 2.5
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 4.0
		0xDE,
		0xC1, -- FADDP ST1,ST0
		0xD9,
		0x1E,
		0x30,
		0x03, -- FSTP [0x330]
	})
	m:run(100)
	closeTo(expect, readF32(m, 0x320), 6.5, "FADD")
	closeTo(expect, readF32(m, 0x324), 10.0, "FMUL")
	closeTo(expect, readF32(m, 0x328), 1.6, "FDIV")
	closeTo(expect, readF32(m, 0x330), 6.5, "FADDP")
	expect(fpu.top == 0 and fpu:tagWord() == 0xFFFF, "stack not empty after arithmetic")
end)

T("fpu_fxch", function(expect)
	const m, fpu = newMachine()
	putF32(m, 0x300, 1.5)
	putF32(m, 0x304, 4.0)
	putCode(m, {
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 1.5
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 4.0
		0xD9,
		0xC9, -- FXCH ST1
		0xD9,
		0x1E,
		0x20,
		0x03, -- FSTP [0x320] -> 1.5
		0xD9,
		0x1E,
		0x24,
		0x03, -- FSTP [0x324] -> 4.0
	})
	m:run(100)
	closeTo(expect, readF32(m, 0x320), 1.5, "FXCH first")
	closeTo(expect, readF32(m, 0x324), 4.0, "FXCH second")
	expect(fpu.top == 0, "TOP=" .. fpu.top)
end)

T("fpu_compare_fstsw", function(expect)
	const m, fpu = newMachine()
	putF32(m, 0x300, 1.5)
	putF32(m, 0x304, 2.5)
	putCode(m, {
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 1.5
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 2.5
		0xD8,
		0xD1, -- FCOM ST1 (greater)
		0xDF,
		0xE0, -- FSTSW AX
		0xA3,
		0x20,
		0x03, -- MOV [0x320],AX
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 1.5
		0xD8,
		0xD1, -- FCOM ST1 (less)
		0xDF,
		0xE0, -- FSTSW AX
		0xA3,
		0x22,
		0x03, -- MOV [0x322],AX
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 1.5
		0xD8,
		0xD1, -- FCOM ST1 (equal)
		0xDF,
		0xE0, -- FSTSW AX
		0xA3,
		0x24,
		0x03, -- MOV [0x324],AX
	})
	m:run(100)
	const greater = m.mem:read16(0x6000 + 0x320)
	const less = m.mem:read16(0x6000 + 0x322)
	const equal = m.mem:read16(0x6000 + 0x324)
	expect(band(greater, 0x4700) == 0, string.format("greater flags=%04X", greater))
	expect(band(less, 0x4700) == 0x0100, string.format("less flags=%04X", less))
	expect(band(equal, 0x4700) == 0x4000, string.format("equal flags=%04X", equal))
	expect(band(equal, 0xFFFF) == band(fpu.status, 0xFFFF), "FSTSW did not read the status word")
end)

T("fpu_fninit_control", function(expect)
	const m, fpu = newMachine()
	putData(m, 0x300, { 0x7F, 0x07 }) -- control 0x077F
	putCode(m, {
		0xD9,
		0xE8, -- FLD1
		0xD9,
		0x2E,
		0x00,
		0x03, -- FLDCW [0x300]
		0xD9,
		0x3E,
		0x02,
		0x03, -- FNSTCW [0x302]
		0xDB,
		0xE3, -- FNINIT
	})
	m:run(100)
	expect(
		m.mem:read16(0x6000 + 0x302) == 0x077F,
		string.format("control=%04X", m.mem:read16(0x6000 + 0x302))
	)
	expect(fpu.control == 0x037F, string.format("post-init control=%04X", fpu.control))
	expect(fpu.top == 0, "post-init TOP=" .. fpu.top)
	expect(fpu.status == 0, string.format("post-init status=%04X", fpu.status))
	expect(fpu:tagWord() == 0xFFFF, string.format("post-init tag=%04X", fpu:tagWord()))
end)

T("fpu_exception_clear", function(expect)
	const m, fpu = newMachine()
	putCode(m, {
		0xD9,
		0xEE, -- FLDZ
		0xD9,
		0xE8, -- FLD1
		0xD8,
		0xF1, -- FDIV ST0,ST1 -> 1/0
		0xDB,
		0xE2, -- FNCLEX
	})
	m:run(100)
	expect(
		band(fpu.status, 0x00FF) == 0,
		string.format("exception bits after FNCLEX=%04X", fpu.status)
	)
end)

T("fpu_subr_divr_and_compare_pop", function(expect)
	const m, fpu = newMachine()
	putF32(m, 0x300, 8.0)
	putF32(m, 0x304, 2.0)
	putCode(m, {
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 8
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 2
		0xD8,
		0xE9, -- FSUBR ST0,ST1 -> 8 - 2
		0xD9,
		0x1E,
		0x20,
		0x03, -- FSTP [0x320]
		0xD9,
		0x1E,
		0x2C,
		0x03, -- FSTP [0x32C] (drain)
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 8
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 2
		0xD8,
		0xF9, -- FDIVR ST0,ST1 -> 8 / 2
		0xD9,
		0x1E,
		0x24,
		0x03, -- FSTP [0x324]
		0xD9,
		0x1E,
		0x2E,
		0x03, -- FSTP [0x32E] (drain)
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 2
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 2
		0xDE,
		0xD9, -- FCOMPP (equal)
		0xDF,
		0xE0, -- FSTSW AX
		0xA3,
		0x28,
		0x03, -- MOV [0x328],AX
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 2
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 8
		0xDA,
		0xE9, -- FUCOMPP (greater)
		0xDF,
		0xE0, -- FSTSW AX
		0xA3,
		0x2A,
		0x03, -- MOV [0x32A],AX
	})
	m:run(100)
	closeTo(expect, readF32(m, 0x320), 6.0, "FSUBR")
	closeTo(expect, readF32(m, 0x324), 4.0, "FDIVR")
	expect(band(m.mem:read16(0x6000 + 0x328), 0x4700) == 0x4000, "FCOMPP equal flags")
	expect(band(m.mem:read16(0x6000 + 0x32A), 0x4700) == 0, "FUCOMPP greater flags")
	expect(fpu.top == 0 and fpu:tagWord() == 0xFFFF, "compare-pop stack not empty")
end)

T("fpu_register_and_rounding", function(expect)
	const m, fpu = newMachine()
	putF32(m, 0x300, 2.7)
	putF32(m, 0x308, 2.0)
	putData(m, 0x304, { 0x7F, 0x07 }) -- round down, 64-bit precision
	putData(m, 0x306, { 0x7F, 0x03 }) -- round nearest
	putCode(m, {
		0xD9,
		0xE8, -- FLD1
		0xD9,
		0xE8, -- FLD1
		0xD8,
		0xC0, -- FADD ST0,ST0
		0xDD,
		0xD1, -- FST ST1
		0xDD,
		0xD8, -- FSTP ST0
		0xD9,
		0x1E,
		0x20,
		0x03, -- FSTP [0x320]
		0xD9,
		0xE8, -- FLD1
		0xDD,
		0xC0, -- FFREE ST0
		0xD9,
		0xE8, -- FLD1 again after FFREE
		0xD9,
		0x1E,
		0x24,
		0x03, -- FSTP [0x324]
		0xD9,
		0x2E,
		0x04,
		0x03, -- FLDCW round-down
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 2.7
		0xD9,
		0xFC, -- FRNDINT
		0xD9,
		0x1E,
		0x28,
		0x03, -- FSTP [0x328]
		0xD9,
		0x2E,
		0x06,
		0x03, -- FLDCW round-nearest
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 2.7
		0xD9,
		0xFC, -- FRNDINT
		0xD9,
		0x1E,
		0x2C,
		0x03, -- FSTP [0x32C]
		0xD9,
		0x06,
		0x08,
		0x03, -- FLD 2.0
		0xD9,
		0xE8, -- FLD1
		0xD9,
		0xFD, -- FSCALE -> 1 * 2^2
		0xD9,
		0x1E,
		0x30,
		0x03, -- FSTP [0x330]
		0xD9,
		0x1E,
		0x34,
		0x03, -- FSTP [0x334] (drain)
	})
	m:run(100)
	closeTo(expect, readF32(m, 0x320), 2.0, "FST/FSTP stack")
	closeTo(expect, readF32(m, 0x324), 1.0, "FLD after FFREE")
	closeTo(expect, readF32(m, 0x328), 2.0, "FRNDINT round down")
	closeTo(expect, readF32(m, 0x32C), 3.0, "FRNDINT round nearest")
	closeTo(expect, readF32(m, 0x330), 4.0, "FSCALE")
	expect(fpu:tagWord() == 0xFFFF, "register/rounding stack not empty")
end)

T("fpu_fcomi_flags", function(expect)
	const m, fpu = newMachine()
	putF32(m, 0x300, 1.5)
	putF32(m, 0x304, 2.5)
	putCode(m, {
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 1.5
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 2.5
		0xDB,
		0xF1, -- FCOMI ST1: 2.5 > 1.5
		0xDF,
		0xF1, -- FCOMIP ST1: compare again then pop
	})
	m:run(100)
	expect(band(m.cpu.flags, 0x0045) == 0, string.format("FCOMI greater flags=%04X", m.cpu.flags))
	expect(fpu.top == 7, "FCOMIP did not pop once: TOP=" .. fpu.top)
end)

T("fpu_cr0_em_ts_nm", function(expect)
	const m, fpu = newMachine()
	putF32(m, 0x300, 1.5)
	putCode(m, {
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 1.5
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 1.5
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 1.5
	})
	m.mem:write16(0x1C, 0) -- clear the default IVT stub so #NM dispatches inline
	m.mem:write16(0x1E, 0)
	m.cpu.defaultInts[7] = function() end

	m.cpu.cr0 = 0x00000004 -- EM
	m:run(1)
	expect((m.cpu.intCounts[7] or 0) == 1, "#NM not raised for EM")
	expect(fpu.top == 0 and fpu:tagWord() == 0xFFFF, "EM executed the FPU instruction")

	m.cpu.cr0 = 0x00000008 -- TS
	m:run(1)
	expect((m.cpu.intCounts[7] or 0) == 2, "#NM not raised for TS")
	expect(fpu.top == 0, "TS executed the FPU instruction")

	m.cpu.cr0 = 0
	m:run(1)
	expect((m.cpu.intCounts[7] or 0) == 2, "unexpected #NM with EM/TS clear")
	closeTo(expect, fpu:st(0), 1.5, "FLD after clearing EM/TS")
end)

T("fpu_stack_faults", function(expect)
	const m, fpu = newMachine()
	local code = {}
	for _ = 1, 9 do
		code[#code + 1] = 0xD9
		code[#code + 1] = 0xE8 -- FLD1; the ninth push overflows
	end
	for _ = 1, 8 do
		code[#code + 1] = 0xD9
		code[#code + 1] = 0x1E
		code[#code + 1] = 0x00
		code[#code + 1] = 0x03 -- FSTP [0x300]
	end
	code[#code + 1] = 0xD8
	code[#code + 1] = 0xC1 -- FADD with an empty stack
	putCode(m, code)
	m:run(100)
	expect(fpu.stackFaultCount >= 2, "stack fault count=" .. fpu.stackFaultCount)
	expect(band(fpu.status, 0x41) == 0x41, string.format("stack status=%04X", fpu.status))
	expect(fpu:tagWord() == 0xFFFF, string.format("stack tag=%04X", fpu:tagWord()))
end)

T("fpu_unsupported_sets_invalid", function(expect)
	const m, fpu = newMachine()
	putCode(m, { 0xD9, 0x0E, 0x00, 0x03 }) -- D9 /1 is reserved
	m:run(10)
	expect(fpu.invalidCount == 1, "invalid count=" .. fpu.invalidCount)
	expect(band(fpu.status, 0x0081) == 0x0081, string.format("invalid status=%04X", fpu.status))
	expect(fpu:tagWord() == 0xFFFF, "unsupported op corrupted the stack")
end)

T("fpu_env16_layout", function(expect)
	const m, fpu = newMachine()
	putData(m, 0x300, { 0x00, 0x07 }) -- control 0x0700
	putData(m, 0x308, { 0x7F, 0x03 }) -- default control
	putF32(m, 0x304, 1.5)
	putCode(m, {
		0xD9,
		0x2E,
		0x00,
		0x03, -- FLDCW [0x300]
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD dword [0x304]
		0xD9,
		0x36,
		0x10,
		0x03, -- FNSTENV m14 [0x310]
		0xD9,
		0x2E,
		0x08,
		0x03, -- FLDCW default
		0xD9,
		0x26,
		0x10,
		0x03, -- FLDENV m14 [0x310]
		0xD9,
		0x3E,
		0x20,
		0x03, -- FNSTCW [0x320]
	})
	m:run(100)
	expect(m.mem:read16(0x6000 + 0x310) == 0x0700, "16-bit control")
	const status = m.mem:read16(0x6000 + 0x312)
	expect(band(status, 0x3800) == 0x3800, string.format("16-bit TOP=%04X", status))
	expect(
		m.mem:read16(0x6000 + 0x314) == 0x3FFF,
		string.format("16-bit tag=%04X", m.mem:read16(0x6000 + 0x314))
	)
	expect(m.mem:read16(0x6000 + 0x316) == 0x0104, "16-bit FIP=" .. m.mem:read16(0x6000 + 0x316))
	expect(m.mem:read16(0x6000 + 0x318) == 0x0600, "16-bit FCS=" .. m.mem:read16(0x6000 + 0x318))
	expect(m.mem:read16(0x6000 + 0x31A) == 0x0304, "16-bit FDP=" .. m.mem:read16(0x6000 + 0x31A))
	expect(m.mem:read16(0x6000 + 0x31C) == 0x0600, "16-bit FDS=" .. m.mem:read16(0x6000 + 0x31C))
	expect(fpu.control == 0x0700, string.format("restored control=%04X", fpu.control))
	expect(fpu.top == 7, "restored TOP=" .. fpu.top)
	expect(m.mem:read16(0x6000 + 0x320) == 0x0700, "FNSTCW after FLDENV")
	closeTo(expect, fpu:st(0), 1.5, "FLDENV left registers intact")
end)

T("fpu_env32_layout", function(expect)
	const m, fpu = newMachine()
	putData(m, 0x300, { 0x00, 0x07 })
	putData(m, 0x308, { 0x7F, 0x03 })
	putF32(m, 0x304, 1.5)
	putCode(m, {
		0xD9,
		0x2E,
		0x00,
		0x03, -- FLDCW [0x300]
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD dword [0x304]
		0x9B,
		0x66,
		0xD9,
		0x36,
		0x10,
		0x03, -- FSTENV m28 [0x310]
		0xD9,
		0x2E,
		0x08,
		0x03, -- FLDCW default
		0x66,
		0xD9,
		0x26,
		0x10,
		0x03, -- FLDENV m28 [0x310]
		0xD9,
		0x3E,
		0x40,
		0x03, -- FNSTCW [0x340]
	})
	m:run(100)
	expect(m.mem:read16(0x6000 + 0x310) == 0x0700, "32-bit control")
	const status = m.mem:read16(0x6000 + 0x314)
	expect(band(status, 0x3800) == 0x3800, string.format("32-bit TOP=%04X", status))
	expect(
		m.mem:read16(0x6000 + 0x318) == 0x3FFF,
		string.format("32-bit tag=%04X", m.mem:read16(0x6000 + 0x318))
	)
	expect(m.mem:read32(0x6000 + 0x31C) == 0x0104, "32-bit FIP=" .. m.mem:read32(0x6000 + 0x31C))
	expect(band(m.mem:read32(0x6000 + 0x320), 0xFFFF) == 0x0600, "32-bit FCS")
	expect(band(bit32.rshift(m.mem:read32(0x6000 + 0x320), 16), 0x7FF) == 0xD9, "32-bit FOP")
	expect(m.mem:read32(0x6000 + 0x324) == 0x0304, "32-bit FDP=" .. m.mem:read32(0x6000 + 0x324))
	expect(band(m.mem:read32(0x6000 + 0x328), 0xFFFF) == 0x0600, "32-bit FDS")
	expect(fpu.control == 0x0700, string.format("restored control=%04X", fpu.control))
	expect(fpu.top == 7, "restored TOP=" .. fpu.top)
	expect(m.mem:read16(0x6000 + 0x340) == 0x0700, "FNSTCW after FLDENV")
end)

T("fpu_fsave_frstor_roundtrip", function(expect)
	const m, fpu = newMachine()
	putData(m, 0x300, { 0x00, 0x07 })
	putF32(m, 0x304, 1.5)
	putF32(m, 0x308, 2.5)
	putCode(m, {
		0xD9,
		0x2E,
		0x00,
		0x03, -- FLDCW [0x300]
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 1.5
		0xD9,
		0x06,
		0x08,
		0x03, -- FLD 2.5
		0xD8,
		0xC1, -- FADD -> 4.0
		0x66,
		0xDD,
		0x36,
		0x00,
		0x04, -- FNSAVE m108 [0x400]
		0x66,
		0xDD,
		0x26,
		0x00,
		0x04, -- FRSTOR m108 [0x400]
		0xDD,
		0x1E,
		0x20,
		0x03, -- FSTP qword [0x320]
		0xDD,
		0x1E,
		0x28,
		0x03, -- FSTP qword [0x328]
		0xD9,
		0x3E,
		0x30,
		0x03, -- FNSTCW [0x330]
	})
	m:run(100)
	expect(m.mem:read16(0x6000 + 0x400) == 0x0700, "saved control")
	expect(band(m.mem:read16(0x6000 + 0x404), 0x3800) == 0x3000, "saved TOP")
	expect(
		m.mem:read16(0x6000 + 0x408) == 0x0FFF,
		string.format("saved tag=%04X", m.mem:read16(0x6000 + 0x408))
	)
	expect(m.mem:read32(0x6000 + 0x41C) == 0, "R0 low significand")
	expect(m.mem:read32(0x6000 + 0x420) == 0x80000000, "R0 high significand")
	expect(m.mem:read16(0x6000 + 0x424) == 0x4001, "R0 exponent")
	expect(m.mem:read32(0x6000 + 0x426) == 0, "R1 low significand")
	expect(m.mem:read32(0x6000 + 0x42A) == 0xC0000000, "R1 high significand")
	expect(m.mem:read16(0x6000 + 0x42E) == 0x3FFF, "R1 exponent")
	closeTo(expect, readF64(m, 0x320), 4.0, "FRSTOR ST0")
	closeTo(expect, readF64(m, 0x328), 1.5, "FRSTOR ST1")
	expect(m.mem:read16(0x6000 + 0x330) == 0x0700, "FRSTOR control")
	expect(fpu:tagWord() == 0xFFFF, string.format("post-restore tag=%04X", fpu:tagWord()))
end)

T("fpu_fstenv_masks_exceptions", function(expect)
	const m, fpu = newMachine()
	putData(m, 0x300, { 0x00, 0x07 }) -- control 0x0700, all exceptions unmasked
	putCode(m, {
		0xD9,
		0x2E,
		0x00,
		0x03, -- FLDCW [0x300]
		0xD9,
		0x36,
		0x10,
		0x03, -- FNSTENV [0x310]
	})
	m:run(100)
	expect(m.mem:read16(0x6000 + 0x310) == 0x0700, "saved control was masked")
	expect(fpu.control == 0x073F, string.format("live control=%04X", fpu.control))
end)

T("fpu_fsave16_roundtrip", function(expect)
	const m, fpu = newMachine()
	putF32(m, 0x300, 3.5)
	putCode(m, {
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD dword [0x300]
		0xDD,
		0x36,
		0x00,
		0x04, -- FNSAVE m94 [0x400]
		0xDD,
		0x26,
		0x00,
		0x04, -- FRSTOR m94 [0x400]
		0xDD,
		0x1E,
		0x20,
		0x03, -- FSTP qword [0x320]
	})
	m:run(100)
	expect(m.mem:read16(0x6000 + 0x400) == 0x037F, "16-bit saved control")
	expect(band(m.mem:read16(0x6000 + 0x402), 0x3800) == 0x3800, "16-bit saved TOP")
	expect(
		m.mem:read16(0x6000 + 0x404) == 0x3FFF,
		string.format("16-bit saved tag=%04X", m.mem:read16(0x6000 + 0x404))
	)
	expect(m.mem:read32(0x6000 + 0x40E) == 0, "16-bit R0 low significand")
	expect(m.mem:read32(0x6000 + 0x412) == 0xE0000000, "16-bit R0 high significand")
	expect(m.mem:read16(0x6000 + 0x416) == 0x4000, "16-bit R0 exponent")
	closeTo(expect, readF64(m, 0x320), 3.5, "16-bit FNSAVE/FRSTOR")
	expect(fpu:tagWord() == 0xFFFF, "16-bit state stack not empty")
end)

T("fpu_m80_roundtrip", function(expect)
	const m, fpu = newMachine()
	putData(m, 0x300, { 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0xC0, 0xFF, 0x3F }) -- 1.5
	putF64(m, 0x328, 2.5)
	putCode(m, {
		0xDB,
		0x2E,
		0x00,
		0x03, -- FLD m80 [0x300]
		0xDB,
		0x3E,
		0x10,
		0x03, -- FSTP m80 [0x310]
		0xDB,
		0x2E,
		0x10,
		0x03, -- FLD m80 [0x310]
		0xDD,
		0x1E,
		0x20,
		0x03, -- FSTP qword [0x320]
		0xDD,
		0x06,
		0x28,
		0x03, -- FLD qword [0x328]
		0xDB,
		0x3E,
		0x30,
		0x03, -- FSTP m80 [0x330]
		0xDB,
		0x2E,
		0x30,
		0x03, -- FLD m80 [0x330]
		0xDD,
		0x1E,
		0x40,
		0x03, -- FSTP qword [0x340]
	})
	m:run(100)
	for index = 0, 9 do
		expect(
			m.mem:read8(0x6000 + 0x310 + index) == m.mem:read8(0x6000 + 0x300 + index),
			"m80 byte " .. index
		)
	end
	closeTo(expect, readF64(m, 0x320), 1.5, "m80 -> f64")
	closeTo(expect, readF64(m, 0x340), 2.5, "f64 -> m80 -> f64")
	expect(m.mem:read16(0x6000 + 0x338) == 0x4000, "2.5 exponent")
	expect(m.mem:read32(0x6000 + 0x334) == 0xA0000000, "2.5 high significand")
	expect(fpu:tagWord() == 0xFFFF, "m80 stack not empty")
end)

T("fpu_bcd_roundtrip", function(expect)
	const m, fpu = newMachine()
	putData(m, 0x300, { 0x89, 0x67, 0x45, 0x23, 0x01, 0x00, 0x00, 0x00, 0x00, 0x00 }) -- 123456789
	putCode(m, {
		0xDF,
		0x26,
		0x00,
		0x03, -- FBLD [0x300]
		0xDF,
		0x36,
		0x10,
		0x03, -- FBSTP [0x310]
		0xDF,
		0x26,
		0x10,
		0x03, -- FBLD [0x310]
		0xDF,
		0x36,
		0x20,
		0x03, -- FBSTP [0x320]
	})
	m:run(100)
	for index = 0, 9 do
		expect(
			m.mem:read8(0x6000 + 0x310 + index) == m.mem:read8(0x6000 + 0x300 + index),
			"BCD byte " .. index
		)
		expect(
			m.mem:read8(0x6000 + 0x320 + index) == m.mem:read8(0x6000 + 0x300 + index),
			"BCD second byte " .. index
		)
	end
	expect(fpu:tagWord() == 0xFFFF, "BCD stack not empty")
end)

T("fpu_ts_lazy_switch", function(expect)
	const m, fpu = newMachine()
	putCode(m, {
		0xD9,
		0xE8, -- FLD1 (TS -> #NM)
		0x0F,
		0x06, -- CLTS
		0xD9,
		0xE8, -- FLD1
		0xDB,
		0xE3, -- FNINIT (TS -> #NM)
		0xDB,
		0xE2, -- FNCLEX (TS -> #NM)
		0x0F,
		0x06, -- CLTS
		0xD9,
		0xE8, -- FLD1
	})
	m.mem:write16(0x1C, 0)
	m.mem:write16(0x1E, 0)
	m.cpu.defaultInts[7] = function() end

	m.cpu.cr0 = 0x00000008
	m:run(1)
	expect((m.cpu.intCounts[7] or 0) == 1, "TS FLD did not raise #NM")
	expect(fpu.top == 0, "TS FLD modified the FPU")

	m:run(1) -- CLTS
	expect(band(m.cpu.cr0, 0x00000008) == 0, "CLTS did not clear TS")
	m:run(1) -- FLD1
	expect(fpu.top == 7, "FLD after CLTS did not execute")

	m.cpu.cr0 = bor(m.cpu.cr0, 0x00000008)
	m:run(1) -- FNINIT
	expect((m.cpu.intCounts[7] or 0) == 2, "FNINIT did not raise #NM under TS")
	expect(band(m.cpu.cr0, 0x00000008) ~= 0, "FNINIT cleared TS")
	expect(fpu.top == 7 and fpu:tagWord() == 0x3FFF, "FNINIT executed under TS")

	m:run(1) -- FNCLEX
	expect((m.cpu.intCounts[7] or 0) == 3, "FNCLEX did not raise #NM under TS")
	expect(band(m.cpu.cr0, 0x00000008) ~= 0, "FNCLEX cleared TS")
	expect(fpu.top == 7, "FNCLEX executed under TS")

	m:run(1) -- CLTS
	m:run(1) -- FLD1
	expect(band(m.cpu.cr0, 0x00000008) == 0, "second CLTS did not clear TS")
	expect(fpu.top == 6, "FLD after second CLTS did not execute")
	expect(fpu:tagWord() == 0x0FFF, string.format("TS lazy tag=%04X", fpu:tagWord()))
end)

T("fpu_cpuid_fpu_bit", function(expect)
	const m = newMachine()
	putCode(m, { 0xB8, 0x01, 0x00, 0x0F, 0xA2 }) -- MOV AX,1; CPUID
	m:run(20)
	const edx = m.cpu:rr32(2)
	expect(band(edx, 0x00000001) ~= 0, string.format("FPU bit missing EDX=%08X", edx))
	expect(band(edx, 0x00000010) ~= 0, string.format("TSC bit missing EDX=%08X", edx))
	expect(band(edx, 0x00000008) == 0, string.format("PSE advertised EDX=%08X", edx))

	const noFpu = newMachine(false)
	putCode(noFpu, { 0xB8, 0x01, 0x00, 0x0F, 0xA2 })
	noFpu:run(20)
	const noEdx = noFpu.cpu:rr32(2)
	expect(band(noEdx, 0x00000001) == 0, string.format("FPU bit set without FPU EDX=%08X", noEdx))
end)

T("fpu_absent_esc_harmless", function(expect)
	const m = newMachine(false)
	putF32(m, 0x300, 1.5)
	putCode(m, {
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD ignored without an FPU
		0xB8,
		0x34,
		0x12, -- MOV AX,0x1234
	})
	m:run(20)
	expect(m.cpu.r[1] == 0x1234, string.format("AX=%04X", m.cpu.r[1]))
end)

T("fpu_transcendental_and_constants", function(expect)
	const m, fpu = newMachine()
	putF32(m, 0x300, 8.0)
	putF32(m, 0x304, 1.0)
	putCode(m, {
		0xD9,
		0xE8, -- FLD1
		0xD9,
		0xFA, -- FSQRT
		0xD9,
		0xE0, -- FCHS
		0xD9,
		0xE1, -- FABS
		0xD9,
		0x1E,
		0x20,
		0x03, -- FSTP [0x320]
		0xD9,
		0x06,
		0x04,
		0x03, -- FLD 1.0
		0xD9,
		0x06,
		0x00,
		0x03, -- FLD 8.0
		0xD9,
		0xF1, -- FYL2X -> log2(8)
		0xD9,
		0x1E,
		0x24,
		0x03, -- FSTP [0x324]
		0xD9,
		0xEB, -- FLDPI
		0xD9,
		0xFE, -- FSIN
		0xD9,
		0x1E,
		0x28,
		0x03, -- FSTP [0x328]
		0xD9,
		0xEB, -- FLDPI
		0xD9,
		0xFF, -- FCOS
		0xD9,
		0x1E,
		0x2C,
		0x03, -- FSTP [0x32C]
		0xD9,
		0xEE, -- FLDZ
		0xD9,
		0xF0, -- F2XM1
		0xD9,
		0x1E,
		0x30,
		0x03, -- FSTP [0x330]
		0xD9,
		0xEB, -- FLDPI
		0xD9,
		0xFB, -- FSINCOS
		0xD9,
		0x1E,
		0x34,
		0x03, -- FSTP [0x334] (sine)
		0xD9,
		0x1E,
		0x38,
		0x03, -- FSTP [0x338] (cosine)
	})
	m:run(100)
	closeTo(expect, readF32(m, 0x320), 1.0, "FSQRT/FCHS/FABS")
	closeTo(expect, readF32(m, 0x324), 3.0, "FYL2X")
	expect(math.abs(readF32(m, 0x328)) < 1e-7, string.format("FSIN(pi)=%g", readF32(m, 0x328)))
	closeTo(expect, readF32(m, 0x32C), -1.0, "FCOS(pi)")
	closeTo(expect, readF32(m, 0x330), 0.0, "F2XM1(0)")
	expect(math.abs(readF32(m, 0x334)) < 1e-7, string.format("FSINCOS sin=%g", readF32(m, 0x334)))
	closeTo(expect, readF32(m, 0x338), -1.0, "FSINCOS cos")
	expect(fpu.top == 0 and fpu:tagWord() == 0xFFFF, "transcendental stack not empty")
end)

return TESTS
