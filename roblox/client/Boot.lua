--!nonstrict
-- Boot.lua -- find a guest machine supplied by the surrounding game.
--
-- RVPC core ships no ROM or OS media. A game provides one of the ModuleScripts
-- below in ReplicatedStorage:
--
--   RvpcBoot, Boot, boot, Machine
--
-- Each may return:
--   * function(Rvpc, RvpcUi) -> Machine
--   * a table with :boot(Rvpc, RvpcUi), :create(...) or :new(...)
--   * a ready Machine table (run, pressKey, releaseKey, mouseMove, vga)
--
-- A "Machine" here is the configured instance, not core/Machine.lua's class.

const ReplicatedStorage = game:GetService("ReplicatedStorage")

const Boot = {}

const MODULE_NAMES = { "RvpcBoot", "Boot", "boot", "Machine" }

local function isMachine(value: any): boolean
	if type(value) ~= "table" then
		return false
	end
	const vga = value.vga
	return type(value.run) == "function"
		and type(value.pressKey) == "function"
		and type(value.releaseKey) == "function"
		and type(value.mouseMove) == "function"
		and type(vga) == "table"
		and type(vga.width) == "function"
		and type(vga.height) == "function"
end

local function callFactory(factory: any, Rvpc: any, RvpcUi: any): (any?, string?)
	if type(factory) == "function" then
		const ok, machine = pcall(factory, Rvpc, RvpcUi)
		if not ok then
			return nil, tostring(machine)
		end
		return machine, nil
	end
	if type(factory) ~= "table" then
		return nil, "module did not return a function or table"
	end
	if isMachine(factory) then
		return factory, nil
	end
	if factory == Rvpc.Machine then
		return nil, "core Machine class needs a configured factory"
	end
	for _, methodName in { "boot", "create", "new" } do
		const method = factory[methodName]
		if type(method) == "function" then
			const ok, machine = pcall(method, factory, Rvpc, RvpcUi)
			if not ok then
				return nil, tostring(machine)
			end
			return machine, nil
		end
	end
	return nil, "module has no boot/create/new method"
end

-- Returns machine, sourceName, details. details is filled when nothing loaded.
function Boot.resolve(Rvpc: any, RvpcUi: any, container: Instance?): (any?, string?, string?)
	const root = container or ReplicatedStorage
	const problems: { string } = {}
	local found = false
	for _, name in MODULE_NAMES do
		const module = root:FindFirstChild(name)
		if module and module:IsA("ModuleScript") then
			found = true
			const okRequire, factory = pcall(require, module)
			if not okRequire then
				problems[#problems + 1] = name .. ": require failed: " .. tostring(factory)
			else
				const machine, err = callFactory(factory, Rvpc, RvpcUi)
				if isMachine(machine) then
					return machine, name, nil
				end
				problems[#problems + 1] = name .. ": " .. (err or "factory returned no machine")
			end
		end
	end
	if not found then
		problems[#problems + 1] = "no RvpcBoot/Boot/boot/Machine ModuleScript in ReplicatedStorage"
	end
	return nil, nil, table.concat(problems, "\n")
end

-- A text-mode VGA showing the shell's instructions. This exercises the real
-- Vga -> VgaView path even when no guest machine exists.
function Boot.diagnosticVga(Rvpc: any, details: string?): any
	const mem = Rvpc.Memory.new(1024 * 1024)
	const vga = Rvpc.Vga.new(mem)
	vga:setMode(0x03)
	for row = 0, 24 do
		vga:writeText(row, 0, string.rep(" ", 80), 0x07)
	end

	local function put(row: number, text: string, attr: number)
		if row >= 25 then
			return
		end
		vga:writeText(row, 0, string.sub(text, 1, 80), attr)
	end

	put(0, " RVPC / 98  -  CLIENT DIAGNOSTIC", 0x1F)
	put(2, "No boot machine is available.", 0x0F)
	put(3, "The VGA presenter and input bridge are running.", 0x07)
	put(5, "Supply a ModuleScript in ReplicatedStorage named:", 0x0F)
	put(6, "  RvpcBoot, Boot, boot or Machine", 0x0E)
	put(8, "Return one of:", 0x0F)
	put(9, "  function(Rvpc, RvpcUi) -> Machine", 0x07)
	put(10, "  table:boot(...) / :create(...) / :new(...)", 0x07)
	put(11, "  a ready Machine table", 0x07)
	put(13, "Machine fields: run, pressKey, releaseKey, mouseMove, vga.", 0x0F)
	put(15, "No SeaBIOS/SeaVGABIOS ROM or guest OS media is bundled.", 0x07)
	put(17, "Details:", 0x0F)

	if details and #details > 0 then
		local row = 18
		for line in string.gmatch(details, "[^\r\n]+") do
			local position = 1
			while position <= #line and row < 25 do
				vga:writeText(row, 0, string.sub(line, position, position + 79), 0x0C)
				row += 1
				position += 80
			end
			if row >= 25 then
				break
			end
		end
	end

	return vga
end

return Boot
