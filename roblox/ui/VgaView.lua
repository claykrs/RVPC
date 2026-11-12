--!nonstrict
-- VgaView.lua -- Roblox EditableImage presenter for a Vga device.
--
-- The core VgaSink computes dirty regions and an RGBA snapshot. This adapter
-- creates/recreates an EditableImage when the guest changes video mode and
-- uploads each presented region. Today Vga.snapshotRegionRGBA returns the whole
-- retained frame and the rect says which pixels changed; the buffer length is
-- checked so a future compact-region snapshot also works. Full-frame snapshots
-- are packed down to the dirty rect before WritePixelsBuffer so a one-pixel
-- change does not re-upload the entire screen.
--
-- API: VgaView.new(vga, parent, options), view:Poll(force?), view:Destroy().
-- force repaints even without a dirty rect (the shell uses this for text mode,
-- whose B8000 writes are outside the VGA aperture). If EditableImage/Content is
-- unavailable the view keeps a diagnostic TextLabel and retries creation
-- occasionally instead of erroring every frame.

const AssetService = game:GetService("AssetService")

const VgaSink = require(script.Parent.Parent.Rvpc.VgaSink)

const VgaView = {}
VgaView.__index = VgaView

const RETRY_SECONDS = 5

export type Options = {
	width: number?,
	height: number?,
	size: UDim2?,
	background: Color3?,
	aspect: boolean?,
	-- snap the frame to an integer multiple of the guest resolution, centered;
	-- non-integer fills blur every glyph, integer scaling keeps them crisp
	integerScale: boolean?,
	-- vertical center position (0..1 scale) for the snapped frame
	integerScaleY: number?,
}

export type VgaView = {
	Frame: Frame,
	Image: ImageLabel,
	Status: TextLabel,
	Sink: any,
	EditableImage: any?,
	Poll: (self: VgaView, force: boolean?) -> (),
	Destroy: (self: VgaView) -> (),
}

-- CreateEditableImage is the blank-image constructor. CreateEditableImageAsync
-- is for loading an existing Content and does not accept Size, so it is not a
-- fallback here.
local function createEditableImage(width: number, height: number): any?
	local ok, method = pcall(function()
		return AssetService.CreateEditableImage
	end)
	if not ok or type(method) ~= "function" then
		return nil
	end
	local okCreate, image = pcall(method, AssetService, {
		Size = Vector2.new(width, height),
	})
	if okCreate then
		return image
	end
	return nil
end

function VgaView.new(vga: any, parent: Instance, options: Options?): VgaView
	const cfg = options or {}
	const self = setmetatable({}, VgaView) :: any

	-- The EditableImage must match the VGA's current geometry, which is 640x400
	-- in text mode. width/height options only size the on-screen frame hint.
	const initialWidth = vga:width()
	const initialHeight = vga:height()

	const frame = Instance.new("Frame")
	frame.Name = "VgaView"
	frame.BackgroundColor3 = cfg.background or Color3.new(0, 0, 0)
	frame.BorderSizePixel = 0
	frame.ClipsDescendants = true
	frame.Size = cfg.size
		or UDim2.fromOffset(cfg.width or initialWidth, cfg.height or initialHeight)
	frame.Parent = parent

	const imageLabel = Instance.new("ImageLabel")
	imageLabel.Name = "Screen"
	imageLabel.BackgroundTransparency = 1
	imageLabel.BorderSizePixel = 0
	imageLabel.Size = UDim2.fromScale(1, 1)
	imageLabel.ScaleType = Enum.ScaleType.Stretch
	imageLabel.ResampleMode = Enum.ResamplerMode.Pixelated
	imageLabel.Parent = frame

	local aspect = nil
	if cfg.aspect ~= false then
		aspect = Instance.new("UIAspectRatioConstraint")
		aspect.AspectRatio = initialWidth / initialHeight
		aspect.AspectType = Enum.AspectType.FitWithinMaxSize
		aspect.Parent = frame
	end

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
	status.ZIndex = 2
	status.Parent = frame

	self.Frame = frame
	self.Image = imageLabel
	self.Status = status
	self.EditableImage = nil
	self.Sink = nil
	self.RetryAt = 0
	self._width = initialWidth
	self._height = initialHeight
	self._destroyed = false

	-- snap the frame to an integer multiple of the guest resolution, centered:
	-- a fractional fill makes the pixelated resampler draw glyphs with uneven
	-- pixel sizes, which reads as blur on text
	local function applyIntegerScale()
		if not cfg.integerScale then
			return
		end
		if not parent:IsA("GuiObject") then
			return
		end
		local abs = parent.AbsoluteSize
		if abs.X < 1 or abs.Y < 1 then
			return
		end
		local scale = math.max(1, math.floor(math.min(abs.X / self._width, abs.Y / self._height)))
		local holder = frame:FindFirstChild("UIAspectRatioConstraint")
		if holder then
			holder:Destroy()
		end
		frame.AnchorPoint = Vector2.new(0.5, 0.5)
		frame.Position = UDim2.fromScale(0.5, cfg.integerScaleY or 0.5)
		frame.Size = UDim2.fromOffset(self._width * scale, self._height * scale)
	end
	self._applyIntegerScale = applyIntegerScale
	if cfg.integerScale then
		pcall(function()
			(parent :: any).PropertyChanged:Connect(function(prop: string)
				if prop == "AbsoluteSize" or prop == "Size" then
					applyIntegerScale()
				end
			end)
		end)
	end

	local function attach(width: number, height: number)
		if self._destroyed then
			return
		end
		const image = createEditableImage(width, height)
		if not image then
			status.Text = "EditableImage unavailable on this client"
			status.Visible = true
			self.RetryAt = os.clock() + RETRY_SECONDS
			return
		end

		const okContent = pcall(function()
			imageLabel.ImageContent = Content.fromObject(image)
		end)
		if not okContent then
			if image.Destroy then
				image:Destroy()
			end
			status.Text = "Content.fromObject unavailable on this client"
			status.Visible = true
			self.RetryAt = os.clock() + RETRY_SECONDS
			return
		end

		status.Visible = false
		self.EditableImage = image
		self._width = width
		self._height = height
		self.RetryAt = 0
		if aspect then
			aspect.AspectRatio = width / height
		end

		local regionBuffer = nil
		local regionCapacity = 0

		local function packRegion(pixels: buffer, frameWidth: number, rect: any): buffer
			const regionWidth = rect.width
			const regionHeight = rect.height
			const regionBytes = regionWidth * regionHeight * 4
			if not regionBuffer or regionCapacity < regionBytes then
				regionBuffer = buffer.create(regionBytes)
				regionCapacity = regionBytes
			end
			const rowBytes = regionWidth * 4
			for row = 0, regionHeight - 1 do
				const source = ((rect.y + row) * frameWidth + rect.x) * 4
				buffer.copy(regionBuffer, row * rowBytes, pixels, source, rowBytes)
			end
			return regionBuffer
		end

		self.Sink = VgaSink.new(
			vga,
			function(pixels: buffer, frameWidth: number, frameHeight: number, rect: any)
				if self._destroyed or self.EditableImage ~= image then
					return
				end
				const regionBytes = rect.width * rect.height * 4
				const fullBytes = frameWidth * frameHeight * 4
				const okWrite, err = pcall(function()
					if buffer.len(pixels) == regionBytes then
						image:WritePixelsBuffer(
							Vector2.new(rect.x, rect.y),
							Vector2.new(rect.width, rect.height),
							pixels
						)
					elseif buffer.len(pixels) == fullBytes then
						image:WritePixelsBuffer(
							Vector2.new(rect.x, rect.y),
							Vector2.new(rect.width, rect.height),
							packRegion(pixels, frameWidth, rect)
						)
					else
						error("unexpected VGA buffer length")
					end
				end)
				if not okWrite then
					status.Text = "VGA upload failed: " .. tostring(err)
					status.Visible = true
					self.Sink = nil
					self.EditableImage = nil
					self.RetryAt = os.clock() + RETRY_SECONDS
					if image.Destroy then
						image:Destroy()
					end
				end
			end
		)
		if self.Sink then
			self.Sink:poll(true)
		end
		applyIntegerScale()
	end

	attach(initialWidth, initialHeight)

	function self:Poll(force: boolean?)
		if self._destroyed then
			return
		end
		const width = vga:width()
		const height = vga:height()
		if self.Sink and (width ~= self._width or height ~= self._height) then
			self.Sink = nil
			if self.EditableImage and self.EditableImage.Destroy then
				self.EditableImage:Destroy()
			end
			self.EditableImage = nil
			attach(width, height)
			return
		end
		if not self.Sink then
			if os.clock() >= self.RetryAt then
				attach(width, height)
			end
			return
		end
		-- Advance the text cursor/attribute blink once per presented frame.
		-- Snapshots themselves stay phase-stable; the presenter owns the clock.
		if self.Sink.vga.tickBlink then
			pcall(self.Sink.vga.tickBlink, self.Sink.vga)
		end
		if vga:isTextMode() then
			-- Text writes are invisible to dirty tracking, so a plain force
			-- would repaint the whole 1 MiB frame at a fixed rate whether or
			-- not anything changed. Poll the visible-plane checksum every
			-- frame instead: the presenter updates the moment the guest
			-- writes text and stays idle while it does not.
			local okSum, sum = pcall(function()
				return vga:textChecksum()
			end)
			if okSum then
				if sum == self._lastTextSum then
					return
				end
				self._lastTextSum = sum
				self.Sink:poll(true)
				return
			end
		end
		self.Sink:poll(force)
	end

	function self:Destroy()
		if self._destroyed then
			return
		end
		self._destroyed = true
		self.Sink = nil
		if self.EditableImage and self.EditableImage.Destroy then
			self.EditableImage:Destroy()
		end
		self.EditableImage = nil
		frame:Destroy()
	end

	return self
end

return VgaView
