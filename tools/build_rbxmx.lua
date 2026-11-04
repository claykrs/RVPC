--!nonstrict
-- build_rbxmx.lua -- generate Vdm.rbxmx (Roblox model XML) for manual import:
--   Vdm            (ModuleScript tree from core/)          -> ReplicatedStorage
--   VdmUi          (ModuleScript tree from roblox/ui/)     -> ReplicatedStorage
--   VdmFixtures    (Folder tree from fixtures/)            -> ReplicatedStorage
--   VdmClient      (Folder tree from roblox/client/)       -> StarterPlayerScripts
-- Run from the repo root: lune run tools/build_rbxmx.lua

const fs = require("@lune/fs")

local function cdata(source: string): string
	return "<![CDATA[" .. (string.gsub(source, "]]>", "]]]]><![CDATA[>")) .. "]]>"
end

local referent = 0
local function nextRef(): string
	referent += 1
	return "RBX" .. referent
end

local function scriptItem(class: string, name: string, source: string, indent: string): string
	return string.format(
		'%s<Item class="%s" referent="%s">\n'
			.. "%s  <Properties>\n"
			.. '%s    <string name="Name">%s</string>\n'
			.. '%s    <ProtectedString name="Source">%s</ProtectedString>\n'
			.. "%s  </Properties>\n",
		indent,
		class,
		nextRef(),
		indent,
		indent,
		name,
		indent,
		cdata(source),
		indent
	)
end

local function folderItem(name: string, indent: string): string
	return string.format(
		'%s<Item class="Folder" referent="%s">\n'
			.. "%s  <Properties>\n"
			.. '%s    <string name="Name">%s</string>\n'
			.. "%s  </Properties>\n",
		indent,
		nextRef(),
		indent,
		indent,
		name,
		indent
	)
end

local function luaItem(path: string, name: string, indent: string): string
	const source = fs.readFile(path)
	if string.find(name, ".client.lua", 1, true) then
		const className = "LocalScript"
		const scriptName = string.gsub(name, ".client.lua$", "")
		return scriptItem(className, scriptName, source, indent) .. indent .. "</Item>\n"
	end
	const scriptName = string.gsub(name, "%.lua$", "")
	return scriptItem("ModuleScript", scriptName, source, indent) .. indent .. "</Item>\n"
end

local function tree(
	dirPath: string,
	outName: string,
	indent: string,
	initFile: string?,
	class: string
): string
	local out: string
	if initFile then
		out = scriptItem(class, outName, fs.readFile(dirPath .. "/" .. initFile), indent)
	else
		out = folderItem(outName, indent)
	end
	for _, entry in fs.readDir(dirPath) do
		const full = dirPath .. "/" .. entry
		if entry ~= initFile and not fs.isDir(full) and string.find(entry, "%.lua$") then
			out = out .. luaItem(full, entry, indent .. "  ")
		end
	end
	return out .. indent .. "</Item>\n"
end

local doc = '<?xml version="1.0" encoding="utf-8"?>\n'
	.. '<roblox xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance" version="4">\n'
doc = doc .. tree("core", "Vdm", "  ", "init.lua", "ModuleScript")
doc = doc .. tree("roblox/ui", "VdmUi", "  ", "init.lua", "ModuleScript")
doc = doc .. tree("fixtures", "VdmFixtures", "  ", nil, "Folder")
doc = doc .. tree("roblox/client", "VdmClient", "  ", nil, "Folder")
doc = doc .. "</roblox>\n"
fs.writeFile("Vdm.rbxmx", doc)
print(("wrote Vdm.rbxmx (%d bytes, %d items)"):format(#doc, referent))
