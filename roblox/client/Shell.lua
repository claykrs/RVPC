--!nonstrict
-- Shell.lua -- the Roblox presentation shell for RVPC.
--
-- Builds ScreenGui -> VgaView -> Input, resolves a configured machine from a
-- boot ModuleScript, and pumps the machine from RunService.Heartbeat. The core
-- stays responsible for emulation; this file only owns Roblox instances and the
-- wall-clock step budget.

const Players = game:GetService("Players")
const RunService = game:GetService("RunService")
const UserInputService = game:GetService("UserInputService")

const Boot = require(script.Parent.Boot)

const Shell = {}

const CAPTURE_HOTKEY = Enum.KeyCode.F8

export type Options = {
	timeBudget: number?,
	maxStepsPerFrame: number?,
	stepChunk: number?,
	-- Injection hooks: a ready machine, a factory, or a container to search for
	-- RvpcBoot/Boot/boot/Machine. With none of these, Boot.resolve uses
	-- ReplicatedStorage and falls back to the diagnostic VGA when nothing loads.
	machine: any?,
	boot: ((any, any) -> any)?,
	container: Instance?,
}

export type Shell = {
	Gui: ScreenGui,
	View: any?,
	Input: any,
	Machine: any?,
	Destroy: (self: Shell) -> (),
}

local function formatSteps(count: number): string
	if count >= 1e9 then
		return string.format("%.2fG", count / 1e9)
	elseif count >= 1e6 then
		return string.format("%.2fM", count / 1e6)
	elseif count >= 1e3 then
		return string.format("%.1fK", count / 1e3)
	end
	return tostring(count)
end

local function makeGui(playerGui: PlayerGui): ScreenGui
	const gui = Instance.new("ScreenGui")
	gui.Name = "RvpcShell"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 10
	gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
	gui.Parent = playerGui
	return gui
end

local function makeErrorLabel(parent: Instance, message: string): TextLabel
	const label = Instance.new("TextLabel")
	label.Name = "Error"
	label.BackgroundColor3 = Color3.fromRGB(24, 0, 0)
	label.BorderSizePixel = 0
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.Code
	label.TextSize = 16
	label.TextColor3 = Color3.fromRGB(255, 180, 180)
	label.TextWrapped = true
	label.Text = "RVPC presenter failed:\n" .. message
	label.Parent = parent
	return label
end

function Shell.start(Rvpc: any, RvpcUi: any, options: Options?): Shell?
	const player = Players.LocalPlayer
	if not player then
		return nil
	end
	const playerGui = player:WaitForChild("PlayerGui")
	const cfg = options or {}

	const gui = makeGui(playerGui)

	const background = Instance.new("Frame")
	background.Name = "Desktop"
	background.BackgroundColor3 = Color3.fromRGB(7, 16, 19)
	background.BorderSizePixel = 0
	background.Size = UDim2.fromScale(1, 1)
	background.Parent = gui

	const status = Instance.new("TextLabel")
	status.Name = "Status"
	status.BackgroundColor3 = Color3.fromRGB(16, 32, 34)
	status.BackgroundTransparency = 0.2
	status.BorderSizePixel = 0
	status.Position = UDim2.new(0, 0, 1, -28)
	status.Size = UDim2.new(1, 0, 0, 28)
	status.Font = Enum.Font.Code
	status.TextSize = 14
	status.TextColor3 = Color3.fromRGB(210, 230, 215)
	status.TextXAlignment = Enum.TextXAlignment.Left
	status.Text = "RVPC / 98 | starting"
	status.Parent = background

	const captureButton = Instance.new("TextButton")
	captureButton.Name = "Capture"
	captureButton.AnchorPoint = Vector2.new(1, 0.5)
	captureButton.Position = UDim2.new(1, -12, 0.5, 0)
	captureButton.Size = UDim2.fromOffset(170, 22)
	captureButton.BackgroundColor3 = Color3.fromRGB(40, 64, 68)
	captureButton.BorderSizePixel = 0
	captureButton.Font = Enum.Font.Code
	captureButton.TextSize = 13
	captureButton.TextColor3 = Color3.fromRGB(230, 240, 235)
	captureButton.Text = "Capture mouse (F8)"
	captureButton.Visible = false
	captureButton.Parent = status

	const display = Instance.new("Frame")
	display.Name = "Display"
	display.BackgroundTransparency = 1
	display.Size = UDim2.new(1, 0, 1, -28)
	display.Parent = background

	local machine = nil
	local source = nil
	local details = nil
	if cfg.machine then
		machine = cfg.machine
		source = "options.machine"
	elseif cfg.boot then
		const okBoot, result = pcall(cfg.boot, Rvpc, RvpcUi)
		if okBoot then
			machine = result
			source = "options.boot"
		else
			details = tostring(result)
		end
	else
		local okResolve, resolvedMachine, resolvedSource, resolvedDetails =
			pcall(Boot.resolve, Rvpc, RvpcUi, cfg.container)
		if okResolve then
			machine = resolvedMachine
			source = resolvedSource
			details = resolvedDetails
		else
			details = tostring(resolvedMachine)
		end
	end

	if machine and type(machine.vga) ~= "table" then
		details = "boot result has no vga device"
		machine = nil
		source = nil
	end

	local vga = nil
	if machine then
		vga = machine.vga
	else
		vga = Boot.diagnosticVga(Rvpc, details)
	end

	local okView, view = pcall(RvpcUi.VgaView.new, vga, display, {
		integerScale = true,
		integerScaleY = 0.56,
		background = Color3.new(0, 0, 0),
	})
	-- headless-driving hook: client-side Luau (execute_luau on the Client
	-- datamodel) reaches the machine through the shell attribute
	local shellGui = Instance.new("ScreenGui")
	shellGui.Name = "RvpcShellGui"
	shellGui.Parent = (cfg.container :: any)
		or game:GetService("Players").LocalPlayer:WaitForChild("PlayerGui")
	shellGui:SetAttribute("HasMachine", true)
	if machine then
		shellGui:SetAttribute("MachineReady", true)
	end

	if okView then
		view.Frame.AnchorPoint = Vector2.new(0.5, 0.5)
		view.Frame.Position = UDim2.fromScale(0.5, 0.47)
	else
		makeErrorLabel(display, tostring(view))
		view = nil
	end

	const input = RvpcUi.Input.new({
		captureMouse = false,
		invertY = true,
		onCaptureChanged = function(captured: boolean)
			captureButton.Text = if captured then "Release mouse (F8)" else "Capture mouse (F8)"
		end,
	})
	if machine then
		input:Bind(machine)
	end
	captureButton.Visible = machine ~= nil

	local steps = 0
	local frames = 0
	local statusTime = 0
	local textTime = 0
	local screenTime = 0
	local fps = 0
	local machineMsTotal = 0
	local pollMsTotal = 0
	local pollCount = 0
	local stepsMark = 0
	local maxFrameMs = 0
	local running = true

	local function statusText(): string
		local pc = "--"
		if machine and type(machine.bootPc) == "function" then
			local ok, value = pcall(machine.bootPc, machine)
			if ok then
				pc = tostring(value)
			end
		end
		const mode = if machine then "running" else "diagnostic"
		const bootSource = source or "no boot module"
		const capture = if input.Captured then "mouse captured" else "F8 capture"
		return string.format(
			"RVPC / 98 | %s | %s | %s steps | %s | %.0f fps | %s",
			mode,
			bootSource,
			formatSteps(steps),
			pc,
			fps,
			capture
		)
	end

	local function refreshStatus()
		status.Text = statusText()
	end

	local captureConnection = captureButton.MouseButton1Click:Connect(function()
		if machine then
			input:ToggleCapture()
		end
	end)

	const hotkeyConnection = UserInputService.InputBegan:Connect(function(inputObject, processed)
		if processed then
			return
		end
		if inputObject.KeyCode == CAPTURE_HOTKEY and machine then
			input:ToggleCapture()
		end
	end)

	const loopConnection = RunService.Heartbeat:Connect(function(dt: number)
		if not running then
			return
		end
		if dt * 1000 > maxFrameMs then
			maxFrameMs = dt * 1000
		end
		const ok, err = pcall(function()
			input:Step()
			local machineMs = 0
			local pollMs = 0
			if machine then
				const started = os.clock()
				const budget = cfg.timeBudget or 0.006
				const maxSteps = cfg.maxStepsPerFrame or 250000
				const chunk = cfg.stepChunk or 500
				local frameSteps = 0
				repeat
					const ran = machine:run(chunk)
					frameSteps += ran
					steps += ran
					if ran < chunk then
						break
					end
				until frameSteps >= maxSteps or os.clock() - started >= budget
				machineMs = (os.clock() - started) * 1000
			end
			-- Text-mode writes land in plain B8000 RAM, not the VGA aperture, so
			-- the core cannot see them dirty. Repaint text mode at 20 Hz; the
			-- 1 MiB full-frame upload stays modest at that rate.
			textTime += dt
			local forceText = false
			if
				machine
				and type(vga.isTextMode) == "function"
				and vga:isTextMode()
				and textTime >= 0.05
			then
				forceText = true
				textTime = 0
				-- publish the guest's top screen lines for external drivers
				local text = machine:outputText()
				local first = string.match(text, "[^\n]+") or ""
				background:SetAttribute("ScreenLine", first)
				screenTime += dt
				if screenTime >= 2 then
					screenTime = 0
					background:SetAttribute("ScreenText", string.sub(text, 1, 1200))
				end
				-- FreeDOS floppy-edition install support: when the guest asks
				-- for a package diskette, swap the image into drive A. The
				-- boot factory exposes the embedded set as machine.floppyDisks.
				local disks = machine.floppyDisks
				if disks and machine.fdc then
					local screen = machine:outputText()
					-- the guest labels diskettes "x86-DSK1"; the table keys are
					-- "x86DSK01", so normalize punctuation and pad the number
					local label = string.match(screen, "diskette %S+ %((.-)%) in A")
					local image = nil
					if label then
						local tag = string.upper(string.gsub(label, "[^%w]", ""))
						local num = string.match(tag, "^X86DSK(%d+)$")
						if num then
							image = disks["x86DSK" .. string.format("%02d", tonumber(num))]
						elseif tag == "X86BOOT" then
							image = disks.x86BOOT
						end
					end
					local drive = machine.fdc.drives[1]
					if image and drive and drive.image ~= image then
						drive.image = image
						drive.mediaChanged = true
					end
				end
			end
			if view then
				const pollStart = os.clock()
				view:Poll(forceText)
				pollMs = (os.clock() - pollStart) * 1000
			end
			-- perf telemetry for live tuning (read from the Studio property panel)
			machineMsTotal += machineMs
			pollMsTotal += pollMs
			pollCount += 1
			frames += 1
			statusTime += dt
			if statusTime >= 0.5 then
				fps = frames / statusTime
				gui:SetAttribute("RvpcFps", math.floor(fps))
				gui:SetAttribute("RvpcMachineMs", math.floor(machineMsTotal / frames * 10) / 10)
				gui:SetAttribute("RvpcPollMs", math.floor(pollMsTotal / frames * 100) / 100)
				gui:SetAttribute("RvpcStepsPerS", math.floor((steps - stepsMark) / statusTime))
				gui:SetAttribute("RvpcMaxFrameMs", math.floor(maxFrameMs * 10) / 10)
				maxFrameMs = 0
				machineMsTotal = 0
				pollMsTotal = 0
				pollCount = 0
				stepsMark = steps
				frames = 0
				statusTime = 0
				refreshStatus()
			end
		end)
		if not ok then
			running = false
			status.Text = "RVPC error: " .. tostring(err)
			if view and view.Status then
				view.Status.Text = tostring(err)
				view.Status.Visible = true
			end
		end
	end)

	refreshStatus()

	const handle: Shell = {
		Gui = gui,
		View = view,
		Input = input,
		Machine = machine,
		Destroy = function(_self: Shell)
			if not running and not loopConnection.Connected then
				return
			end
			running = false
			if loopConnection.Connected then
				loopConnection:Disconnect()
			end
			if hotkeyConnection.Connected then
				hotkeyConnection:Disconnect()
			end
			if captureConnection.Connected then
				captureConnection:Disconnect()
			end
			input:Destroy()
			if view then
				view:Destroy()
			end
			gui:Destroy()
		end,
	}

	return handle
end

return Shell
