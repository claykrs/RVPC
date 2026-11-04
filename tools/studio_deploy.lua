--!nonstrict
-- studio_deploy.lua -- build execute_luau args for deploying one tree into
-- Studio through the MCP bridge.
--
-- Payload rule: execute_luau double-decodes escapes, so the generated code
-- contains NO backslashes; Luau sources are base64-encoded and decoded by a
-- small pure-Luau decoder embedded in every chunk.
--
-- Usage:
--   lune run tools/studio_deploy.lua reinit
--   lune run tools/studio_deploy.lua core|ui|fixtures|client
--   lune run tools/studio_deploy.lua single <ModuleName>
-- Then:  node tools/mcp.mjs callfile execute_luau tools/deploy_args.json

const fs = require("@lune/fs")
const process = require("@lune/process")

const STUDIO_ID = process.env.RVPC_STUDIO_ID or "45da683b-c6f3-410f-b964-e7c6e4444f26"

local chunk = process.args[1] or "reinit"
local single = process.args[2]

const ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
const B64: { [number]: string } = {}
for index = 1, #ALPHABET do
	B64[index - 1] = string.sub(ALPHABET, index, index)
end

local function base64(data: string): string
	local out = {}
	for index = 1, #data, 3 do
		local a, b, c = string.byte(data, index, index + 2)
		local n = (a or 0) * 65536 + (b or 0) * 256 + (c or 0)
		local encoded = ""
		for shift = 18, 0, -6 do
			encoded ..= B64[math.floor(n / bit32.lshift(1, shift)) % 64]
		end
		out[#out + 1] = encoded
	end
	const pad = (3 - #data % 3) % 3
	local result = table.concat(out)
	if pad > 0 then
		result = string.sub(result, 1, #result - pad) .. string.rep("=", pad)
	end
	return result
end

local function jsonEscape(value: string): string
	local out = table.create(#value + 16)
	for index = 1, #value do
		const char = string.sub(value, index, index)
		const byte = string.byte(char) :: number
		if char == '"' or char == "\\" then
			out[#out + 1] = "\\" .. char
		elseif byte == 10 then
			out[#out + 1] = "\\n"
		elseif byte == 13 then
			out[#out + 1] = "\\r"
		elseif byte == 9 then
			out[#out + 1] = "\\t"
		elseif byte < 32 then
			out[#out + 1] = string.format("\\u%04x", byte)
		else
			out[#out + 1] = char
		end
	end
	return '"' .. table.concat(out) .. '"'
end

-- prelude (no backslashes): roots + base64 decoder + upsert helpers
const prelude = [=[
local RS = game:GetService("ReplicatedStorage")
local SPS = game:GetService("StarterPlayer"):WaitForChild("StarterPlayerScripts", 5)
local SSS = game:GetService("ServerScriptService")
local A2B = {}
do
	local chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/"
	for i = 1, #chars do
		A2B[string.sub(chars, i, i)] = i - 1
	end
end
local function b64(s)
	s = string.gsub(s, "=", "")
	local out = {}
	local acc = 0
	local count = 0
	for i = 1, #s do
		acc = acc * 64 + A2B[string.sub(s, i, i)]
		count = count + 1
		if count == 4 then
			out[#out + 1] = string.char(bit32.band(bit32.rshift(acc, 16), 255), bit32.band(bit32.rshift(acc, 8), 255), bit32.band(acc, 255))
			acc = 0
			count = 0
		end
	end
	if count == 2 then
		out[#out + 1] = string.char(bit32.band(bit32.rshift(acc, 4), 255))
	elseif count == 3 then
		out[#out + 1] = string.char(bit32.band(bit32.rshift(acc, 10), 255), bit32.band(bit32.rshift(acc, 2), 255))
	end
	return table.concat(out)
end
local function upsert(parent, name, className)
	local child = parent:FindFirstChild(name)
	if not child or not child:IsA(className) then
		if child then child:Destroy() end
		child = Instance.new(className)
		child.Name = name
		child.Parent = parent
	end
	return child
end
]=]

type Tree = {
	dir: string,
	container: string,
	className: string,
	init: string?,
}

const TREES: { [string]: Tree } = {
	core = { dir = "core", container = "Rvpc", className = "ModuleScript", init = "init.lua" },
	ui = { dir = "roblox/ui", container = "RvpcUi", className = "ModuleScript", init = "init.lua" },
	fixtures = { dir = "fixtures", container = "RvpcFixtures", className = "Folder", init = nil },
	client = { dir = "roblox/client", container = "RvpcClient", className = "Folder", init = nil },
	server = { dir = "roblox/server", container = "RvpcServer", className = "Folder", init = nil },
}

local function rootExpr(spec: Tree): string
	if spec.container == "RvpcClient" then
		return "SPS"
	elseif spec.container == "RvpcServer" then
		return "SSS"
	end
	return "RS"
end

local function childCode(containerExpr: string, dir: string, initFile: string?): string
	local code = ""
	for _, entry in fs.readDir(dir) do
		if
			entry ~= initFile
			and not fs.isDir(dir .. "/" .. entry)
			and string.find(entry, "%.lua$")
		then
			const encoded = base64(fs.readFile(dir .. "/" .. entry))
			local name = string.gsub(entry, "%.lua$", "")
			local className = "ModuleScript"
			if string.find(entry, ".client.lua", 1, true) then
				name = string.gsub(name, "%.client$", "")
				className = "LocalScript"
			elseif string.find(entry, ".server.lua", 1, true) then
				name = string.gsub(name, "%.server$", "")
				className = "Script"
			end
			code = code
				.. ("local m = upsert(%s, %q, %q)\n"):format(containerExpr, name, className)
				.. ("m.Source = b64(%q)\n"):format(encoded)
		end
	end
	return code
end

local code: string
if chunk == "reinit" then
	code = prelude
	for _, key in { "core", "ui", "fixtures", "client", "server" } do
		const spec = TREES[key]
		const parent = rootExpr(spec)
		local initSource = spec.init and base64(fs.readFile(spec.dir .. "/" .. spec.init)) or nil
		code = code
			.. ("local %s = upsert(%s, %q, %q)\n"):format(
				spec.container,
				parent,
				spec.container,
				spec.className
			)
		if initSource then
			code = code .. ("%s.Source = b64(%q)\n"):format(spec.container, initSource)
		end
	end
	code = code .. 'return "reinit ok"'
elseif chunk == "single" then
	assert(single, "usage: studio_deploy.lua single <ModuleName>")
	local found: Tree? = nil
	for _, spec in TREES do
		if fs.isFile(spec.dir .. "/" .. single .. ".lua") then
			found = spec
			break
		end
	end
	assert(found, "unknown module " .. single)
	const spec = found :: Tree
	const parent = rootExpr(spec)
	const encoded = base64(fs.readFile(spec.dir .. "/" .. single .. ".lua"))
	code = prelude
		.. ("local root = upsert(%s, %q, %q)\n"):format(parent, spec.container, spec.className)
		.. ('local m = upsert(root, %q, "ModuleScript")\n'):format(single)
		.. ("m.Source = b64(%q)\n"):format(encoded)
		.. ("return %q"):format(single .. " ok")
else
	const spec = assert(TREES[chunk], "unknown chunk " .. chunk)
	const parent = rootExpr(spec)
	code = prelude
		.. ("local root = upsert(%s, %q, %q)\n"):format(parent, spec.container, spec.className)
		.. childCode("root", spec.dir, spec.init)
		.. ("return %q"):format(chunk .. " ok")
end

assert(not string.find(code, "\\", 1, true), "payload contains a backslash")

fs.writeFile(
	"tools/deploy_args.json",
	'{"code": '
		.. jsonEscape(code)
		.. ', "datamodel_type": "Edit", "studio_id": "'
		.. STUDIO_ID
		.. '"}'
)
print(("chunk %s: %d bytes"):format(chunk, #code))
