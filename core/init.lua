--!strict
-- init.lua -- RVDM98 core index.

const Vdm = {}

Vdm.Memory = require(script.Memory)
Vdm.Cpu = require(script.Cpu)
Vdm.Vga = require(script.Vga)
Vdm.Pic = require(script.Pic)
Vdm.Pit = require(script.Pit)
Vdm.Cmos = require(script.Cmos)
Vdm.FwCfg = require(script.FwCfg)
Vdm.Ide = require(script.Ide)
Vdm.Kbc = require(script.Kbc)
Vdm.Xms = require(script.Xms)
Vdm.Uart = require(script.Uart)
Vdm.Lpt = require(script.Lpt)
Vdm.Machine = require(script.Machine)

return Vdm
