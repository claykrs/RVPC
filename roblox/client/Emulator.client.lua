--!nonstrict
-- Emulator.client.lua -- Roblox entrypoint for the RVPC shell.
--
-- Maps under StarterPlayerScripts via default.project.json. The core and UI
-- trees live in ReplicatedStorage as Rvpc and RvpcUi.

const ReplicatedStorage = game:GetService("ReplicatedStorage")

const Rvpc = require(ReplicatedStorage:WaitForChild("Rvpc"))
const RvpcUi = require(ReplicatedStorage:WaitForChild("RvpcUi"))
const Shell = require(script.Parent:WaitForChild("Shell"))

const handle = Shell.start(Rvpc, RvpcUi)

if handle then
	script.Destroying:Connect(function()
		handle:Destroy()
	end)
end
