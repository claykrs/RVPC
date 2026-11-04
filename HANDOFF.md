# HANDOFF — RVDM98

Windows 98 SE on a real 486/Pentium-class PC inside Roblox.

## Decisions

- **Target:** Windows 98 SE only (not 95, not 98 Gold).
- **Host:** Roblox/Luau client; core stays environment-pure.
- **Codebase:** forked from RVDM as a reference, but the machine layer is being
  rebuilt. Windows 3.x-specific DOS/VFS/NE hacks are not part of the target.
- **Firmware:** real SeaBIOS (prebuilt ROM, staged locally; not committed).
- **Install:** boot the 98 SE ISO, partition/format a virtual HDD, install,
  then boot from the HDD.
- **Network:** NE2000 + a host-side virtual ISP from the start.

## Milestones

### M0 — machine skeleton
- 32-bit physical memory, bus, ROM mapping
- 386 real mode CPU baseline, PIC/PIT/CMOS, A20
- SeaBIOS reaches its boot menu
- VGA text mode 3 through EditableImage
- Lune harness + Roblox client shell

### M1 — boot a real OS
- 386 protected mode, paging, V86, TSS/descriptor tables
- IDE PIO + ATAPI CD-ROM, MBR/partition reads
- SeaBIOS boots FreeDOS or a Linux floppy/ISO
- PS/2 keyboard/mouse, serial

### M2 — Windows 98 SE install
- IDE HDD writes, partition/format compatibility
- VGA/SVGA modes, mouse, SB16
- Win98 SE setup runs from CD and installs to C:
- First boot to the Windows 98 desktop

### M3 — usable 98
- SVGA 800x600/1024x768, Sound Blaster, mouse pointer
- DOS boxes / V86, 32-bit drivers
- persistent disk images, snapshots, file import/export

### M4 — network
- NE2000 + virtual ISP (DHCP/DNS/ARP/IP/TCP/UDP)
- HTTP/IRC/BBS/mail inside the guest
- optional relay to the real internet

### M5 — platform
- machine library, cloud C:, app store, compatibility telemetry
- releases with model + demo image + media

## Current state

- RVDM HEAD was forked into this repo as reference.
- Core kept: `Cpu`, `Memory`, `Vga`, `Uart`, `Lpt`, `Xms`, `init`.
- Removed: Windows 3.x BIOS/DOS/VFS/NE loader, fixtures, SETUP.INF tools.
- `Cpu.lua` already has 286 PM/descriptor caches from R7; it still needs
  32-bit addressing/paging/V86 for 98.
- `Memory.lua` is still the RVDM 1 MiB model; replace with 32-bit physical
  memory before boot tests.

## Hard rules

- `core/` is environment-pure and `--!strict`.
- No cycle accuracy requirement; compatibility and correctness win.
- Do not commit Microsoft media, SeaBIOS binaries or disk images.
- Every milestone must leave `lune run tools/check.lua` green.
