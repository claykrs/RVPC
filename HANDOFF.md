# HANDOFF - RVPC

Windows 98 SE on a real 486/Pentium-class PC inside Roblox.

## Win98 SETUP phase-2 temp-write error — triage state

With the staged 512 MB `media/win98-hdd.img` and `tools/probe_win98_cab.lua
media/win98se-ide.iso 350 media/win98-hdd.img`, SETUP gets through CD
detection, Welcome, formatting, and the phase-1 file copy (63M→137M steps),
then prints "Setup is unable to write to the temporary directory". The
"RebootPrompt" marker at 137M is a false match: the error screen itself says
"press any key to restart your system" — **there is no reboot; the failure
is at the end of the first copy**, in the same DOS session.

Per-command instrumentation landed in `tools/probe_win98_phase2.lua`
(gitignored): a per-command IDE ring (opcode, CDB, status, error, interrupt
reason, byte counts) with a short-write freeze dump, INT 13h entry/exit and
INT 21h file-op watches with caller CS:IP, a memory scan + write watch over
the DOS kernel's FAT/dir cache buffers, device-control and IRQ14 delivery
logs with per-step timestamps, and a FAT/directory sector op history decoded
from the drive image.

Findings at the failure (deterministic: int13=629, int21=11805, packet=496
every run):

- **The IDE/ATA/ATAPI layer is fully green.** The last 64 commands (ATA PIO
  writes op=30, ATAPI READ(10) op=28, TEST UNIT READY) all complete
  st=50/58 err=00 with full data transfer; no ERR, no hang, no SRST. All
  928 commands over the run are clean. Disk writes land at the expected
  LBAs (temp dir 608, FAT1 64, FAT2 320, root 576, data 608+).
- **The failure is DOS-internal**: INT 21h AH=40h for
  `C:\WININST0.400\COMM.DRV` (caller 230F:5F32) returns AX=1820 for CX=9280
  with CF=0 — a "successful" short write — with **no ATA command issued, no
  INT 13h call, and no FAT allocation mark** for the file's clusters. INT 13h
  shows zero failures all run. Same signature as the old pre-ab997de blocker
  (GDI.EXE, AX=0x071C for 9280): the copy is deterministic, only the failing
  file moved.
- The DOS kernel drives the IDE itself: IO.SYS resident at FF39 (HMA copy at
  FFF8) hooks INT 13h and its AH=67h does the writes directly (caller
  FFFF:184A). SeaBIOS INT 13h is not in the copy path. The flush loop is
  ISR-driven per command: it masks nIEN (device control 0x0A), issues the
  write, transfers by polling, then unmasks (0x08) and expects the
  completion INTRQ after the unmask — which real hardware produces because
  the device holds BSY through its media-commit period.
- After the short write the kernel zeroes its FAT cache (FF39:CC8A writes 0
  words over FAT entries 46..84, then 2), flushes the zeroed FAT sector to
  lba 64 and 320 (destroying the on-disk metadata), and prints the error.
  The sweep frees exactly the clusters allocated after cluster 45 — a
  rollback to the state at the last "known-good" allocation point.
- The kernel's in-memory FAT at the failure is healthy up to entry 84, but
  the allocation marks contain **dangling temps**: each allocation writes
  FAT[N]=0x0001 at the newly allocated cluster and links FAT[N-1]=N, and
  several file-boundary entries never receive their final 0xFFFF EOC — e.g.
  FAT[67]=0x0001 for GDI.EXE's last cluster stays as the garbage value 1.

Interpretation: the IDE layer and the reset paths are healthy and are NOT
the cause. The wrong FAT bookkeeping values (dangling 0x0001 temps, missing
EOCs, the 1820 short count) are computed by the guest DOS kernel itself, so
the CPU's execution of the kernel's allocation routine (FF39:CC8A) is the
prime suspect — the same frontier as the FreeDOS 0FF7:F7AF `0F 10` hang.
Next diagnostic: trace/disassemble the DOS kernel allocation code around
FF39:CC8A and check how the EOC/link writes (0xFFFF vs 0x0001) are computed
and executed.

Also landed: the IDE PIO write path now models the real media-commit delay —
after the last data word the device reports BSY and completes (DRDY + INTRQ)
only after `Ide.advance()` ticks (`WRITE_COMPLETION_DELAY` steps, wired
per-step in `Machine.run`). Previously the write completed instantly at the
last data write, so a driver polling status observed the completion before
the interrupt. Setup's phase-1 copy still runs identically with the delay.

## Pre-installed FreeDOS image (M2.5) — current frontier

A headless driver (`tools/_hinstall.lua`) drives the whole FreeDOS install in
the Lune harness: the settle-repress key pattern (keys pressed right after a
prompt paints are eaten by the installer's keyboard purge — press, settle
~12M steps, re-press) walks language → FDI → proceed/format prompts →
partition Success → reboot → format → sys-transfer. Dumping C: at
"Set active boot partition" (media/fd13-c.img, 1 MiB payload, 64K-alignable)
yields an image whose MBR→VBS→kernel chain boots: the FreeDOS 2043 kernel
banner prints from the dumped disk.

Current hang: after the banner the kernel reads CONFIG.SYS through its own
disk code, loads COMMAND.COM to segment 0FF7, then executes `0F 10` (SSE
MOVUPS, unimplemented) at 0FF7:F7AF. DOS-era binaries do not emit SSE, so
this is most likely a decoder desync (an earlier instruction decoded with the
wrong length steers execution into data) or a missing two-byte opcode. The
core has only 43 H0F handlers — expanding two-byte-opcode coverage and
validating 32-bit decoder lengths is the next workstream (same class as the
Win98 GUI needs). CONFIG.SYS/AUTOEXEC.BAT are pre-written into the test image
(media/_test_hdd.img) to isolate this from the missing config phase.

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

1. **Win98 Setup CAB/file write.** Formatting completes and the temp
   directory/FAT16/IDE/PIO/INT 13/ATAPI/HIMEM paths are healthy. The `FF39`
   segment is resident IO.SYS, not a freed overlay; no CPU fault or
   self-modifying-code issue was found. The last DOS closes succeed. At the
   failure screen `GDI.EXE` is zero-length, and the DOS kernel completion path
   shows `AX=0x071C` (1820) for the 9280-byte write request. Next: trace the
   exact `COMM.DRV`/`GDI.EXE` `INT 21 AH=40` requested-vs-returned counts and
   the corresponding ATA sector writes; determine whether DOS/IDE returns a
   short count or the guest CAB decompressor mishandles a partial write.
   Keep media gitignored and use a separate HDD copy.
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

**Tests:** `tools/bin/lune.exe run tools/check.lua` passes with 1867 assertions.

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
