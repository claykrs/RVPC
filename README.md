# RVDM98 — a real PC in Roblox, targeting Windows 98 SE

RVDM98 is a from-scratch successor to RVDM. It is a **full-system x86 PC
emulator** written in Luau, intended to run inside Roblox on the client.

The target is a **486/Pentium-class PC** with:

- 386/486 real, protected and V86 modes, paging, TSS
- 32–64 MB RAM
- SeaBIOS firmware
- IDE/ATAPI CD-ROM and hard disk
- VGA/SVGA, PS/2 keyboard and mouse
- Sound Blaster, serial, parallel
- NE2000 Ethernet with a host-side virtual ISP

That machine is meant to **boot and install Windows 98 SE from a CD onto a
virtual hard disk**, then run the desktop, applications and a real TCP/IP
stack. Windows is a guest OS, not a reimplementation.

The emulator is environment-pure in `core/`: no `require`, `game`, filesystem,
`print` or Roblox APIs. Host services (video, input, disk, network, audio) are
injected through `Machine.new`.

## Build

Windows 98 SE media is **not** committed. The release page will provide a
ready-to-run demo image and the emulator model; the source repo stays free of
Microsoft binaries.

Firmware is staged locally under `roms/` (gitignored):

```powershell
New-Item -ItemType Directory -Force roms
Invoke-WebRequest `
  https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/bios-256k.bin `
  -OutFile roms/bios-256k.bin
Invoke-WebRequest `
  https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/vgabios-stdvga.bin `
  -OutFile roms/vgabios-stdvga.bin
```

The SeaBIOS image is the 256 KiB QEMU build (`rel-1.17.0` in the current
bring-up); `vgabios-stdvga.bin` supplies the INT 10h text console. Both are
firmware blobs, not Microsoft media.

```powershell
lune run tools/check.lua
lune run tools/harness.lua
lune run tools/harness.lua 40   # step budget in millions
```

## Status

M0 is green: the machine boots real SeaBIOS, initializes PIC/PIT/CMOS/A20/PCI/
fw_cfg, runs SeaVGABIOS in text mode 3, and reaches the no-bootable-device
screen.

M1 is in bring-up: the primary IDE channel exposes an ATA HDD and ATAPI CD-ROM,
SeaBIOS detects both, and its boot menu lists a FreeDOS 1.3 LiveCD. Selecting
the CD currently reaches a measured CPU fault at `F000:85EF` (`bad FF /7`); the
exact trace and next actions are in `docs/M1-REPORT.md`. Stage the FreeDOS
LiveCD (`media/FD13LIVE.iso`) and optional `media/hdd.img` as described there
before running the harness. See also `HANDOFF.md`, `docs/M0-REPORT.md`,
`docs/ARCHITECTURE.md` and `docs/WIN98.md`.

## License

MIT for the emulator source. Microsoft Windows and SeaBIOS media are not
included; supply your own copies where required.
