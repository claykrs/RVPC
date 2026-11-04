--!nonstrict
-- run.lua -- RVDM98 test runner.

local Memory = require("../core/Memory")
local Cpu = require("../core/Cpu")
local Vga = require("../core/Vga")
local Xms = require("../core/Xms")
local Uart = require("../core/Uart")
local Lpt = require("../core/Lpt")
local Machine = require("../core/Machine")
local smokeTests = require("../tests/SmokeTests")

const deps = {
	Memory = Memory,
	Cpu = Cpu,
	Vga = Vga,
	Xms = Xms,
	Uart = Uart,
	Lpt = Lpt,
}

local passed, failures = 0, {}

local function expect(name)
	return function(cond, detail)
		if cond then
			passed += 1
		else
			failures[#failures + 1] = name .. (detail and (" -- " .. detail) or "")
		end
	end
end

local function runSuite(prefix, tests, config)
	for _, test in ipairs(tests) do
		const m = Machine.new(deps, config or test.config or {})
		const e = expect(prefix .. " -- " .. test.name)
		if test.setup then
			test.setup(m, e)
		end
		m:run(test.steps or 100)
		if test.check then
			test.check(m, m.cpu, e)
		end
	end
end

runSuite("smoke", smokeTests)

print(("passed assertions: %d"):format(passed))
if #failures > 0 then
	print(("FAILURES (%d):"):format(#failures))
	for _, failure in ipairs(failures) do
		print("  " .. failure)
	end
	error("tests failed")
end
print("ALL TESTS PASSED")
