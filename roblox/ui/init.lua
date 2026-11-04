--!nonstrict
-- init.lua -- the VdmUi tree as one ModuleScript.
-- Consumers: `const VdmUi = require(ReplicatedStorage:WaitForChild("VdmUi"))`.

const VdmUi = {
	Theme = require(script.Theme),
	Cleaner = require(script.Cleaner),
	State = require(script.State),
	Components = require(script.Components),
	Window = require(script.Window),
}

return VdmUi
