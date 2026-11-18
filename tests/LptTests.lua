--!nonstrict
-- LptTests.lua -- LPT1 data/control/strobe and status bytes.

const Lpt = require("../core/Lpt")

const TESTS = {}

local function T(name, run)
	TESTS[#TESTS + 1] = { name = name, run = run }
end

T("data_latch_and_status", function(expect)
	const lpt = Lpt.new()
	lpt:out8(0x378, 0x41)
	expect(lpt:in8(0x378) == 0x41, "data latch")
	expect(lpt:in8(0x379) == 0xDF, "status")
	expect(lpt:in8(0x37A) == 0x0C, "control reset value")
end)

T("strobe_emits_centronics_byte", function(expect)
	local output = ""
	const lpt = Lpt.new({
		write = function(_backend, text)
			output ..= text
		end,
	})
	lpt:out8(0x378, string.byte("Z"))
	lpt:out8(0x37A, 0x0D) -- STROBE high
	lpt:out8(0x37A, 0x0C) -- falling edge latches
	expect(output == "Z", "output=" .. output)
	expect(lpt.bytes == 1, "byte count")
	lpt:writeText("RV")
	expect(output == "ZRV", "writeText=" .. output)
end)

return TESTS
