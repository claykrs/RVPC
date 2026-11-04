# RVPC architecture

## Machine

A 486/Pentium-class PC, not a Windows-specific host.

```
CPU (386/486)
  | 32-bit address bus
Memory (32–64 MB) + ROM (SeaBIOS)
  | ISA/PCI bus
Chipset: 8259 PIC x2, 8254 PIT, 8237 DMA, CMOS/RTC, A20, PCI config
Devices: VGA, IDE, ATAPI CD, PS/2, UART, LPT, SB16, NE2000
```

Physical memory is a flat byte buffer up to the configured size. The first
1 MiB follows the PC map; A0000–AFFFF routes to the VGA aperture; B8000–BFFFF
is colour text RAM; C0000–DFFFF is option-ROM shadow RAM; E0000–EFFFF is BIOS
extension RAM; F0000–FFFFF is a writable shadow of the BIOS image's last 64 KiB.
The full 256 KiB SeaBIOS image is also mapped read-only at `0xFFFC0000`
(`0x100000000 - 256 KiB`), which is where 32-bit firmware and the reset vector
can fetch it. A20M only forces bit 20 low; addresses above the configured RAM
are open bus (reads `0xFF`, writes dropped).

## CPU

- 386/486 integer core: real mode, protected mode, V86, paging, TSS, GDT/LDT.
- 16/32-bit operands and addressing.
- Exceptions: #DE, #UD, #GP, #PF, #DF, #TS, #NP, #SS, #BP, #OF.
- No FPU in the first pass; add x87 after Win98 boot (98 works without it for
  most setup/desktop paths, but some apps need it).

The inherited `Cpu.lua` already has 286 protected mode, descriptor caches, call
gates, IDT and 386 instruction subsets. RVPC keeps that as a reference but
rewrites address translation and adds paging/V86.

## Firmware

SeaBIOS. A real 256 KiB QEMU/SeaBIOS image is mapped read-only at `0xFFFC0000`
and shadowed at `F0000-FFFFF`; the low reset vector is at `F000:FFF0`. The
`SeaVGABIOS` stdvga ROM is supplied through fw_cfg as
`vgaroms/vgabios-stdvga.bin` and installs the real INT 10h console. Do not write
an HLE BIOS for the Win98 target; the installer depends on real INT 13h/INT 15h/
PCI/ACPI behavior.

## Storage

- IDE primary: ports 0x1F0–0x1F7, IRQ14.
- Master: virtual HDD (persistent image).
- Slave: ATAPI CD-ROM (Win98 SE ISO).
- PIO mode first; DMA later.
- MBR/partition table, FAT16/FAT32 handled by the guest OS, not the emulator.
- Floppy: optional, 1.44 MB image for diagnostics.

## Video

- VGA text mode 3 and planar mode 12h first.
- Linear mode 13h; SVGA/VBE later.
- Host: `EditableImage` via `VgaSink` with dirty rectangles.
- Native 640x480/800x600 window, integer scaling where possible.

## Input

- 8042 keyboard controller, set-1 scan codes, IRQ1.
- PS/2 mouse, IRQ12.
- Absolute host pointer mapping; single visible guest cursor.

## Network

- NE2000 at 0x300, IRQ10, 16 KiB packet ring.
- Guest runs a real NDIS/packet driver; Windows 98 has NE2000 support.
- Host side implements ARP/IP/ICMP/UDP/TCP/DHCP/DNS in Luau.
- A relay outside Roblox can provide real TCP/UDP; Roblox `HttpService` cannot
  open raw sockets.
- The virtual ISP can host HTTP, IRC, BBS, mail and a retro web without leaving
  Roblox.

## Host interface

`Machine.new(deps, config)` receives:

- `Memory`, `Cpu`, `Vga`, `Pic`, `Pit`, `Cmos`, `FwCfg`, `Ide`, `Ne2000`,
  `Uart`, `Lpt`
- `config.serial`, `config.printer`, `config.disk`, `config.network`,
  `config.audio`, `config.logger`, `config.rom`, `config.vgaRom`

Core never requires Roblox or Lune. The same machine runs under the Lune
harness and the Roblox client.

## Testing

- `tools/check.lua`: format, lint, strict types, tests.
- `tools/harness.lua`: SeaBIOS + IDE/ATAPI + VGA text, headless.
- CPU tests: real/PM/V86, paging, exceptions, 32-bit addressing.
- OS tests: FreeDOS boot, Linux boot, Win98 setup, Win98 desktop.
