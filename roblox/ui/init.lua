--!nonstrict
-- init.lua -- the RvpcUi tree as one ModuleScript.
-- Consumers: `const RvpcUi = require(ReplicatedStorage:WaitForChild("RvpcUi"))`.

const RvpcUi = {
	Theme = require(script.Theme),
	Cleaner = require(script.Cleaner),
	State = require(script.State),
	Components = require(script.Components),
	Window = require(script.Window),
	VgaView = require(script.VgaView),
}

return RvpcUi
