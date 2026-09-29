# Pascal Porting Conventions

Rules for moving C# files in `src/` to Pascal units in `src/`. Read fully
before porting. The authoritative hard limits are in `AGENTS.md` §2 — this
file is the working detail for porting, plus the conventions the existing
ports settled on.

## 1. Where code lives

| Kind | Path | Example |
|---|---|---|
| Architecture-neutral kernel logic | `src/kernel/pas/<name>.pas` | `pmm.pas`, `ipc.pas` |
| x86_64-only code | `src/arch/x86_64/<name>.pas` | `gdt.pas`, `vmm.pas` |
| Architecture primitive declarations | `src/arch/arch_interface.pas` | `Arch_*` |
| x86_64 primitive implementations | `src/arch/x86_64/Hardware.asm` | NASM |

Ask: would this code still be correct on ARM64? If no, it belongs in
`src/arch/x86_64/`. If yes, it belongs in `src/kernel/pas/`.

## 2. Unit skeleton

```pascal
unit mymodule;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}   { only if records are laid out explicitly }
{$ASMMODE Intel}   { only if inline asm is used }

interface

{ Exported API. No record types here - see §4. }

implementation

uses libc, kstring, terminal, pmm;

{ Hardware primitives live in Hardware.asm. Bind them with `external name`
  so calls emit a direct reference and no wrapper stub is generated:
  }
procedure Arch_WritePort8(port: Word; value: Byte); cdecl;
  external name 'Arch_WritePort8';

end.
```

## 3. Strings — the #1 porting trap

C# `char` is UTF-16 (2 bytes). Terminal and every userland string API takes
UTF-16 (`PWord`). FPC literals are ANSI (1 byte). Use `kstring.W()`:

```pascal
uses kstring;

Terminal_Print_Pas(W('[!] cannot allocate'#13#10));
Serial_WriteString(W('[+] ready'#13#10));
```

`#13#10` is CRLF — the serial driver and terminal both expect it.

`W()` returns a pointer into a rotating pool of 8 slots, valid until 8 more
`W()` calls. That is always enough for call arguments, since the pointer is
consumed before any nested call. **Never store the result** — copy it with
`StrCpyLimited` if it must outlive the statement.

## 4. Records — the #2 porting trap

FPC emits RTTI for any record type reachable from the `interface` section,
**regardless of where `{$TYPEINFO OFF}` appears**. lld cannot resolve those
symbols and the link fails with `undefined symbol: RTTI_$SYSTEM_$$_WORD$indirect`.

Therefore: **all record types go in `implementation`; the interface exposes
`Pointer`.**

```pascal
interface
function Gdt_GetTss: Pointer;          { not PTssEntry }

implementation
type
  PTssEntry = ^TTssEntry;
  TTssEntry = packed record Rsp0: QWord; Iopb: array[0..8191] of Byte; end;
```

Use `{$PACKRECORDS 1}` so records match the C# `[StructLayout(Pack = 1)]`
originals byte for byte. Always use `packed record` for anything that
crosses a boundary with NASM or with data produced by another module.

Verify with `objdump -t build/<mod>.o | grep -i rtti` — the count must be 0.

## 5. Static state replaces static classes

A C# `public static class` becomes unit-level `var` in the `implementation`
section.

```pascal
var
  Gdt_Tss: PTssEntry = nil;
  Gdt_CoreCnt: Cardinal = 1;
```

Static arrays **cannot** be initialised to `nil` in FPC — a static array is
already zero-filled, so just declare it:

```pascal
  Gdt_CoreTss: array[0..63] of Pointer;   { zero = nil, correct already }
```

## 6. Callbacks and cycles

FPC has no circular `uses`. When module A and B genuinely need each other:

- **Shared data**: put it in a dependency-free unit. `kstate.pas` is the
  model — the syscall layer writes the shared-memory window, VMM reads it
  during teardown. Neither imports the other.
- **Genuine upward calls** (leaf -> kernel service): bind with
  `external name` in the implementation section. No cycle, direct call.
- **Genuine downward calls** (kernel -> leaf): pass a function pointer, as
  `scheduler.pas` already does via `Sched_SetCallbacks_Pas`.

Prefer the first two. Reach for callbacks only where a callback table would
be unwieldy.

## 7. Language mapping

| C# | Pascal |
|---|---|
| `ulong` | `QWord` |
| `uint` | `Cardinal` |
| `ushort` | `Word` |
| `byte*` / `void*` | `PByte` / `Pointer` |
| `char*` (UTF-16) | `PWord` |
| `bool` | `Boolean` |
| `byte b = 1` | `b: Byte = 1` |
| `0x1F` | `$1F` — **FPC uses `$`, not `0x`** |
| `new T[512]` | no heap: use a static array, or `Pmm_AllocatePage` |
| `string` literal | `AnsiString` -> use `W()` at the call |
| `out` / `ref` | `var` |

`0x` literals are a silent trap: FPC does not accept them, so `0x3F8` is a
parse error while `$3F8` is correct.

## 8. Naming

Prefix public API with the unit name to keep the flat global namespace
readable: `Gdt_Init`, `Vmm_MapPage`, `Pic_Remap`, `Vdso_Init`, `Pmm_FreePage`.

Reserved and easily confused, avoid or prefix:
`Fatal` (built-in), `Result` (built-in — use `fnName :=`), `W` (kstring).

## 9. Registering a new unit — both lists, both scripts

Adding a unit to only one place produces a confusing failure:

1. `compile_pascal.sh` — add to `PASCAL_MODULES` (or `ARCH_X86_64_MODULES`),
   and add the name to `mod_src()` if it lives in `src/arch/x86_64/`.
   **This is also what runs the relocation stripper.** Skip it and you get
   `lld: error: unsupported relocation type 0x0 in build/<mod>.o`.
2. `build.sh` — add `build/<mod>.o` to the `--ldflags` object list, or the
   link fails with `undefined symbol: <UNIT>_$$_...`.

## 10. Hardware primitives

Never re-implement a CPU instruction that already exists in
`arch_interface.pas` / `Hardware.asm`. Add to `Hardware.asm` and declare it
in `arch_interface.pas` with `external name`. The arch lint in `build.sh`
keeps these out of kernel and app code.

## 11. Porting checklist

- [ ] Records only in `implementation`; interface uses `Pointer`
- [ ] `{$TYPEINFO OFF}`, `{$M-}`, and `{$PACKRECORDS 1}` where applicable
- [ ] `W()` for every string; no bare string literals passed as `PWord`
- [ ] `$` hex literals, not `0x`
- [ ] Struct sizes verified against the C# original (see §12)
- [ ] `objdump -t build/<mod>.o | grep -i rtti` returns nothing
- [ ] Registered in **both** `compile_pascal.sh` and `build.sh`
- [ ] `./build.sh` succeeds
- [ ] `python3 test/automation/smoke_test.py` reports 9/9
- [ ] The C# original is deleted once nothing references it

## 12. Verifying a struct layout

C# and Pascal records must agree byte for byte, or you get memory corruption
with no diagnostic. FPC here only ships win64 units, so a host test program
cannot run; instead emit the sizes as initialised data and read the object
file:

```pascal
var L_TssEntry: QWord = SizeOf(TTssEntry);
```

```bash
fpc -Twin64 -O1 -CX -Ur -g- -Si -CD @.fpc/fpc.cfg -FU. probe.pas
objdump -h probe.o   # find the .data section File off for the symbol
# then read 8 bytes little-endian at that offset
```

Use this for any record that crosses a boundary with NASM, with another
module, or with the vDSO/hand-built structures.
