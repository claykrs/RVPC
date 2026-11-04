--!nonstrict
-- SmokeTests.lua -- baseline RVPC CPU checks.

local function code(m, bytes)
	for index = 1, #bytes do
		m.mem:write8(0x6000 + 0x100 + index - 1, bytes[index])
	end
	m.cpu.cs = 0x0600
	m.cpu.segBase.cs = 0x6000
	m.cpu.ip = 0x0100
	m.cpu.halted = false
end

return {
	{
		name = "mov_add_16",
		setup = function(m)
			code(m, { 0xB8, 0x05, 0x00, 0x05, 0x03, 0x00, 0xF4 })
		end,
		steps = 10,
		check = function(_m, cpu, expect)
			expect(cpu.r[1] == 8, "AX=" .. cpu.r[1])
		end,
	},
	{
		name = "mov_eax_32",
		setup = function(m)
			code(m, { 0x66, 0xB8, 0x34, 0x12, 0x00, 0x00, 0xF4 })
		end,
		steps = 10,
		check = function(_m, cpu, expect)
			expect(cpu.r[1] == 0x1234, "EAX=" .. cpu.r[1])
		end,
	},
}
