--!nonstrict
-- State.lua -- minimal observable value: Get/Set/Subscribe for UI bindings.

const State = {}
State.__index = State

export type State<T> = {
	Get: (self: State<T>) -> T,
	Set: (self: State<T>, value: T) -> (),
	Subscribe: (self: State<T>, fn: (T) -> ()) -> () -> (),
}

function State.new<T>(initial: T): State<T>
	return setmetatable({ _value = initial, _subs = {} }, State) :: any
end

function State.Get<T>(self: State<T>): T
	return (self :: any)._value
end

function State.Set<T>(self: State<T>, value: T)
	const state = self :: any
	if state._value == value then
		return
	end
	state._value = value
	for _, callback in table.clone(state._subs) do
		callback(value)
	end
end

function State.Subscribe<T>(self: State<T>, fn: (T) -> ()): () -> ()
	const state = self :: any
	state._subs[#state._subs + 1] = fn
	fn(state._value)
	return function()
		const index = table.find(state._subs, fn)
		if index then
			table.remove(state._subs, index)
		end
	end
end

return State
