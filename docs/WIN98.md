# Windows 98 SE target

## Why 98 SE
- Last widely used DOS-based Windows; huge software library.
- Real TCP/IP, IE, Outlook Express, DOS boxes, USB/ACPI-era drivers.
- Still small enough for a 486/Pentium-class machine.

## What Win98 needs from the PC

- 386 enhanced mode: paging, V86, 32-bit protected mode
- VxD / 32-bit driver model (VMM, IOS, VDD, sound, disk)
- IDE/ATAPI CD-ROM and HDD, MBR/partition support
- VGA/SVGA modes, PS/2 mouse
- PIT/PIC/DMA/RTC, A20
- ~16 MB minimum; 32–64 MB realistic
- No ACPI required for the first boot; PnP/PCI later

## Install flow

1. SeaBIOS boots the 98 SE CD.
2. Setup loads a RAM disk / real-mode drivers.
3. Partition and format the virtual HDD (FAT16/32).
4. Copy CAB files, reboot into the GUI setup.
5. First boot to the desktop; install VGA/mouse/sound/network drivers.

## Known blockers to clear first

- 386 PM + paging + V86 in the CPU.
- Real BIOS disk services; no HLE VFS.
- IDE/ATAPI PIO and CD reads.
- VGA text + mode 12h/13h; SVGA later.
- Mouse/keyboard.
- Enough instruction throughput to make setup tolerable.

## Non-goals for the first 98 boot

- USB, ACPI, AGP, 3D, printing, networking (network comes after desktop).
- Cycle accuracy.
