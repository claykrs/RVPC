# RVPC style guide

This repository targets **Roblox Studio** first and **Lune** second. Every
decision below is chosen so the same source runs in both without a build step
and without leaking Roblox APIs into the emulator core.

## Language

- **Luau, current syntax.** `const`, `continue`, compound assignment (`+=`),
  generalized iteration, and string interpolation are expected.
- **No native bitwise operators.** Luau does not parse `& | ~ << >>` (verified
  against `luau-compile`). Use `bit32` through module-local aliases:
  `const band, bor, lshift, rshift = bit32.band, bit32.bor, bit32.lshift, bit32.rshift`.
- `const` for bindings that are never reassigned. Use `local` only when the
  binding is reassigned later in the same scope. Constants are
  `SCREAMING_SNAKE_CASE`.
- Generalised iteration is the default: `for index, value in list do`. Reach
  for `pairs` when the distinction actually matters (sparse tables, mutation
  during iteration).
- Prefer early returns over nested `if`s. Prefer guard clauses.
- Prefer `UDim2.fromScale` / `UDim2.fromOffset` over four-argument `UDim2.new`.

## Naming

| Kind | Convention | Example |
| --- | --- | --- |
| Module / class / type | `PascalCase` | `Machine`, `Executables` |
| Function / method | `camelCase` | `machine:dosAlloc`, `parseEntryTable` |
| Local / field | `camelCase` | `segBases`, `entryOff` |
| Constant | `SCREAMING_SNAKE_CASE` | `SFT_ENTRY_SIZE`, `ARENA_TOP` |
| Module file | `PascalCase.lua` | `core/Executables.lua` |
| Tool script | `snake_case.lua` | `tools/load_real.lua` |
| Roblox entry point | `Name.client.lua` | `roblox/client/Emulator.client.lua` |
| Test module | `PascalCaseTests.lua` | `tests/MachineTests.lua` |

The project uses `.lua` extensions everywhere (Rojo and Lune both understand
them); there is no `.luau`/`.lua` split.

## Types

- Shipping modules in `core/` start with `--!strict`.
- Annotate all public functions: parameters, returns, and the shape of
  injected dependencies.
- Class methods are declared with an explicit receiver under strict mode:
  `function Machine.dosAlloc(self: Machine, paras: number): number?`. Luau's
  `function Class:method()` inference treats `self` as read-only in some
  recursive class shapes.
- `any` is allowed only at three seams: the dependency-injection table, the
  CPU opcode dispatch table, and VFS nodes at the Roblox boundary.
- Roblox UI and tools are `--!nonstrict` (the standalone analyzer has no
  Roblox type definitions) but still annotate public APIs.

## Module boundaries

- `core/` is environment-pure: **no `require`**, no `game`, no `workspace`, no
  `print`/`warn`, no filesystem access. Dependencies arrive through
  `Machine.new(deps)`.
- Host diagnostics go through `machine:log(message)`; it appends to
  `machine.diagnostics` and forwards to an optional `deps.logger`.
- Roblox code lives under `roblox/`. It defines UI and platform glue only.
- Roblox loads modules through **service roots and index modules**:
  `require(ReplicatedStorage:WaitForChild("Rvpc"))`, `RvpcUi`, `RvpcFixtures`.
  String-path requires (`./`, `../`, `@self`) are not available in this Studio
  build, so deep `script.Parent.Parent.X` chains are not used either. Sibling
  requires inside one UI folder (`script.Parent.Theme`) are allowed.
- Lune tools and tests use relative requires (`require("../core/Cpu")`).
- Demo/test binaries and the Win16 KERNEL stand-in live in `fixtures/`, not in
  `core/`.

## Errors

- `error(...)` is for programmer mistakes and unimplemented hardware. Include
  `CS:IP` in CPU errors.
- Guest faults (divide error, bad DOS call, missing file) are handled by the
  emulated BIOS/DOS layer and never unwind the host.
- The Roblox boundary wraps frame work in `pcall` so one guest fault cannot
  kill the client script silently.

## Formatting and checks

- Formatter: StyLua (`stylua.toml`, tabs, 100 columns, one statement per line).
- Linter: Selene (`selene.toml` std `luau`; `selene_roblox.toml` std `roblox`
  for `roblox/` and `core/init.lua`).
- Type checker: `luau-analyze --mode=strict` on `core/` (excluding the Roblox
  `init.lua`).
- Tests: `lune run tools/run.lua`.

Run everything with:

```powershell
lune run tools/check.lua
```

## Comments

Comment the hardware or DOS behaviour being emulated, not the mechanics of the
code. Every non-obvious constant (MCB layout, SFT stride, NE fixup record,
SFT name offset) gets one line explaining where it comes from.

## Commits

Functional milestones (R0, R1, ...) and style/tooling passes are separate
commits. A style commit must leave `tools/check.lua` green and change no
behaviour.
