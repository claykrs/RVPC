--!strict
-- VgaSink.lua -- dirty-rectangle presenter for a Vga device.
--
-- The core owns no Roblox types. A host supplies present(pixels, width, height,
-- rect); the Roblox adapter turns that into an EditableImage write, while the
-- Lune harness can save a PPM or inspect the buffer.

const VgaSink = {}
VgaSink.__index = VgaSink

export type Rect = {
	x: number,
	y: number,
	width: number,
	height: number,
}

export type Present = (pixels: buffer, width: number, height: number, rect: Rect) -> ()

export type VgaSink = typeof(setmetatable(
	{} :: {
		vga: any,
		present: Present,
		frames: number,
		lastRect: Rect?,
		lastPixels: buffer?,
		poll: (self: VgaSink, force: boolean?) -> boolean,
		invalidate: (self: VgaSink) -> (),
	},
	VgaSink
))

function VgaSink.new(vga: any, present: Present?): VgaSink
	local self = setmetatable({
		vga = vga,
		present = present
			or function(_pixels: buffer, _width: number, _height: number, _rect: Rect) end,
		frames = 0,
		lastRect = nil,
		lastPixels = nil,
	}, VgaSink) :: any
	return self
end

function VgaSink.invalidate(self: VgaSink)
	self.vga:markAllDirty()
end

-- Present only when the VGA has a dirty rectangle, or when force is set. The
-- region snapshot preserves pixels outside the rectangle from prior frames.
function VgaSink.poll(self: VgaSink, force: boolean?): boolean
	local rect: Rect? = self.vga:consumeDirty()
	if not rect and not force then
		return false
	end
	const activeRect: Rect = rect
		or {
			x = 0,
			y = 0,
			width = self.vga:width() :: number,
			height = self.vga:height() :: number,
		}
	const pixels =
		self.vga:snapshotRegionRGBA(activeRect.x, activeRect.y, activeRect.width, activeRect.height)
	self.present(pixels, self.vga:width() :: number, self.vga:height() :: number, activeRect)
	self.frames += 1
	self.lastRect = activeRect
	self.lastPixels = pixels
	return true
end

return VgaSink
