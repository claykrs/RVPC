--!nonstrict
-- win98_run.lua -- headless Win98 SE Setup driver with checkpoints.
--
-- Drives the CD boot menus and Setup prompts, prints each screen change and
-- stops on a CPU fault or the "Bad Fault" screen. A run can save a checkpoint
-- (a delta against a freshly built machine, see core/Snapshot.lua) and later
-- resume from it, so a fix near step 2.7B is retried in minutes, not an hour.
--
-- Usage:
--   lune run tools/win98_run.lua --budget 3500 --save-at 2700 --save tools/out/w98.snap
--   lune run tools/win98_run.lua --load tools/out/w98.snap --budget 3500
--   lune run tools/win98_run.lua --verify 40 --verify-span 20   (determinism proof)
--
-- Options (millions of steps): --budget (absolute), --steps (relative to --load), --save-at, --save-every (rolling
-- checkpoints named <save>.<N>m), --verify, --verify-span.
-- Paths: --iso, --hdd, --boot, --save, --load. The HDD/ISO/boot images are the
-- same ones the probes use and must be the same ones a checkpoint was taken on.

local fs = require("@lune/fs")
local process = require("@lune/process")
local Memory = require("../core/Memory")
local Cpu = require("../core/Cpu")
local Vga = require("../core/Vga")
local Pic = require("../core/Pic")
local Pit = require("../core/Pit")
local Cmos = require("../core/Cmos")
local FwCfg = require("../core/FwCfg")
local Ide = require("../core/Ide")
local Kbc = require("../core/Kbc")
local Fpu = require("../core/Fpu")
local Dma = require("../core/Dma")
local Sb16 = require("../core/Sb16")
local Fdc = require("../core/Fdc")
local Ne2000 = require("../core/Ne2000")
local Isp = require("../core/Isp")
local Xms = require("../core/Xms")
local Uart = require("../core/Uart")
local Lpt = require("../core/Lpt")
local Machine = require("../core/Machine")
local Snapshot = require("../core/Snapshot")

local opts = {
	iso = "media/win98se-ide.iso",
	hdd = "media/win98-hdd-xms.img",
	boot = "media/win98-boot.img",
	budget = 3500,
	save = "tools/out/win98.snap",
}
do
	local args = process.args
	local i = 1
	while i <= #args do
		local key = string.match(args[i], "^%-%-(.+)$")
		if not key then
			error("unexpected argument " .. args[i])
		end
		local value = args[i + 1]
		if value == nil then
			error("missing value for --" .. key)
		end
		key = string.gsub(key, "%-(%w)", string.upper)
		opts[key] = tonumber(value) or value
		i += 2
	end
end

local function build()
	local bootImage = if fs.isFile(opts.boot)
		then buffer.fromstring(fs.readFile(opts.boot))
		else nil
	local m = Machine.new({
		Memory = Memory,
		Cpu = Cpu,
		Vga = Vga,
		Pic = Pic,
		Pit = Pit,
		Cmos = Cmos,
		FwCfg = FwCfg,
		Ide = Ide,
		Kbc = Kbc,
		Fpu = Fpu,
		Dma = Dma,
		Sb16 = Sb16,
		Fdc = Fdc,
		Ne2000 = Ne2000,
		Isp = Isp,
		Xms = Xms,
		Uart = Uart,
		Lpt = Lpt,
	}, {
		memorySize = 32 * 1024 * 1024,
		cpu = { cpuLevel = "486" },
		rom = buffer.fromstring(fs.readFile("roms/bios-256k.bin")),
		vgaRom = buffer.fromstring(fs.readFile("roms/vgabios-stdvga.bin")),
		hdd = buffer.fromstring(fs.readFile(opts.hdd)),
		cdrom = buffer.fromstring(fs.readFile(opts.iso)),
		floppy = if bootImage then { image = bootImage } else nil,
	})
	m.timerDivisor = 2
	return m
end

-- Driver state that must survive a checkpoint (the machine itself is
-- captured separately).
local function newState()
	return {
		executed = 0,
		bootEpoch = 0,
		menu1Epoch = -1,
		menu2Epoch = -1,
		enterEpoch = -1,
		rebootPromptSeen = false,
		lastPromptScreen = "",
		lastScreen = "",
		lastGuiAct = 0,
		guiShot = 0,
		statusAt = 0,
		irqSeen = 0,
		irqAt = 0,
		stallReported = false,
	}
end

local m = build()

-- Side-effect-free linear-to-physical walk for debug probes: unlike
-- Cpu.translatePage it never raises #PF, sets CR2, touches A/D bits or fills
-- the TLB. Errors (not present) so pcall-wrapped callers print "??".
local function probePhys(cpu: any, la: number, _w: any?, _u: any?): number
	la = bit32.band(la, 0xFFFFFFFF)
	if bit32.band(cpu.cr0, 0x80000000) == 0 then
		return la
	end
	const pde = cpu.mem:read32(bit32.band(cpu.cr3, 0xFFFFF000) + bit32.rshift(la, 22) * 4)
	if bit32.band(pde, 1) == 0 then
		error("pde not present")
	end
	if bit32.band(pde, 0x80) ~= 0 and bit32.band(cpu.cr4 or 0, 0x10) ~= 0 then
		return bit32.band(pde, 0xFFC00000) + bit32.band(la, 0x3FFFFF)
	end
	const pte =
		cpu.mem:read32(bit32.band(pde, 0xFFFFF000) + bit32.band(bit32.rshift(la, 12), 0x3FF) * 4)
	if bit32.band(pte, 1) == 0 then
		error("pte not present")
	end
	return bit32.band(pte, 0xFFFFF000) + bit32.band(la, 0xFFF)
end
local st = newState()
if opts.load then
	local started = os.clock()
	st = Snapshot.apply(m, fs.readFile(opts.load))
	print(("loaded %s at step %d in %.1fs"):format(opts.load, st.executed, os.clock() - started))
	-- --hide-pnp 1: hide the PnP BIOS header in the loaded state's BIOS shadow (F-segment),
	-- as a fresh Machine does by default.
	if opts.hidePnp then
		print(
			("HIDE-PNP hid %d header(s)"):format(Machine.hidePnpHeader(m.mem.buf, 0xF0000, 0x10000))
		)
	end
	-- --import-hdd PATH: replace the loaded state's hard disk contents with the image at PATH
	-- (same size), e.g. after editing files in an exported image.
	if opts.importHdd then
		const data = buffer.fromstring(fs.readFile(tostring(opts.importHdd)))
		const image = m.ide.master.image
		assert(
			buffer.len(data) == buffer.len(image),
			"import-hdd: size differs from the current disk"
		)
		buffer.copy(image, 0, data)
		if m.ide.markAllDirty then
			m.ide:markAllDirty()
		end
		print(("IMPORTED hdd from %s"):format(tostring(opts.importHdd)))
	end
	-- --export-hdd PATH: write the loaded state's current hard disk image to PATH and exit.
	if opts.exportHdd then
		fs.writeFile(tostring(opts.exportHdd), buffer.tostring(m.ide.master.image))
		print(("EXPORTED hdd to %s"):format(tostring(opts.exportHdd)))
		process.exit(0)
	end
	-- --call-int HEX --call-ax HEX: from a real-mode state, run INT n with AX set (code at
	-- 0000:0600), print the returned registers and flags, and exit.
	-- --call-code HEXBYTES instead runs those bytes at 0000:0600 up to their final F4 (HLT).
	if opts.callInt or opts.callCode then
		const cpu = m.cpu
		local bytes = {}
		if opts.callCode then
			for h in string.gmatch(tostring(opts.callCode), "%x%x") do
				table.insert(bytes, tonumber(h, 16))
			end
		else
			bytes = { 0xCD, tonumber(tostring(opts.callInt), 16), 0xF4 }
		end
		for q, v in bytes do
			m.mem:write8(0x600 + q - 1, v)
		end
		const haltAt = 0x600 + #bytes - 1
		cpu:loadSeg("cs", 0)
		cpu.ip = 0x600
		cpu:wr32(0, tonumber(tostring(opts.callAx or "0"), 16) :: number)
		for _ = 1, 2_000_000 do
			if cpu.cs == 0 and cpu.ip == haltAt then
				break
			end
			m:run(1)
		end
		print(("CALL mem[700..74F]=%s"):format((function()
			local t = {}
			for q = 0, 0x4F do
				t[#t + 1] = ("%02X"):format(m.mem:read8(0x700 + q))
			end
			return table.concat(t, " ")
		end)()))
		print(
			("CALL int=%s -> eax=%08X ebx=%08X ecx=%08X edx=%08X edi=%08X flags=%04X at %04X:%X"):format(
				tostring(opts.callInt),
				cpu:rr32(0),
				cpu:rr32(3),
				cpu:rr32(1),
				cpu:rr32(2),
				cpu:rr32(7),
				cpu.flags,
				cpu.cs,
				cpu.ip
			)
		)
		process.exit(0)
	end
	-- --rtc-date YYYY-MM-DD: set the CMOS clock (e.g. 1999-06-01 so Win98's
	-- 1999-era code-signing certificates still validate).
	if opts.rtcDate then
		const y, mo, d = string.match(tostring(opts.rtcDate), "^(%d+)-(%d+)-(%d+)$")
		assert(y, "--rtc-date wants YYYY-MM-DD")
		m.cmos:setDate(tonumber(y) :: number, tonumber(mo) :: number, tonumber(d) :: number)
		print(("RTC set to %s"):format(tostring(opts.rtcDate)))
	end
	-- --reset-after-load 1: press the reset button on the loaded state (disks keep their contents).
	if opts.resetAfterLoad then
		m:reset()
		print("RESET after load")
	end
	if opts.rtc then
		local r = m.rtcState
		print(("RTC regA=%02X regB=%02X regC=%02X"):format(r.regA or -1, r.regB, r.regC or -1))
		process.exit(0)
	end
	if opts.pic then
		local pc = m.pic
		print(
			("PIC master imr=%02X irr=%02X isr=%02X | slave imr=%02X irr=%02X isr=%02X"):format(
				pc.master.imr,
				pc.master.irr,
				pc.master.isr,
				pc.slave.imr,
				pc.slave.irr,
				pc.slave.isr
			)
		)
		process.exit(0)
	end
	-- --pte LINEAR: print CR3 and the PDE/PTE for a linear address of the loaded checkpoint.
	if opts.pte then
		local la = tonumber(opts.pte) :: number
		local cr3 = bit32.band(m.cpu.cr3, 0xFFFFF000)
		local pde = m.mem:read32(cr3 + bit32.rshift(la, 22) * 4)
		local pte = 0
		if bit32.band(pde, 1) ~= 0 and bit32.band(pde, 0x80) == 0 then
			pte = m.mem:read32(
				bit32.band(pde, 0xFFFFF000) + bit32.band(bit32.rshift(la, 12), 0x3FF) * 4
			)
		end
		print(("CR3=%X PDE=%X PTE=%X cr0=%X cr4?"):format(cr3, pde, pte, m.cpu.cr0))
		process.exit(0)
	end
	-- --desc SEL: print the raw GDT/LDT descriptor and the cached CS state, then exit.
	if opts.desc then
		local sel = tonumber(tostring(opts.desc), 16) :: number
		local tb = if bit32.band(sel, 4) ~= 0 then m.cpu.ldtrBase else m.cpu.gdtr.base
		local a = tb + bit32.band(sel, 0xFFF8)
		print(
			("DESC %04X at %X: %08X %08X gdtr=%X/%X cs=%04X cslim=%X"):format(
				sel,
				a,
				m.cpu.mem:read32(probePhys(m.cpu, a)),
				m.cpu.mem:read32(probePhys(m.cpu, a + 4)),
				m.cpu.gdtr.base,
				m.cpu.gdtr.limit,
				m.cpu.cs,
				m.cpu.segLimit.cs
			)
		)
		process.exit(0)
	end
	-- --dump ADDR [--dump-len N]: print physical bytes of the loaded checkpoint and exit.
	-- --idt HEX: print the IDT gate for that vector of the loaded state and exit.
	if opts.idt then
		local v = tonumber(tostring(opts.idt), 16) :: number
		local a = m.cpu.idtr.base + v * 8
		print(
			("IDT %02X at %X: %08X %08X idtr=%X/%X"):format(
				v,
				a,
				m.cpu.mem:read32(probePhys(m.cpu, a)),
				m.cpu.mem:read32(probePhys(m.cpu, a + 4)),
				m.cpu.idtr.base,
				m.cpu.idtr.limit
			)
		)
		process.exit(0)
	end
	-- --dump-file PATH: with --dump/--dump-len, write the raw bytes to PATH instead
	-- (unmapped linear pages read as zero with --dump-lin).
	if opts.dump and opts.dumpFile then
		local a, n = tonumber(opts.dump) :: number, tonumber(opts.dumpLen) or 64
		local out = buffer.create(n)
		local k = 0
		while k < n do
			local pageLeft = math.min(4096 - ((a + k) % 4096), n - k)
			local okP, phys = true, a + k
			if opts.dumpLin then
				okP, phys = pcall(function()
					return probePhys(m.cpu, a + k, false, false)
				end)
			end
			if okP then
				for j = 0, pageLeft - 1 do
					buffer.writeu8(out, k + j, m.mem:read8(phys + j))
				end
			end
			k += pageLeft
		end
		fs.writeFile(tostring(opts.dumpFile), out)
		process.exit(0)
	end
	if opts.dump then
		local a, n = tonumber(opts.dump), tonumber(opts.dumpLen) or 64
		for row = 0, n - 1, 16 do
			local t = {}
			for k = row, math.min(row + 15, n - 1) do
				local pa = a + k
				if opts.dumpLin then
					local okP, phys = pcall(function()
						return probePhys(m.cpu, a + k, false, false)
					end)
					pa = if okP then phys else 0xFFFFFFFF
				end
				table.insert(t, ("%02X"):format(m.mem:read8(pa)))
			end
			print(("%X: %s"):format(a + row, table.concat(t, " ")))
		end
		process.exit(0)
	end
end

-- --poke LINEAR=BYTE: write a byte through paging after loading (experiments only).
if opts.poke and opts.load then
	local la, val = string.match(opts.poke, "^(%x+)=(%x+)$")
	local pa = probePhys(m.cpu, tonumber(la, 16) :: number, true, false)
	m.mem:write8(pa, tonumber(val, 16) :: number)
	print(("poked %s at phys %X"):format(opts.poke, pa))
end

-- --unmask IRQ: clear an IRQ mask bit after loading (diagnostic experiment).
if opts.unmask and opts.load then
	local irq = tonumber(opts.unmask) :: number
	if irq >= 8 then
		m.pic.slave.imr = bit32.band(m.pic.slave.imr, bit32.bnot(bit32.lshift(1, irq - 8)))
		m.pic:syncCascade()
	else
		m.pic.master.imr = bit32.band(m.pic.master.imr, bit32.bnot(bit32.lshift(1, irq)))
	end
	print("unmasked irq " .. irq)
end

local function checkpoint(path)
	local started = os.clock()
	local data = Snapshot.capture(m, build(), st)
	fs.writeFile(path, data)
	print(
		("SAVED %s at step %d (%.1f MiB, %.1fs)"):format(
			path,
			st.executed,
			#data / 1048576,
			os.clock() - started
		)
	)
end

local function fingerprint()
	local cpu = m.cpu
	return ("step=%d cs:ip=%04X:%X eax=%08X ecx=%08X esp=%08X irq=%s int13=%s int21=%s"):format(
		st.executed,
		cpu.cs,
		cpu.ip,
		cpu:rr32(0),
		cpu:rr32(1),
		cpu:rr32(4),
		tostring(m.irqCount),
		tostring(cpu.intCounts[0x13]),
		tostring(cpu.intCounts[0x21])
	)
end

local function shot()
	local pixels = m.vga:snapshotRGBA()
	local width, height = m.vga:width(), m.vga:height()
	local out = { ("P6\n%d %d\n255\n"):format(width, height) }
	for y = 0, height - 1 do
		local row = table.create(width * 3)
		for x = 0, width - 1 do
			local o = (y * width + x) * 4
			row[x * 3 + 1] = string.char(buffer.readu8(pixels, o))
			row[x * 3 + 2] = string.char(buffer.readu8(pixels, o + 1))
			row[x * 3 + 3] = string.char(buffer.readu8(pixels, o + 2))
		end
		out[#out + 1] = table.concat(row)
	end
	st.guiShot += 1
	-- --shot-prefix NAME: name GUI shots tools/out/NAME_<n>.ppm (default w98) so parallel runs do not collide.
	fs.writeFile(
		("tools/out/%s_%03d.ppm"):format(tostring(opts.shotPrefix or "w98"), st.guiShot),
		table.concat(out)
	)
	print(("SHOT %d at %d steps pc=%s"):format(st.guiShot, st.executed, m:bootPc()))
end

-- --shot-only PATH: write the current screen of the loaded state to PATH (PPM) and exit.
if opts.shotOnly then
	local pixels = m.vga:snapshotRGBA()
	local width, height = m.vga:width(), m.vga:height()
	local out = { ("P6\n%d %d\n255\n"):format(width, height) }
	for index = 0, width * height - 1 do
		out[#out + 1] = string.char(
			buffer.readu8(pixels, index * 4),
			buffer.readu8(pixels, index * 4 + 1),
			buffer.readu8(pixels, index * 4 + 2)
		)
	end
	fs.writeFile(tostring(opts.shotOnly), table.concat(out))
	print(("SHOT-ONLY %dx%d %s"):format(width, height, m.vga.info.label))
	process.exit(0)
end

-- One driver tick: react to the current screen. Returns "stop" to end the run.
local function react(screen)
	if string.find(screen, "Bad Fault in MS-DOS Extender", 1, true) then
		print(("BADFAULT at %d pc=%s"):format(st.executed, m:bootPc()))
		return "stop"
	end
	if
		string.find(screen, "Setup will restart your computer now", 1, true)
		or string.find(screen, "press any key to restart", 1, true)
	then
		if not st.rebootPromptSeen then
			st.rebootPromptSeen = true
			st.bootEpoch += 1
			print(("reboot epoch -> %d at %d"):format(st.bootEpoch, st.executed))
		end
	elseif
		string.find(screen, "Booting from", 1, true) or string.find(screen, "SeaBIOS", 1, true)
	then
		st.rebootPromptSeen = false
	end
	if st.menu1Epoch ~= st.bootEpoch and string.find(screen, "CD-ROM Startup Menu", 1, true) then
		if m:injectBdaKey(0x03, string.byte("2")) then
			st.menu1Epoch = st.bootEpoch
		end
	end
	if
		st.menu2Epoch ~= st.bootEpoch
		and string.find(screen, "Microsoft Windows 98 Startup Menu", 1, true)
		and not string.find(screen, "CD-ROM Startup Menu", 1, true)
	then
		if m:injectBdaKey(0x03, string.byte("1")) then
			st.menu2Epoch = st.bootEpoch
		end
	end
	if st.menu2Epoch == st.bootEpoch and st.enterEpoch ~= st.bootEpoch then
		if m:injectBdaKey(0x1C, 0x0D) then
			st.enterEpoch = st.bootEpoch
		end
	end
	if string.find(screen, "unable to write to the temporary directory", 1, true) then
		print(("TEMP WRITE ERROR at %d pc=%s"):format(st.executed, m:bootPc()))
		return "stop"
	end
	if
		screen ~= st.lastPromptScreen
		and (
			string.find(screen, "Welcome to Setup", 1, true)
			or string.find(screen, "Configure unallocated disk space", 1, true)
			or string.find(screen, "You have chosen to", 1, true)
			or string.find(screen, "press ENTER", 1, true)
			or string.find(screen, "ENTER=Continue", 1, true)
			or string.find(screen, "press any key", 1, true)
		)
	then
		if m:injectBdaKey(0x1C, 0x0D) then
			st.lastPromptScreen = screen
			print(("ENTER injected at %d"):format(st.executed))
		end
	end
	return nil
end

-- --timer-div N: guest steps per PIT count (default 2), applied after --load.
if opts.timerDiv then
	m.timerDivisor = opts.timerDiv
end
-- --steps N: run N million steps past the loaded checkpoint (relative; --budget is absolute).
local budget = if opts.steps then st.executed + opts.steps * 1_000_000 else opts.budget * 1_000_000
local saveAt = if opts.saveAt then opts.saveAt * 1_000_000 else nil
local verifyAt = if opts.verify then opts.verify * 1_000_000 else nil
-- --keys "Text{TAB}{ENTER}" [--keys-at M] [--keys-gap M]: type a key script
-- (set-1 make codes; uppercase and !@ etc. use Shift) starting at absolute step
-- M million, one key every gap million steps (default 2). --no-auto-enter 1
-- stops the periodic Enter the GUI loop otherwise sends.
local SCAN: { [string]: number } = {}
do
	local rows = {
		{ "1234567890-=", 0x02 },
		{ "qwertyuiop[]", 0x10 },
		{ "asdfghjkl;'`", 0x1E },
		{ "zxcvbnm,./", 0x2C },
	}
	for _, r in rows do
		for i = 1, #r[1] do
			SCAN[string.sub(r[1], i, i)] = r[2] + i - 1
		end
	end
	SCAN["\\"] = 0x2B
	SCAN[" "] = 0x39
end
local SHIFTED = {
	["!"] = "1",
	["@"] = "2",
	["#"] = "3",
	["$"] = "4",
	["%"] = "5",
	["^"] = "6",
	["&"] = "7",
	["*"] = "8",
	["("] = "9",
	[")"] = "0",
	["_"] = "-",
	["+"] = "=",
	[":"] = ";",
	['"'] = "'",
	["<"] = ",",
	[">"] = ".",
	["?"] = "/",
}
local NAMED = {
	ENTER = 0x1C,
	TAB = 0x0F,
	SPACE = 0x39,
	ESC = 0x01,
	BKSP = 0x0E,
	UP = 0x48,
	DOWN = 0x50,
	LEFT = 0x4B,
	RIGHT = 0x4D,
	ALT = 0x38,
	SHIFT = 0x2A,
	CTRL = 0x1D,
	F1 = 0x3B,
	F8 = 0x42,
	DEL = 0x53,
}
local keyQueue: { { number } } = {}
local keyMode: { [number]: string } = {}
if opts.keys then
	local text = tostring(opts.keys)
	local i = 1
	while i <= #text do
		local c = string.sub(text, i, i)
		if c == "{" then
			local j = string.find(text, "}", i, true) :: number
			local name = string.sub(text, i + 1, j - 1)
			-- {ALT+X}, {CTRL+X}, {SHIFT+X} and stacked forms such as {CTRL+ALT+DEL};
			-- {HOLD+X} presses X without releasing it, {UP+X} releases it.
			local mods, key = string.match(name, "^([%u%+]+)%+(%w+)$")
			if mods == "HOLD" or mods == "UP" then
				table.insert(keyQueue, { NAMED[key] or SCAN[string.lower(key)] })
				keyMode[#keyQueue] = mods
			elseif mods and key and NAMED[string.match(mods, "^(%u+)")] then
				local combo = {}
				for mod in string.gmatch(mods, "%u+") do
					table.insert(combo, NAMED[mod])
				end
				table.insert(combo, NAMED[key] or SCAN[string.lower(key)])
				table.insert(keyQueue, combo)
			else
				table.insert(keyQueue, { NAMED[name] })
			end
			i = j + 1
		else
			local lower = string.lower(c)
			if SHIFTED[c] then
				table.insert(keyQueue, { 0x2A, SCAN[SHIFTED[c]] })
			elseif lower ~= c then
				table.insert(keyQueue, { 0x2A, SCAN[lower] })
			else
				table.insert(keyQueue, { SCAN[c] })
			end
			i += 1
		end
	end
end
local keysAt = if opts.keysAt then opts.keysAt * 1_000_000 else 0
local keysGap = (opts.keysGap or 2) * 1_000_000
local keyIndex = 1
local saveEvery = if opts.saveEvery then opts.saveEvery * 1_000_000 else nil
local nextSave = if saveEvery then (st.executed // saveEvery + 1) * saveEvery else nil
local verifySpan = (opts.verifySpan or 20) * 1_000_000
local stopReason = "budget"
local startedAt = os.clock()

-- --watch ADDR [--watch-len N] [--watch-step 1]: stop when physical bytes change.
-- Chunk mode names the 1M-step window; step mode wraps Cpu.executeStep and prints
-- the writing instruction (run it from a checkpoint just before the window).
local watchAddr = if opts.watch then tonumber(opts.watch) else nil
local watchLen = tonumber(opts.watchLen) or 8
local function watchBytes()
	local t = table.create(watchLen)
	for k = 0, watchLen - 1 do
		t[k + 1] = ("%02X"):format(m.mem:read8(watchAddr + k))
	end
	return table.concat(t, " ")
end
local watchLast = if watchAddr then watchBytes() else nil
local watchHits = 0
if watchAddr and opts.watchStep then
	local orig = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		local pc = ("%04X:%X"):format(self.cs, self.ip)
		local before = watchBytes()
		local pre = ("pre ecx=%X esi=%X edi=%X ds=%04X es=%04X sp=%X"):format(
			self:rr32(1),
			self:rr32(6),
			self:rr32(7),
			self.ds,
			self.es,
			self:rr32(4)
		)
		local r = orig(self)
		if watchHits < 40 then
			local after = watchBytes()
			if after ~= before then
				watchHits += 1
				print(
					("WATCH written by %s %s cr0=%X ds=%04X es=%04X ss=%04X eax=%X ecx=%X esi=%X edi=%X: %s -> %s"):format(
						pc,
						pre,
						self.cr0,
						self.ds,
						self.es,
						self.ss,
						self:rr32(0),
						self:rr32(1),
						self:rr32(6),
						self:rr32(7),
						before,
						after
					)
				)
			end
		end
		return r
	end
end

-- --ring-at CS:IP [--ring-len N]: print the last N executed cs:ip (with registers)
-- when CS:IP is reached, plus the code bytes there, A20 and SS:SP, then exit.
if opts.ringAt then
	local wantCs, wantIp = string.match(opts.ringAt, "^(%x+):(%x+)$")
	local rcs, rip = tonumber(wantCs or "0", 16), tonumber(wantIp or "0", 16)
	local rlin = if wantCs then nil else tonumber(opts.ringAt)
	local ringLen = tonumber(opts.ringLen) or 64
	local ring, rpos = {}, 0
	local lastCs, lastIp = 0, 0
	local traceLeft = 0
	local ringHits = 0
	local orig2 = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		if traceLeft > 0 then
			traceLeft -= 1
			print(
				("T %04X:%04X eax=%08X ebx=%08X ecx=%08X edx=%08X esi=%08X edi=%08X ebp=%08X fl=%04X"):format(
					self.cs,
					self.ip,
					self:rr32(0),
					self:rr32(3),
					self:rr32(1),
					self:rr32(2),
					self:rr32(6),
					self:rr32(7),
					self:rr32(5),
					self.flags
				)
			)
			if traceLeft == 0 then
				process.exit(0)
			end
			return orig2(self)
		end
		if
			(
				(rlin and self.cs * 16 + self.ip == rlin)
				or (not rlin and self.cs == rcs and self.ip == rip)
			) and (opts.ringSp == nil or self:rr32(4) == tonumber(opts.ringSp))
		then
			ringHits += 1
			if ringHits < (tonumber(opts.ringNth) or 1) then
				return orig2(self)
			end
			for k = 1, ringLen do
				local e = ring[(rpos + k - 1) % ringLen + 1]
				if e then
					print(e)
				end
			end
			print(("HIT %04X:%X"):format(rcs, rip))
			if opts.ringSave then
				checkpoint(opts.ringSave)
			end
			local cb = self.cs * 16 + self.ip
			local bt = {}
			for q = -8, 24 do
				table.insert(bt, ("%02X"):format(m.mem:read8(cb + q)))
			end
			print("CODE(-8..+24): " .. table.concat(bt, " "))
			if opts.ringGdt then
				local g = self.gdtr
				print(("GDTR base=%X limit=%X"):format(g.base, g.limit))
				for idx = 0, math.min(7, bit32.rshift(g.limit, 3)) do
					local d = {}
					for q = 0, 7 do
						table.insert(d, ("%02X"):format(m.mem:read8(g.base + idx * 8 + q)))
					end
					print(("GDT[%d]: %s"):format(idx, table.concat(d, " ")))
				end
			end
			if opts.ringMem then
				local ma = tonumber(opts.ringMem)
				if opts.ringMem == "esp" then
					ma = self:rr32(4)
				elseif opts.ringMem == "ebp" then
					ma = self:rr32(5)
				end
				local words = {}
				for q = 0, 15 do
					local la = ma + q * 4
					local pa = if opts.ringLin then probePhys(self, la, false, false) else la
					table.insert(words, ("%08X"):format(m.mem:read32(pa)))
				end
				print(("MEM %X: %s"):format(ma, table.concat(words, " ")))
			end
			print(
				("A20=%s SS=%04X SP=%X DS=%04X ES=%04X SI=%X DI=%X BX=%X FL=%X"):format(
					tostring(m.mem.a20),
					self.ss,
					self:rr32(4),
					self.ds,
					self.es,
					self:rr32(6),
					self:rr32(7),
					self:rr32(3),
					self.flags
				)
			)
			if opts.traceAfter then
				traceLeft = tonumber(opts.traceAfter) :: number
			else
				process.exit(0)
			end
		end
		local jump = opts.ringXfer == nil
			or self.cs ~= lastCs
			or self.ip < lastIp
			or self.ip - lastIp > 12
		lastCs, lastIp = self.cs, self.ip
		if not jump then
			return orig2(self)
		end
		ring[rpos % ringLen + 1] = ("%04X:%04X cr0=%X ax=%X bx=%X cx=%X dx=%X sp=%X"):format(
			self.cs,
			self.ip,
			self.cr0,
			self:rr32(0),
			self:rr32(3),
			self:rr32(1),
			self:rr32(2),
			self:rr32(4)
		)
		rpos += 1
		local r3 = orig2(self)
		if opts.ringPost and self.opCS * 16 + self.opIP == tonumber(opts.ringPost) then
			print(("POST op=%04X:%X -> %04X:%X"):format(self.opCS, self.opIP, self.cs, self.ip))
		end
		return r3
	end
end

-- --hist N: after loading, count executed cs:ip for N steps, print the 25 hottest, exit.
if opts.hist then
	local limit = tonumber(opts.hist) :: number
	local counts: { [string]: number } = {}
	local seen = 0
	local origH = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		local key = ("%04X:%04X"):format(self.cs, self.ip)
		counts[key] = (counts[key] or 0) + 1
		seen += 1
		if seen >= limit then
			local list = {}
			for k, v in counts do
				table.insert(list, { k = k, v = v })
			end
			table.sort(list, function(a, b)
				return a.v > b.v
			end)
			for i = 1, math.min(25, #list) do
				print(("%s %d"):format(list[i].k, list[i].v))
			end
			process.exit(0)
		end
		return origH(self)
	end
end

-- --bench N: time N raw executeStep calls (no device/IRQ loop) and exit.
if opts.bench then
	local n = tonumber(opts.bench) :: number
	local t0 = os.clock()
	if opts.benchRun then
		m:run(n)
	else
		local cpu = m.cpu
		for _ = 1, n do
			cpu:step()
		end
	end
	local dt = os.clock() - t0
	print(
		("bench%s: %d steps in %.2fs = %.2f M/s"):format(
			if opts.benchRun then " (m:run)" else " (raw step)",
			n,
			dt,
			n / dt / 1e6
		)
	)
	process.exit(0)
end

local vgaHistRef: { [string]: number }? = nil
-- --vgalog LO HI N: print the first N writes to aperture offsets LO..HI (decimal or 0x)
-- with the writing cs:ip, then exit. Use --vgalog-skip K to ignore the first K hits.
if opts.vgalog then
	local lo = tonumber(opts.vgalog) :: number
	local hi = tonumber(opts.vgalogHi) :: number
	local want = tonumber(opts.vgalogN) or 40
	local skip = tonumber(opts.vgalogSkip) or 0
	local seen, shown = 0, 0
	local vga = m.vga
	local origW = vga.write8
	local hist: { [string]: number } = {}
	vgaHistRef = hist
	vga.write8 = function(self, addr, value)
		local off = bit32.band(addr, 0xFFFF)
		if off >= lo and off <= hi then
			seen += 1
			if seen > skip then
				shown += 1
				local c = m.cpu
				if opts.vgalogHist then
					local key = ("%04X:%X wm=%d"):format(c.cs, c.ip, bit32.band(self.gfx[5], 3))
					hist[key] = (hist[key] or 0) + 1
				else
					print(
						("VGAW off=%04X val=%02X by %04X:%X (mode wm=%d)"):format(
							off,
							value,
							c.cs,
							c.ip,
							bit32.band(self.gfx[5], 3)
						)
					)
				end
				if shown >= want then
					for k, v in hist do
						print(("HIST %s %d"):format(k, v))
					end
					process.exit(0)
				end
			end
		end
		return origW(self, addr, value)
	end
end

-- --hook CS:IP [--hook-di LO HI] [--hook-n N] [--hook-bytes B]: print regs and B bytes at DS:SI
-- every time CS:IP is reached (optionally only when DI is in LO..HI), stop after N hits.
if opts.hook then
	local hcs, hip = string.match(opts.hook, "^(%x+):(%x+)$")
	local hcsN, hipN = tonumber(hcs, 16), tonumber(hip, 16)
	local diLo, diHi = tonumber(opts.hookDi or "0"), tonumber(opts.hookDiHi or "65535")
	local want = tonumber(opts.hookN) or 20
	local nbytes = tonumber(opts.hookBytes) or 16
	local got = 0
	local origHook = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		if self.cs == hcsN and self.ip == hipN then
			local di = bit32.band(self:rr32(7), 0xFFFF)
			if di >= diLo and di <= diHi then
				got += 1
				local si = self:rr32(6)
				local bt = {}
				for q = 0, nbytes - 1 do
					table.insert(
						bt,
						("%02X"):format(
							m.mem:read8(self:linear("ds", bit32.band(si + q, 0xFFFF), 1))
						)
					)
				end
				print(
					("HOOK#%d ds=%04X dsbase=%X si=%X di=%X cx=%X bx=%X dx=%X ax=%X: %s"):format(
						got,
						self.ds,
						self.segBase.ds,
						si,
						di,
						self:rr32(1),
						self:rr32(3),
						self:rr32(2),
						self:rr32(0),
						table.concat(bt, " ")
					)
				)
				if opts.hookStack then
					local sp = bit32.band(self:rr32(4), 0xFFFF)
					local words = {}
					for q = 0, 11 do
						table.insert(
							words,
							("%04X"):format(
								m.mem:read16(self.ss * 16 + bit32.band(sp + q * 2, 0xFFFF))
							)
						)
					end
					print(
						("  STACK ss=%04X sp=%X: %s"):format(self.ss, sp, table.concat(words, " "))
					)
				end
				if got >= want then
					process.exit(0)
				end
			end
		end
		return origHook(self)
	end
end

-- --ring-fault N: keep the last N executed cs:ip with registers and print them when the run faults.
local irqHistRef: { [number]: number }? = nil
local ioHistRef: { [string]: number }? = nil
local faultRing: { string }? = nil
local faultRingLen = 0
local faultRingPos = 0
if opts.ringFault then
	faultRingLen = tonumber(opts.ringFault) :: number
	faultRing = {}
	-- --pe-stop N: stop at the Nth CR0.PE 1->0 transition and print the ring.
	local peStop = tonumber(opts.peStop)
	local peLast, peStopSeen = bit32.band(m.cpu.cr0, 1), 0
	local origF = m.cpu.executeStep
	-- --ring-jumps 1: only record an instruction when it is not within 16 bytes after the previous one.
	local jumpsOnly = opts.ringJumps ~= nil
	local lastCs, lastIp = -1, -1
	-- --ring-skip-cs HEX: do not record instructions executed with this CS.
	local skipCs = if opts.ringSkipCs then tonumber(tostring(opts.ringSkipCs), 16) else nil
	-- --ring-ip-lo HEX --ring-ip-hi HEX: only record instructions with lo <= ip < hi.
	local ipLo = if opts.ringIpLo then tonumber(tostring(opts.ringIpLo), 16) else nil
	local ipHi = if opts.ringIpHi then tonumber(tostring(opts.ringIpHi), 16) else nil
	m.cpu.executeStep = function(self)
		local record = self.cs ~= skipCs
			and (ipLo == nil or (self.ip >= ipLo and self.ip < (ipHi :: number)))
		if jumpsOnly then
			local d = self.ip - lastIp
			record = record and (self.cs ~= lastCs or d < 0 or d > 16)
			lastCs, lastIp = self.cs, self.ip
		end
		if record then
			faultRing[faultRingPos % faultRingLen + 1] = ("%04X:%08X cr0=%X eax=%X ebx=%X ecx=%X edx=%X esi=%X edi=%X esp=%X ds=%04X es=%04X ss=%04X"):format(
				self.cs,
				self.ip,
				self.cr0,
				self:rr32(0),
				self:rr32(3),
				self:rr32(1),
				self:rr32(2),
				self:rr32(6),
				self:rr32(7),
				self:rr32(4),
				self.ds,
				self.es,
				self.ss
			)
			faultRingPos += 1
		end
		if peStop then
			const pe = bit32.band(self.cr0, 1)
			if peLast == 1 and pe == 0 then
				peStopSeen += 1
				if peStopSeen >= peStop then
					print(
						("PE CLEARED at %04X:%08X (transition %d)"):format(
							self.cs,
							self.ip,
							peStopSeen
						)
					)
					if opts.save then
						checkpoint(opts.save)
					end
					for q = 1, faultRingLen do
						local e = (faultRing :: { string })[(faultRingPos + q - 1) % faultRingLen + 1]
						if e then
							print(e)
						end
					end
					process.exit(0)
				end
			end
			peLast = pe
		end
		return origF(self)
	end
	-- --triple-stop 1: print the ring and exit at the first triple fault instead of resetting.
	if opts.tripleStop then
		m.cpu.tripleFault = function(self)
			print(("TRIPLE FAULT at %04X:%08X cr0=%X"):format(self.cs, self.ip, self.cr0))
			for q = 1, faultRingLen do
				local e = (faultRing :: { string })[(faultRingPos + q - 1) % faultRingLen + 1]
				if e then
					print(e)
				end
			end
			process.exit(0)
		end
	end
end

-- --fault-log N [--fault-vec V]: print the first N hardware/guest exceptions (vector,
-- error code, faulting cs:ip, V86 flag, eax/ebx/esp) as they are delivered.
if opts.faultLog then
	local want = tonumber(opts.faultLog) :: number
	local onlyVec = tonumber(opts.faultVec)
	local seen = 0
	local origI = m.cpu.interrupt
	m.cpu.interrupt = function(self, n, errorCode, soft)
		if not soft and (onlyVec == nil or onlyVec == n) and seen < want then
			seen += 1
			print(
				("FAULT#%d vec=%X err=%s at %04X:%X v86=%s cr0=%X eax=%X ebx=%X ecx=%X esp=%X fl=%X cr2=%X ds=%X si=%X es=%X di=%X"):format(
					seen,
					n,
					tostring(errorCode),
					self.opCS or self.cs,
					self.opIP or self.ip,
					tostring(self:isV86()),
					self.cr0,
					self:rr32(0),
					self:rr32(3),
					self:rr32(1),
					self:rr32(4),
					self.flags,
					if self.lastPageFault then self.lastPageFault.addr else 0,
					self.ds,
					self:rr32(6),
					self.es,
					self:rr32(7)
				)
			)
		end
		if opts.faultTbIp and (self.opIP or self.ip) == tonumber(tostring(opts.faultTbIp), 16) then
			print(
				("TB vec=%X cslim=%X csacc=%X csflags=%X"):format(
					n,
					self.segLimit.cs,
					self.segAccess.cs,
					self.segFlags.cs or 0
				)
			)
			print(debug.traceback())
		end
		-- --fault-ring-ip HEX: with --ring-fault, print the ring and exit at the first fault at that ip.
		if
			opts.faultRingIp
			and faultRing
			and (self.opIP or self.ip) == tonumber(tostring(opts.faultRingIp), 16)
		then
			print(("RING at fault vec=%X err=%s"):format(n, tostring(errorCode)))
			for q = 1, faultRingLen do
				local e = faultRing[(faultRingPos + q - 1) % faultRingLen + 1]
				if e then
					print(e)
				end
			end
			process.exit(0)
		end
		if opts.faultTrace and errorCode and errorCode > 0xFFFF then
			print(debug.traceback())
		end
		if opts.faultCode and not soft and (onlyVec == nil or onlyVec == n) and seen <= want then
			local t = {}
			local base = self.segBase.cs + (self.opIP or self.ip)
			for k = 0, 15 do
				local okB, b = pcall(function()
					return self.mem:read8(probePhys(self, base + k, false, false))
				end)
				table.insert(t, if okB then ("%02X"):format(b) else "??")
			end
			print(
				("  ldt=%X fs=%X fsbase=%X fslim=%X dslim=%X sslim=%X"):format(
					self.ldtrBase,
					self.fs,
					self.segBase.fs,
					self.segLimit.fs,
					self.segLimit.ds,
					self.segLimit.ss
				)
			)
			print(
				("  csbase=%X dsbase=%X esbase=%X ssbase=%X code: %s"):format(
					self.segBase.cs,
					self.segBase.ds,
					self.segBase.es,
					self.segBase.ss,
					table.concat(t, " ")
				)
			)
		end
		return origI(self, n, errorCode, soft)
	end
end

-- --v86ret N: print the first N protected-mode IRETD instructions whose popped EFLAGS
-- has VM set (the VMM resuming V86 code), with the EIP/CS/EFLAGS image on the stack.
if opts.v86ret then
	local want = tonumber(opts.v86ret) :: number
	local seen = 0
	local origR = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		if seen < want and bit32.band(self.cr0, 1) ~= 0 and not self:isV86() then
			local okT, lin = pcall(function()
				return probePhys(self, self.segBase.cs + self.ip, false, false)
			end)
			if okT and m.mem:read8(lin) == 0xCF then
				local okS, a, b, c = pcall(function()
					local sp = self.segBase.ss + self:rr32(4)
					return self.mem:read32(probePhys(self, sp)),
						self.mem:read32(probePhys(self, sp + 4)),
						self.mem:read32(probePhys(self, sp + 8))
				end)
				if okS and bit32.band(c, 0x20000) ~= 0 then
					seen += 1
					print(
						("V86RET#%d esp=%X phys=%X from %04X:%X -> %04X:%X eflags=%X"):format(
							seen,
							self:rr32(4),
							probePhys(self, self.segBase.ss + self:rr32(4) + 8, false, false),
							self.cs,
							self.ip,
							bit32.band(b, 0xFFFF),
							a,
							c
						)
					)
				end
			end
		end
		return origR(self)
	end
end

-- --dr-log N: print the first N MOV DRn writes with cs:ip.
if opts.drLog then
	local want = tonumber(opts.drLog) :: number
	local seen = 0
	local real = m.cpu.dr :: { [number]: number }
	m.cpu.dr = setmetatable({}, {
		__index = function(_, k)
			return real[k]
		end,
		__newindex = function(_, k, v)
			if seen < want then
				seen += 1
				print(
					("DRWRITE#%d dr%d=%X at %04X:%X cr0=%X"):format(
						seen,
						k,
						v,
						m.cpu.cs,
						m.cpu.ip,
						m.cpu.cr0
					)
				)
			end
			real[k] = v
		end,
	}) :: any
end

-- --vxd-dev HEX: print each protected-mode INT 20h VxD call to that device (cs:ip, service).
if opts.vxdDev then
	local dev = tonumber(tostring(opts.vxdDev), 16)
	local origV = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		if self:isProtected() and not self:isV86() then
			const lin = self.segBase.cs + self.ip
			const ok, b0 = pcall(function()
				return self.mem:read8(probePhys(self, lin))
			end)
			if ok and b0 == 0xCD then
				const ok2, b1, id = pcall(function()
					return self.mem:read8(probePhys(self, lin + 1)),
						self.mem:read32(probePhys(self, lin + 2))
				end)
				if ok2 and b1 == 0x20 then
					if bit32.band(bit32.rshift(id, 16), 0x7FFF) == dev then
						print(
							("VXD %04X:%08X -> %08X step %d"):format(
								self.cs,
								self.ip,
								id,
								st.executed
							)
						)
					end
				end
			end
		end
		return origV(self)
	end
end

-- --dos-calls 1: print INT 21h calls with AH 3D/48/49/4A/4B/4C/58 (any mode) and the
-- ASCIIZ name at DS:DX for opens/execs.
if opts.dosCalls then
	local want = {
		[0x3D] = true,
		[0x48] = true,
		[0x49] = true,
		[0x4A] = true,
		[0x4B] = true,
		[0x4C] = true,
		[0x58] = true,
	}
	local origD2 = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		if not self:isProtected() or self:isV86() then
			const lin = self.segBase.cs + self.ip
			const ok, b0, b1 = pcall(function()
				return self.mem:read8(probePhys(self, lin)),
					self.mem:read8(probePhys(self, lin + 1))
			end)
			if ok and b0 == 0xCD and b1 == 0x21 then
				const ah = bit32.band(bit32.rshift(self:rr32(0), 8), 0xFF)
				if want[ah] then
					local name = ""
					if ah == 0x3D or ah == 0x4B then
						local t = {}
						const base = self.segBase.ds + bit32.band(self:rr32(2), 0xFFFF)
						for q = 0, 79 do
							const okc, c = pcall(function()
								return self.mem:read8(probePhys(self, base + q))
							end)
							if not okc or c == 0 then
								break
							end
							t[#t + 1] = string.char(c)
						end
						name = table.concat(t)
					end
					print(
						("DOS %04X:%04X ah=%02X ax=%04X bx=%04X cx=%04X %s step %d"):format(
							self.cs,
							self.ip,
							ah,
							bit32.band(self:rr32(0), 0xFFFF),
							bit32.band(self:rr32(3), 0xFFFF),
							bit32.band(self:rr32(1), 0xFFFF),
							name,
							st.executed
						)
					)
				end
			end
		end
		return origD2(self)
	end
end

-- --api-log HEX,HEX,... [--api-log-n N]: for 32-bit user code, log each call that
-- reaches one of these entry addresses (first two stack args, as ASCII strings when
-- they point at text) and the EAX it returns with.
if opts.apiLog then
	local entries: { [number]: boolean } = {}
	for h in string.gmatch(tostring(opts.apiLog), "%x+") do
		entries[tonumber(h, 16) :: number] = true
	end
	local left = tonumber(opts.apiLogN) or 2000
	local pending: { [number]: { ret: number, esp: number, what: string } } = {}
	local function peek32(cpu: any, la: number): number?
		const ok, v = pcall(function()
			return cpu.mem:read32(probePhys(cpu, la))
		end)
		return if ok then v else nil
	end
	local function text(cpu: any, la: number): string?
		local t = {}
		for q = 0, 79 do
			const ok, c = pcall(function()
				return cpu.mem:read8(probePhys(cpu, la + q))
			end)
			if not ok then
				return nil
			end
			if c == 0 then
				break
			end
			if c < 32 or c > 126 then
				return nil
			end
			t[#t + 1] = string.char(c)
		end
		return if #t > 0 then table.concat(t) else nil
	end
	local origA = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		if left > 0 and self.cs == 0x167 then
			const ip = self.ip
			const esp = self:rr32(4)
			const p = pending[ip]
			if p and esp > p.esp then
				pending[ip] = nil
				left -= 1
				print(("API ret %s -> eax=%08X step %d"):format(p.what, self:rr32(0), st.executed))
			end
			if entries[ip] then
				const ret = peek32(self, esp) or 0
				const a1 = peek32(self, esp + 4) or 0
				const a2 = peek32(self, esp + 8) or 0
				const s1 = text(self, a1)
				const s2 = text(self, a2)
				const what = ("%08X(%s, %s) from %08X"):format(
					ip,
					if s1 then '"' .. s1 .. '"' else ("%X"):format(a1),
					if s2 then '"' .. s2 .. '"' else ("%X"):format(a2),
					ret
				)
				pending[ret] = { ret = ret, esp = esp, what = what }
			end
		end
		return origA(self)
	end
end

-- --stop-ip HEX [--stop-cs HEX]: save --save and exit just before executing that ip (and cs).
if opts.stopIp then
	local wantIp = tonumber(tostring(opts.stopIp), 16)
	local wantCs = if opts.stopCs then tonumber(tostring(opts.stopCs), 16) else nil
	local origS = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		if
			self.ip == wantIp
			and (wantCs == nil or self.cs == wantCs)
			-- --stop-after M: ignore hits before absolute step M million.
			and (
				opts.stopAfter == nil
				or st.executed >= (tonumber(opts.stopAfter) :: number) * 1_000_000
			)
		then
			print(("STOP at %04X:%08X step %d"):format(self.cs, self.ip, st.executed))
			if faultRing then
				for q = 1, faultRingLen do
					local e = faultRing[(faultRingPos + q - 1) % faultRingLen + 1]
					if e then
						print(e)
					end
				end
			end
			if opts.save then
				checkpoint(opts.save)
			end
			process.exit(0)
		end
		return origS(self)
	end
end

-- --pc-hist N: sample cs:ip every N instructions and print the 40 most frequent at the end.
local pcHistRef: { [string]: number }? = nil
if opts.pcHist then
	local every = tonumber(opts.pcHist) :: number
	local count = 0
	local hist: { [string]: number } = {}
	pcHistRef = hist
	local origP = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		count += 1
		if count >= every then
			count = 0
			const k = ("%04X:%08X"):format(self.cs, self.ip)
			hist[k] = (hist[k] or 0) + 1
		end
		return origP(self)
	end
end

-- --io-hist 1: count port reads/writes (8-bit paths) and print them when the run ends.
-- --dos-write 1: print the data of every V86 INT 21h AH=40h (write to handle) as text.
if opts.dosWrite then
	local origD = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		if
			self:isV86()
			and (
				(
					bit32.band(self:rr32(0), 0xFF00) == 0x4000
					and self.ip == self.mem:read16(0x84)
					and self.cs == self.mem:read16(0x86)
				) or (self.ds == 0x7800 and self.cs == 0xFCB2 and self.ip == 0x2FF7)
			)
		then
			local t = {}
			local n = math.min(bit32.band(self:rr32(1), 0xFFFF), 200)
			for k = 0, n - 1 do
				local okC, c = pcall(function()
					return self.mem:read8(
						probePhys(
							self,
							self.ds * 16 + bit32.band(self:rr32(2), 0xFFFF) + k,
							false,
							false
						)
					)
				end)
				c = if okC then c else 63
				table.insert(t, if c >= 32 and c < 127 then string.char(c) else "|")
			end
			print(("DOSWRITE h=%d %s"):format(bit32.band(self:rr32(3), 0xFFFF), table.concat(t)))
		end
		return origD(self)
	end
end

-- --lwatch LINEAR [--lwatch-len N] [--lwatch-max N]: print each instruction that changes N bytes at a
-- paged linear address (the first --lwatch-max changes, default 60).
if opts.lwatch then
	local la = tonumber(opts.lwatch) :: number
	local n = tonumber(opts.lwatchLen) or 8
	local function grab(cpu: any): string
		local t = {}
		for k = 0, n - 1 do
			local okB, b = pcall(function()
				return cpu.mem:read8(probePhys(cpu, la + k, false, false))
			end)
			t[k + 1] = if okB then ("%02X"):format(b) else "??"
		end
		return table.concat(t, " ")
	end
	local last = grab(m.cpu)
	local hits = 0
	local origW = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		local pc = ("%04X:%X"):format(self.cs, self.ip)
		local r = origW(self)
		local now = grab(self)
		-- --lwatch-cs HEX: only report changes made while CS is this selector, and
		-- ignore the slot mapping in/out across address-space switches ("??").
		local report = now ~= last and hits < (tonumber(opts.lwatchMax) or 60)
		if report and opts.lwatchCs then
			report = string.find(now, "?", 1, true) == nil
				and string.find(last, "?", 1, true) == nil
				and self.cs == tonumber(tostring(opts.lwatchCs), 16)
		end
		if not report and now ~= last and opts.lwatchCs then
			last = now
		end
		if report then
			hits += 1
			print(
				("LWATCH %s -> %s by %s eax=%X ebx=%X ecx=%X edx=%X esi=%X edi=%X"):format(
					last,
					now,
					pc,
					self:rr32(0),
					self:rr32(3),
					self:rr32(1),
					self:rr32(2),
					self:rr32(6),
					self:rr32(7)
				)
			)
			last = now
		end
		return r
	end
end

-- --port-log P1,P2,.. [--port-log-n N]: print each 8-bit access to those ports with cs:eip and value.
if opts.portLog then
	local want: { [number]: boolean } = {}
	for h in string.gmatch(opts.portLog, "%x+") do
		want[tonumber(h, 16) :: number] = true
	end
	local left = tonumber(opts.portLogN) or 400
	local io = m.cpu.io :: any
	local oi, oo = io.in8, io.out8
	io.in8 = function(port)
		local v = oi(port)
		if want[port] and left > 0 then
			left -= 1
			print(
				("PORT in  %02X -> %02X at %04X:%X"):format(
					port,
					v,
					m.cpu.opCS or m.cpu.cs,
					m.cpu.opIP or m.cpu.ip
				)
			)
		end
		return v
	end
	io.out8 = function(port, v)
		if want[port] and left > 0 then
			left -= 1
			print(
				("PORT out %02X <- %02X at %04X:%X"):format(
					port,
					v,
					m.cpu.opCS or m.cpu.cs,
					m.cpu.opIP or m.cpu.ip
				)
			)
		end
		return oo(port, v)
	end
	for _, w in { { "in16", "out16", 4 }, { "in32", "out32", 8 } } do
		local wi, wo = io[w[1]], io[w[2]]
		if wi then
			io[w[1]] = function(port)
				local v = wi(port)
				if want[port] and left > 0 then
					left -= 1
					print(
						("PORT %s %02X -> %0" .. w[3] .. "X at %04X:%X"):format(
							w[1],
							port,
							v,
							m.cpu.opCS or m.cpu.cs,
							m.cpu.opIP or m.cpu.ip
						)
					)
				end
				return v
			end
		end
		if wo then
			io[w[2]] = function(port, v)
				if want[port] and left > 0 then
					left -= 1
					print(
						("PORT %s %02X <- %0" .. w[3] .. "X at %04X:%X"):format(
							w[2],
							port,
							v,
							m.cpu.opCS or m.cpu.cs,
							m.cpu.opIP or m.cpu.ip
						)
					)
				end
				return wo(port, v)
			end
		end
	end
end

if opts.ioHist then
	local cnt: { [string]: number } = {}
	local io = m.cpu.io :: any
	local oi, oo = io.in8, io.out8
	io.in8 = function(port)
		local k = ("in  %04X"):format(port)
		cnt[k] = (cnt[k] or 0) + 1
		return oi(port)
	end
	io.out8 = function(port, v)
		local k = ("out %04X"):format(port)
		cnt[k] = (cnt[k] or 0) + 1
		return oo(port, v)
	end
	ioHistRef = cnt
end

-- --ide-log N: print the first N IDE command-register writes (cmd, lba, count) and bus-master starts.
if opts.ideLog and m.ide then
	local left = tonumber(opts.ideLog) :: number
	local ide = m.ide :: any
	local o8 = ide.out8
	ide.out8 = function(self, port, v)
		if left > 0 and port - self.base == 7 then
			left -= 1
			print(
				("IDE cmd=%02X lba=%d cnt=%s dc=%02X cs:eip=%04X:%X"):format(
					v,
					self.lba or -1,
					tostring(self.sectorCount),
					self.deviceControl,
					m.cpu.cs,
					m.cpu.ip
				)
			)
		end
		return o8(self, port, v)
	end
end

-- --pic-log N: print the first N writes to the slave PIC mask/command ports (A0/A1) with the guest eip.
if opts.picLog then
	local left = tonumber(opts.picLog) :: number
	local io = m.cpu.io :: any
	local oo = io.out8
	io.out8 = function(port, v)
		if
			left > 0
			and (
				port == 0xA1
				or port == 0xA0
				or (opts.picMaster and (port == 0x20 or port == 0x21))
			)
		then
			left -= 1
			print(
				("PICW %02X=%02X cs:eip=%04X:%X irr=%02X"):format(
					port,
					v,
					m.cpu.cs,
					m.cpu.ip,
					m.pic.slave and m.pic.slave.irr or -1
				)
			)
		end
		return oo(port, v)
	end
end

-- --exec-count 1: count retired executeStep calls (vs. steps) to measure HLT idle.
local execCountRef: { n: number }? = nil
if opts.execCount then
	local c = { n = 0 }
	local oe = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		c.n += 1
		return oe(self)
	end
	execCountRef = c
end

-- --pci-log N: print the first N writes to the PCI address port (0xCF8) with the guest eip.
if opts.pciLog then
	local left = tonumber(opts.pciLog) :: number
	local io = m.cpu.io :: any
	local o32 = io.out32
	io.out32 = function(port, v)
		if left > 0 and port == 0xCF8 then
			left -= 1
			print(("PCI addr=%08X cs:eip=%04X:%X"):format(v, m.cpu.cs, m.cpu.ip))
		end
		return o32(port, v)
	end
end

-- --pc-log A,B,... [--pc-log-n N]: print registers (and the dword at [eax]) each time
-- execution reaches one of the linear addresses; stops printing after N hits.
if opts.pcLog then
	local want: { [number]: boolean } = {}
	for a in string.gmatch(tostring(opts.pcLog), "[^,]+") do
		want[tonumber(a, 16) :: number] = true
	end
	local left = tonumber(opts.pcLogN) or 50
	local oe = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		if left > 0 then
			const lin = self.segBase.cs + self.ip
			-- --pc-log-ss HEX: only count hits while SS is this selector/segment.
			if
				want[lin]
				and (opts.pcLogSs == nil or self.ss == tonumber(tostring(opts.pcLogSs), 16))
			then
				left -= 1
				const okd, at = pcall(function()
					return self.mem:read32(probePhys(self, self:rr32(0)))
				end)
				const okc, atc = pcall(function()
					return self.mem:read32(probePhys(self, self:rr32(1)))
				end)
				print(
					("PC %08X tsc=%d ss:sp=%04X:%X eax=%08X ebx=%08X ecx=%08X edx=%08X esi=%08X edi=%08X [eax]=%s [ecx]=%s"):format(
						lin,
						self.tsc,
						self.ss,
						self:rr32(4),
						self:rr32(0),
						self:rr32(3),
						self:rr32(1),
						self:rr32(2),
						self:rr32(6),
						self:rr32(7),
						if okd then ("%08X"):format(at) else "?",
						if okc then ("%08X"):format(atc) else "?"
					)
				)
				-- --pc-log-stack N: also print N words at SS:SP (paged linear SS base + SP).
				if opts.pcLogStack then
					local w = {}
					for q = 0, (tonumber(opts.pcLogStack) :: number) - 1 do
						const okw, v = pcall(function()
							return self.mem:read16(
								probePhys(
									self,
									self.segBase.ss + ((self:rr32(4) + q * 2) % 0x10000)
								)
							)
						end)
						table.insert(w, if okw then ("%04X"):format(v) else "????")
					end
					print("  STK " .. table.concat(w, " "))
				end
				if faultRing then
					for q = 1, faultRingLen do
						local e = faultRing[(faultRingPos + q - 1) % faultRingLen + 1]
						if e then
							print(e)
						end
					end
				end
				if opts.pcSave then
					checkpoint(opts.pcSave)
					process.exit(0)
				end
			end
		end
		return oe(self)
	end
end

-- --cs-trace SEL [--cs-trace-n N]: print ip, code bytes, registers and flags before every
-- instruction executed with CS = SEL (hex); stops after N lines.
if opts.csTrace then
	local sel = tonumber(tostring(opts.csTrace), 16)
	local left = tonumber(opts.csTraceN) or 100000
	local oe = m.cpu.executeStep
	local logging = false
	local depth = 0
	for _, w in { { "read8", 1 }, { "read16", 2 }, { "read32", 4 } } do
		local orig = m.cpu[w[1]]
		m.cpu[w[1]] = function(self, addr, sup)
			depth += 1
			const v = orig(self, addr, sup)
			depth -= 1
			if logging and depth == 0 then
				print(("R %d %08X %X"):format(w[2], addr, v))
			end
			return v
		end
	end
	for _, w in { { "write8", 1 }, { "write16", 2 }, { "write32", 4 } } do
		local orig = m.cpu[w[1]]
		m.cpu[w[1]] = function(self, addr, v, sup)
			if logging and depth == 0 then
				print(("W %d %08X %X"):format(w[2], addr, v))
			end
			depth += 1
			orig(self, addr, v, sup)
			depth -= 1
		end
	end
	m.cpu.executeStep = function(self)
		logging = false
		if left > 0 and self.segSel.cs == sel then
			left -= 1
			depth += 1
			const lin = self.segBase.cs + self.ip
			local bytes = {}
			for q = 0, 7 do
				const ok, b = pcall(function()
					return self.mem:read8(probePhys(self, lin + q))
				end)
				bytes[#bytes + 1] = if ok then ("%02X"):format(b) else "??"
			end
			print(
				("T %04X %s %08X %08X %08X %08X %08X %08X %08X %08X %08X"):format(
					self.ip,
					table.concat(bytes),
					self:rr32(0),
					self:rr32(1),
					self:rr32(2),
					self:rr32(3),
					self:rr32(4),
					self:rr32(5),
					self:rr32(6),
					self:rr32(7),
					self.flags
				)
			)
			print(("S %08X %08X %08X"):format(self.segBase.ds, self.segBase.es, self.segBase.ss))
			depth -= 1
			logging = true
		end
		return oe(self)
	end
end

-- --cslim-watch LIMIT: print the ring and descriptor the first time CS's cached limit equals LIMIT (hex).
if opts.cslimWatch then
	local want = tonumber(tostring(opts.cslimWatch), 16)
	local oe = m.cpu.executeStep
	local done = false
	local prevSel, prevIp = 0, 0
	m.cpu.executeStep = function(self)
		if not done and self.segLimit.cs == want then
			done = true
			local a = self.gdtr.base + bit32.band(self.cs, 0xFFF8)
			print(
				("CSLIM %X at %04X:%08X prev %04X:%08X desc %08X %08X tsc=%d"):format(
					want,
					self.cs,
					self.ip,
					prevSel,
					prevIp,
					self.mem:read32(probePhys(self, a)),
					self.mem:read32(probePhys(self, a + 4)),
					self.tsc
				)
			)
			if faultRing then
				for q = 1, faultRingLen do
					local e = faultRing[(faultRingPos + q - 1) % faultRingLen + 1]
					if e then
						print(e)
					end
				end
			end
		end
		prevSel, prevIp = self.cs, self.ip
		return oe(self)
	end
end

-- --irq-hist 1: count Pic:raise calls per IRQ and print at end.
if opts.irqHist then
	local rc: { [number]: number } = {}
	local origRaise = m.pic.raise
	m.pic.raise = function(self, irq)
		rc[irq] = (rc[irq] or 0) + 1
		return origRaise(self, irq)
	end
	irqHistRef = rc
end

-- --vxdlog DEVICE [--vxdlog-service S]: print every `int 20h` dynamic link call to the VxD
-- DEVICE (hex) with cs:ip and the other registers; stops after --vxdlog-n hits.
if opts.vxdlog then
	local dev = if opts.vxdlog == "any" then nil else tonumber(opts.vxdlog, 16)
	local svc = if opts.vxdlogService then tonumber(opts.vxdlogService, 16) else nil
	local want = tonumber(opts.vxdlogN) or 20
	local got = 0
	local origV = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		do
			local lin = self.segBase.cs + self.ip
			local okT, phys = pcall(function()
				return probePhys(self, lin, false, false)
			end)
			if okT then
				lin = phys
			end
			if m.mem:read8(lin) == 0xCD and m.mem:read8(lin + 1) == 0x20 then
				local service = m.mem:read16(lin + 2)
				local device = m.mem:read16(lin + 4)
				if (dev == nil or device == dev) and (svc == nil or service == svc) then
					got += 1
					print(
						("VXD#%d %04X:%X call dev=%X svc=%X eax=%X ebx=%X ecx=%X edx=%X esi=%X edi=%X esp=%X"):format(
							got,
							self.cs,
							self.ip,
							device,
							service,
							self:rr32(0),
							self:rr32(3),
							self:rr32(1),
							self:rr32(2),
							self:rr32(6),
							self:rr32(7),
							self:rr32(4)
						)
					)
					if got >= want then
						process.exit(0)
					end
				end
			end
		end
		return origV(self)
	end
end

local function advance(limit)
	-- Runs until st.executed reaches `limit`; returns a stop reason or nil.
	while st.executed < limit do
		local ok, result = pcall(function()
			return m:run(math.min(1_000_000, limit - st.executed))
		end)
		if not ok then
			print(("FAULT after %d steps: %s"):format(st.executed, tostring(result)))
			if faultRing then
				for q = 1, faultRingLen do
					local e = faultRing[(faultRingPos + q - 1) % faultRingLen + 1]
					if e then
						print("RF " .. e)
					end
				end
			end
			return "fault"
		end
		st.executed += result
		if watchAddr then
			local now = watchBytes()
			if now ~= watchLast then
				print(
					("WATCH %s changed in the chunk ending at %d: %s -> %s"):format(
						opts.watch,
						st.executed,
						watchLast,
						now
					)
				)
				watchLast = now
				if opts.watchStop then
					return "watch"
				end
			end
		end
		if m.irqCount ~= st.irqSeen then
			st.irqSeen = m.irqCount
			st.irqAt = st.executed
			st.stallReported = false
		elseif st.executed - st.irqAt >= 12_000_000 and not st.stallReported then
			st.stallReported = true
			print(
				([[IRQSTALL since %d (now %d) IF=%s pc=%s]]):format(
					st.irqAt,
					st.executed,
					tostring(bit32.band(m.cpu.flags, 0x200) ~= 0),
					m:bootPc()
				)
			)
		end
		if st.executed >= 500_000_000 and m.pit.channel0Divisor ~= 1 then
			m.pit.channel0Divisor = 1
		end
		if keyIndex <= #keyQueue and st.executed >= keysAt then
			local combo = keyQueue[keyIndex]
			if keyMode[keyIndex] ~= "UP" then
				for _, code in ipairs(combo) do
					m:pressKey(code)
				end
			end
			if keyMode[keyIndex] ~= "HOLD" then
				for k = #combo, 1, -1 do
					m:releaseKey(combo[k])
				end
			end
			print(("KEY %d/%d at %d"):format(keyIndex, #keyQueue, st.executed))
			keyIndex += 1
			keysAt = st.executed + keysGap
			if keyIndex > #keyQueue then
				shot()
			end
		end
		if st.executed >= 580_000_000 and st.executed - st.lastGuiAct >= 80_000_000 then
			st.lastGuiAct = st.executed
			shot()
			if not opts.noAutoEnter then
				m:pressKey(0x1C)
				m:releaseKey(0x9C)
			end
		end
		if st.executed - st.statusAt >= 100_000_000 then
			st.statusAt = st.executed - st.executed % 100_000_000
			print(
				("STATUS %d pc=%s vga=%dx%d irqs=%d elapsed=%.0fs"):format(
					st.executed,
					m:bootPc(),
					m.vga:width(),
					m.vga:height(),
					m.irqCount,
					os.clock() - startedAt
				)
			)
		end
		if nextSave and st.executed >= nextSave then
			checkpoint(("%s.%dm"):format(opts.save, nextSave // 1_000_000))
			nextSave += saveEvery
		end
		local screen = m:outputText()
		if screen ~= st.lastScreen then
			st.lastScreen = screen
			print(("-- screen at %d pc=%s --"):format(st.executed, m:bootPc()))
			print(screen)
		end
		if react(screen) == "stop" then
			return "stop"
		end
		if result == 0 then
			print(("HALT at %d pc=%s"):format(st.executed, m:bootPc()))
			return "halt"
		end
	end
	return nil
end

if verifyAt then
	-- Determinism proof: run to verifyAt, checkpoint, run on for verifySpan and
	-- fingerprint; restore into a fresh machine and run the same span.
	local reason = advance(verifyAt)
	if reason then
		print("verify aborted early: " .. reason)
		process.exit(1)
	end
	local blob = Snapshot.capture(m, build(), st)
	print(("checkpoint %.1f MiB at %d"):format(#blob / 1048576, st.executed))
	advance(verifyAt + verifySpan)
	local want = fingerprint()
	local want_screen = m:outputText()
	m = build()
	st = Snapshot.apply(m, blob)
	advance(verifyAt + verifySpan)
	local got = fingerprint()
	print("original: " .. want)
	print("restored: " .. got)
	if want == got and want_screen == m:outputText() then
		print("VERIFY OK")
		process.exit(0)
	end
	print("VERIFY MISMATCH")
	process.exit(1)
end

if saveAt and st.executed < saveAt then
	local reason = advance(saveAt)
	if reason then
		stopReason = reason
	else
		checkpoint(opts.save)
	end
end
if stopReason == "budget" then
	stopReason = advance(budget) or "budget"
end
if irqHistRef then
	for irq, n in irqHistRef do
		print(("IRQRAISE %d %d"):format(irq, n))
	end
end
if opts.ideState and m.ide then
	local ide = m.ide :: any
	local t = ide.transfer
	print(
		("IDEST status=%02X irqPending=%s devCtl=%02X lba=%s cnt=%s bmCmd=%s bmStatus=%s prdt=%s transfer=%s pos=%s len=%s"):format(
			ide.selected.status,
			tostring(ide.irqPending),
			ide.deviceControl,
			tostring(ide.lba),
			tostring(ide.sectorCount),
			tostring(ide.bmCmd),
			tostring(ide.bmStatus),
			tostring(ide.bmPrdt),
			tostring(t ~= nil),
			tostring(t and t.pos),
			tostring(t and t.length)
		)
	)
end
if opts.bt then
	local cpu = m.cpu :: any
	local esp = cpu:rr32(4)
	local base = cpu.segBase.ss
	local out = {}
	for i = 0, tonumber(opts.bt) :: number do
		local ok, v = pcall(function()
			return cpu.mem:read32(probePhys(cpu, base + esp + i * 4))
		end)
		if ok and v >= 0xC0000000 and v < 0xC1000000 then
			table.insert(out, ("%X:%08X"):format(i * 4, v))
		end
	end
	print(
		("BT esp=%08X eip=%08X ebp=%08X: %s"):format(
			esp,
			cpu.ip,
			cpu:rr32(5),
			table.concat(out, " ")
		)
	)
end
if opts.tss then
	local cpu = m.cpu :: any
	local mb = cpu.mem:read16(probePhys(cpu, cpu.trBase + 0x66))
	local function b(port)
		return cpu.mem:read8(probePhys(cpu, cpu.trBase + mb + port // 8))
	end
	print(
		("TSS tr=%04X base=%08X limit=%X tr32=%s mapBase=%X bits20=%02X bitsA0=%02X bits1F0=%02X"):format(
			cpu.tr or -1,
			cpu.trBase,
			cpu.trLimit,
			tostring(cpu.tr32),
			mb,
			b(0x20),
			b(0xA0),
			b(0x1F0)
		)
	)
end
if execCountRef then
	print(("EXEC %d instructions"):format(execCountRef.n))
end
if pcHistRef then
	local keys = {}
	for k in pcHistRef do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return (pcHistRef :: any)[a] > (pcHistRef :: any)[b]
	end)
	for i = 1, math.min(40, #keys) do
		print(("PC %s %d"):format(keys[i], (pcHistRef :: any)[keys[i]]))
	end
	-- Per-code-segment totals of the same samples.
	local bySeg: { [string]: number } = {}
	for k, v in pcHistRef :: any do
		const seg = string.sub(k, 1, 4)
		bySeg[seg] = (bySeg[seg] or 0) + v
	end
	for seg, v in bySeg do
		print(("PCSEG %s %d"):format(seg, v))
	end
end
if ioHistRef then
	local keys = {}
	for k in ioHistRef do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return (ioHistRef :: any)[a] > (ioHistRef :: any)[b]
	end)
	for i = 1, math.min(20, #keys) do
		print(("IO %s %d"):format(keys[i], (ioHistRef :: any)[keys[i]]))
	end
end
if vgaHistRef then
	for k, v in vgaHistRef do
		print(("HIST %s %d"):format(k, v))
	end
end
-- --ring-end 1: with --ring-fault, print the ring when the run ends.
if opts.ringEnd and faultRing then
	for q = 1, faultRingLen do
		local e = faultRing[(faultRingPos + q - 1) % faultRingLen + 1]
		if e then
			print(e)
		end
	end
end
if opts.endText then
	print("-- text screen at end --")
	print(m:outputText())
end
print(
	("END %s at %d steps pc=%s elapsed=%.0fs"):format(
		stopReason,
		st.executed,
		m:bootPc(),
		os.clock() - startedAt
	)
)
print(m:outputText())
