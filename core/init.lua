--!strict
-- init.lua -- RVDM98 core index.

const Vdm = {}

Vdm.Memory = require(script.Memory)
Vdm.Cpu = require(script.Cpu)
Vdm.Vga = require(script.Vga)
Vdm.Xms = require(script.Xms)
Vdm.Uart = require(script.Uart)
Vdm.Lpt = require(script.Lpt)
Vdm.Machine = require(script.Machine)

return Vdm
