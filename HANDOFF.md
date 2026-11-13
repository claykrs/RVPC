# HANDOFF - RVPC

Windows 98 SE on a real 486/Pentium-class PC inside Roblox.

## Win98 SETUP phase-2 temp-write error — RESOLVED (cpu: CMPS/SCAS flag width)

**Root cause (fixed in `core/Cpu.lua`):** `stringOp` passed its raw byte-count
width (2/4) to `doALU` as the flag-width argument, but `doALU`'s width mapper
only recognizes 32/16/true/8 — width 2 silently fell through to 8-bit flags.
Every REPE/REPNE CMPSW/CMPSD/SCASW therefore judged a 16/32-bit compare by the
LOW BYTE of the result only.

The visible Win98 failure chain: SETUP's AH=3Ch create of
`C:\WININST0.400\COMM.DRV` walks the BIOS-segment device-header chain with
`repz cmpsw` (FF39:8A65) comparing the parsed name against each device name.
"COMM    " vs "COM1    " differs at word 1 (0x314D vs 0x4D4D → result 0xE400,
high byte nonzero, low byte zero), but the 8-bit-flag compare called it EQUAL.
The kernel concluded the new file was the COM1 character device and initialized
its SFT entry (table 0x0BA1:0000 entry 0, JFT[7]=5) with device-info 0x00C0 and
the COM1 device-header pointer 0070:006A. The following AH=40h of COMM.DRV's
9280 bytes then took the cooked character-device write path: byte-at-a-time
device requests scanning for Ctrl-Z, finding the 0x1A byte at buffer offset
0x071B, and returning AX=1820 (0x071C) with CF=0 — a "successful" short write
with no ATA command, no INT 13h, and no FAT allocation. SETUP read AX<CX as
disk-full, printed the temp-directory error, and the kernel's rollback zeroed
its FAT cache and flushed it (lba 64/320). The identical GDI.EXE AX=0x071C
signature from the pre-ab997de state was the same mechanism one file earlier.

With the fix COMM.DRV's 9280 bytes write in full and the copy advances well
past it: the post-fix run reaches 188M steps (vs the old 137M failure),
int13=740, int21=12081 — 276 more file operations — and enters SETUP's
protected-mode transition (CR0.PE=1, segment 0367) before faulting on
`0F FF` at 0367:AF59. That `0F FF` is a NEW, separate frontier (an undefined
opcode inside the early PM phase; same class as the FreeDOS `0F 10` slide —
verify data before blaming the decoder).

Diagnosis tooling (gitignored probes): `probe_win98_phase2.lua` (per-command
IDE ring + INT watches + FAT write watch), `probe_win98_cabtrace2.lua`
(per-step CPU trace of the failing AH=40h with registers, opcode bytes and
FAT-cache writes), `probe_win98_sftwatch.lua` (SFT/JFT dump + write watch),
and `probe_win98_cabtrace3.lua` (create/write tracing with kernel-variable
snapshots). Evidence: int13=629, int21=11805, packet=496 every run — the IDE
layer is fully green (all 928 commands clean; writes land at the expected
LBAs), INT 13h never fails, and the failure is entirely DOS-internal.

Also landed: the IDE PIO write path now models the real media-commit delay —
after the last data word the device reports BSY and completes (DRDY + INTRQ)
only after `Ide.advance()` ticks (`WRITE_COMPLETION_DELAY` steps, wired
per-step in `Machine.run`). Previously the write completed instantly at the
last data write, so a driver polling status observed the completion before
the interrupt. Setup's phase-1 copy still runs identically with the delay.

## Pre-installed FreeDOS image (M2.5) — RESOLVED: boots to C:\>

A headless driver (`tools/_hinstall.lua`) drives the whole FreeDOS install in
the Lune harness: the settle-repress key pattern (keys pressed right after a
prompt paints are eaten by the installer's keyboard purge — press, settle
~12M steps, re-press) walks language → FDI → proceed/format prompts →
partition Success → reboot → format → sys-transfer. Dumping C: at
"Set active boot partition" (media/fd13-c.img, 1 MiB payload, 64K-alignable)
yields an image whose MBR→VBS→kernel chain boots. The install itself is
verified pristine: an instrumented replay (tools/_hinstall_trace.lua) dumps a
C: byte-identical to fd13-c.img.

The reported 0FF7:F7AF `0F 10` (SSE MOVUPS) fault was never a CPU bug. The
lost step that turned fd13-c.img into media/_test_hdd.img (32 MiB pad +
CONFIG.SYS/AUTOEXEC.BAT pre-write) corrupted the disk three ways: it shifted
KERNEL.SYS and COMMAND.COM forward by exactly 2 bytes (two leading zeros, two
tail bytes lost), claimed clusters 4/5 — the middle of COMMAND.COM's chain
3..44 — for the two small files, and stamped FAT1[4]=FAT1[5]=0xFFFF over that
chain (FAT2 kept the true chain; DOS reads FAT1). The kernel therefore read a
4 KB truncation of COMMAND.COM, and its exec jumped to the (correct) entry
0FF7:8410 inside zeroed memory; the CPU slid through `00 00` bytes until the
`0F 10` bytes of the exec handoff frame at 0FF7:F7AF faulted as an
unimplemented SSE opcode.

tools/_fixfd13.lua rebuilds _test_hdd.img from the pristine dump and
pre-writes CONFIG.SYS/AUTOEXEC.BAT correctly (root entries + both FAT copies
+ data on genuinely free clusters 68/69), then verifies every file chain in
both FATs. tools/_boothdd.lua on the rebuilt image reaches the prompt:
kernel banner → InitDisk → CONFIG.SYS (the DRIVPARM line logs a guest-syntax
warning and is skipped) → FreeCom 0.85a → AUTOEXEC → `C:\>` at ~10.8M steps.

CPU two-byte coverage touched while closing this: 0F B0/B1 CMPXCHG (the one
missing 486-era instruction) and the 0F 18-1F hintable-NOP family (as
modrm-consuming no-ops so newer toolchains' long NOPs run). MOVZX/MOVSX/
BSF/BSR/BSWAP/SHLD/SHRD/IMUL/Jcc/SETcc/LFS/LSS/LGS/BT* were already present,
and the 66-prefixed two-byte dispatch is now covered by tests (five new
CpuTests cases). The Win98-lane FF39 FAT-cache mis-execution is a different
frontier and is not reproduced by the FreeDOS boot.

Also landed this round: the OTI "No drives found" root cause (ab997de) —
empty IDE device positions now float the ISA bus (0xFF reads, lost writes,
no phantom ATAPI signatures), matching real hardware; Win98 SETUP passes CD
detection and reaches the CAB-copy blocker.

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

1. **Win98 Setup CAB/file write: fixed.** The blocker was the CPU's CMPS/SCAS
   flag-width bug (see the triage section above). Next: let the post-fix runs
   set the new frontier — the copy should continue toward "Setup is
   initializing" and the reboot into the GUI phase.
2. **Cold boot fixed (`c5be06b`).** `Ide.softReset`/SRST clears the stale
   OAKCDROM probe ERR and reloads both signatures; `Machine` resets the IDE
   channels on an INT 19 boot attempt or a return to `F000:FFF0`. A fresh
   blank HDD now reports `BDA 0x475=1` and reaches Setup Welcome/disk
   configuration. No further action unless a later reboot path bypasses both.
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
- **IDE warm boot** (`c5be06b`): SRST/softReset clears stale ATAPI-probe
  errors and Machine resets the IDE channels on INT 19/reset-vector entry;
  a blank HDD now reports one disk to SeaBIOS after the partition restart.
- **Tools** (`beac165`, `3b5dae9`): local IDE-only Win98 boot-image builder and
  a Roblox model build that tolerates a missing fixtures tree.

**Tests:** `tools/bin/lune.exe run tools/check.lua` passes with 1877 assertions.

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
