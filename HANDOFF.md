# HANDOFF - RVPC

Windows 98 SE on a real 486/Pentium-class PC inside Roblox.

## Decisions

- **Target:** Windows 98 SE only (not 95, not 98 Gold).
- **Host:** Roblox/Luau client; core stays environment-pure.
- **Codebase:** forked from the original Windows 3.0 emulator as a reference, but the machine layer is being
  rebuilt. Windows 3.x-specific DOS/VFS/NE hacks are not part of the target.
- **Firmware:** real SeaBIOS (prebuilt ROM, staged locally; not committed).
- **Install:** boot the 98 SE ISO, partition/format a virtual HDD, install,
  then boot from the HDD.
- **Network:** NE2000 + a host-side virtual ISP from the start.

## Milestones

### M0 — machine skeleton
- 32-bit physical memory, bus, ROM mapping
- 386 real mode CPU baseline, PIC/PIT/CMOS, A20
- SeaBIOS reaches its boot menu
- VGA text mode 3 through EditableImage
- Lune harness + Roblox client shell

### M1 — boot a real OS
- 386 protected mode, paging, V86, TSS/descriptor tables
- IDE PIO + ATAPI CD-ROM, MBR/partition reads
- SeaBIOS boots FreeDOS or a Linux floppy/ISO
- PS/2 keyboard/mouse, serial

### M2 — Windows 98 SE install
- IDE HDD writes, partition/format compatibility
- VGA/SVGA modes, mouse, SB16
- Win98 SE setup runs from CD and installs to C:
- First boot to the Windows 98 desktop

### M3 — usable 98
- SVGA 800x600/1024x768, Sound Blaster, mouse pointer
- DOS boxes / V86, 32-bit drivers
- persistent disk images, snapshots, file import/export

### M4 — network
- NE2000 + virtual ISP (DHCP/DNS/ARP/IP/TCP/UDP)
- HTTP/IRC/BBS/mail inside the guest
- optional relay to the real internet

### M5 — platform
- machine library, cloud C:, app store, compatibility telemetry
- releases with model + demo image + media

## Current state

M0 is complete and committed. Details are in `docs/M0-REPORT.md`.

- **Memory:** 32-bit physical RAM (16/32/64 MiB configurable), A20M masks bit
  20 only, VGA/option-ROM windows, open-bus reads, and a 256 KiB SeaBIOS high
  mapping at `0xFFFC0000` with a writable `F0000-FFFFF` shadow.
- **CPU:** 386/486 real/PM core: 32-bit operands and addressing (SIB), full
  EIP, CR0/CR3, two-level paging with #PF error codes, V86 entry via IRETD,
  32-bit interrupt/trap frames, 32-bit CALL/RET/PUSH/POP/string/MUL/DIV,
  CPUID, BSWAP, SHLD/SHRD, BT/BTS/BTR/BTC, XADD, INVD/WBINVD.
- **Chipset:** `Pic` (8259 master/slave), `Pit` (8254), `Cmos` (RTC/shutdown/
  memory words), port `0x92` A20/reset, PCI config `0xCF8/0xCFC` with an
  i440FX host bridge and Bochs-compatible VGA function, and QEMU fw_cfg
  (`0x510/0x511`) providing e820/bootorder/vgarom files.
- **Firmware:** real SeaBIOS `rel-1.17.0` + SeaVGABIOS `rel-1.17.0` staged in
  `roms/` (gitignored). `tools/harness.lua` loads both.
- **M0 hardening (commit `7986985`):** V86 interrupt delivery clears VM before
  the ring-0 stack switch; IRETD/RETF pop the correct 16/32-bit frame slots;
  #PF frames restart the faulting instruction; PIC ISR priority and slave EOI
  are correct. CPU, 386 frame and XMS suites are in the gate again.
- **Tests:** `lune run tools/check.lua` passes with 600 assertions.
- **M1 bring-up (commit `4fbd3bc`):** `Ide.lua` (ATA/ATAPI PIO), `Kbc.lua`
  (8042/PS2), PAM shadow locking, and the harness attach a 32 MiB HDD plus a
  FreeDOS LiveCD. SeaBIOS detects both drives, shows its boot menu, and starts
  the CD entry.
- **ATAPI command set (commit `acae154`):** READ(10/12/16), GET CONFIGURATION,
  MODE SENSE 6/10, READ TOC formats, READ HEADER, VERIFY/SEEK and correct
  sense/status. Real FD13LIVE El Torito LBA 17/403/404 reads are byte-exact.
- **Network (commit `ea7f43d`):** `Ne2000.lua` (DP8390 registers, remote DMA,
  ring, IRQ mask) and `Isp.lua` (ARP, IPv4/ICMP, DHCP, DNS) with link tests.
- **Video (commit `ea7f43d`):** `VgaSink.lua` dirty-region presenter and
  `roblox/ui/VgaView.lua` EditableImage/ImageLabel adapter. Input/client bridge
  is in progress.

### Next blockers

1. SeaBIOS boot selection: the IRQ return-frame bug is fixed, but the BEV list
   still starts at the floppy fallback instead of `boot_cdrom`. ACPI/PNP0303 and
   fw_cfg bootorder are the current leads.
2. Once CD boot is selected, get the FreeDOS banner or the next fault with
   PC/register evidence. ATAPI El Torito reads are already byte-exact.
3. Finish the Roblox input/client bridge around the new `VgaView`/`VgaSink`.
4. Then IDE writes/MBR partitions, SVGA, x87, and the Win98 SE installer path.


## Hard rules

- `core/` is environment-pure and `--!strict`.
- No cycle accuracy requirement; compatibility and correctness win.
- Do not commit Microsoft media, SeaBIOS binaries or disk images.
- Every milestone must leave `lune run tools/check.lua` green.
