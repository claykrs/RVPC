--!nonstrict
-- run.lua -- RVPC test runner.

local Memory = require("../core/Memory")
local Cpu = require("../core/Cpu")
local Vga = require("../core/Vga")
local VgaSink = require("../core/VgaSink")
local Pic = require("../core/Pic")
local Pit = require("../core/Pit")
local Cmos = require("../core/Cmos")
local FwCfg = require("../core/FwCfg")
local Ide = require("../core/Ide")
local Kbc = require("../core/Kbc")
local Fpu = require("../core/Fpu")
local Dma = require("../core/Dma")
local Sb16 = require("../core/Sb16")
local Fdc = require("../core/Fdc")
local Xms = require("../core/Xms")
local Uart = require("../core/Uart")
local Lpt = require("../core/Lpt")
local Ne2000 = require("../core/Ne2000")
local Isp = require("../core/Isp")
local Machine = require("../core/Machine")
local smokeTests = require("../tests/SmokeTests")
local cpuTests = require("../tests/CpuTests")
local cpu386Tests = require("../tests/Cpu386Tests")
local fpuTests = require("../tests/FpuTests")
local xmsTests = require("../tests/XmsTests")
local memoryTests = require("../tests/MemoryTests")
local systemTests = require("../tests/SystemTests")
local ideTests = require("../tests/IdeTests")
local kbcTests = require("../tests/KbcTests")
local uartTests = require("../tests/UartTests")
local lptTests = require("../tests/LptTests")
local ne2000Tests = require("../tests/Ne2000Tests")
local ispTests = require("../tests/IspTests")
local vgaSinkTests = require("../tests/VgaSinkTests")
local networkTests = require("../tests/NetworkTests")
local vbeTests = require("../tests/VbeTests")
local dmaTests = require("../tests/DmaTests")
local sb16Tests = require("../tests/Sb16Tests")
local fdcTests = require("../tests/FdcTests")
local inputMapTests = require("../tests/InputMapTests")

const deps = {
	Memory = Memory,
	Cpu = Cpu,
	Vga = Vga,
	VgaSink = VgaSink,
	Pic = Pic,
	Pit = Pit,
	Cmos = Cmos,
	FwCfg = FwCfg,
	Ide = Ide,
	Kbc = Kbc,
	Fpu = Fpu,
	Dma = Dma,
	Sb16 = Sb16,
	Fdc = Fdc,
	Ne2000 = Ne2000,
	Isp = Isp,
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

local function runDirectSuite(prefix, tests)
	for _, test in ipairs(tests) do
		const name = prefix .. " -- " .. test.name
		const e = expect(name)
		local ok, err = pcall(function()
			test.run(e)
		end)
		if not ok then
			failures[#failures + 1] = name .. " THREW: " .. tostring(err)
		end
	end
end

runSuite("smoke", smokeTests)
runSuite("cpu", cpuTests)
runDirectSuite("cpu386", cpu386Tests)
runDirectSuite("fpu", fpuTests)
runSuite("xms", xmsTests)
runDirectSuite("memory", memoryTests)
runDirectSuite("system", systemTests)
runDirectSuite("ide", ideTests)
runDirectSuite("kbc", kbcTests)
runDirectSuite("uart", uartTests)
runDirectSuite("lpt", lptTests)
runDirectSuite("ne2000", ne2000Tests)
runDirectSuite("isp", ispTests)
runDirectSuite("vga", vgaSinkTests)
runDirectSuite("network", networkTests)
runDirectSuite("vbe", vbeTests)
runDirectSuite("dma", dmaTests)
runDirectSuite("sb16", sb16Tests)
runDirectSuite("fdc", fdcTests)
runDirectSuite("inputmap", inputMapTests)

print(("passed assertions: %d"):format(passed))
if #failures > 0 then
	print(("FAILURES (%d):"):format(#failures))
	for _, failure in ipairs(failures) do
		print("  " .. failure)
	end
	error("tests failed")
end
print("ALL TESTS PASSED")
