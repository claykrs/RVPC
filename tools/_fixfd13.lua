--!nonstrict
-- _fixfd13.lua -- rebuild media/_test_hdd.img (the 32 MiB-padded boot test
-- copy of the pre-installed FreeDOS C:) from the pristine sys-transfer dump
-- media/fd13-c.img, then pre-write CONFIG.SYS/AUTOEXEC.BAT correctly.
--
-- Why this exists: the original (lost) step that turned fd13-c.img into
-- _test_hdd.img corrupted the disk three ways - it shifted KERNEL.SYS and
-- COMMAND.COM forward by exactly 2 bytes (two leading zeros, two tail bytes
-- lost), claimed clusters 4/5 for the two small files (they are the middle of
-- COMMAND.COM's chain 3..44), and stamped FAT1[4]=FAT1[5]=0xFFFF over
-- COMMAND.COM's chain. DOS reads FAT1, so the kernel exec'ed a 4 KB
-- truncation of COMMAND.COM and jumped to entry 0FF7:8410 inside zeroed
-- memory; the CPU slid through `00 00` bytes until it hit the `0F 10` bytes
-- of the exec handoff frame at 0FF7:F7AF (misread as an unimplemented SSE
-- MOVUPS). The install itself is verified clean: a replayed dump is
-- byte-identical to fd13-c.img.
--
-- The rebuild pads the pristine dump to 32 MiB and allocates CONFIG.SYS and
-- AUTOEXEC.BAT on genuinely free clusters (68/69), updating both FAT copies
-- and the root directory. Prints a verification of every file chain.
local fs = require("@lune/fs")
local band = bit32.band
local bor = bit32.bor
local lshift = bit32.lshift
local rshift = bit32.rshift

local SRC = "media/fd13-c.img"
local PATH = "media/_test_hdd.img"
local TOTAL = 32 * 1024 * 1024

-- CONFIG.SYS / AUTOEXEC.BAT as pre-written for the boot test (55 / 78 bytes,
-- matching the sizes the original pre-write step recorded in its directory
-- entries).
local CONFIG_SYS = "FILES=20\r\nBUFFERS=20\r\nLASTDRIVE=Z\r\nDRIVPARM=/D:0 /F:0\r\n"
local AUTOEXEC_BAT =
	"@ECHO OFF\r\nPROMPT $P$G\r\nPATH=C:\\\r\nECHO FreeDOS 1.3 preinstalled image ready.\r\n"

local data = fs.readFile(SRC)
assert(#data <= TOTAL, "payload larger than target image")
data = data .. string.rep("\0", TOTAL - #data)

local function rd16(off: number): number
	local b = (data :: any).byte
	return bor(b(data, off + 1), lshift(b(data, off + 2), 8))
end
local function rd32(off: number): number
	local b = (data :: any).byte
	return bor(
		b(data, off + 1),
		lshift(b(data, off + 2), 8),
		lshift(b(data, off + 3), 16),
		lshift(b(data, off + 4), 24)
	)
end
local function wr16(off: number, v: number)
	local s = string.char(band(v, 0xFF), band(rshift(v, 8), 0xFF))
	data = string.sub(data :: string, 1, off) .. s .. string.sub(data :: string, off + 3)
end

-- geometry from the MBR/VBS
local partLba = 63
local vbs = partLba * 512
assert(string.sub(data :: string, vbs + 4, vbs + 11) == "FRDOS5.1", "unexpected VBS OEM")
local bps = rd16(vbs + 11)
local spc = (data :: any).byte(data, vbs + 14)
local res = rd16(vbs + 14)
local nfat = (data :: any).byte(data, vbs + 17)
local nroot = rd16(vbs + 17)
local spf = rd16(vbs + 22)
local fatStart = partLba * bps + res * bps
local fat2Start = fatStart + spf * bps
local rootStart = fatStart + nfat * spf * bps
local dataStart = rootStart + nroot * 32
local function cluster(clus: number, fatBase: number): number
	return rd16(fatBase + clus * 2)
end
print(
	string.format(
		"geometry: bps=%d spc=%d res=%d nfat=%d nroot=%d spf=%d fat1=%#x fat2=%#x root=%#x data=%#x",
		bps,
		spc,
		res,
		nfat,
		nroot,
		spf,
		fatStart,
		fat2Start,
		rootStart,
		dataStart
	)
)

-- verify the pristine payload before touching anything
local function dirEntry(i: number, name: string, clus: number, size: number): number
	local off = rootStart + i * 32
	local nm = string.sub(data :: string, off + 1, off + 11)
	assert(nm == name, ("root[%d] is %q, expected %q"):format(i, nm, name))
	assert(rd16(off + 26) == clus, ("root[%d] cluster %d != %d"):format(i, rd16(off + 26), clus))
	assert(rd32(off + 28) == size, ("root[%d] size %d != %d"):format(i, rd32(off + 28), size))
	return off
end
assert(cluster(2, fatStart) == 0xFFFF and cluster(2, fat2Start) == 0xFFFF, "TEMP not at cluster 2")
dirEntry(2, "COMMAND COM", 3, 85480)
dirEntry(3, "KERNEL  SYS", 45, 46256)
assert(cluster(68, fatStart) == 0xFFFF, "cluster 68 marked used in FAT1")
assert(cluster(69, fatStart) == 0 and cluster(69, fat2Start) == 0, "cluster 69 not free")

-- 1. root directory entries for CONFIG.SYS / AUTOEXEC.BAT (slots 4 and 5)
local cfgOff = rootStart + 4 * 32
local exeOff = rootStart + 5 * 32
local function setEntry(off: number, name: string, clus: number, size: number)
	-- name(11) attr(1) reserved(10) time(2) date(2) cluster(2) size(4)
	local entry = name
		.. string.char(0x20)
		.. string.rep("\0", 10)
		.. string.rep("\0", 4)
		.. string.char(band(clus, 0xFF), band(rshift(clus, 8), 0xFF))
		.. string.char(
			band(size, 0xFF),
			band(rshift(size, 8), 0xFF),
			band(rshift(size, 16), 0xFF),
			band(rshift(size, 24), 0xFF)
		)
	assert(#entry == 32, "directory entry size")
	data = string.sub(data :: string, 1, off) .. entry .. string.sub(data :: string, off + 33)
end
setEntry(cfgOff, "CONFIG  SYS", 68, #CONFIG_SYS)
setEntry(exeOff, "AUTOEXECBAT", 69, #AUTOEXEC_BAT)

-- 2. FAT entries: 68/69 are one-cluster files; both FAT copies
for _, base in { fatStart, fat2Start } do
	wr16(base + 68 * 2, 0xFFFF)
	wr16(base + 69 * 2, 0xFFFF)
end

-- 3. file data on the fresh clusters
local cfgClus = dataStart + (68 - 2) * spc * bps
local exeClus = dataStart + (69 - 2) * spc * bps
data = string.sub(data :: string, 1, cfgClus)
	.. CONFIG_SYS
	.. string.sub(data :: string, cfgClus + #CONFIG_SYS + 1)
data = string.sub(data :: string, 1, exeClus)
	.. AUTOEXEC_BAT
	.. string.sub(data :: string, exeClus + #AUTOEXEC_BAT + 1)

fs.writeFile(PATH, data :: string)

-- verify: walk every file chain from both FATs
local function walk(clus: number, fatBase: number): { number }
	local out = {}
	while clus >= 2 and clus < 0xFFF8 do
		out[#out + 1] = clus
		clus = cluster(clus, fatBase)
		if #out > 500 then
			error("runaway FAT chain")
		end
	end
	return out
end
local files = {
	{ "TEMP       ", 2, 0 },
	{ "COMMAND COM", 3, 85480 },
	{ "KERNEL  SYS", 45, 46256 },
	{ "CONFIG  SYS", 68, #CONFIG_SYS },
	{ "AUTOEXECBAT", 69, #AUTOEXEC_BAT },
}
for _, f in files do
	local name, clus, size = f[1], f[2], f[3]
	local c1 = walk(clus, fatStart)
	local c2 = walk(clus, fat2Start)
	local need = if size == 0 then 1 else math.ceil(size / (spc * bps))
	local ok = #c1 == need and #c1 == #c2
	print(
		("verify %-12s clus=%d need=%d got=%d chainMatch=%s"):format(
			name,
			clus,
			need,
			#c1,
			tostring(#c1 == #c2)
		)
	)
	assert(ok, "chain verification failed for " .. name)
end
print("rebuilt", PATH, "from", SRC)
