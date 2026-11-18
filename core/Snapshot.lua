--!strict
-- Snapshot.lua -- delta checkpoints of a whole Machine.
--
-- A machine is a graph of plain tables, scalars and buffers plus methods that
-- live on metatables and on instance fields (closures). Saving closures is
-- not possible, so a checkpoint is a *delta against a freshly built machine*:
-- the caller supplies a factory that builds the same machine (same ROMs, same
-- base disk images, same config) and capture() walks the live graph and the
-- fresh one in lock-step, recording only scalar fields that differ, tables the
-- fresh machine lacks, and 4 KiB pages of buffers that differ. apply() builds
-- nothing itself: it overlays that delta onto another fresh machine, leaving
-- every function (including instance-patched ones) untouched.
--
-- Not captured: functions, metatables, userdata other than buffers, tables
-- used as keys. State that lives only in a closure's upvalues is therefore not
-- captured; the determinism test in tests/SnapshotTests.lua is the check that
-- a given machine configuration has none.

local Snapshot = {}

local PAGE = 4096
local MAGIC = "RVPCSNAP1"
local ZERO_PAGE = string.rep("\0", PAGE)

local pack = string.pack
-- string.unpack is typed as returning unknowns; every format used here yields
-- numbers (the one string result is only passed through as `any`).
local unpack = string.unpack :: (fmt: string, s: string, init: number?) -> ...number

local encodeValue: (v: any, out: { string }, seen: { [any]: boolean }) -> ()

local function encodeBuffer(b: buffer, out: { string })
	local len = buffer.len(b)
	local pages: { string } = {}
	local count = 0
	local off = 0
	while off < len do
		local n = math.min(PAGE, len - off)
		local s = buffer.readstring(b, off, n)
		if s ~= string.sub(ZERO_PAGE, 1, n) then
			count += 1
			pages[#pages + 1] = pack("<I4", off // PAGE)
			pages[#pages + 1] = s
		end
		off += PAGE
	end
	out[#out + 1] = pack("<I4I4", len, count)
	for _, p in pages do
		out[#out + 1] = p
	end
end

function encodeValue(v: any, out: { string }, seen: { [any]: boolean })
	local t = typeof(v)
	if t == "boolean" then
		out[#out + 1] = if v then "T" else "F"
	elseif t == "number" then
		out[#out + 1] = "N" .. pack("<d", v)
	elseif t == "string" then
		out[#out + 1] = "S" .. pack("<s4", v)
	elseif t == "buffer" then
		out[#out + 1] = "B"
		encodeBuffer(v, out)
	elseif t == "table" then
		if seen[v] then
			error("snapshot: cycle inside a table the fresh machine does not have")
		end
		seen[v] = true
		local keys: { { any } } = {}
		for k, val in v do
			local kt = typeof(k)
			local vt = typeof(val)
			if
				(kt == "string" or kt == "number" or kt == "boolean")
				and vt ~= "function"
				and vt ~= "thread"
				and vt ~= "userdata"
				and vt ~= "vector"
			then
				keys[#keys + 1] = { k, val }
			end
		end
		out[#out + 1] = "{" .. pack("<I4", #keys)
		for _, kv in keys do
			encodeValue(kv[1], out, seen)
			encodeValue(kv[2], out, seen)
		end
		seen[v] = nil
	else
		out[#out + 1] = "Z"
	end
end

local decodeValue: (data: string, pos: number) -> (any, number)

function decodeValue(data: string, pos: number): (any, number)
	local tag = string.sub(data, pos, pos)
	pos += 1
	if tag == "Z" then
		return nil, pos
	elseif tag == "T" then
		return true, pos
	elseif tag == "F" then
		return false, pos
	elseif tag == "N" then
		local n, p = unpack("<d", data, pos)
		return n, p
	elseif tag == "S" then
		local s, p = unpack("<s4", data, pos)
		return s, p
	elseif tag == "B" then
		local len, count = unpack("<I4I4", data, pos)
		pos += 8
		local b = buffer.create(len)
		for _ = 1, count do
			local idx = unpack("<I4", data, pos)
			pos += 4
			local off = idx * PAGE
			local n = math.min(PAGE, len - off)
			buffer.writestring(b, off, string.sub(data, pos, pos + n - 1))
			pos += n
		end
		return b, pos
	elseif tag == "{" then
		local count = unpack("<I4", data, pos)
		pos += 4
		local t: { [any]: any } = {}
		for _ = 1, count do
			local k, v
			k, pos = decodeValue(data, pos)
			v, pos = decodeValue(data, pos)
			t[k] = v
		end
		return t, pos
	end
	error("snapshot: bad value tag at " .. tostring(pos - 1))
end

local function encodePath(path: { any }, out: { string })
	out[#out + 1] = pack("<I2", #path)
	for _, key in path do
		encodeValue(key, out, {})
	end
end

local function emitSet(path: { any }, value: any, out: { string })
	out[#out + 1] = "V"
	encodePath(path, out)
	encodeValue(value, out, {})
end

local function emitBufferDiff(path: { any }, live: buffer, ref: buffer, out: { string })
	local len = buffer.len(live)
	local pages: { string } = {}
	local count = 0
	local off = 0
	while off < len do
		local n = math.min(PAGE, len - off)
		local s = buffer.readstring(live, off, n)
		if s ~= buffer.readstring(ref, off, n) then
			count += 1
			pages[#pages + 1] = pack("<I4", off // PAGE)
			pages[#pages + 1] = s
		end
		off += PAGE
	end
	if count == 0 then
		return
	end
	out[#out + 1] = "D"
	encodePath(path, out)
	out[#out + 1] = pack("<I4I4", len, count)
	for _, p in pages do
		out[#out + 1] = p
	end
end

local function skippable(vt: string): boolean
	return vt == "function" or vt == "thread" or vt == "userdata" or vt == "vector"
end

local function walk(
	live: any,
	ref: any,
	path: { any },
	out: { string },
	visited: { [any]: boolean }
)
	for k, v in live do
		local kt = typeof(k)
		if kt == "string" or kt == "number" or kt == "boolean" then
			local vt = typeof(v)
			path[#path + 1] = k
			if vt == "table" then
				if not visited[v] then
					visited[v] = true
					local r = ref[k]
					if typeof(r) == "table" then
						walk(v, r, path, out, visited)
					else
						emitSet(path, v, out)
					end
				end
			elseif vt == "buffer" then
				if not visited[v] then
					visited[v] = true
					local r = ref[k]
					if typeof(r) == "buffer" and buffer.len(r) == buffer.len(v) then
						emitBufferDiff(path, v, r, out)
					else
						emitSet(path, v, out)
					end
				end
			elseif not skippable(vt) then
				if ref[k] ~= v then
					emitSet(path, v, out)
				end
			end
			path[#path] = nil
		end
	end
	for k, r in ref do
		local kt = typeof(k)
		if (kt == "string" or kt == "number" or kt == "boolean") and live[k] == nil then
			if not skippable(typeof(r)) then
				path[#path + 1] = k
				emitSet(path, nil, out)
				path[#path] = nil
			end
		end
	end
end

-- Records how `live` differs from `ref` (a machine freshly built the same way).
-- `extra` is any plain-data table the caller wants stored alongside (driver
-- state such as step counters); apply() hands it back.
function Snapshot.capture(live: any, ref: any, extra: any?): string
	local out: { string } = { MAGIC }
	encodeValue(extra or {}, out, {})
	walk(live, ref, {}, out, { [live] = true })
	return table.concat(out)
end

local function resolve(root: any, path: { any }): any
	local t = root
	for i = 1, #path - 1 do
		local nxt = t[path[i]]
		if typeof(nxt) ~= "table" then
			error("snapshot: path does not exist in the fresh machine")
		end
		t = nxt
	end
	return t
end

-- Overlays a checkpoint onto `target`, a machine built exactly like the
-- reference was. Returns the `extra` table that was captured.
function Snapshot.apply(target: any, data: string): any
	if string.sub(data, 1, #MAGIC) ~= MAGIC then
		error("snapshot: bad header")
	end
	local pos = #MAGIC + 1
	local extra
	extra, pos = decodeValue(data, pos)
	local size = #data
	while pos <= size do
		local tag = string.sub(data, pos, pos)
		pos += 1
		local n = unpack("<I2", data, pos)
		pos += 2
		local path: { any } = {}
		for i = 1, n do
			path[i], pos = decodeValue(data, pos)
		end
		local parent = resolve(target, path)
		local key = path[#path]
		if tag == "V" then
			local v
			v, pos = decodeValue(data, pos)
			parent[key] = v
		elseif tag == "D" then
			local len, count = unpack("<I4I4", data, pos)
			pos += 8
			local b = parent[key]
			if typeof(b) ~= "buffer" or buffer.len(b) ~= len then
				error(
					"snapshot: buffer mismatch against the fresh machine at "
						.. table.concat(path, ".")
						.. " (len "
						.. tostring(len)
						.. " vs "
						.. (if typeof(b) == "buffer" then tostring(buffer.len(b)) else typeof(b))
						.. ")"
				)
			end
			for _ = 1, count do
				local idx = unpack("<I4", data, pos)
				pos += 4
				local off = idx * PAGE
				local len2 = math.min(PAGE, len - off)
				buffer.writestring(b, off, string.sub(data, pos, pos + len2 - 1))
				pos += len2
			end
		else
			error("snapshot: bad op tag at " .. tostring(pos - 3))
		end
	end
	return extra
end

return Snapshot
