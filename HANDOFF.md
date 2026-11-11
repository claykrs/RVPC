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

The exact next three actions, in order:

1. **Installer boot: OTI-91X ATAPI probe.** The Win98 CD startup menu and the
   DOS-side startup menu both run. The Oak OTI-91X driver loads from the boot
   floppy's `CONFIG.SYS` and prints its banner, then "No drives found".
   New trace evidence (probe `tools/probe_oti_print.lua`):

   - the DOS device-driver code is at segment `0B5B` (not `028E`);
   - the driver's `lcall 0,0x6050` is relocated to a resident shim at
     `028E:6050`, which jumps to the IDE probe at `028E:6C48`;
   - the AH=0x23 probe returns AX=0x002D (failure). The probe reads the IDE
     **error register** at the selected device and dispatches: 0x10 takes the
     success path at `028E:6CE5` (CF=0), 0x00/0x04 take failure paths
     `6D0C`/`6D23` (AH=4, CF=1);
   - at the stall the slave CD has `error=00 status=50`, the master HDD has
     `error=04 status=41`; the ATAPI signature read of `1F5/1F4` is
     `EB/14` and DEVICE RESET returns `50`.
   - the per-device port table lives at `028E:636C` (base/error/count/LBA/
     drive-head/status/control), but the final dump shows it cleared to a
     pattern after the failure.

   Next: instrument `028E:6C48/6D26/6D34/6D92/6E8E/6EF4/6F05/6D0C/6CE5`
   live, log AX/BX/CX/DX plus `1F1/1F4/1F5/1F7` at each branch, and identify the
   exact check that rejects the slave CD. `tools/probe_win98_boot.lua` is the
   baseline; `tools/probe_oti_print.lua` has the new ring/INT/segment logging.
   The `/P:<port>,<irq>,<unit>` CONFIG.SYS switch is a possible media-side
   workaround while the real cause is fixed.
2. **TSS/task gates and 80-bit x87.** Hardware task switching landed in
   `39b96de` (IDT task gates, far CALL/JMP to a TSS, IRET back-link). The
   double-fault task gate works; x87 is now full 80-bit (`9e81135`). Recheck
   only if SETUP or VMM trips them.
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

**Tests:** `tools/bin/lune.exe run tools/check.lua` passes with 1644 assertions.

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
