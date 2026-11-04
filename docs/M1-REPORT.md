# M1 relay report — IDE/ATAPI, input, first boot attempt

**M1 bring-up commit:** `4fbd3bc` (`M1: add IDE/ATAPI and 8042 bring-up; FreeDOS boot in progress`)
**M0 hardening commit:** `7986985` (`M0 hardening: V86/IRET frames, fault restart and PIC priority`)

This report is the relay point for the next session. It records the measured
state after the M1 bring-up, including the first boot fault.

## What changed and why

### IDE / ATAPI (`core/Ide.lua`)

- Primary task file at `0x1F0-0x1F7`, alternate status/device control at
  `0x3F6`, IRQ14.
- Master ATA hard disk: IDENTIFY, LBA28 READ/WRITE, FLUSH, SET FEATURES,
  diagnostic/NOP, PIO data-in/data-out, IRQ on command completion.
- Slave ATAPI CD-ROM: IDENTIFY PACKET, PACKET command, READ(10), READ
  CAPACITY(10), INQUIRY, MODE SENSE, REQUEST SENSE, TEST UNIT READY, START
  STOP, PREVENT/ALLOW, and a minimal READ TOC/PMA/ATIP response.
- `Ide.parseMbr` for the four primary partition entries; SeaBIOS still does
  the actual MBR boot logic.
- Machine attaches `config.hdd` and `config.cdrom` buffers and wires the ports,
  16-bit data transfers and IRQ14.
- Machine's PCI config now exposes a PIIX3-style IDE function at `00:01.0`
  (`prog_if=0`, legacy `1F0/3F6`) so SeaBIOS's PCI ATA scanner picks up the
  controller. Earlier it skipped ISA ports because a PCI VGA device made
  `PCIDevices` non-empty.

### 8042 keyboard/mouse (`core/Kbc.lua`)

- `0x60/0x64` status/data, controller self-test/config, keyboard ACK/self-test,
  set-1 make/break queues, scan-code-set command, IRQ1.
- PS/2 mouse command ACK path, 3-byte packets, sign bits/buttons, IRQ12.
- Machine host hooks: `pressKey`, `releaseKey`, `mouseMove`; KBC IRQ1/IRQ12
  are raised through the PIC.
- A BDA injection helper exists for headless firmware menus because SeaBIOS's
  own IRQ1 thunk is currently the generic EOI stub (see blocker).

### VGA

- Mode 12h (640×480×16 planar) and mode 13h (320×200×256 linear) already exist
  in `core/Vga.lua`; `tests/SystemTests.lua` now exercises both plus text mode 3.
- SeaVGABIOS still initializes text mode 3 through the option ROM. A Roblox
  EditableImage sink is not wired yet; the core exposes `snapshotRGBA` and the
  harness writes graphics screens to `tools/out/screen.ppm`.

### Harness

- `tools/harness.lua` attaches an optional 32 MiB `media/hdd.img` and an
  optional `media/FD13LIVE.iso` (FreeDOS 1.3 LiveCD), loads SeaBIOS +
  SeaVGABIOS, and drives the SeaBIOS boot menu.
- ROM/media paths are gitignored; no disk image or Microsoft media is
  committed.

## Check result

`lune run tools/check.lua` → **CHECK PASSED** (format, Luau lint, Roblox lint,
strict typecheck, **333 assertions**). New suites: `tests/IdeTests.lua`,
`tests/KbcTests.lua`; 386 frame/XMS suites were restored by M0 hardening.

## How to run the harness / media

```powershell
New-Item -ItemType Directory -Force roms,media

Invoke-WebRequest `
  https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/bios-256k.bin `
  -OutFile roms/bios-256k.bin
Invoke-WebRequest `
  https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/vgabios-stdvga.bin `
  -OutFile roms/vgabios-stdvga.bin

# FreeDOS 1.3 LiveCD (the zip is ~393 MB; extract FD13LIVE.iso)
Invoke-WebRequest `
  https://www.ibiblio.org/pub/micro/pc-stuff/freedos/files/distributions/1.3/official/FD13-LiveCD.zip `
  -OutFile media/FD13-LiveCD.zip
Expand-Archive media/FD13-LiveCD.zip media/FD13-LiveCD -Force
Copy-Item media/FD13-LiveCD/FD13LIVE.iso media/FD13LIVE.iso

# Optional blank master HDD (32 MiB). Without it the CD is the only device.
$fs = [System.IO.File]::Create("media/hdd.img")
$fs.SetLength(32 * 1024 * 1024)
$fs.Close()

lune run tools/check.lua
lune run tools/harness.lua 10   # step budget in millions
```

The harness prints the SeaBIOS boot menu, selects entry 1 (the CD) through the
BDA keyboard buffer, then reports the first fault.

On this machine the FreeDOS floppy-emulation image also exists in
`media/freedos-boot.iso`; it was made with `tools/make_freedos_iso.py` and is
not committed.

## Measured M1 state

SeaBIOS sees both drives and reaches its boot menu:

```text
SeaBIOS (version rel-1.17.0-0-gb52ca86e094d-prebuilt.qemu.org)
Select boot device:

1. DVD/CD [ata0-1: VRMD89V RIUTLAC  D ATAPI-0 DVD/CD] (FD13-LiveCD)
2. ata0-0: VRMD89V RIUTLAH DD ATA-2 Hard-Disk (32 MiBytes)
```

Selecting entry 1 (CD) leads to:

```text
FAULT at F000:000085EF after 6000000 steps:
  bad FF /7 at F000:85ED
```

- Boot PC: `F000:000085EF`
- 6,000,000 steps, 38 IRQs, 0 page faults
- IDE: 6 commands, 3 IDENTIFY, 3 PACKET
- PAM0 is locked (`PAM58=0x11111000`) and `csBase=0x000F0000`; the BIOS shadow
  was not overwritten.
- Trace shows the real-mode hardware IRQ thunk at `F000:D2EC` calling the
  generic `handle_hwpic1` EOI at `F000:FA67`, then IRET returning to
  `F000:0000` — i.e. the interrupted/return frame is wrong, and execution runs
  through F-segment data until it hits `FF /7`. The same PC occurs with the
  FreeDOS live CD's no-emulation boot entry and with the earlier floppy-
  emulation ISO.

This is the first boot fault, not a no-bootable-device fallback. The CD is
detected, identified, read, and selected; the failure is in the CPU/BIOs
interrupt-return path during the boot thunk (possibly an IRQ landing while
SeaBIOS is in the VGA BIOS/option-ROM call chain).

## Next 3 actions

1. **Fix the real-mode IRQ return frame during the boot thunk.** Add a CPU
   regression that raises IRQ0 while execution is in an option-ROM/INT10
   frame and checks the IRET target. The trace points at `F000:D2EC` →
   `F000:FA67` → `F000:0000`; inspect the saved frame and SeaBIOS's
   `entry_hwpic1` stack hop. Masking timer IRQs only around the VGA BIOS call
   may be a valid short-term workaround if the frame is genuinely clobbered by
   the option ROM's stack.
2. **Finish ATAPI boot.** Verify the FD13LIVE no-emulation entry, the boot
   catalog, and the first FreeDOS loader bytes through the IDE data path; get
   to a `FreeDOS` banner or `A:\>` prompt.
3. **Wire the VGA host sink and input.** Add a Roblox EditableImage sink for
   `snapshotRGBA` (text 3, planar 12h, linear 13h), and a UserInputService
   bridge to `pressKey`/`releaseKey`/`mouseMove`; then re-check the boot menu
   with real IRQ1/IRQ12 instead of BDA injection.

After that: MBR/partition boot, IDE writes, VGA SVGA, x87, and the Win98 SE
installer path. Do not add Windows media to git.

## Uncommitted files

No tracked working-tree changes are left after this report. Local gitignored
media includes:

- `roms/bios-256k.bin`, `roms/vgabios-stdvga.bin`
- `media/FD13LIVE.iso`, `media/FD13-LiveCD.zip`
- `media/freedos-boot.iso`, `media/freedos-boot.img`, `media/hdd.img`
- `media/FD13-FloppyEdition.zip`

The code commits are `4fbd3bc` (M1 bring-up) and `7986985` (M0 hardening).
This report commit follows them and names the exact code state.
