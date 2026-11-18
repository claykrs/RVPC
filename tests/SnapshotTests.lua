--!nonstrict
-- SnapshotTests.lua -- delta checkpoints round-trip and resume deterministically.

local Memory = require("../core/Memory")
local Cpu = require("../core/Cpu")
local Pic = require("../core/Pic")
local Pit = require("../core/Pit")
local Machine = require("../core/Machine")
local Snapshot = require("../core/Snapshot")

local function build()
	local t = {
		count = 1,
		name = "fresh",
		nested = { x = 1, list = { 1, 2, 3 } },
		data = buffer.create(3 * 4096 + 100),
	}
	t.alias = t.nested
	t.method = function()
		return "own"
	end
	return t
end

local function newMachine()
	local m = Machine.new({ Memory = Memory, Cpu = Cpu, Pic = Pic, Pit = Pit }, {})
	local code = { 0x40, 0xA3, 0x00, 0x70, 0xEB, 0xFA }
	for i, b in code do
		m.mem:write8(0x6100 + i - 1, b)
	end
	m.cpu.cs = 0x0600
	m.cpu.segBase.cs = 0x6000
	m.cpu.ip = 0x0100
	m.cpu.halted = false
	return m
end

local function fingerprint(m)
	return string.format(
		"ax=%d ip=%04X mem=%d irq=%s",
		m.cpu.r[1],
		m.cpu.ip,
		m.mem:read16(0x7000),
		tostring(m.irqCount)
	)
end

return {
	{
		name = "delta_round_trips_scalars_tables_buffers_and_deletions",
		run = function(expect)
			local live = build()
			live.count = 42
			live.nested.x = 9
			live.nested.list[2] = 20
			live.nested.extra = { 5, 6 }
			live.name = nil
			live.fresh_field = "added"
			buffer.writeu8(live.data, 5, 200)
			buffer.writeu8(live.data, 2 * 4096 + 7, 77)
			local blob = Snapshot.capture(live, build(), { step = 123 })
			local target = build()
			local extra = Snapshot.apply(target, blob)
			expect(extra.step == 123, "extra payload comes back")
			expect(target.count == 42, "scalar restored")
			expect(target.name == nil, "deleted field removed")
			expect(target.fresh_field == "added", "new field restored")
			expect(target.nested.x == 9 and target.nested.list[2] == 20, "nested tables restored")
			expect(target.nested.extra[2] == 6, "table absent from fresh machine is recreated")
			expect(target.alias == target.nested, "aliases of untouched tables survive")
			expect(buffer.readu8(target.data, 5) == 200, "buffer page 0 restored")
			expect(buffer.readu8(target.data, 2 * 4096 + 7) == 77, "buffer page 2 restored")
			expect(buffer.readu8(target.data, 4096) == 0, "untouched page stays clean")
			expect(target.method() == "own", "functions are never overwritten")
		end,
	},
	{
		name = "unchanged_machine_produces_an_empty_delta",
		run = function(expect)
			local blob = Snapshot.capture(build(), build())
			local target = build()
			target.count = 7
			Snapshot.apply(target, blob)
			expect(target.count == 7, "no-op delta leaves the target alone")
		end,
	},
	{
		name = "bad_header_is_rejected",
		run = function(expect)
			local ok = pcall(Snapshot.apply, build(), "not a snapshot")
			expect(not ok, "garbage input errors")
		end,
	},
	{
		name = "restored_machine_runs_identically_to_the_original",
		run = function(expect)
			local live = newMachine()
			live:run(5000)
			local blob = Snapshot.capture(live, newMachine())
			live:run(7000)
			local want = fingerprint(live)
			local restored = newMachine()
			Snapshot.apply(restored, blob)
			restored:run(7000)
			expect(
				fingerprint(restored) == want,
				"want " .. want .. " got " .. fingerprint(restored)
			)
			expect(live.cpu.r[1] > 100, "program actually ran")
		end,
	},
}
