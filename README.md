# RVPC

A 486-class PC emulator written in Luau that runs inside Roblox. It boots real
SeaBIOS firmware and real operating system media, and presents the machine's
VGA output in a Roblox window. The target profile is **RVPC/98**: a machine
meant to install and run Windows 98 SE from a CD onto a virtual hard disk.
Windows is a guest operating system here, not a reimplementation.

## Status

Verified by `tools/check.lua` (1644 assertions) and headless boots in
`tools/harness.lua`:

- **Firmware:** real SeaBIOS 1.17.0 + SeaVGABIOS run end to end — PIC/PIT/CMOS/
  A20/PCI/fw_cfg init, the boot menu, El Torito CD boot and floppy boot.
- **FreeDOS 1.3 boots three ways:** the floppy-emulation ISO through its
  language menu to the FreeCom shell, a raw floppy image through the 82077 FDC
  (DMA2/IRQ6), and the LiveCD ISOLINUX image to its `D:\>` prompt.
- **Storage:** PIIX3 PCI/IDE with PIO and BMIDE on two channels, ATAPI packet
  commands (INQUIRY, READ(10/12/16), TOC, sense, DEVICE RESET, task-file
  signature), 512 MiB LBA validation, dirty-sector write-back to a virtual HDD.
- **CPU:** 386/486 real, protected and V86 modes, two-level paging with a TLB,
  32-bit operands and addressing, CPUID, and a 486-class x87 with context
  switching and deferred `#MF`.
- **Video:** a hardware-accurate VGA mode 12h planar path (latches, write
  modes, set/reset, ALU, CRTC) plus VBE/DISPI SVGA with a linear framebuffer.
- **Network:** NE2000 (DP8390) with a host-side virtual ISP providing
  DHCP/DNS/ARP/ICMP, a TCP state machine and an HTTP server.
- **Input and sound:** PS/2 keyboard and mouse, Sound Blaster 16, UART, LPT.

In progress: the **Windows 98 SE installer boot**. The CD startup menu, the
Win98 DOS menu and the OTI-91x ATAPI probe all run; the driver's
completion-IRQ handshake is the current blocker. Next after that: hardware
task gates, full 80-bit x87 precision, and the first SETUP run. The
milestone-by-milestone state lives in `docs/WIN98.md`.

## Running it

The emulator runs headless under [Lune](https://github.com/lune-org/lune) for
development, and inside Roblox Studio as a client experience.

```shell
lune run tools/check.lua          # full gate: stylua, selene, luau-analyze, tests
lune run tools/harness.lua        # boot with the staged media
lune run tools/harness.lua 40     # step budget in millions
```

Firmware is staged locally under `roms/` (gitignored); the emulator does not
ship binary blobs:

```powershell
Invoke-WebRequest `
  https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/bios-256k.bin `
  -OutFile roms/bios-256k.bin
Invoke-WebRequest `
  https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/vgabios-stdvga.bin `
  -OutFile roms/vgabios-stdvga.bin
```

To attempt the Windows 98 SE installer, stage your own media (see
`docs/WIN98.md` for the exact layout and a staging checker):

```powershell
# media/win98se.iso  (bootable OEM SE CD)
# media/win98-hdd.img (512 MiB virtual disk; the staging tool creates it)
lune run tools/harness.lua 300
```

The Roblox side is a client experience: an `EditableImage` VGA presenter, a
set-1 keyboard/mouse input bridge and a machine shell. Build the model with
`tools/build_rbxmx.lua` and import it into Studio.

## Architecture

`core/` is environment-pure `--!strict` Luau: no `game`, no filesystem, no
`print`. Host services (video, input, disk, network, audio) are injected
through `Machine.new(deps)`, so the same machine runs under Lune and under
Roblox. `tools/check.lua` gates every change with stylua, selene (luau and
roblox configs), strict `luau-analyze` and the test suite; nothing lands
without it.

Module map: `Cpu` (386/486 + x87), `Memory` (32-bit physical RAM, A20, ROM
windows), `Ide`/`Fdc` (disks), `Vga` (display), `Pic`/`Pit`/`Cmos` (core
silicon), `Kbc` (8042), `Sb16`, `Uart`, `Lpt`, `Ne2000` + `Isp` (network),
`FwCfg` (firmware config), `Machine` (wiring and run loop). The host side
lives in `roblox/`.

Deeper reading: `docs/ARCHITECTURE.md`, `docs/NETWORK.md`, `docs/WIN98.md`,
and the code-style rules in `docs/STYLE.md`.

## Media and firmware

The repo contains no copyrighted media. SeaBIOS and SeaVGABIOS are LGPL
firmware fetched from the QEMU project at setup time. Windows 98 SE and any
other operating system images are never included or distributed — supply your
own copies where you have the license to use them.

## License

MIT for the emulator source. Firmware and guest media keep their own licenses
and stay out of this repository.
