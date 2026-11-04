--!nonstrict
-- XmsTests.lua -- INT 2Fh install check/driver entry, A20, HMA, EMB moves.
-- These run with a 286 and 4 MiB of RAM so the driver has extended memory.

const lshift = bit32.lshift

local TESTS = {}

local function T(name, spec)
	TESTS[#TESTS + 1] = {
		name = name,
		setup = spec.setup,
		steps = spec.steps or 50,
		check = spec.check,
		config = spec.config,
	}
end

const LEVEL_286 = { cpu = { cpuLevel = "286" }, memorySize = 4 * 1024 * 1024 }

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

local function fresh(m)
	const cpu = m.cpu
	cpu.cs, cpu.ds, cpu.es, cpu.ss = 0x600, 0x600, 0x600, 0x600
	cpu.ip = 0x100
	cpu.r[5] = 0xFFFE
end

local function dispatch(m, ah, dx)
	m.cpu.r[1] = lshift(ah, 8)
	m.cpu.r[3] = dx or 0
	m.xms:dispatch()
end

T("xms_install_check_286", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, { 0xB8, 0x00, 0x43, 0xCD, 0x2F }) -- MOV AX,4300h; INT 2Fh
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0x80, "AL=" .. string.format("%02X", cpu:rb(0)))
		expect(cpu.r[4] == 0x0100, "BX=" .. string.format("%04X", cpu.r[4]))
	end,
})

T("xms_install_check_8086_absent", {
	config = { cpu = { cpuLevel = "8086" }, memorySize = 4 * 1024 * 1024 },
	setup = function(m)
		putCode(m, { 0xB8, 0x00, 0x43, 0xCD, 0x2F })
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu:rb(0) == 0, "AL=" .. string.format("%02X", cpu:rb(0)))
	end,
})

T("xms_driver_entry_version", {
	config = LEVEL_286,
	setup = function(m)
		putCode(m, {
			0xB8,
			0x10,
			0x43, -- MOV AX,4310h
			0xCD,
			0x2F, -- INT 2Fh -> ES:BX
			0x89,
			0x1E,
			0x00,
			0x03, -- MOV [0x300],BX
			0x8C,
			0x06,
			0x02,
			0x03, -- MOV [0x302],ES
			0xB4,
			0x00, -- MOV AH,0
			0xFF,
			0x1E,
			0x00,
			0x03, -- CALL FAR [0x300]
		})
		fresh(m)
	end,
	check = function(_m, cpu, expect)
		expect(cpu.r[1] == 0x0300, "AX=" .. string.format("%04X", cpu.r[1]))
		expect(cpu.r[4] == 0x0100, "BX=" .. string.format("%04X", cpu.r[4]))
	end,
})

T("xms_a20_gate", {
	config = LEVEL_286,
	setup = function(m)
		fresh(m)
	end,
	check = function(m, _cpu, expect)
		expect(m.mem.a20, "A20 should start enabled with HIMEM")
		dispatch(m, 0x06)
		expect(m.cpu.r[1] == 1 and not m.mem.a20, "local disable")
		dispatch(m, 0x07)
		expect(m.cpu.r[1] == 0, "query disabled")
		dispatch(m, 0x03)
		expect(m.cpu.r[1] == 1 and m.mem.a20, "enable")
		dispatch(m, 0x04)
		expect(m.cpu.r[1] == 1 and not m.mem.a20, "disable")
	end,
})

T("xms_query_free", {
	config = LEVEL_286,
	setup = function(m)
		fresh(m)
	end,
	check = function(m, cpu, expect)
		dispatch(m, 0x08)
		expect(cpu.r[1] == 3008, "largest=" .. cpu.r[1])
		expect(cpu.r[3] == 3008, "total=" .. cpu.r[3])
		dispatch(m, 0x88)
		expect(cpu.r[1] == 3072, "any=" .. cpu.r[1])
	end,
})

T("xms_hma_request_release", {
	config = LEVEL_286,
	setup = function(m)
		fresh(m)
	end,
	check = function(m, cpu, expect)
		dispatch(m, 0x01, 0x40)
		expect(cpu.r[1] == 1, "HMA request")
		expect(m.xms.hmaInUse, "HMA flag")
		dispatch(m, 0x02)
		expect(cpu.r[1] == 1 and not m.xms.hmaInUse, "HMA release")
	end,
})

T("xms_emb_move_segment_offset", {
	config = LEVEL_286,
	setup = function(m)
		fresh(m)
		m.mem:writeString(0x6400, "WXYZ")
	end,
	check = function(m, cpu, expect)
		dispatch(m, 0x09, 64)
		expect(cpu.r[1] == 1, "allocate status")
		const handle = cpu.r[3]
		expect(handle ~= 0, "handle")
		dispatch(m, 0x0C, handle)
		expect(cpu.r[1] == 1, "lock status")
		expect(cpu.r[4] == 0 and cpu.r[3] == 0x11, "lock linear address")
		-- move 4 bytes from 0600:0400 to EMB offset 0
		m.mem:write16(0x6300, 4)
		m.mem:write16(0x6302, 0)
		m.mem:write16(0x6304, 0)
		m.mem:write16(0x6306, 0x0400)
		m.mem:write16(0x6308, 0x0600)
		m.mem:write16(0x630A, handle)
		m.mem:write16(0x630C, 0)
		m.mem:write16(0x630E, 0)
		m.cpu.r[1] = 0x0B00
		m.cpu.r[7] = 0x0300
		m.xms:dispatch()
		expect(cpu.r[1] == 1, "move out")
		-- move back to 0600:0500
		m.mem:write16(0x6304, handle)
		m.mem:write16(0x6306, 0)
		m.mem:write16(0x6308, 0)
		m.mem:write16(0x630A, 0)
		m.mem:write16(0x630C, 0x0500)
		m.mem:write16(0x630E, 0x0600)
		m.cpu.r[1] = 0x0B00
		m.xms:dispatch()
		expect(cpu.r[1] == 1, "move back")
		expect(m.mem:readString(0x6500, 4) == "WXYZ", "moved data")
		dispatch(m, 0x0A, handle)
		expect(cpu.r[1] == 1, "free")
		dispatch(m, 0x08)
		expect(cpu.r[1] == 3008, "free memory restored")
	end,
})

T("xms_release_all", {
	config = LEVEL_286,
	setup = function(m)
		fresh(m)
	end,
	check = function(m, cpu, expect)
		dispatch(m, 0x09, 64)
		expect(cpu.r[1] == 1, "allocate")
		m.xms:releaseAll()
		dispatch(m, 0x08)
		expect(cpu.r[1] == 3008, "releaseAll did not free blocks")
	end,
})

return TESTS
