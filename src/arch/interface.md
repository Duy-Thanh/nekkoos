# Architecture Abstraction Layer (AAL) Interface

This document defines the architecture-agnostic interface that NekkoOS kernel code must use. The x86_64 implementation is in `x86_64/Hardware.asm`.

## Design Principles

1. **Kernel code NEVER directly imports arch-specific symbols**
2. **All arch operations go through the AAL interface**
3. **Each architecture (x86_64, ARM, RISC-V) implements the same interface**
4. **Interface is stable; implementations can differ**

## Symbol Naming Convention

All AAL symbols use the `Arch_` prefix:
- C# code: `[DllImport("*")] static extern RetType Arch_FunctionName(...);`
- Pascal code: `function Arch_FunctionName(...): RetType; cdecl; external name 'Arch_FunctionName';`

## Interface Categories

### 1. I/O Port Operations

```
procedure Arch_WritePort8(port: Word; value: Byte)
function Arch_ReadPort8(port: Word): Byte
procedure Arch_WritePort16(port: Word; value: Word)
function Arch_ReadPort16(port: Word): Word
procedure Arch_WritePort32(port: Word; value: Cardinal)
function Arch_ReadPort32(port: Word): Cardinal
procedure Arch_IoWait()
```

**x86_64**: `out`/`in` instructions
**ARM/RISC-V**: MMIO-based or trap to handler

### 2. Memory-Mapped I/O

```
procedure Arch_WriteMmio32(addr: QWord; value: Cardinal)
function Arch_ReadMmio32(addr: QWord): Cardinal
```

**x86_64**: Direct memory write with fence
**ARM/RISC-V**: Memory barrier + device memory access

### 3. CPU Control

```
procedure Arch_EnableInterrupts()
procedure Arch_DisableInterrupts()
procedure Arch_Halt()
function Arch_InterruptsEnabled(): Byte
```

**x86_64**: `sti`/`cli`/`hlt`/`pushfq`
**ARM**: `cpsie`/`cpsid`/`wfi`/`mrs`
**RISC-V**: `csrs`/`csrc`/`wfi`/`csrr`

### 4. Atomic Operations

```
function Arch_AtomicExchange(var location: Cardinal; newValue: Cardinal): Cardinal
function Arch_AtomicAdd64(var location: QWord; delta: QWord): QWord
function Arch_CmpXchg(var location: Cardinal; comparand, newValue: Cardinal): Cardinal
```

**x86_64**: `lock xchg`/`lock xadd`/`lock cmpxchg`
**ARM**: `ldrex`/`strex` loops
**RISC-V**: `lr.w`/`sc.w` + `amo*` instructions

### 5. Memory Barriers

```
procedure Arch_CompilerFence()
procedure Arch_StoreFence()
procedure Arch_LoadFence()
procedure Arch_FullFence()
```

**x86_64**: compiler barrier / `sfence` / `lfence` / `mfence`
**ARM**: compiler barrier / `dmb st` / `dmb ld` / `dmb sy`
**RISC-V**: compiler barrier / `fence w,w` / `fence r,r` / `fence rw,rw`

### 6. Spinlocks

```
procedure Arch_SpinlockAcquire(lockVar: PCardinal)
procedure Arch_SpinlockRelease(lockVar: PCardinal)
```

**All architectures**: Architecture-specific atomic test-and-set loop

### 7. Paging & Memory Management

```
procedure Arch_LoadPageTable(physAddr: QWord)
function Arch_ReadPageTable(): QWord
function Arch_GetFaultAddress(): QWord
procedure Arch_FlushTLB()
procedure Arch_EnableNX()
```

**x86_64**: `mov cr3` / `mov rax,cr3` / `mov rax,cr2` / `invlpg` / MSR write
**ARM**: `msr ttbr0` / `mrs` / `mrs far` / `tlbi` / TCR configuration
**RISC-V**: `csrw satp` / `csrr satp` / `csrr stval` / `sfence.vma` / `satp` mode

### 8. Descriptor Tables (x86_64-specific, will need abstraction)

```
procedure Arch_LoadGDT(gdtrAddr: Pointer)
procedure Arch_LoadIDT(idtrAddr: Pointer)
procedure Arch_LoadTSS(selector: Word)
function Arch_GetCS(): Word
function Arch_GetSS(): Word
function Arch_GetIDTR(): QWord
```

**x86_64**: `lgdt`/`lidt`/`ltr`/segment registers
**ARM/RISC-V**: No direct equivalent (use vector table base / exception handlers)

### 9. CPU State & Diagnostics

```
function Arch_GetFlags(): QWord
function Arch_ReadTimestamp(): QWord
procedure Arch_SaveFPU(buffer: Pointer)
procedure Arch_RestoreFPU(buffer: Pointer)
function Arch_ReadVolatile64(addr: Pointer): QWord
```

**x86_64**: `pushfq`/`rdtsc`/`fxsave`/`fxrstor`/volatile load
**ARM**: `mrs cpsr`/`mrs cntvct`/VFP save/restore/volatile load
**RISC-V**: `csrr mstatus`/`rdcycle`/F extension save/restore/volatile load

### 10. Interrupt Service Routine Entry Points

```
function Arch_GetIsrDiv0(): Pointer
function Arch_GetIsrGPF(): Pointer
function Arch_GetIsrPageFault(): Pointer
function Arch_GetIsrTimer(): Pointer
function Arch_GetIsrKeyboard(): Pointer
function Arch_GetIsrMouse(): Pointer
function Arch_GetIsrSyscall(): Pointer
function Arch_GetIsrYield(): Pointer
```

**All architectures**: Return pointer to asm stub that saves context + calls C handler

### 11. Scheduler Primitives

```
procedure Arch_LockScheduler()
procedure Arch_UnlockScheduler()
procedure Arch_ForceYield()
```

**All architectures**: Disable interrupts + spinlock / restore / trigger scheduler IRQ

## Usage Patterns

### C# Code

```csharp
using System.Runtime.InteropServices;

// In your module:
[DllImport("*")]
private static extern void Arch_DisableInterrupts();

// Use it:
Arch_DisableInterrupts();
// ... critical section ...
Arch_EnableInterrupts();
```

### Pascal Code

```pascal
// In your module's implementation section:
procedure Arch_DisableInterrupts; cdecl; external name 'Arch_DisableInterrupts';

// Use it:
Arch_DisableInterrupts;
// ... critical section ...
Arch_EnableInterrupts;
```

## Implementation Status

### x86_64 (Current)
- ✅ All symbols implemented in `x86_64/Hardware.asm`
- ✅ NASM label aliases (`Arch_X:` before original symbols)
- ✅ Linked into kernel via `Hardware.obj`

### ARM64 (Future)
- ⏳ Planned
- Will implement same interface in `arm64/hardware.S`

### RISC-V (Future)
- ⏳ Planned
- Will implement same interface in `riscv64/hardware.S`

## Migration Checklist

When porting a module to use AAL:

1. Find all direct Hardware.asm symbol references
2. Replace with `Arch_*` equivalents
3. Add proper `DllImport` or `external name` declarations
4. Test on x86_64
5. Document any architecture assumptions that need future work

## Notes

- **No wrapper modules**: Don't create intermediate Pascal/C# modules that wrap these functions. Direct `external name` declarations avoid linker conflicts and wrapper overhead.
- **Inline when possible**: For hot-path operations (spinlocks, atomics), architectures should inline these in their implementation files.
- **Document assumptions**: If code assumes x86_64 behavior (e.g., strong memory ordering), add a comment noting it needs review for ARM/RISC-V.
