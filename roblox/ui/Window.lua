--!nonstrict
-- Window.lua -- draggable Windows 3.0-style host window with title bar and
-- close button.

const UserInputService = game:GetService("UserInputService")

const Theme = require(script.Parent.Theme)
const Cleaner = require(script.Parent.Cleaner)
const Components = require(script.Parent.Components)
const State = require(script.Parent.State)

const Window = {}

export type Window = {
	Gui: Frame,
	Content: Frame,
	TitleLabel: TextLabel,
	Closed: State.State<boolean>,
	SetTitle: (self: Window, text: string) -> (),
	ClampToViewport: (self: Window) -> (),
	Clean: (self: Window) -> (),
}

local function rule(cleaner: any, parent: Instance, y: number, color: Color3): Frame
	const line = cleaner:Add(Instance.new("Frame"))
	line.Name = "Rule"
	line.Size = UDim2.new(1, 0, 0, 1)
	line.Position = UDim2.fromOffset(0, y)
	line.BackgroundColor3 = color
	line.BorderSizePixel = 0
	line.Parent = parent
	return line
end

function Window.new(title: string, size: UDim2, position: UDim2?): Window
	const cleaner = Cleaner.new()

	const gui = cleaner:Add(Instance.new("Frame"))
	gui.Size = size
	gui.Position = position or UDim2.fromScale(0.5, 0.5)
	gui.AnchorPoint = Vector2.new(0.5, 0.5)
	gui.BackgroundColor3 = Theme.Colors.Surface
	gui.BorderSizePixel = 0
	gui.Active = true
	gui.ClipsDescendants = true

	const border = cleaner:Add(Instance.new("UIStroke"))
	border.Color = Theme.Colors.Border
	border.Thickness = 1
	border.Parent = gui

	-- Windows 3.0 title bar: navy, white caption, square controls.
	const titleBar = cleaner:Add(Instance.new("Frame"))
	titleBar.Name = "TitleBar"
	titleBar.Size = UDim2.new(1, 0, 0, Theme.Sizes.TitleBar)
	titleBar.BackgroundColor3 = Theme.Colors.Accent
	titleBar.BorderSizePixel = 0
	titleBar.Parent = gui
	rule(cleaner, titleBar, 0, Theme.Colors.BevelLight)
	rule(cleaner, titleBar, Theme.Sizes.TitleBar - 1, Theme.Colors.Border)

	const titleLabel = Components.Label(cleaner, titleBar, {
		Text = title,
		Font = Theme.Fonts.UiBold,
		TextSize = Theme.Sizes.WindowTitle,
		TextColor3 = Theme.Colors.AccentText,
		Size = UDim2.new(1, -40, 1, -2),
		Position = UDim2.fromOffset(Theme.Sizes.Padding, 0),
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Center,
	})

	const closed = State.new(false)
	const closeButton = Components.Button(cleaner, titleBar, "X", function()
		closed:Set(true)
	end)
	closeButton.Name = "Close"
	closeButton.Size = UDim2.fromOffset(16, 16)
	closeButton.Position = UDim2.new(1, -20, 0, 4)
	closeButton.TextColor3 = Theme.Colors.Text
	closeButton.BackgroundColor3 = Theme.Colors.SurfaceRaised
	closeButton.TextSize = 11
	const closeStroke = cleaner:Add(Instance.new("UIStroke"))
	closeStroke.Color = Theme.Colors.BevelDark
	closeStroke.Thickness = 1
	closeStroke.Parent = closeButton

	const content = cleaner:Add(Instance.new("Frame"))
	content.Name = "Content"
	content.Size = UDim2.new(1, 0, 1, -Theme.Sizes.TitleBar)
	content.Position = UDim2.fromOffset(0, Theme.Sizes.TitleBar)
	content.BackgroundColor3 = Theme.Colors.Screen
	content.BorderSizePixel = 0
	content.Parent = gui

	local function clampToViewport()
		const parent = gui.Parent
		if not parent or not parent:IsA("GuiObject") then
			return
		end
		const size = gui.AbsoluteSize
		const area = parent.AbsoluteSize
		if size.X <= 0 or size.Y <= 0 or area.X <= 0 or area.Y <= 0 then
			return
		end
		-- Position is relative to the parent (the desktop frame), so clamp in
		-- local space instead of mixing screen insets with absolute pixels.
		const localX = gui.AbsolutePosition.X - parent.AbsolutePosition.X
		const localY = gui.AbsolutePosition.Y - parent.AbsolutePosition.Y
		const clampedX = math.clamp(localX, 0, math.max(0, area.X - size.X))
		const clampedY = math.clamp(localY, 0, math.max(0, area.Y - size.Y))
		gui.Position = UDim2.fromOffset(
			clampedX + size.X * gui.AnchorPoint.X,
			clampedY + size.Y * gui.AnchorPoint.Y
		)
	end
	task.delay(0.1, clampToViewport)

	-- dragging via the title bar
	local dragging = false
	local dragStart: Vector3? = nil
	local startPosition: UDim2? = nil
	const isDragInput = function(input: InputObject): boolean
		return input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
	end

	cleaner:Connect(titleBar.InputBegan, function(input: InputObject)
		if
			input.UserInputType == Enum.UserInputType.MouseButton1
			or input.UserInputType == Enum.UserInputType.Touch
		then
			dragging = true
			dragStart = input.Position
			startPosition = gui.Position
		end
	end)
	cleaner:Connect(UserInputService.InputChanged, function(input: InputObject)
		if
			not dragging
			or not dragStart
			or not startPosition
			or not (
				input.UserInputType == Enum.UserInputType.MouseMovement
				or input.UserInputType == Enum.UserInputType.Touch
			)
		then
			return
		end
		const delta = input.Position - dragStart
		gui.Position = UDim2.new(
			startPosition.X.Scale,
			startPosition.X.Offset + delta.X,
			startPosition.Y.Scale,
			startPosition.Y.Offset + delta.Y
		)
	end)
	cleaner:Connect(UserInputService.InputEnded, function(input: InputObject)
		if isDragInput(input) then
			dragging = false
			clampToViewport()
		end
	end)

	const window: Window = {
		Gui = gui,
		Content = content,
		TitleLabel = titleLabel,
		Closed = closed,
		SetTitle = function(_self: Window, text: string)
			titleLabel.Text = text
		end,
		ClampToViewport = function(_self: Window)
			clampToViewport()
		end,
		Clean = function(_self: Window)
			cleaner:Clean()
		end,
	}

	-- closing destroys the window
	closed:Subscribe(function(value: boolean)
		if value then
			task.defer(function()
				cleaner:Clean()
			end)
		end
	end)
	return window
end

return Window
