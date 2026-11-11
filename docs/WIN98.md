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
- 32-64 MB RAM; x87 FPU (a practical 486 subset is in, host-double precision).
- ACPI not required for the first boot; PnP/PCI later.

## Current status

SeaBIOS boots the Win98 SE CD (El Torito, 1.44M floppy emulation) to the
"Microsoft Windows 98 CD-ROM Startup Menu". With `2` (Boot from CD-ROM)
answered, the CD's DOS startup image loads and the OTI-91X ATAPI CD driver
reports `Number of drives : 1`.

The **unpatched** boot image then loads the AIC/BT SCSI ASPI managers; their
`INT 15h/AH=86h` wait chains through the guest XMS/UMB code and never
returns, so the machine stops after "PCI bus scan complete." The local
IDE-only image `media/win98se-ide.iso` (built by
`tools/win98_ide_media.py`, original ISO untouched) removes those unnecessary
SCSI drivers. With it, MSCDEX assigns `D:`, FINDCD locates the CD, OEMSETUP
starts, and Setup reaches **Welcome** and the **disk-configuration** screen:

```text
Setup needs to configure the unallocated space on your
hard disk to prepare it for use with Windows.
    Configure unallocated disk space (recommended).
    Exit Setup.
```

No CPU fault or page fault has occurred through 22M steps. The next step is
to answer/skip this prompt and drive partition/format/file-copy.

Everything below it is green:

- IDE primary master HDD + primary slave CD is the installer path.
- ATA PIO writes, dirty-sector tracking and HDD image write-back are in place.
- ATAPI READ(10/12/16), TOC, capacity, sense, DEVICE RESET, task-file
  signature and packet-phase interrupt reason/byte count are implemented.
- The 82077 FDC boots `media/freedos-boot.img` from A: through DMA2/IRQ6.
- VGA text 3, planar 12h (write modes 0-3, latches, palette banking), linear
  13h and VBE/DISPI SVGA modes work.
- IDE is validated on a 512 MiB image at high LBAs with PIO and multi-PRDT
  BMIDE, including clean out-of-range aborts.
- A paging TLB now backs protected-mode translation (see "Performance").
- NE2000 plus the virtual ISP cover DHCP, DNS, TCP and a small HTTP server.
- x87 context save/restore, TS/EM lazy switching and deferred #MF delivery.

## Staging a Win98 SE install run

Windows media is **not** committed. Supply it locally:

1. **ISO.** Download a bootable Windows 98 SE ISO into `media/win98se.iso`.
   The image used for bring-up was
   `https://archive.org/download/windows-98-second-edition_202407/Windows%2098%20Second%20Edition.iso`
   (655,591,424 bytes, the OEM "fully bootable" disc - retail SE ISOs are not
   El Torito bootable and will not reach the startup menu).
2. **Verify + stage.**
   ```
   lune run tools/stage_win98.lua
   ```
   checks: 655 MB size, ISO9660 PVD in sector 16, El Torito boot record in
   sector 17 ("EL TORITO SPECIFICATION"), the boot catalog (this image uses a
   legacy validation-entry header `0x01` with the standard AA55 key - accepted
   like SeaBIOS accepts it), a 1.44M floppy-emulation boot entry, the `WIN98`
   folder and `SETUP.EXE` in the ISO root, and writes a zeroed 512 MiB
   `media/win98-hdd.img` when missing (`--hdd-mib` to change the size).
3. **Run.**
   ```
   lune run tools/harness.lua 200
   ```
   The harness prefers `media/win98se.iso` as the CD and
   `media/win98-hdd.img` as the HDD, boots SeaBIOS, answers the SeaBIOS boot
   menu with `1` and the Microsoft CD-ROM startup menu with `2` (its countdown
   path mis-executes into a data blob at `0000:7C00` otherwise), and persists
   HDD writes back to `media/win98-hdd.img` after the run.

## Triage guide

- **SeaBIOS output appears but no Microsoft menu:** the El Torito image did
  not boot - re-run `tools/stage_win98.lua` and check the boot entry line.
- **Menu shows and counts down, then a `bad FF /7` fault:** the harness did
  not answer the menu; the countdown path executes into the AIC ASPI data blob
  loaded at `0000:7C00`. Fixed by the harness `Boot from CD-ROM` injection.
- **"No drives found, aborting installation":** fixed in `ed95334`. The OTI
  driver issues IDENTIFY DEVICE, then checks the ATAPI signature in
  `1F5/1F4`; the aborted command now preserves the CD's `EB/14` signature, so
  the driver prints `Number of drives : 1`. The resident probe is at
  `028E:6C48`; the decisive check is the signature at `028E:7D5A-7D6D`.
- **"PCI bus scan complete." then a halt at `F000:B757` (unpatched ISO):** the
  AIC ASPI managers' `INT 15h/AH=86h` delay chains through the guest XMS/UMB
  code and never returns. IRQ0 and the BDA tick continue, the IVT 08/1A
  handlers are still BIOS, and Enter via KBC/BDA does not reach the menu
  because the ASPI driver is still inside the wait. Use the IDE-only image
  (`tools/win98_ide_media.py` -> `media/win98se-ide.iso`) to skip the
  unnecessary SCSI drivers, or fix the guest `INT 15h/AH=86h` chain.
- **IDE-only image reaches Setup:** MSCDEX prints `Drive D: = Driver OEMCD001
  unit 0`, FINDCD/OEMSETUP run, and Setup reaches Welcome and "Configure
  unallocated disk space". Press ENTER and continue with partition/format.
  No protected-mode fault has been observed yet.
- **Warm reset loop:** the startup menu reboots the machine after the CD
  driver fails; each cycle looks like the menu appearing again. This is
  guest-side control flow, not an emulator crash.

## Performance

- Paging TLB (commit `3957100`): full page-table walk on first touch of a
  linear page, then cached per entry with U/S + R/W rechecked per access so
  `#PF` error codes stay byte-identical. CR3 reload and CR0.PG transitions
  flush via a 7-bit epoch (O(1)); INVLPG drops one entry; CPU stores into
  tracked page-directory/table frames invalidate the slots that map through
  them; the walker's own accessed/dirty writeback deliberately bypasses that
  watcher.
- Benchmarks (same machine, same workload): FreeDOS 24M-step boot 36.1 s
  before vs 36.8 s after (paging off there - no regression). The Win98 CD
  boot before the TLB ran 16M steps in 26.8 s with paging never enabled, so
  the TLB's win will only show once VMM paging starts; measure it with the
  per-run wall time of the first SETUP phases.

## Install flow

1. SeaBIOS boots the 98 SE CD; the Microsoft menu is answered with 2.
2. The IDE-only boot image loads HIMEM + OAKCDROM, MSCDEX assigns D:, and
   OEMSETUP starts. (The stock image's AIC/BT ASPI drivers are skipped.)
3. Partition and format the virtual HDD (FAT16/32).
4. Copy CAB files, reboot into the GUI setup.
5. First boot to the desktop; install VGA/mouse/sound/network drivers.

## Known blockers to clear

- OTI-91X IDE detection is fixed (`ed95334`); the unpatched image's AIC ASPI
  `INT 15h/AH=86h` chain still hangs, but the IDE-only image bypasses it.
- The IDE-only image reaches Setup's disk-configuration prompt; partition,
  format and CAB copy are the next interactive steps.
- No ACPI: Win98 falls back to Standard PC. SMBIOS 2.4 and APM 1.2 are
  present.
- 80-bit x87 and hardware task gates landed (`9e81135`, `39b96de`); recheck
  only if SETUP/VMM trips them.
- PS/2 mouse integration and audio/network drivers after first boot.

## Non-goals for the first 98 boot

- USB, AGP, 3D, printing, networking before the desktop.
- Cycle accuracy.
