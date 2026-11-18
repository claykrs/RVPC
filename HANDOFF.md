# HANDOFF - RVPC

Windows 98 SE on a real 486/Pentium-class PC inside Roblox.

## Current state (2026-11-18) - read this first

## Update (later 2026-11-18): the IRQ0 stall is explained and fixed; a new derail follows it

**Root cause of the IRQ0 stall (fixed in `fa8e0d0`):** `IRQSTALL` starts at 1438M steps. The machine is in protected mode at
CPL 3 (selector 03A7, DPL 3) with IOPL=2 and a 16-bit TSS, so `out 0x20,al` (the extender's PIC EOI) raises #GP forever
(INT 0Dh at 03A7:287, about 220 per 100k steps) and IF stays 0. IOPL had been clobbered because POPF/IRET let ring-3 code
overwrite IOPL and IF. They now follow x86: only CPL 0 changes IOPL, IF changes only when CPL <= IOPL (`privilegedFlags`
in `core/Cpu.lua`, tests in `tests/Cpu386Tests.lua`).

**Checkpoint bug fixed (`cbb47f1`):** `vga.info` aliased the shared `MODES[3]` table, so restoring a checkpoint mutated a
module constant and every later fresh machine inherited the mode (a checkpoint saved from an already-loaded machine could not
be loaded). `vga.info` is now a per-machine copy. Checkpoints taken before this change and saved from loaded machines are
unusable; `win98.snap.*` from the original driver run are fine to load. `win98_run` now prints `IRQSTALL since N`.

**New failure after the fix (not understood yet):** from the corrected checkpoints SETUP now faults at 1438M instead
(`bad FF /7 at 06DF:8492`). Straight-line execution runs through DOS data (the CDS/directory cache) because a `retf` at
`4974:E27B` returns to `0000:0000` (a null far pointer; the IVT is then executed as code for ~1400 steps, then a DOS INT 21
return lands in 06DF:817B). So the question is where that null far pointer on the stack/table comes from (the routine at
4974:E246-E27B and its caller around 4974:CCA..F873). Reproduce in about 50 s: `lune run tools/win98_run.lua --load
tools/out/w98n.snap.1400m --budget 1440` (make `w98n.snap.1400m` with `--load tools/out/win98.snap.1250m --save-every 100
--save tools/out/w98n.snap --budget 1400`).

Narrowed further: the routine at 4974:E260 is an INT 10h hook (IVT[10h]=1B9F:191C) whose tail chains to the previous handler with `push [040F:010A]; push [040F:0108]; ... retf 2`. That slot (physical 0x41F8) is 0000:0000 for as long as I looked (since at least 1300M), so the first INT 10h the hook does not handle itself jumps to 0:0. The failing call is DOS's console output (INT 29h at FE2E:25A6 -> INT 10h at FFFF:6C8 in the HMA). Open question: who should have stored the old INT 10h vector in that slot (the hook's install code, or memory that was zeroed/overwritten afterwards)? Watch physical 0x41F8 from the start of the extender's load.

**Better lead than the null INT 10h slot (found later the same day):** the null-slot chain is a symptom. The real problem is that code at `4974:F5AE` is garbage. `6C77 push cs; call F5AE` (legit near call) enters a stretch that, in checkpoints 500m..1437m, holds a high-entropy byte pattern (`FA EE F8 6E 0C FB 17 73 ...`, physical 0x58CEE). In checkpoint 250m the same bytes were real code/data (`8C D8 90 45 55 8B` = mov ax,ds; nop; inc bp; push bp; mov bp,sp). So conventional memory that held resident extender/loader code at 250M was overwritten with what looks like CAB/file data during the copy phase (250M-500M), and the guest still calls into it at 1438M. Candidates: (1) our IDE/PIO/DMA path writing a sector buffer to the wrong physical address (check the PRD/DMA targets and `INT 13h` ES:BX handling for reads that cross 64 KiB or wrap), (2) an MCB/arena disagreement (guest freed or reused memory because INT 12h / the BIOS memory map / the XMS or UMB info we report differs from what it expects). Next step: diff conventional memory 0x40000-0x60000 between checkpoints 250m, 300m and 500m (make 300m..450m with `--save-every 50`) to find the first write into 0x58CEE and its source (which INT 13h/IDE read, buffer address and length).

**Who overwrites it (measured):** from `w98e.snap.375m` (made with `--load tools/out/win98.snap.250m --save-every 25 --save tools/out/w98e.snap --budget 500`; the loaded Windows code there is a real far-prolog `8C D8 90 45 55 8B EC` at 4974:F5C0) the first write into physical 0x58CEE happens between 382M and 383M steps, executed by a protected-mode instruction at `041F:11FF` (a rep move; DS=0427, ES=042F with base 0x58C40, DI about 0x121, A20 on, CR0=1, no paging). So the extender maps selector 042F onto real-mode memory at paragraph 0x58C4 and copies data into it, while a Windows code segment loaded at 4974 (physical 0x49740..0x59740) still occupies that range. Either the extender's allocation overlaps the module (its memory map comes from our INT 15h / INT 12h / XMS answers or the DOS arena) or DOS handed out paragraphs it had already given to the module. Next: log INT 21h AH=48h/49h/4Ah results and INT 15h AH=88h/E801h/E820h answers up to 383M and compare against the 4974 module's range.

**DOS arena at 375m (so the overlap is inside the guest's own heap):** `DOSSETUP` 22FF..4240, `dosxg` 424E..47C2, then `krnl386` 47D1..9FFF (0x582F paragraphs: it owns all remaining conventional memory). Both the module at 4974 and the block at 58C4 therefore live inside krnl386's private heap, so DOS did not hand out overlapping memory; krnl386's own sub-allocator (or a discard/reload of the 4974 segment) put new data at 58C4 and the later `call F5AE` still assumes the old contents. Note F5AE at 250m is a table (`09 08 07 06 06 05 ...`) followed by a far-prolog function at F5C0, so check whether the call target should be F5C0 (a call/offset computed 0x12 low) rather than assuming the data was overwritten. Reading the krnl386 heap (global arena headers in its first segment) at 375m vs 400m would show whether the 4974 segment was freed before 382M. A 16-bit disassembler is available: `python -c "import capstone"` (feed `m.mem:read8` bytes, mode CS_MODE_16).

**Correction after tracing selector 042F (supersedes the 'overwritten code' theory):** LDT selector 042F is a 1 KB data window (base 0x58C40, limit 0x3FF) created at 191M-192M steps by DOSX code at 0367:2B74/2B7C, and the 382M `rep movsb` (041F:11FF, 0x104 bytes from 0427:00DC) legitimately fills it. Base 0x58C40 equals `4974:F500`, so that window is the module's own data block at the end of segment 4974, and `4974:F5AE` is a table inside it (250m: `09 08 07 06 06 05 04 04 03 03 02 02 01 01 01 00 00 00`, then a far-prolog function at F5C0). The call at `4974:6C77` (`nop; push cs; call F5AE`, the loader's patched same-segment far call) therefore targets data: either the fixed-up target is 0x12 bytes low or the module image is displaced by 0x12 bytes relative to the layout the fixups assume (check how the module is read: INT 21h AH=3Fh into 4974:0 via `B4 3F CD 21` at F51D, any short read / offset handling in the guest's loader, or our ISO/IDE/PIO read returning a count or alignment the loader does not expect). The bytes executed at F5AE (`FA EE F8 6E` = cli; out dx,al; clc; outsb) also do stray port I/O. Tooling: `win98_run --watch PHYS --watch-len N [--watch-step 1] [--watch-stop 1]` prints every change (chunk mode) or the writing instruction (step mode, up to 40 hits); checkpoints from boot are `w98b.snap.25m` to `.250m` (every 25M).

**Probing technique that worked:** load a checkpoint, wrap `m.cpu.executeStep` with a function that records `cs:ip` into a
ring buffer, then call `m:run(1000000)` twice. Results depend on the `m:run` chunk size (IRQ delivery granularity), so use
the same 1M chunks as `win98_run` or the failure does not reproduce. Keys are injected by the driver every 80M steps after
580M; a bare probe misses those and diverges.

**Win98 SETUP is past the old faults but hangs at the graphical wizard.** The fix `7e17181` (retf #NP) is confirmed:
SETUP no longer Bad-Faults at 2761M steps. The wizard ("Preparing to run Windows 98 Setup", progress 100%) draws at about
580M steps and then nothing advances through 4.5B (`END budget`, no reboot). Evidence: `irqCount` is frozen at 12186 from
~1.5B on (no further IRQs, so no timer ticks), the screen text never changes, and the machine sits in a ~450 instruction
loop: PM<->RM switches via selectors 0053/0070/0078 (DOS extender), lots of `mov sreg`, `66`/`67` prefixes, `cr0` flips to 0
(checkpoint 4000m shows `cr0=0`, cs:ip 024C:17D). **First thing to find:** why IRQ0 stops. Check PIC IMR / the PIT channel-0
state at checkpoints 1500m vs 2000m (`probe_vga_inspect.lua` shows how to load one), whether `channel0Divisor` (set to 1 at
500M by the driver) or the guest masks IRQ0, and whether the extender's wait loop needs an RTC/IRQ8 tick instead.

**Tooling added this session (all committed, gate green):**
- `core/Snapshot.lua` + `tests/SnapshotTests.lua`: delta checkpoints of a whole Machine against a freshly built one.
  Verified identical resume at 150M steps. Not captured: functions/closures state, metatables.
- `tools/win98_run.lua`: headless Win98 SETUP driver. `--budget M`, `--save-every M --save path`, `--save-at M`,
  `--load path`, `--verify M --verify-span M`. Needs `media/win98se-ide.iso`, `media/win98-hdd-xms.img`,
  `media/win98-boot.img`, `roms/` (all git-ignored). Writes `tools/out/w98_NNN.ppm` every 80M steps after 580M.
- Checkpoints from the last run are in `tools/out/win98.snap.<N>m` (every 250M to 4500m, ~20 MiB each, git-ignored). Resume
  any of them in about 15 s instead of replaying: `lune run tools/win98_run.lua --load tools/out/win98.snap.2250m`.
- Local, git-ignored probes (names match `probe_*`): `probe_bench.lua` (steps/sec + register fingerprint from a checkpoint,
  `--span M`), `probe_hist.lua` (address/opcode histogram), `probe_micro.lua`/`probe_micro2.lua` (synthetic loops),
  `probe_vga_inspect.lua` (CRTC dump). Recreate from `win98_run.lua`'s `build()` if they are missing.
- Use `tools/bin/lune.exe` (the Downloads copy of lune was deleted). Never `taskkill /IM lune.exe`: it kills other jobs.

**Rendering defects seen in the headless screenshots (not fixed):** (1) the first ~32 scanlines show stable stale
text-mode-looking junk (identical in every shot; CRTC line compare is 0x3FF so it is not split screen; start address 0);
(2) wide glyphs `W`/`w` render blank ("Windows" -> "jndo  s"), 'i' looks like 'j'; suspect a guest font-blit path or an
emulated instruction, not the host presenter. RVPC has never been visually verified in Studio.

**Performance (measured, details for whoever picks this up):** about 0.64-0.9M emulated steps/s in Lune (a real 486 is 50x+
faster). Findings so far:
- Per-step cost is dominated by `Cpu.executeStep` itself, not `Machine.run` (synthetic NOP loop: executeStep alone ~= through
  `run`). `fetch8` is only ~0.12 us.
- `Cpu.step` (used when CR0.PG is set) allocated a closure per instruction for `pcall`; now `pcall(executeStep, self)`
  (committed; no measurable effect on the real-mode checkpoints because none has paging on).
- In a minimal-config machine, assigning `nil` to the absent fields `oseg`/`osegReg`/`rep`/`faultIP`/`faultCS` at the top of
  `executeStep` triggered a Luau table rehash every instruction (~2 us of ~2.5 us; synthetic loops ran 3.5-5.7x faster when
  guarded with read-before-write). **On the real Win98 machine that change was 6-10% SLOWER** (best-of-3 at checkpoint
  500m: old ~830k, nil-guard ~700-780k), so it was reverted. The cliff depends on how full the `Cpu` table is; do not
  assume it applies. A prefix-byte lookup table (`PREFIX_BYTES[op]`) looked neutral-to-positive (within noise).
- Benchmark protocol that works: `probe_bench.lua --load <snap> --span 4`, best of 3, nothing else running; compare the
  printed `FINGERPRINT` line between old and new code (must be identical) before trusting a speedup. Single runs vary +-10%.
- Untested ideas: decoded-instruction cache, cheaper segment-register loads (the hang loop is dominated by them), cache the
  per-instruction `baseOperand32` state, hoist the per-step device polling in `Machine.run`.

**Repo state:** `master` and `main` pushed. `.mcp.json` has an uncommitted local change (GitHub MCP entry removed): leave it.
`gh` is logged in as `claykrs`. Rules: no Co-Authored-By trailers, never commit media/ROMs/ISOs, gate must print CHECK PASSED,
`main` is a single squash commit refreshed with `git commit-tree master^{tree}` and pushed by commit id (the branch is checked out
in another worktree, so do not `branch -f` it).

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

## Update (2026-11-18, module layout at 4974)

The 1438M call at `4974:6C77` (`nop; push cs; call F5AE`, same bytes from 192M on) targets the middle of a lookup table, 0x12 below the function at `F5C0`. The module is real-mode segment `4974` (phys `0x49740`); the loader (PM code at `02EF:7A1D`, step 191M-192M) writes the patched call. Memory layout at 192M, identical to 250M, so nothing overwrites it before the 382M fill:

- `4974:F500..F542` is the last function of a code segment ending in `pop bp; dec bp; retf`; it still holds an unresolved far call (`9A FFFF 0000`).
- `F544..F58E` is an NE relocation table (count 9, 8-byte records), then zeros, then a 32-byte lookup table at `F5A0`, then real functions from `F5C0` (a keyboard-controller poll routine).
- Unresolved `9A FFFF 0000` fixups exist only at `F52F`, `FA23`, `FAA4`: everything from F500 up is raw, unrelocated data, so the code segment is only `F543` bytes and the callers' target `F5AE` is outside it.
- Seven callers share target `F5AE`; every other call target below F500 lands on a prologue.

Reading: the loader computed the near-call target from a relocation record that does not belong to this segment (or segment 4974 was given a wrong size), so look at the segment-table/relocation read that feeds `02EF:7A1D` next. New tool: `tools/win98_run.lua --load SNAP --dump ADDR [--dump-len N]` prints physical bytes from a checkpoint and exits. Checkpoints `tools/out/w98b.snap191/192` bracket the load (ignored files).

## Update (2026-11-18, later: the 4974 call is a symptom, the real derail is a stack-return chain in the HMA)

Correction to the entry above. The call at `4974:6C77` is not the first bad event. Tracing from `tools/out/w98n_1437.snap` with the new `--ring-at CS:IP [--ring-len N]` option (prints the last N executed `cs:ip` and registers when that address is reached) shows:

- The `call far [cs:241C]` at `1B9F:18E0` (an interrupt-hook chain) normally reaches `1B67:0104`. On its fourth execution the instruction bytes had become `2E FF 1E 1C 6E`: the displacement byte at `1B9F:18E4` went from `24` to `6E`, so the pointer read came from ASCII text (`ultIcon"` = `4974:6C75`). That is how execution reached `4974:6C75` and then `F5AE`.
- The corruption is done by a zero sled: execution slides through `0575:0003..FFFF` (`add [bx+si],al` over zero bytes, hundreds of thousands of steps) and its writes damage nearby code. `--watch 0x1D2D3 --watch-step 1` names the writer as `0575:1D48`.
- The sled starts from a bad return: DOS code in the HMA (`FE2E:` = linear `0x100000+`, A20 is on) runs the BCD date routine at `FE2E:288F` (`INT 1Ah AH=4`), then `ret`s along a chain `FE2E:295D -> BCA3 -> A324 -> A3E2 -> 1E8B -> 1EDA` and the last `ret` pops `0575:0002`. The stack is `1B9F:2679` (the word there is `BCA3` before the window starts, so it was pushed earlier than 1437M).
- Nothing in the 4974 segment layout notes above needs fixing: segment 1 of that NE module is `C571` bytes with calls beyond it (those are the linker's `push cs; call` thunks into the module's other segments), and the data at `5896:0` is seg 2 loaded by the DOSX real-mode copier `1B9F:0479`.

Next step: find which `call`/`ret` pair on this chain is unbalanced, i.e. who pushed `BCA3` at `1B9F:2679` and why the chain from `A324` returns into `1E8B`. Take a checkpoint before 1437M (`tools/out/w98n.snap.1400m`) and `--ring-at FE2E:288F --ring-len 400` to see the entry. Tools added this pass: `--dump ADDR [--dump-len N]`, `--ring-at CS:IP [--ring-len N]`, and `--watch-step` now prints the pre-instruction `ecx/esi/edi/ds/es`.

## Update (2026-11-18, later still: the bad return chain is DOS console output via INT 29h)

Further narrowing of the 1438M derail (all from `tools/out/w98n.snap.1400m`, run with the driver):

- The HMA code involved is the DOS console path: `FE2E:259E` is a `les/mov al,es:[di]; int 29h; loop` string writer, `FFFF:06C0..06CE` is the INT 29h/INT 10h shim (`lcall [40h]`, `pop ds,bx,bp,di,si,ax; iret`), and `FE2E:E2A2..E430` is the I/O buffer routine that calls it.
- The INT 29h `iret` lands correctly at `FE2E:25A6`. The failure is the next `ret` at `25A9`, which pops `259A` (the middle of an instruction), then `259D` pops `E3D1` (also mid-instruction; the instruction there is the 5-byte `mov cx,ss:[607]` at `E3CE`). After that the chain `E430 -> 878B -> 252C -> 28A3` follows, then the zero sled.
- So the two words at `1B9F:2661..2664` hold `259A`/`E3D1` instead of a valid return address. The first writer from 1400M is `FE2E:E420` (`call E2A2`, pushes `E423`); later writers are `4689:074B/0750`, `FE2E:E2A2/E2A3` and SeaBIOS `F000:FE75/D378/D40D`. The next step is to watch `0x1E051` only inside the last pass (checkpoint just before the final INT 29h) to see which of those leaves `259A` there; compare with `1B9F:2663`.
- A reference emulator is not installed (no qemu/bochs/dosbox); nothing was downloaded.
- Tools: `--ring-at` also accepts a linear address (no colon), `tools/dis16.py SNAP SEG START LEN` disassembles 16-bit code straight from a checkpoint.

## Update (2026-11-18, 1438M derail FIXED: MOV SS / POP SS interrupt shadow)

Root cause of the 1438M failure: the real-mode INT hook wrapper at `4689:06F4..071C` switches stacks with `mov ss,[24C0]` / `mov sp,[24C2]` (and `pop ss` / `mov sp,[100]`). x86 holds interrupts off for one instruction after `MOV SS`/`POP SS` (and `LSS`) so SS:SP loads as a pair; the CPU only had that shadow after STI, POPF and IRET. A timer IRQ landing between the two instructions pushed its frame on the old stack with the new SS, the saved SS:SP slot was clobbered, and the wrapper later returned onto a stack inside the code of segment `1B9F` (`sp=8C4`), whose `and [bp+0Ah],300h` flag merge then overwrote code (`1B9F:08CC`), sending execution into the zero sled. Fix: `core/Cpu.lua` sets `irqDelay = 1` after POP SS, MOV SS and LSS; tests `mov_ss_inhibits_interrupts_for_one_instruction`, `pop_ss_...`, `mov_ds_does_not_inhibit_interrupts`. From `tools/out/w98n.snap.1400m` SETUP now runs past 1438M with no fault (1500M reached, VGA 640x480, IRQs flowing). Earlier entries about the 4974 call and the HMA return chain were symptoms of this single bug.

## Update (2026-11-18, 1641M fault fixed: segment limit violations are guest #GP/#SS)

SETUP's DOSX pointer validator (`0367:4B62`, `les bx,[bp+8]` then `mov al,es:[bx]`) probes a possibly null selector and relies on the #GP handler to resume it. `Cpu.linear` raised a host error for a limit violation, so the run died at 1641M (`#GP: es selector 0000`). It now delivers #GP(0) (#SS(0) for SS) through the IDT and unwinds the instruction with the existing abort sentinel; because that unwind needs a pcall, `Cpu.step` and `Machine.run` use it whenever CR0.PE or PG is set (about 25% slower in protected mode). SETUP now passes 1641M and reached 1700M from `w98f.snap.1500m`.

## Update (2026-11-18, Win98 SETUP now copies files; the blocker is run time)

State after the CPU fixes above (IOPL in POPF/IRET, MOV SS/POP SS interrupt shadow, guest #GP for limit and selector violations) and a 1.4x faster `Machine.run` (device pass every 8 steps, one pcall per run loop):

- SETUP boots from the CD, runs its real graphical wizard in 640x480x16, finishes "Collecting information" and is in "Copying Windows 98 files": "File copy progress" 7% at about 8.9B steps (`tools/out/w98j.snap.*`, `w98i.snap.*`; 223 minutes remaining on SETUP's own estimate). No fault since 4300M.
- It is CPU-bound (CAB decompression and INF parsing; hot spots are spread over many loops, no single routine). Progress is roughly 1% per 2B steps, so the copy phase needs on the order of 150-200B steps. At about 0.7M steps/s that is days of wall time, not a CPU bug. Resume with `tools/bin/lune.exe run tools/win98_run.lua --load tools/out/<latest>.snap.NNNNm --budget 400000 --save tools/out/w98k.snap --save-every 500` and watch for `FAULT`.
- To finish in reasonable time the interpreter needs a large speed-up (decoded-instruction/basic-block cache, cheaper segment and memory paths). `win98_run --bench N` measures the raw core (about 0.86M steps/s) and `--hist N` prints the hottest `cs:ip`.
- Open cosmetic defect: every `W`/`w` glyph in SETUP's text is blank while the advance width is kept ("indo s 98"). Not yet traced; the font bitmap for those two characters may be zero in memory or the planar write path may drop them.

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
