--!nonstrict
-- Components.lua -- small themed building blocks. Every creator takes a Cleaner
-- and parents to a given container; all instances register for cleanup.
-- Theme defaults apply FIRST so caller props always win.

const Theme = require(script.Parent.Theme)

const Components = {}

export type InstanceProps = { [string]: any }

local function base<T>(instance: T, defaults: InstanceProps, props: InstanceProps?, cleaner: any): T
	const target = instance :: any
	for key, value in defaults do
		target[key] = value
	end
	for key, value in props or {} do
		target[key] = value
	end
	cleaner:Add(instance)
	return instance
end

function Components.Panel(cleaner: any, parent: Instance, props: InstanceProps?): Frame
	const frame = base(Instance.new("Frame"), {
		BackgroundColor3 = Theme.Colors.Surface,
		BorderSizePixel = 0,
	}, props, cleaner)
	const corner = cleaner:Add(Instance.new("UICorner"))
	corner.CornerRadius = UDim.new(0, Theme.Sizes.Corner)
	corner.Parent = frame
	frame.Parent = parent
	return frame
end

function Components.Label(cleaner: any, parent: Instance, props: InstanceProps?): TextLabel
	const label = base(Instance.new("TextLabel"), {
		BackgroundTransparency = 1,
		Font = Theme.Fonts.Ui,
		TextSize = Theme.Sizes.BodyText,
		TextColor3 = Theme.Colors.Text,
		Text = "",
	}, props, cleaner)
	label.Parent = parent
	return label
end

function Components.Button(
	cleaner: any,
	parent: Instance,
	text: string,
	onClick: (() -> ())?
): TextButton
	const button = base(Instance.new("TextButton"), {
		Text = text,
		Font = Theme.Fonts.UiBold,
		TextSize = Theme.Sizes.BodyText,
		TextColor3 = Theme.Colors.Text,
		BackgroundColor3 = Theme.Colors.SurfaceRaised,
		BorderSizePixel = 0,
		AutoButtonColor = true,
	}, nil, cleaner)
	const corner = cleaner:Add(Instance.new("UICorner"))
	corner.CornerRadius = UDim.new(0, Theme.Sizes.Corner)
	corner.Parent = button
	if onClick then
		cleaner:Connect(button.MouseButton1Click, onClick)
	end
	button.Parent = parent
	return button
end

return Components
