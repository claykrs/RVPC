--!nonstrict
-- check.lua -- run every gate the CI uses: format, lint, typecheck, tests.
-- Usage: lune run tools/check.lua

const fs = require("@lune/fs")
const process = require("@lune/process")

const WINDOWS = process.os == "windows"

local function tool(name: string): string
	const localPath = "tools/bin/" .. name .. (WINDOWS and ".exe" or "")
	if fs.isFile(localPath) then
		return localPath
	end
	return name -- installed globally (rokit / CI)
end

local function collect(dir: string, out: { string }, skip: { [string]: boolean }?)
	for _, entry in fs.readDir(dir) do
		const path = dir .. "/" .. entry
		if fs.isDir(path) then
			collect(path, out, skip)
		elseif string.find(entry, "%.lua$") and not (skip and skip[path]) then
			out[#out + 1] = path
		end
	end
end

-- Gate the tracked tree, not whatever scratch probes happen to be lying around
-- a development worktree. CI checks out exactly these files anyway.
local function trackedLua(): { string }?
	local ok, result = pcall(function()
		return process.exec("git", { "ls-files", "*.lua" })
	end)
	if not ok or not result.ok then
		return nil
	end
	local files = {}
	for line in string.gmatch(result.stdout, "[^\r\n]+") do
		files[#files + 1] = line
	end
	return files
end

local function run(label: string, command: string, args: { string }): boolean
	print("== " .. label)
	const result = process.exec(command, args)
	if #result.stdout > 0 then
		print(result.stdout)
	end
	if #result.stderr > 0 then
		print(result.stderr)
	end
	if not result.ok then
		print(("FAILED (%d): %s %s"):format(result.code, command, table.concat(args, " ")))
	end
	return result.ok
end

local failures = 0
const tracked = trackedLua()
const formatArgs: { string } = { "--check" }
if tracked and #tracked > 0 then
	for _, path in tracked do
		formatArgs[#formatArgs + 1] = path
	end
else
	formatArgs[#formatArgs + 1] = "."
end

if not run("format", tool("stylua"), formatArgs) then
	failures += 1
end

local core: { string } = {}
collect("core", core)
const coreForAnalyze: { string } = {}
for _, path in core do
	if path ~= "core/init.lua" then
		coreForAnalyze[#coreForAnalyze + 1] = path
	end
end

const lintDirs = { "tests", "tools" }
const lintArgs: { string } = {}
for _, path in coreForAnalyze do
	lintArgs[#lintArgs + 1] = path
end
if tracked and #tracked > 0 then
	for _, path in tracked do
		for _, dir in lintDirs do
			if string.sub(path, 1, #dir + 1) == dir .. "/" then
				lintArgs[#lintArgs + 1] = path
				break
			end
		end
	end
else
	for _, dir in lintDirs do
		lintArgs[#lintArgs + 1] = dir
	end
end
if not run("lint (luau)", tool("selene"), lintArgs) then
	failures += 1
end

if
	not run(
		"lint (roblox)",
		tool("selene"),
		{ "--config", "selene_roblox.toml", "core/init.lua", "roblox" }
	)
then
	failures += 1
end

const analyzeArgs: { string } = { "--mode=strict" }
for _, path in coreForAnalyze do
	analyzeArgs[#analyzeArgs + 1] = path
end
if not run("typecheck", tool("luau-analyze"), analyzeArgs) then
	failures += 1
end

if not run("tests", tool("lune"), { "run", "tools/run.lua" }) then
	failures += 1
end

if failures > 0 then
	print(("CHECK FAILED: %d stage(s)"):format(failures))
	process.exit(1)
end
print("CHECK PASSED")
