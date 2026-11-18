--!nonstrict
-- Input.lua -- Roblox UserInputService bridge to the RVPC 8042.
--
-- Keyboard events become set-1 make/break codes through InputMap. Keys with an
-- E0 prefix (arrows, Home/End, right Ctrl/Alt, keypad Divide/Enter) use a
-- machine pressExtendedKey/releaseExtendedKey hook when present; otherwise the
-- E0 byte is pushed directly onto Kbc's queue (Kbc only exposes one-byte
-- pressKey), and if no Kbc is reachable the prefix is dropped so the guest sees
-- the keypad alias.
--
-- Mouse movement becomes PS/2 packets through machine:mouseMove. Screen Y grows
-- downward while PS/2 Y grows upward, so the delta is negated by default.
-- Capture is opt-in: while captured the cursor is locked/hidden and relative
-- motion is polled in Step(); releasing capture or losing window focus restores
-- the cursor and sends button-up packets.

const UserInputService = game:GetService("UserInputService")

const InputMap = require(script.Parent.Parent.Rvpc.InputMap)

const Input = {}
Input.__index = Input

const BUTTON_LEFT = 0x01
const BUTTON_RIGHT = 0x02
const BUTTON_MIDDLE = 0x04

const MOUSE_BUTTONS = {
	[Enum.UserInputType.MouseButton1] = BUTTON_LEFT,
	[Enum.UserInputType.MouseButton2] = BUTTON_RIGHT,
	[Enum.UserInputType.MouseButton3] = BUTTON_MIDDLE,
}

export type Options = {
	enabled: boolean?,
	captureMouse: boolean?,
	sensitivity: number?,
	invertY: boolean?,
	onCaptureChanged: ((captured: boolean) -> ())?,
}

export type Input = {
	Machine: any?,
	Enabled: boolean,
	Captured: boolean,
	Bind: (self: Input, machine: any?) -> (),
	SetEnabled: (self: Input, enabled: boolean) -> (),
	SetCapture: (self: Input, captured: boolean) -> (),
	ToggleCapture: (self: Input) -> boolean,
	Step: (self: Input) -> (),
	ReleaseAll: (self: Input) -> (),
	Destroy: (self: Input) -> (),
}

-- Extended set-1 keys are represented as 0xE0xx. Kbc exposes only one-byte
-- pressKey/releaseKey, so a prefix goes directly onto its queue when the host
-- can (Kbc's queue/irq1 are part of its exported shape). A machine may instead
-- provide pressExtendedKey/releaseExtendedKey; otherwise E0 is stripped and
-- the guest sees the keypad alias.
local function pushExtendedPrefix(kbc: any): boolean
	if type(kbc) ~= "table" or kbc.keyboardEnabled == false then
		return false
	end
	const queue = kbc.queue
	if type(queue) ~= "table" then
		return false
	end
	queue[#queue + 1] = { value = 0xE0, aux = false }
	if type(kbc.config) == "number" and bit32.band(kbc.config, 0x01) ~= 0 then
		kbc.irq1 = true
	end
	return true
end

local function sendKey(machine: any, scancode: number, down: boolean)
	if scancode > 0xFF then
		const hookName = if down then "pressExtendedKey" else "releaseExtendedKey"
		const hook = machine[hookName]
		if type(hook) == "function" then
			hook(machine, scancode)
			return
		end
		pushExtendedPrefix(machine.kbc)
		scancode = scancode % 0x100
	end
	if down then
		machine:pressKey(scancode)
	else
		machine:releaseKey(scancode)
	end
end

function Input.new(options: Options?): Input
	const cfg = options or {}
	const self = setmetatable({}, Input) :: any

	self.Machine = nil
	self.Enabled = cfg.enabled ~= false
	self.Captured = false
	self.Sensitivity = cfg.sensitivity or 1
	self.InvertY = cfg.invertY ~= false
	self.OnCaptureChanged = cfg.onCaptureChanged
	self._pressed = {}
	self._buttons = 0
	self._accX = 0
	self._accY = 0
	self._skipMouse = 0
	self._connections = {}
	self._destroyed = false
	self._savedBehavior = UserInputService.MouseBehavior
	self._savedIcon = UserInputService.MouseIconEnabled
	self._captureSaved = false

	local function track(connection: RBXScriptConnection)
		self._connections[#self._connections + 1] = connection
	end

	track(UserInputService.InputBegan:Connect(function(input: InputObject, processed: boolean)
		self:_onInput(input, processed, true)
	end))
	track(UserInputService.InputEnded:Connect(function(input: InputObject, processed: boolean)
		self:_onInput(input, processed, false)
	end))
	track(UserInputService.InputChanged:Connect(function(input: InputObject, processed: boolean)
		if
			processed
			or not self.Enabled
			or self._destroyed
			or self.Captured
			or input.UserInputType ~= Enum.UserInputType.MouseMovement
		then
			return
		end
		self:_mouseDelta(input.Delta.X, input.Delta.Y)
	end))
	track(UserInputService.WindowFocusReleased:Connect(function()
		self:ReleaseAll()
		self:SetCapture(false)
	end))
	track(UserInputService.TextBoxFocused:Connect(function()
		self:ReleaseAll()
		self:SetCapture(false)
	end))

	self:SetCapture(cfg.captureMouse == true)

	return self
end

function Input.Bind(self: Input, machine: any?)
	if self.Machine == machine then
		return
	end
	self:ReleaseAll()
	self.Machine = machine
end

function Input.SetEnabled(self: Input, enabled: boolean)
	self.Enabled = enabled
	if not enabled then
		self:ReleaseAll()
		self:SetCapture(false)
	end
end

function Input.SetCapture(self: Input, captured: boolean)
	const shouldCapture = captured and self.Enabled and not self._destroyed
	if self.Captured == shouldCapture then
		return
	end
	self.Captured = shouldCapture
	self._accX = 0
	self._accY = 0
	self._skipMouse = if shouldCapture then 2 else 0

	if shouldCapture then
		if not self._captureSaved then
			self._savedBehavior = UserInputService.MouseBehavior
			self._savedIcon = UserInputService.MouseIconEnabled
			self._captureSaved = true
		end
		UserInputService.MouseBehavior = Enum.MouseBehavior.LockCenter
		UserInputService.MouseIconEnabled = false
	else
		UserInputService.MouseBehavior = self._savedBehavior
		UserInputService.MouseIconEnabled = self._savedIcon
		self:_setButtons(0)
	end

	if self.OnCaptureChanged then
		self.OnCaptureChanged(self.Captured)
	end
end

function Input.ToggleCapture(self: Input): boolean
	self:SetCapture(not self.Captured)
	return self.Captured
end

function Input.Step(self: Input)
	if not self.Captured or not self.Enabled or self._destroyed or not self.Machine then
		return
	end
	const delta = UserInputService:GetMouseDelta()
	if self._skipMouse > 0 then
		-- LockCenter warps the cursor to the middle; discard those first deltas.
		self._skipMouse -= 1
		return
	end
	self:_mouseDelta(delta.X, delta.Y)
end

function Input.ReleaseAll(self: Input)
	const machine = self.Machine
	const pressed = self._pressed
	self._pressed = {}
	if machine then
		for scancode in pressed do
			sendKey(machine, scancode, false)
		end
	end
	self:_setButtons(0)
	self._accX = 0
	self._accY = 0
end

function Input.Destroy(self: Input)
	if self._destroyed then
		return
	end
	self:ReleaseAll()
	self:SetCapture(false)
	self._destroyed = true
	self.Machine = nil
	for _, connection in self._connections do
		if connection.Connected then
			connection:Disconnect()
		end
	end
	table.clear(self._connections)
end

function Input._onInput(self: any, input: InputObject, processed: boolean, down: boolean)
	if not self.Enabled or self._destroyed then
		return
	end
	if input.UserInputType == Enum.UserInputType.Keyboard then
		-- Always honour a release: if focus moves while a key is held, the
		-- release can arrive marked processed and must still clear the make.
		if processed and down then
			return
		end
		const scancode = InputMap.scancode(input.KeyCode.Name)
		if scancode then
			self:_key(scancode, down)
		end
		return
	end
	-- A press over UI belongs to the UI, but a release must still clear a guest
	-- button that went down over the screen.
	if processed and down then
		return
	end
	const mask = MOUSE_BUTTONS[input.UserInputType]
	if mask then
		if down then
			self:_setButtons(bit32.bor(self._buttons, mask))
		else
			self:_setButtons(bit32.band(self._buttons, bit32.bnot(mask)))
		end
	end
end

function Input._key(self: any, scancode: number, down: boolean)
	if down then
		if self._pressed[scancode] then
			return -- Roblox may re-send InputBegan; do not repeat make codes.
		end
		self._pressed[scancode] = true
		if self.Machine then
			sendKey(self.Machine, scancode, true)
		end
	else
		if not self._pressed[scancode] then
			return
		end
		self._pressed[scancode] = nil
		if self.Machine then
			sendKey(self.Machine, scancode, false)
		end
	end
end

function Input._setButtons(self: any, buttons: number)
	if self._buttons == buttons then
		return
	end
	self._buttons = buttons
	if self.Machine then
		self:_mousePacket(self.Machine, 0, 0)
	end
end

function Input._mouseDelta(self: any, dx: number, dy: number)
	if not self.Machine then
		return
	end
	if self.InvertY then
		dy = -dy
	end
	self._accX += dx * self.Sensitivity
	self._accY += dy * self.Sensitivity

	const stepX = if self._accX >= 0 then math.floor(self._accX) else math.ceil(self._accX)
	const stepY = if self._accY >= 0 then math.floor(self._accY) else math.ceil(self._accY)
	self._accX -= stepX
	self._accY -= stepY
	if stepX ~= 0 or stepY ~= 0 then
		self:_mousePacket(self.Machine, stepX, stepY)
	end
end

function Input._mousePacket(self: any, machine: any, dx: number, dy: number)
	if type(machine.mouseMove) ~= "function" then
		return
	end
	if dx == 0 and dy == 0 then
		machine:mouseMove(0, 0, self._buttons)
		return
	end
	-- Kbc clamps each packet to +/-127; split big host deltas instead of losing
	-- the remainder.
	while dx ~= 0 or dy ~= 0 do
		const stepX = math.clamp(dx, -127, 127)
		const stepY = math.clamp(dy, -127, 127)
		machine:mouseMove(stepX, stepY, self._buttons)
		dx -= stepX
		dy -= stepY
	end
end

return Input
