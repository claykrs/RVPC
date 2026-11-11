# HANDOFF - RVPC

Windows 98 SE on a real 486/Pentium-class PC inside Roblox.

## Decisions

- **Target:** Windows 98 SE only (not 95, not 98 Gold).
- **Host:** Roblox/Luau client; core stays environment-pure.
- **Codebase:** forked from the original Windows 3.0 emulator as a reference, but the machine layer is
  rebuilt. Windows 3.x-specific DOS/VFS/NE hacks are not part of the target.
- **Firmware:** real SeaBIOS (prebuilt ROM, staged locally; not committed).
- **Install:** boot the 98 SE ISO, partition/format a virtual HDD, install, then boot from the HDD.
- **Network:** NE2000 + a host-side virtual ISP from the start.

## Milestones

- **M0 - machine skeleton: done.** 32-bit memory/A20/PAM, SeaBIOS POST, VGA
  text through EditableImage, Lune harness + Roblox shell. `docs/M0-REPORT.md`.
- **M1 - boot a real OS: done.** SeaBIOS boots FreeDOS (floppy-emulation and
  LiveCD ISOLINUX) to a shell; ATA/ATAPI PIO + BMIDE, KBC/PS/2, x87 486
  subset, NE2000 + virtual ISP, VBE SVGA. `docs/M1-REPORT.md`.
- **M2 - Windows 98 SE install: in progress.** Blocked on the OTI-91x ATAPI
  CD driver rejecting the CD after a completed INQUIRY (see Current frontier).
  Storage scale (512 MiB IDE), PIIX3, FDC, VBE, PAM, SMBIOS/APM are done;
  `docs/M2-REPORT.md`.
- **M3 - usable 98: blocked on M2.** SVGA/SB16/mouse polish, V86 DOS boxes,
  persistent images and snapshots come after a real install.
- **M4 - network: hardware done, guest blocked on M2.** NE2000 + ISP deliver
  DHCP/DNS/ICMP/TCP; guest-side usage needs a booted Windows.
- **M5 - platform: not started.** Machine library, cloud C:, releases.

## Current frontier

1. **Win98 Setup CAB copy.** Formatting completes. The temp-directory and
   FAT16 path succeed: Setup creates `C:\WININST0.400\COMM.DRV`, writes and
   closes it, then the guest CAB decompressor/overlay fails at `FF39:4358`
   immediately after the close and prints "Setup is unable to write to the
   temporary directory". IDE/PIO (0 word mismatches), INT 13, ATAPI, FAT16 and
   HIMEM/UMB are ruled out; the temp directory had only ~11 entries and the
   FAT had ~65k free clusters. The overlay at `FF39:5A54` is no longer
   resident when the handler runs. Next: trace the CAB decompressor/overlay
   code and CPU state before `FF39:4358`; use a separate HDD copy or a
   pre-cleanup checkpoint. Keep media gitignored.
2. **Cold-boot HDD after partition restart.** On a blank HDD, after the
   partition/restart prompt, the OAKCDROM ATAPI probe leaves the ATA master at
   `status=0x41 error=0x04`; SeaBIOS `INT 13 AH=08 DL=80` returns
   `AH=01/CF=1`, and Setup reports "Your computer does not have a hard disk."
   Fix the IDE reset/error/status semantics so the HDD is visible to BIOS
   after the ATAPI probe. This is separate from the CAB-overlay failure.
3. **ACPI HAL decision.** Win98 falls back to Standard PC (SMBIOS 2.4 + APM
   1.2 present). Only add ACPI if SETUP later refuses without it.

A paging TLB landed (commit `3957100`): epoch-flushed 1M-entry table with
per-entry U/S + R/W recheck, CR3/INVLPG invalidation, and page-table write
watching. The FreeDOS 24M-step benchmark is unchanged (paging stays off in
that workload; the win shows once VMM runs - see `docs/WIN98.md`).

## State (commits in order)

- **M0** (`7986985`): V86 interrupt delivery, 32-bit frame pops, #PF restart,
  PIC ISR priority/slave EOI. CPU/386/XMS suites in the gate.
- **M1** (`4fbd3bc`): `Ide.lua` ATA/ATAPI PIO, `Kbc.lua` 8042/PS2, PAM shadow
  locking; SeaBIOS detects HDD+CD and boots the CD entry.
- **M1** (`acae154`): ATAPI READ(10/12/16), GET CONFIGURATION, MODE SENSE,
  READ TOC/HEADER, VERIFY/SEEK, sense/status; FD13LIVE El Torito reads
  byte-exact.
- **M1** (`ea7f43d`): `Ne2000.lua` DP8390 + `Isp.lua` ARP/IP/ICMP/DHCP/DNS;
  `VgaSink.lua` presenter + Roblox `VgaView.lua`; client `InputMap`/`Shell`.
- **M1** (`8f202f5`): 32-bit SIB index fix and null LLDT fix; SeaBIOS enters
  `boot_cdrom`, FreeDOS reaches FreeCom.
- **x87** (`8f202f5`, `65d4faf`): FLDENV/FSTENV/FNSAVE/FRSTOR, m80/BCD,
  TS/EM lazy switching, V86 I/O bitmap traps, deferred `#MF`.
- **M2 storage** (`6b091a8`, `aceeaac`, `973c6f0`): dirty-sector write-back,
  MBR/no-emulation boot, PIIX3 dual IDE + BMIDE, 82077 FDC with DMA2/IRQ6,
  512 MiB IDE scale validation.
- **M2 platform** (`a846fd6`, `2c40d4e`): VBE/DISPI 8/16/32bpp + 4 MiB LFB,
  PIRQ routing, ELCR, SMBIOS 2.4, APM 1.2 (no ACPI).
- **M2 CPU/VGA** (`973c7ef`, `ce4c7d4`): 16-bit write high-half preservation,
  `MOV r32,Sreg` zero-extension (unblocked ISOLINUX/COM32); VGA mode 12h
  write/read modes, latches, set/reset/ALU, CRTC, palette banking.
- **M2 speed** (`49d13e9`): unpaged fast paths; FreeDOS 24M boot 90 s -> 33 s;
  mixed ~1.6M steps/s.
- **Paging TLB** (`3957100`): software TLB in `Cpu.translatePage` - 2^20
  entries, 7-bit epoch flush, U/S + R/W re-checked on every hit against the
  access and CR0.WP, 4 MiB/PSE entries with the reserved-bit condition,
  A/D bookkeeping on the walk (write-hits without a cached dirty bit fall
  back to the walk), CR3 reload + PG transitions flush, INVLPG single-entry,
  stores into tracked PD/PT frames invalidate what maps through them.
  `#PF` error codes are byte-identical to the uncached walker (test suite
  covers hits, invalidation, WP and A/D).
- **IDE ATAPI** (`8b98007`): DEVICE RESET (0x08) reloads the per-drive task
  file signature; post-reset signature reads (ATAPI 0x14/0xEB in the cylinder
  registers, cleared by task-file writes and commands); packet-phase interrupt
  reason (CoD/I/O) in the sector-count register and burst byte count in the
  cylinder registers. This is what gets the OTI-91x probe as far as INQUIRY.
- **Win98 Setup**: `ed95334` preserves the ATAPI signature after an aborted
  IDENTIFY DEVICE, so the OTI-91X driver reports `Number of drives : 1`;
  `e3bc272` models the PPI refresh bit so the AIC ASPI delay loop completes;
  `41c1608` models the MC146818 periodic IRQ8/status C so the stock image's
  INT 15h/AH=86h waits expire. Both stock and IDE-only images reach Setup's
  Formatting drive C; the current blocker is the guest temp-directory/CAB
  copy.
- **VGA cursor** (`7c1dff9`): CRTC cursor location/shape, blink phase and
  attribute blink rendered in RGBA snapshots; the Roblox presenter advances
  the phase (`238794f`).
- **RTC** (`41c1608`, `cd1b14a`): periodic/status C IRQ8 for INT 15h/AH=86h,
  then full wall-clock/date/alarm registers with BCD/binary and 12/24-hour
  modes, settable time and leap-year rollover.
- **Tools** (`beac165`, `3b5dae9`): local IDE-only Win98 boot-image builder and
  a Roblox model build that tolerates a missing fixtures tree.

**Tests:** `tools/bin/lune.exe run tools/check.lua` passes with 1791 assertions.

## Definition of done

Every change - core, tests, tools, docs - lands only with
`tools/bin/lune.exe run tools/check.lua` printing `CHECK PASSED`. The gate
runs stylua/lint/typecheck plus the full Luau suite; fix style with
`tools/bin/stylua.exe <file>`. Media, ROMs and disk images stay out of git
(`media/`, `roms/` are gitignored); never push; commit locally on the current
branch with natural lowercase messages.

## Hard rules

- `core/` is environment-pure and `--!strict`.
- No cycle accuracy requirement; compatibility and correctness win.
- Do not commit Microsoft media, SeaBIOS binaries or disk images.
- Every milestone must leave `lune run tools/check.lua` green.
