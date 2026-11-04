# M0 relay report — machine skeleton + SeaBIOS

**Code commit:** `686c9069e5d84298edb38df471776ddaf55e82dd`
(`M0: boot SeaBIOS on a 32-bit 486 machine`)

This report is the relay point for the next session. The functional work is in
the commit above; this file is added immediately afterwards so it can name that
exact hash.

## What changed and why

### Memory (`core/Memory.lua`)

- Replaced the inherited 1 MiB/RVDM wrap-around model with configurable 32-bit
  physical RAM (16/32/64 MiB; tests use all three).
- A20M now clears address bit 20 only, so `0x100000-0x1FFFFF` folds onto
  `0-0xFFFFF` while higher bits are untouched. This is 486 chipset behavior,
  not a blanket 20-bit mask.
- Added explicit PC windows:
  - `A0000-AFFFF` VGA aperture (routed to `Vga`)
  - `B8000-BFFFF` colour text RAM
  - `C0000-DFFFF` option-ROM shadow RAM
  - `E0000-EFFFF` BIOS extension RAM
  - `F0000-FFFFF` writable BIOS shadow (SeaBIOS's 32-bit flat BSS/F-segment)
  - `0xFFFC0000-0xFFFFFFFF` read-only 256 KiB SeaBIOS high mapping
- Above RAM, reads return `0xFF` and writes are dropped (open bus). Reads and
  writes now have byte/word/dword paths, including ROM/aperture fallbacks.

Why: SeaBIOS writes its relocatable data and F-segment allocator in the legacy
BIOS window, while also executing the 256 KiB image through the top-of-4G
mapping. A read-only low ROM caused the earlier “No space for init relocation”
panic.

### CPU (`core/Cpu.lua`)

- Full 32-bit EIP handling while preserving 16-bit real-mode wrap.
- 32-bit operand/address forms: SIB/ModRM, EAX..EDI, 32-bit ALU/TEST/MOV/XCHG,
  PUSH/POP/CALL/RET/PUSHFD/POPFD/IRETD, string ops, IN/OUT, far pointers.
- 32-bit MUL/IMUL/DIV/IDIV with exact 32×32→64 and 64÷32 helpers.
- CR0/CR3, two-level paging, 4 MiB PDE support, accessed/dirty updates, and #PF
  error-code delivery. Page faults unwind the faulting instruction cleanly.
- V86 entry through IRETD: 32-bit frame, VM flag, real-mode segment caches,
  ring-3 CPL, and V86-safe segment loads.
- 32-bit interrupt/trap gate frames, error-code frames, nested ring returns and
  IRETD back to V86.
- Added CPUID (486/GenuineIntel, no PAE/long mode), RDTSC, BSWAP, SHLD/SHRD,
  BT/BTS/BTR/BTC, XADD, INVD/WBINVD, 32-bit LAR/LSL, LGDT/LIDT widths, and
  386 TSS types for ring transitions.

Why: the prebuilt QEMU SeaBIOS uses flat 32-bit protected mode during POST and
the SeaVGABIOS option ROM uses 32-bit call/return and stack traffic.

### Chipset (`core/Pic.lua`, `core/Pit.lua`, `core/Cmos.lua`, `core/Machine.lua`)

- 8259 master/slave pair: ICW/OCW, IRR/ISR/IMR, IRQ2 cascade, EOI, vector base.
- 8254: three counters, LSB/MSB access, mode/BCD state, read-back latch, IRQ0
  wrap detection.
- CMOS/RTC: index/data ports, shutdown byte, 640 KiB base, extended-memory
  words (`0x30/0x31`), status B/C/D, frozen valid BCD clock.
- Port `0x92`: A20 gate and fast-reset bit.
- PCI config `0xCF8/0xCFC`: i440FX host bridge and Bochs/QEMU-compatible VGA
  function at `00:02.0` (no BARs yet, so SeaBIOS does not panic on resource
  assignment).
- QEMU fw_cfg `0x510/0x511`: signature, file directory, e820 map, bootorder,
  and `vgaroms/vgabios-stdvga.bin`. This is what lets the QEMU SeaBIOS build see
  RAM and deploy the VGA option ROM without a fw_cfg-capable host.
- Machine reset now actually resets the CPU, PIC/PIT and A20, and reset fetches
  the BIOS entry (`F000:FFF0` → `EA 5B E0 00 F0`).
- Machine runs PIT IRQ0, delivers PIC vectors when IF is set, wakes `HLT`, and
  exposes text/debug output for the harness.

### Firmware and tooling

- `tools/harness.lua` stages a real 256 KiB SeaBIOS plus the SeaVGABIOS stdvga
  ROM, runs the machine, prints screen/debug output, and stops on boot text.
- ROMs live in `roms/` and remain gitignored. No Microsoft media was added.

### Tests

- `tests/MemoryTests.lua`: 16/32/64 MiB sizing, 32-bit RAM, A20 bit-20 fold,
  open bus, low/high BIOS mapping, writable shadow, option-ROM shadow.
- `tests/SystemTests.lua`: flat-32 ALU/addressing, paging translation, page
  fault handler/error code, V86 entry/execution, PIC cascade/EOI, PIT counter
  and IRQ wrap, CMOS memory/shutdown.
- `tools/run.lua` now runs the smoke, memory and system suites.

## Check result

`lune run tools/check.lua` → **CHECK PASSED** (format, Luau lint, Roblox lint,
strict typecheck, 64 assertions).

## How to run the harness / ROM

```powershell
New-Item -ItemType Directory -Force roms
Invoke-WebRequest `
  https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/bios-256k.bin `
  -OutFile roms/bios-256k.bin
Invoke-WebRequest `
  https://raw.githubusercontent.com/qemu/qemu/master/pc-bios/vgabios-stdvga.bin `
  -OutFile roms/vgabios-stdvga.bin

lune run tools/check.lua
lune run tools/harness.lua
lune run tools/harness.lua 40   # step budget in millions
```

Both ROMs are gitignored. The harness calls them “SeaBIOS” and “SeaVGABIOS” in
its output; versions in the current staging are `rel-1.17.0`.

## Measured boot state

- **Boot PC:** `F000:B757` (the `wait_irq` inside SeaBIOS's boot-failure retry
  loop), after **6,000,000 steps**, 8 IRQs, 0 page faults.
- **VGA:** mode 3 text through SeaVGABIOS; no VBE DISPI interface, so SeaVGABIOS
  falls back to stdvga (expected).
- **Screen:**

```text
SeaBIOS (version rel-1.17.0-0-gb52ca86e094d-prebuilt.qemu.org)
Booting from Hard Disk...
Boot failed: could not read the boot disk

Booting from Hard Disk...
Boot failed: could not read the boot disk

No bootable device.  Retrying in 60 seconds.
```

The “no bootable device” state is the expected M0 endpoint: there is no IDE/
ATAPI controller or disk image attached yet, so SeaBIOS cannot read a boot
sector. This is a measured BIOS screen, not a fault.

## Next 3 actions

1. **IDE/ATAPI PIO + boot media.** Implement ports `0x1F0-0x1F7`/`0x3F6`,
   IDENTIFY, PIO read, ATAPI packet reads, MBR/partition validation; attach an
   empty HDD and a Win98 SE ISO. Target: SeaBIOS boots the CD or reports a
   readable partition table.
2. **8042 keyboard/PS2 mouse.** Ports `0x60/0x64`, self-test/ACK behavior,
   scan-code set 1, IRQ1/IRQ12 via the PIC. Target: boot menu selection and
   keyboard input reach the guest.
3. **VGA modes 12h/13h + EditableImage sink.** The text mode 3 path works via
   SeaVGABIOS. Add planar 640×480×16 and linear 320×200×256, dirty rectangles,
   and a host sink so the Roblox client shows the same screen the harness logs.

After those: TSS/task-gate/complex-exception polish, x87, then the actual Win98
SE installer flow. Do not add Windows media to git.

## Uncommitted files

At the code commit there were no tracked working-tree changes left uncommitted.
The only local files intentionally left out are:

- `roms/bios-256k.bin` — SeaBIOS 256 KiB image (gitignored)
- `roms/vgabios-stdvga.bin` — SeaVGABIOS stdvga option ROM (gitignored)

This report file is committed as the relay/docs commit directly after the code
commit.

## Post-M0 hardening (commit `7986985`)

A follow-up pass corrected several architectural details found while auditing
M0:

- V86 interrupt delivery now clears the VM flag before switching to the ring-0
  stack and reloading CS/SS, so the frame is written with supervisor rights and
  the selectors resolve through the GDT.
- 32-bit interrupt/trap and IRET frames use 32-bit slots for CS, SS and the
  V86 ESP/segment state; 16-bit frames keep 16-bit slots. RETF uses the same
  operand-size rule.
- #PF and synchronous exceptions save the faulting instruction's CS:EIP, so a
  handler can map the page and IRETD re-executes the access. `pageFault` still
  unwinds the partially executed instruction.
- `TEST EAX,imm32`, PIC fixed-priority/ISR blocking, slave non-specific EOI,
  the Memory aperture word boundary, and a 16 MiB default RAM size.
- The legacy 8086 CPU suite, XMS suite and a new `tests/Cpu386Tests.lua` are
  back in `tools/check.lua`: 333 assertions.

M1 bring-up (IDE/ATAPI, 8042/PS2, PAM locking) is commit `4fbd3bc` and is
still in progress; see `HANDOFF.md` for its exact boot state and blockers.

