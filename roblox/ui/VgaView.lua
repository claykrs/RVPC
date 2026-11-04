--!nonstrict
-- VgaView.lua -- Roblox EditableImage presenter for a Vga device.
--
-- The core VgaSink computes dirty regions and an RGBA buffer. This adapter
-- creates/recreates an EditableImage when the guest changes video mode and
-- uploads the full retained frame; the ImageLabel stretches it to the window.

const AssetService = game:GetService("AssetService")

const VgaSink = require(script.Parent.Parent.Rvpc.VgaSink)

const VgaView = {}
VgaView.__index = VgaView

export type Options = {
	width: number?,
	height: number?,
	background: Color3?,
}

export type VgaView = {
	Frame: Frame,
	Image: ImageLabel,
	Status: TextLabel,
	Sink: any,
	EditableImage: any?,
	Poll: (self: VgaView) -> (),
	Destroy: (self: VgaView) -> (),
}

local function createEditableImage(width: number, height: number): any?
	const ok, image = pcall(function()
		return AssetService:CreateEditableImage({ Size = Vector2.new(width, height) })
	end)
	if ok and image then
		return image
	end
	return nil
end

function VgaView.new(vga: any, parent: Instance, options: Options?): VgaView
	const cfg = options or {}
	const self = setmetatable({}, VgaView) :: any

	const frame = Instance.new("Frame")
	frame.Name = "VgaView"
	frame.BackgroundColor3 = cfg.background or Color3.new(0, 0, 0)
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Size = UDim2.fromOffset(cfg.width or 640, cfg.height or 480)
	frame.Parent = parent

	const imageLabel = Instance.new("ImageLabel")
	imageLabel.Name = "Screen"
	imageLabel.BackgroundTransparency = 1
	imageLabel.BorderSizePixel = 0
	imageLabel.Size = UDim2.fromScale(1, 1)
	imageLabel.ScaleType = Enum.ScaleType.Stretch
	imageLabel.Parent = frame

	const aspect = Instance.new("UIAspectRatioConstraint")
	aspect.AspectRatio = (cfg.width or 640) / (cfg.height or 480)
	aspect.AspectType = Enum.AspectType.FitWithinMaxSize
	aspect.Parent = frame

	const status = Instance.new("TextLabel")
	status.Name = "Fallback"
	status.BackgroundTransparency = 1
	status.Size = UDim2.fromScale(1, 1)
	status.Font = Enum.Font.Code
	status.TextSize = 16
	status.TextColor3 = Color3.fromRGB(220, 220, 220)
	status.TextWrapped = true
	status.Text = ""
	status.Visible = false
	status.Parent = frame

	self.Frame = frame
	self.Image = imageLabel
	self.Status = status
	self.EditableImage = nil
	self.Sink = nil

	local function attach(width: number, height: number)
		const image = createEditableImage(width, height)
		if not image then
			status.Text = "EditableImage unavailable"
			status.Visible = true
			return
		end
		imageLabel.ImageContent = Content.fromObject(image)
		status.Visible = false
		self.EditableImage = image
		self.Sink = VgaSink.new(vga, function(pixels: buffer)
			image:WritePixelsBuffer(Vector2.zero, Vector2.new(width, height), pixels)
		end)
		self.Sink:poll(true)
	end

	attach(vga:width(), vga:height())

	function self:Poll()
		if
			self.Sink
			and (
				vga:width() ~= self.EditableImage.Size.X
				or vga:height() ~= self.EditableImage.Size.Y
			)
		then
			if self.EditableImage.Destroy then
				self.EditableImage:Destroy()
			end
			self.EditableImage = nil
			self.Sink = nil
			attach(vga:width(), vga:height())
		end
		if self.Sink then
			self.Sink:poll()
		end
	end

	function self:Destroy()
		if self.EditableImage and self.EditableImage.Destroy then
			self.EditableImage:Destroy()
		end
		frame:Destroy()
	end

	return self
end

return VgaView
