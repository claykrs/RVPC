--!nonstrict
-- stage_win98.lua -- verify media/win98se.iso is a bootable El Torito image
-- and stage media/win98-hdd.img for the Windows 98 installer run.
--
-- Usage: lune run tools/stage_win98.lua [--hdd-mib 512]

const fs = require("@lune/fs")
const process = require("@lune/process")

const ISO_PATH = "media/win98se.iso"
const HDD_PATH = "media/win98-hdd.img"

local hddMib = 512
for index = 1, #process.args - 1 do
	if process.args[index] == "--hdd-mib" then
		hddMib = tonumber(process.args[index + 1]) or 512
	end
end

local function fail(message: string)
	print("STAGE FAILED: " .. message)
	process.exit(1)
end

if not fs.isFile(ISO_PATH) then
	fail(ISO_PATH .. " missing; download a Windows 98 SE ISO into media/")
end

local iso = buffer.fromstring(fs.readFile(ISO_PATH))
const isoSize = buffer.len(iso)
print(("ISO: %s, %d bytes (%.1f MiB)"):format(ISO_PATH, isoSize, isoSize / 1048576))
if isoSize < 400 * 1048576 then
	fail("ISO smaller than 400 MiB - the download probably did not complete")
end

local function sector(lba: number): number
	return lba * 2048
end

local function match(offset: number, text: string): boolean
	for index = 1, #text do
		if buffer.readu8(iso, offset + index - 1) ~= string.byte(text, index) then
			return false
		end
	end
	return true
end

local function le32(offset: number): number
	return buffer.readu32(iso, offset)
end

local function le16(offset: number): number
	return buffer.readu16(iso, offset)
end

-- ISO9660: primary volume descriptor in sector 16.
const pvd = sector(16)
if not match(pvd + 1, "CD001") then
	fail("sector 16 has no CD001 signature - not an ISO9660 image")
end
if buffer.readu8(iso, pvd) ~= 0x01 then
	fail(("sector 16 descriptor type %d, expected 1 (PVD)"):format(buffer.readu8(iso, pvd)))
end
print("ISO9660 PVD found in sector 16")

-- Root directory record lives at PVD offset 156.
const rootExtent = le32(pvd + 156 + 2)
const rootSize = le32(pvd + 156 + 10)
print(("root directory: LBA %d, %d bytes"):format(rootExtent, rootSize))

-- El Torito: boot record volume descriptor in sector 17.
const brvd = sector(17)
if not match(brvd + 1, "CD001") then
	fail("sector 17 has no CD001 signature - no boot record volume descriptor")
end
if not match(brvd + 7, "EL TORITO SPECIFICATION") then
	fail("sector 17 is not an El Torito boot record - the ISO is not bootable")
end
const catalogLba = le32(brvd + 71)
print(("El Torito boot record found, catalog at LBA %d"):format(catalogLba))

-- Validation entry. Standard images carry header 0x69 and a zero word-sum;
-- some Win98-era writers emitted a legacy header (0x01) with the same AA55
-- key, and SeaBIOS boots those, so accept both and only fail on the key.
const ve = sector(catalogLba)
const header = buffer.readu8(iso, ve)
const platform = buffer.readu8(iso, ve + 1)
if header == 0x69 then
	local sum = 0
	for word = 0, 15 do
		sum = (sum + le16(ve + word * 2)) % 0x10000
	end
	if sum ~= 0 then
		fail(("validation entry checksum %04X, expected 0"):format(sum))
	end
	print(
		('validation entry OK (platform %s, id "%s")'):format(
			if platform == 0 then "x86" else tostring(platform),
			string.sub(buffer.tostring(iso), ve + 4 + 1, ve + 4 + 24):gsub("%s+$", "")
		)
	)
elseif header == 0x01 and le16(ve + 30) == 0xAA55 then
	print("validation entry uses the legacy Win98 header (01), key AA55 OK")
else
	fail(("catalog header %02X without AA55 key - no usable El Torito catalog"):format(header))
end

-- Initial/default entry: bootable flag 0x88 and the load spec.
const entry = ve + 32
const bootable = buffer.readu8(iso, entry)
const mediaType = buffer.readu8(iso, entry + 1)
const loadSegment = le16(entry + 2)
const sectorCount = le16(entry + 8)
const loadLba = le32(entry + 12)
if bootable ~= 0x88 then
	fail(("initial boot entry flag %02X, expected 0x88 (bootable)"):format(bootable))
end
const mediaNames = {
	[0] = "no emulation",
	[1] = "1.2M floppy",
	[2] = "1.44M floppy",
	[3] = "2.88M floppy",
	[4] = "hard disk",
}
print(
	("boot entry: %s, load segment %04X, %d sectors from LBA %d"):format(
		mediaNames[mediaType] or ("type " .. mediaType),
		loadSegment,
		sectorCount,
		loadLba
	)
)

-- Walk the root directory and look for the WIN98 folder the installer needs.
const rootData = rootExtent * 2048
local win98Found = false
local setupExe = false
local offset = 0
while offset < rootSize do
	const recordLength = buffer.readu8(iso, rootData + offset)
	if recordLength == 0 then
		break
	end
	const nameLength = buffer.readu8(iso, rootData + offset + 32)
	const name = string.sub(
		buffer.tostring(iso),
		rootData + offset + 33 + 1,
		rootData + offset + 33 + nameLength
	)
	if name == "WIN98" then
		win98Found = true
	end
	if name == "SETUP.EXE;1" or name == "SETUP.EXE" then
		setupExe = true
	end
	offset += recordLength
end
if win98Found then
	print("root directory contains WIN98 (the installer folder)")
else
	print("warning: no WIN98 folder in the ISO root; this may not be the retail CD")
end
print(("root directory SETUP.EXE: %s"):format(tostring(setupExe)))

-- Stage the blank hard disk image the installer will partition and format.
if fs.isFile(HDD_PATH) then
	const existing = buffer.fromstring(fs.readFile(HDD_PATH))
	print(("HDD: %s already staged, %d MiB"):format(HDD_PATH, buffer.len(existing) / 1048576))
else
	const sectors = math.floor(hddMib * 1048576 / 512)
	fs.writeFile(HDD_PATH, buffer.tostring(buffer.create(sectors * 512)))
	print(("HDD: wrote %s, %d MiB of zeros (%d sectors)"):format(HDD_PATH, hddMib, sectors))
end

print("")
print("next steps:")
print("  1. tools\\bin\\lune.exe run tools\\harness.lua 300")
print("     the harness attaches " .. ISO_PATH .. " as the CD and " .. HDD_PATH)
print("     as the hard disk, boots SeaBIOS, and answers the Microsoft")
print("     CD-ROM startup menu with 2 (Boot from CD-ROM).")
print("  2. the Windows 98 startup menu then defaults to 1 (Start Windows")
print("     98 Setup); watch the VGA text output for SETUP progress.")
print("  3. media/win98-hdd.img is persisted back by the harness when IDE")
print("     sectors change, so an install can resume across runs.")
