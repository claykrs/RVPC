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
-- Options (millions of steps): --budget, --save-at, --save-every (rolling
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
local st = newState()
if opts.load then
	local started = os.clock()
	st = Snapshot.apply(m, fs.readFile(opts.load))
	print(("loaded %s at step %d in %.1fs"):format(opts.load, st.executed, os.clock() - started))
	-- --dump ADDR [--dump-len N]: print physical bytes of the loaded checkpoint and exit.
	if opts.dump then
		local a, n = tonumber(opts.dump), tonumber(opts.dumpLen) or 64
		for row = 0, n - 1, 16 do
			local t = {}
			for k = row, math.min(row + 15, n - 1) do
				table.insert(t, ("%02X"):format(m.mem:read8(a + k)))
			end
			print(("%X: %s"):format(a + row, table.concat(t, " ")))
		end
		process.exit(0)
	end
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
	fs.writeFile(("tools/out/w98_%03d.ppm"):format(st.guiShot), table.concat(out))
	print(("SHOT %d at %d steps pc=%s"):format(st.guiShot, st.executed, m:bootPc()))
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

local budget = opts.budget * 1_000_000
local saveAt = if opts.saveAt then opts.saveAt * 1_000_000 else nil
local verifyAt = if opts.verify then opts.verify * 1_000_000 else nil
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
		local pre = ("pre ecx=%X esi=%X edi=%X ds=%04X es=%04X"):format(
			self:rr32(1),
			self:rr32(6),
			self:rr32(7),
			self.ds,
			self.es
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
	local orig2 = m.cpu.executeStep
	m.cpu.executeStep = function(self)
		if
			(rlin and self.cs * 16 + self.ip == rlin)
			or (not rlin and self.cs == rcs and self.ip == rip)
		then
			for k = 1, ringLen do
				local e = ring[(rpos + k - 1) % ringLen + 1]
				if e then
					print(e)
				end
			end
			print(("HIT %04X:%X"):format(rcs, rip))
			local cb = self.cs * 16 + self.ip
			local bt = {}
			for q = -8, 24 do
				table.insert(bt, ("%02X"):format(m.mem:read8(cb + q)))
			end
			print("CODE(-8..+24): " .. table.concat(bt, " "))
			print(("A20=%s SS=%04X SP=%X"):format(tostring(m.mem.a20), self.ss, self:rr32(4)))
			process.exit(0)
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
		return orig2(self)
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
		if st.executed >= 580_000_000 and st.executed - st.lastGuiAct >= 80_000_000 then
			st.lastGuiAct = st.executed
			shot()
			m:pressKey(0x1C)
			m:releaseKey(0x9C)
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
print(
	("END %s at %d steps pc=%s elapsed=%.0fs"):format(
		stopReason,
		st.executed,
		m:bootPc(),
		os.clock() - startedAt
	)
)
print(m:outputText())
