# Windows 98 SE target

## Why 98 SE

- Last widely used DOS-based Windows; huge software library.
- Real TCP/IP, IE, Outlook Express, DOS boxes, USB/ACPI-era drivers.
- Still small enough for a 486/Pentium-class machine.

## What Win98 needs from the PC

- 386 enhanced mode: paging, V86, 32-bit protected mode.
- VxD / 32-bit driver model (VMM, IOS, VDD, sound, disk).
- IDE/ATAPI CD-ROM and HDD, MBR/partition support.
- VGA/SVGA modes, PS/2 mouse.
- PIT/PIC/DMA/RTC, A20.
- 32-64 MB RAM; x87 FPU (now has a practical 486 subset).
- ACPI not required for the first boot; PnP/PCI later.

## Current status

M1 is green: SeaBIOS boots the FreeDOS 1.3 floppy-emulation CD, shows the
language menu, and reaches FreeCom. The same SeaBIOS also enters `boot_cdrom`
for no-emulation ISOLINUX media. Keyboard input through the emulated 8042
reaches BIOS INT16 (`pressKey(0x1C)` selects the FreeDOS menu item).

For Windows 98:

- IDE primary master HDD + primary slave CD is the installer path.
- ATA PIO writes, dirty-sector tracking and HDD image write-back are in place.
- Synthetic MBR/partition boot and no-emulation El Torito boot are verified.
- ATAPI READ(10/12/16), TOC, capacity and sense are implemented.
- VGA text 3, planar 12h and linear 13h work; SVGA/VBE is still missing.
- x87 context save/restore and TS/EM lazy switching are implemented; no full
  80-bit precision or unmasked #MF yet.

## Install flow

1. SeaBIOS boots the 98 SE CD.
2. Setup loads a RAM disk / real-mode drivers.
3. Partition and format the virtual HDD (FAT16/32).
4. Copy CAB files, reboot into the GUI setup.
5. First boot to the desktop; install VGA/mouse/sound/network drivers.

## Media and run

Windows media is **not** committed and must be supplied locally:

- `media/win98se.iso` - Windows 98 SE install CD.
- `media/win98-hdd.img` - blank or partitioned HDD image (512 MiB recommended;
  the 32 MiB `hdd.img` is only for FreeDOS/geometry tests).
- `roms/bios-256k.bin` and `roms/vgabios-stdvga.bin` - staged firmware.

```powershell
lune run tools/harness.lua 200   # step budget in millions
```

The harness prefers `media/win98se.iso` when present, otherwise the FreeDOS
images. It saves `media/win98-hdd.img` back after guest writes. A 512 MiB image
is suggested for a real install.

## Known blockers to clear

- SVGA/VBE modes and the Roblox host sink for the 98 desktop.
- IDE protected-mode programming details and CD install throughput.
- 80-bit x87 precision, FLDENV/FSTENV edge cases and #MF.
- DMA controller and bus-master IDE if the protected-mode driver requires it.
- PS/2 mouse integration and audio/network drivers after first boot.

## Non-goals for the first 98 boot

- USB, AGP, 3D, printing, networking before the desktop.
- Cycle accuracy.
