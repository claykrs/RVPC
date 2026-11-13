# RVPC

[![CI](https://github.com/claykrs/RVPC/actions/workflows/ci.yml/badge.svg)](https://github.com/claykrs/RVPC/actions/workflows/ci.yml)
![License](https://img.shields.io/badge/license-MIT-blue)
![Language](https://img.shields.io/badge/language-Luau-orange)
![Code style](https://img.shields.io/badge/style-StyLua-purple)

**A 486-class PC emulator written in Luau, running inside Roblox Studio — targeting Windows 98 SE.**

RVPC is a full-system emulator, not a DOS compatibility layer: a real
[SeaBIOS](https://www.seabios.org/) firmware image boots on a cycle-driven
486 core with IDE/ATAPI storage, VGA graphics, a PIC/PIT/CMOS chipset, PS/2
input and an 80-bit x87 FPU. Today it installs **FreeDOS 1.3** from CD onto a
persistent virtual hard disk. The target is a **Windows 98 SE** install and
desktop.

```
SeaBIOS ──▶ boot menu ──▶ CD / floppy / HDD ──▶ FreeDOS 1.3 ──▶ Windows 98 SE (in progress)
```

## Status

| Subsystem | State |
| --- | --- |
| 486 core: real/protected/V86 modes, paging, TLB, task gates | ✅ working |
| SeaBIOS boot (MBR, El Torito CD, floppy, warm reset) | ✅ working |
| IDE/ATAPI (PIO, Busmaster DMA, packet commands, signatures) | ✅ working |
| VGA (text + cursor, planar mode 12h, mode 13h, VBE/DISPI SVGA) | ✅ working |
| 80-bit x87 FPU (190/190 precision-control vectors) | ✅ working |
| Chipset: PIC×2, PIT, MC146818 RTC (clock/alarm/periodic IRQ8), 8237 DMA, PIIX3 PCI | ✅ working |
| NE2000 Ethernet + host virtual ISP (DHCP/DNS/TCP/HTTP) | ✅ working |
| FreeDOS 1.3 CD install onto the virtual HDD (diskette auto-swap) | ✅ working |
| Windows 98 SE SETUP | 🚧 install copy phase reaches 188M steps and SETUP's protected-mode transition — see the [triage guide](docs/WIN98.md) |
| PS/2 mouse integration, SB16 audio in-guest | 🔜 planned |

CI runs the full gate (StyLua, Selene, strict `luau-analyze`, **1800+
assertions**) on every push.

## Quick start

**In Roblox Studio**

```sh
lune run tools/build_rbxmx.lua     # writes the importable Rvpc.rbxmx
```

Import `Rvpc.rbxmx` into a place and press Play. The shell presents the VGA
frame through an `EditableImage` with integer scaling and bridges set-1
keyboard/mouse input.

**Headless (Lune)**

```sh
lune run tools/check.lua           # the CI gate
lune run tools/harness.lua         # boot SeaBIOS headless and watch the screen
lune run tools/harness.lua 40      # step budget in millions
```

## Firmware and media (not committed)

The emulator is a real PC: it needs real firmware and OS media, which stay
out of git. Stage them locally:

**Firmware** (QEMU builds — free):

```powershell
New-Item -ItemType Directory -Force roms
Invoke-WebRequest https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/bios-256k.bin -OutFile roms/bios-256k.bin
Invoke-WebRequest https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/vgabios-stdvga.bin -OutFile roms/vgabios-stdvga.bin
```

**Guest media** under `media/`:

| File | Used for |
| --- | --- |
| `freedos-boot.iso` | FreeDOS 1.3 boot/install CD |
| `x86BOOT.img`, `x86DSK01–05.img` | FreeDOS floppy set (auto-swapped during install) |
| `win98se.iso` | Windows 98 SE — also attached to the [releases page](../../releases), provided there by the repository author for testing |
| `win98-hdd.img` | created automatically for the persistent C: |

## Architecture

```
core/     Machine, Cpu(486), Memory, Vga, Ide, Pic, Pit, Cmos, Kbc,
          Fpu(80-bit), Dma, Fdc, Sb16, Ne2000, Isp, Uart, Lpt, Xms
roblox/   Studio shell: EditableImage presenter, input bridge, perf HUD
tests/    20+ suites, 1800+ assertions, run by CI on every push
tools/    build/deploy/probe tooling (Lune + MCP bridge into Studio)
```

The core is environment-pure (`--!strict`; no `require`, `game`, filesystem
or Roblox APIs) — the same machine runs headless under Lune and interactively
in Studio. Host services (video, input, disks, network, audio) are injected
through `Machine.new`.

## Docs

- [`docs/WIN98.md`](docs/WIN98.md) — Windows 98 staging plan, current blockers, triage guide
- [`docs/ARCHITECTURE.md`](docs/ARCHITECTURE.md) — machine design
- [`HANDOFF.md`](HANDOFF.md) — engineering log: what was fixed and why, with evidence

## License

MIT for the emulator source — see [LICENSE](LICENSE). SeaBIOS/VGA BIOS
firmware and guest OS media are not included; supply your own copies where
required.
