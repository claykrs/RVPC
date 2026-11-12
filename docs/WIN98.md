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

The **stock** image now also works: the RTC periodic IRQ8 model (`41c1608`)
lets SeaBIOS's `INT 15h/AH=86h` waits expire, so the AIC ASPI drivers finish
and MSCDEX/OEMSETUP start. Both the stock ISO and the IDE-only
`media/win98se-ide.iso` reach **Windows 98 Setup**, complete formatting, and
start the CAB copy. The copy creates and writes
`C:\WININST0.400\COMM.DRV`, closes it successfully, then the guest CAB
decompressor/file-write completion fails and Setup prints "Setup is unable to
write to the temporary directory". `FF39` is resident IO.SYS, not an overlay;
no CPU fault is present. At failure `GDI.EXE` is zero-length, and the DOS
completion path shows `AX=0x071C` (1820) for a 9280-byte write request.
IDE/PIO, INT 13, ATAPI, FAT16 and HIMEM/UMB are otherwise healthy.

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
- **"No drives found, aborting installation":** two emulator bugs, both
  fixed. (1, `ed95334`) The driver's ATA/ATAPI discrimination (resident
  subcommand `AH=23h`, seg0:7D29) issues IDENTIFY DEVICE and requires
  `ABRT` with the ATAPI signature `EB/14` left in `1F5/1F4`; the aborted
  command now preserves it. (2) The registration loop (init segment
  `0B5B/0B5F:0780`, 8 drive slots, drive count at `cs:03F0`) runs every
  empty channel through the same detect: its `AH=0` handler (seg0:6ECF)
  polls status for `50` or the `EB/14` signature, and the slot also has to
  pass a write-55/read-55 scratch test on `1F4`. With no drive attached the
  task file must float `0xFF` - the old model answered `0x00` before the
  first command and `DRDY|ERR/ABRT` after, and the empty secondary slave
  (kind cdrom, signature still armed) answered the `EB/14` signature like a
  live CD, so the driver probed phantom ATAPI devices on the empty channels
  and could miss the count. Empty positions now float the bus on every read
  and swallow every task-file write, so only the real CD is detected and
  the probe finishes several million steps sooner.
- **"PCI bus scan complete." then a halt at `F000:B757`:** fixed in
  `41c1608`. SeaBIOS's `INT 15h/AH=86h` uses the MC146818 periodic interrupt;
  the CMOS now exposes status A/B/C, sets PF and raises IRQ8 while PIE is
  enabled. The stock ISO proceeds to MSCDEX/Setup.
- **Formatting/CAB copy:** formatting completes and the CAB copy writes files
  through `COMM.DRV`; the next step fails in the guest CAB/file-write
  completion path, leaving `GDI.EXE` zero-length and a short `AH=40`
  completion count. `FF39` is resident IO.SYS, not an overlay. This is the
  active Setup blocker.
- **Cold boot after partition restart:** fixed in `c5be06b`. `Ide.softReset`/
  SRST clears the stale OAKCDROM probe ERR and reloads signatures; Machine
  resets both IDE channels on an INT 19 attempt or a return to `F000:FFF0`.
  A fresh blank HDD now reports `BDA 0x475=1` and reaches Setup Welcome.
- **IDE-only image reaches Setup:** MSCDEX prints `Drive D: = Driver OEMCD001
  unit 0`, FINDCD/OEMSETUP run, and Setup reaches Welcome/disk configuration.
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

- OTI-91X IDE detection is fixed (`ed95334` signature, empty-channel bus
  float after it); the stock ASPI wait is fixed by the RTC periodic IRQ8
  model (`41c1608`), and both stock and IDE-only images reach Setup
  formatting.
- The 512 MiB HDD is partitioned/formatted; the CAB copy reaches `COMM.DRV`
  and then fails in the guest CAB/file-write completion path.
- No ACPI: Win98 falls back to Standard PC. SMBIOS 2.4 and APM 1.2 are
  present.
- 80-bit x87 and hardware task gates landed (`9e81135`, `39b96de`); recheck
  only if SETUP/VMM trips them.
- PS/2 mouse integration and audio/network drivers after first boot.

## Non-goals for the first 98 boot

- USB, AGP, 3D, printing, networking before the desktop.
- Cycle accuracy.
