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
answered, the CD's DOS startup image loads: the Windows 98 Startup Menu
appears with its 29 s countdown, the OTI-91X ATAPI CD driver and the AIC-6260
ASPI manager load, and the config.sys boot loop restarts when the CD driver
gives up. SETUP never starts yet; the exact blocker is the OTI-91X IDE probe
at `028E:6C48`, described in HANDOFF.md "Current frontier".

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
- **"No drives found, aborting installation":** the OTI-91X driver rejected
  the CD. This is the current blocker. Reproduce with
  `lune run tools/probe_win98_boot.lua 12` (millions of steps), or use the
  newer `tools/probe_oti_print.lua`, which logs the relocated `lcall 0,0x6050`
  (resident shim `028E:6050` -> `028E:6C48`), the per-device port table at
  `028E:636C`, and the probe's error-register dispatch. The OTI device code is
  at segment `0B5B`; `028E:6C48` is the resident IDE probe. At the stall the
  slave CD reports `error=0 status=0x50` and the ATAPI signature `EB/14`;
  the probe takes its AH=4 failure path from `6D0C/6D23`. The success path is
  `6CE5` (CF=0).
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
2. Setup loads a RAM disk / real-mode drivers (OTI-91x CD, AIC ASPI).
3. Partition and format the virtual HDD (FAT16/32).
4. Copy CAB files, reboot into the GUI setup.
5. First boot to the desktop; install VGA/mouse/sound/network drivers.

## Known blockers to clear

- OTI-91X IDE probe (see Triage guide): the INQUIRY path works, but the
  resident probe at `028E:6C48` still takes its failure branch and the driver
  prints "No drives found". Exact branch instrumentation is the next step.
- No ACPI: Win98 falls back to Standard PC. SMBIOS 2.4 and APM 1.2 are
  present.
- 80-bit x87 and hardware task gates landed (`9e81135`, `39b96de`); recheck
  only if SETUP/VMM trips them.
- PS/2 mouse integration and audio/network drivers after first boot.

## Non-goals for the first 98 boot

- USB, AGP, 3D, printing, networking before the desktop.
- Cycle accuracy.
