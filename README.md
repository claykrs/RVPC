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

```powershell
lune run tools/check.lua
lune run tools/harness.lua
```

## Status

Early bring-up. See `HANDOFF.md`, `docs/ARCHITECTURE.md` and
`docs/WIN98.md`.

## License

MIT for the emulator source. Microsoft Windows and SeaBIOS media are not
included; supply your own copies where required.
