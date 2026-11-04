# RVPC - a real PC in Roblox, targeting Windows 98 SE

RVPC is a from-scratch successor to the original Windows 3.0 emulator. It is a **full-system x86 PC
emulator** written in Luau, intended to run inside Roblox on the client.

**RVPC/98** is the Windows 98 SE machine profile. The product is a virtual PC,
not a DOS compatibility layer.

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

M1 boot is reached: the primary IDE channel exposes an ATA HDD and ATAPI
CD-ROM. SeaBIOS enters `boot_cdrom`, boots the staged FreeDOS 1.3 floppy-
emulation ISO through its language menu and reaches the **FreeCom 0.85a**
shell (`tools/harness.lua`). The FD13LIVE no-emulation ISOLINUX path also boots,
but its COM32 payload currently faults at `0020:67612816`; see
`docs/M1-REPORT.md` for both traces.

The Roblox client shell, EditableImage VGA presenter, set-1 keyboard/mouse
input bridge, NE2000 controller and virtual ISP (ARP/IPv4/ICMP/DHCP/DNS) are
in the tree. Stage `media/freedos-boot.iso`, `media/FD13LIVE.iso` and optional
`media/hdd.img` as described in the report before running the harness. See also
`HANDOFF.md`, `docs/M0-REPORT.md`, `docs/ARCHITECTURE.md` and `docs/WIN98.md`.

## License

MIT for the emulator source. Microsoft Windows and SeaBIOS media are not
included; supply your own copies where required.
