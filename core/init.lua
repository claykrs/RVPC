--!strict
-- init.lua -- RVPC core index.

const Rvpc = {}

Rvpc.Memory = require(script.Memory)
Rvpc.Cpu = require(script.Cpu)
Rvpc.Fpu = require(script.Fpu)
Rvpc.Dma = require(script.Dma)
Rvpc.Sb16 = require(script.Sb16)
Rvpc.Vga = require(script.Vga)
Rvpc.VgaSink = require(script.VgaSink)
Rvpc.InputMap = require(script.InputMap)
Rvpc.Pic = require(script.Pic)
Rvpc.Pit = require(script.Pit)
Rvpc.Cmos = require(script.Cmos)
Rvpc.FwCfg = require(script.FwCfg)
Rvpc.Ide = require(script.Ide)
Rvpc.Kbc = require(script.Kbc)
Rvpc.Ne2000 = require(script.Ne2000)
Rvpc.Isp = require(script.Isp)
Rvpc.Xms = require(script.Xms)
Rvpc.Uart = require(script.Uart)
Rvpc.Lpt = require(script.Lpt)
Rvpc.Machine = require(script.Machine)

return Rvpc
