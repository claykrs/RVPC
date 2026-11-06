--!nonstrict
-- Cleaner.lua -- trove-style cleanup: Add collects instances, connections,
-- functions or cleanup-capable objects; Clean() disposes in reverse order.

const Cleaner = {}
Cleaner.__index = Cleaner

export type Disposable = Instance | RBXScriptConnection | (() -> ()) | any
export type Cleaner = {
	Add: <T>(self: Cleaner, item: T) -> T,
	Connect: (self: Cleaner, signal: RBXScriptSignal, fn: (...any) -> ()) -> RBXScriptConnection,
	Clean: (self: Cleaner) -> (),
}

local function dispose(item: any)
	const kind = typeof(item)
	if kind == "RBXScriptConnection" then
		if item.Connected then
			item:Disconnect()
		end
	elseif kind == "Instance" then
		item:Destroy()
	elseif kind == "function" then
		item()
	elseif kind == "table" then
		if type(item.Clean) == "function" then
			item:Clean()
		elseif type(item.Destroy) == "function" then
			item:Destroy()
		end
	end
end

function Cleaner.new(): Cleaner
	return setmetatable({ _items = {}, _cleaned = false }, Cleaner) :: any
end

function Cleaner.Add<T>(self: Cleaner, item: T): T
	assert(not (self :: any)._cleaned, "Cleaner:Clean already ran")
	const items = (self :: any)._items
	items[#items + 1] = item
	return item
end

function Cleaner.Connect(
	self: Cleaner,
	signal: RBXScriptSignal,
	fn: (...any) -> ()
): RBXScriptConnection
	return self:Add(signal:Connect(fn))
end

function Cleaner.Clean(self: Cleaner)
	const state = self :: any
	if state._cleaned then
		return
	end
	state._cleaned = true
	for index = #state._items, 1, -1 do
		dispose(state._items[index])
	end
	table.clear(state._items)
end

return Cleaner
