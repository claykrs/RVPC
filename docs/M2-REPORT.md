# M2 relay — Win98 hardware readiness

**Code state:** `dd966ba` (PIIX3 BMIDE, DMA, SB16), after the FreeDOS M1 boot
commit `8f202f5`.

## Verified

- Real SeaBIOS 256 KiB, SeaVGABIOS stdvga, FreeDOS 1.3 floppy-emulation CD to
  the FreeCom shell. Keyboard INT16 via `pressKey` works.
- 32-bit memory/A20/paging/V86; 32-bit interrupt frames; null LLDT; SIB
  index-with-disp32; task-gate support is still absent.
- x87 subset with context save/restore, TS/EM lazy switching, m80/BCD transfer
  and V86 I/O bitmap traps.
- PIIX3 topology: ISA bridge 00:01.0, IDE 00:01.1, BARs, secondary channel,
  IRQ14/15, BMIDE/PRDT DMA and ATAPI DMA.
- 8237 DMA controller, SB16 DSP/mixer/FM register model, DMA1 8-bit playback,
  IRQ5.
- VBE/DISPI: 640x480, 800x600, 1024x768 at 8/16/32bpp, 4 MiB LFB at
  `0xE0000000`, BAR0 sizing; SeaVGABIOS reports `VBE DISPI: lfb_addr=...`.
- NE2000 at 0x300/IRQ10 and virtual ISP (ARP, IPv4/ICMP, DHCP, DNS, TCP and an
  HTTP/1.0 server on port 80).
- PS/2 keyboard IRQ1 and mouse IRQ12 machine tests; KBC IRQ edges are latched.
- 82077 floppy controller at 0x3F0..0x3F7, IRQ6, DMA2; SeaBIOS boots
  `media/freedos-boot.img` from A: to FreeCom. CMOS 0x10 reports 1.44M drives.
- MBR/partition boot and no-emulation El Torito boot probes pass.
- HDD write-back persists `media/hdd.img` / `media/win98-hdd.img`.

Gate: `lune run tools/check.lua` → 1251 assertions.

## Not yet verified

- No Windows 98 SE media is staged, so the actual installer has not been run.
- No ACPI/APM/SMBIOS tables; Win98 should install as Standard PC but power
  management and device enumeration are untested.
- VBE 4bpp planar modes, native BAR relocation, UDMA, 16-bit SB audio, FM
  synthesis and full 80-bit x87 precision are incomplete.
- Task gates and some x87 exception traps remain unimplemented.

## Next install attempt

1. Stage (never commit) `media/win98se.iso` and a 512 MiB
   `media/win98-hdd.img`.
2. `lune run tools/harness.lua 300` (budget in millions of steps).
3. Capture the first fault with PC/register/trace evidence and the boot stage
   (CD boot sector, setup text-mode, partition/format, first reboot, GUI).
4. Fix the first failing hardware path, then repeat. The harness prefers the
   Win98 ISO/HDD automatically and saves dirty sectors back to the HDD.

Do not add Microsoft media or ROMs to git.
