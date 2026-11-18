# M2 relay — Win98 hardware readiness

**Code state:** `973c6f0` (IDE scale + hot-path optimization), following the
FreeDOS M1 boot, PIIX3/BMIDE, VBE, FDC and TCP/HTTP work.

## Verified

- Real SeaBIOS 256 KiB + SeaVGABIOS stdvga. FreeDOS 1.3 boots from the
  floppy-emulation CD, from the raw floppy through the 82077 FDC, and the
  no-emulation FD13LIVE ISOLINUX image reaches the LiveCD menu and `D:\>`.
- 32-bit memory/A20/paging/V86, 32-bit interrupt frames, SIB
  index-with-disp32, null LLDT. Hardware task gates are still absent.
- x87 subset with context save/restore, TS/EM lazy switching, m80/BCD transfer,
  V86 I/O bitmap traps, and deferred vector-16 `#MF` for unmasked exceptions.
- PIIX3 topology: ISA bridge 00:01.0, IDE 00:01.1, BARs, secondary channel,
  IRQ14/15, BMIDE/PRDT DMA and ATAPI DMA. PIRQ A–D route to IRQ 10/11 and
  `$PIR` resolves the VGA INTC link. SMBIOS 2.4 and APM 1.2 are present;
  there is no ACPI RSDP/FACP.
- 8237 DMA controller, SB16 DSP/mixer/FM register model, DMA1 8-bit playback,
  IRQ5.
- VBE/DISPI: 640x480, 800x600, 1024x768 at 8/16/32bpp, 4 MiB LFB at
  `0xE0000000`, BAR0 sizing, and a 64 KiB banked A0000 window. SeaVGABIOS
  reports the DISPI LFB.
- VGA mode 12h 640x480x16 planar: write modes 0–3, read modes 0/1, latches,
  set/reset/ALU/rotate/bit mask, odd/even and chain-4 addressing, CRTC
  start/offset, attribute palette banking, DAC 6-bit expansion, pixel-accurate
  dirty rects. Guest BIOS mode 12h is detected from the VGA ports.
- NE2000 at 0x300/IRQ10 and virtual ISP (ARP, IPv4/ICMP, DHCP, DNS, TCP and an
  HTTP/1.0 server on port 80).
- PS/2 keyboard IRQ1 and mouse IRQ12 machine tests; KBC IRQ edges are latched.
- 82077 floppy controller at 0x3F0..0x3F7, IRQ6, DMA2; CMOS 0x10 reports 1.44M
  drives.
- MBR/partition boot and no-emulation El Torito boot probes pass.
- HDD write-back persists `media/hdd.img` / `media/win98-hdd.img`.
- IDE is validated on a 512 MiB in-memory image: 1040x16x63 geometry,
  1,048,576 LBA sectors, high-LBA PIO, multi-PRDT BMIDE reads/writes across
  64 KiB boundaries, dirty ranges and clean out-of-range ABRT.
- Hot-path optimization: 24M-step FreeDOS boot drops from ~90 s to ~33 s; mixed
  workloads run at ~1.6M guest steps/s (2.7–3.7x).

Gate: `lune run tools/check.lua` → 1618 assertions.

## Not yet verified

- No Windows 98 SE media is staged, so the actual installer has not been run.
- No ACPI: Win98 should install as Standard PC, but ACPI power management and
  the ACPI HAL are untested.
- Hardware task gates/TSS switching, full 80-bit x87 precision, native BAR
  relocation, UDMA, 16-bit SB audio, FM synthesis and READ/WRITE MULTIPLE are
  incomplete.
- Paging has no TLB yet, so protected-mode workloads are slower than real mode.
- VGA gaps outside the default 640x480x16 path: split screen, PEL panning,
  chain-2, CGA modes and the hardware text cursor.

## Next install attempt

1. Stage (never commit) `media/win98se.iso` and a 512 MiB
   `media/win98-hdd.img`.
2. `lune run tools/harness.lua 300` (budget in millions of steps).
3. Capture the first fault with PC/register/trace evidence and the boot stage
   (CD boot sector, setup text-mode, partition/format, first reboot, GUI).
4. Fix the first failing hardware path, then repeat. The harness prefers the
   Win98 ISO/HDD automatically and saves dirty sectors back to the HDD.

Do not add Microsoft media or ROMs to git.
