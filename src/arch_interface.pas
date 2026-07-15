unit arch_interface;

{$MODE FPC}
{$ASMMODE Intel}
{$MODESWITCH ADVANCEDRECORDS}

interface

{ Architecture Abstraction Layer (AAL) for x86_64.

  This unit provides Pascal declarations for architecture-specific primitives
  implemented in Hardware.asm. Other Pascal code can import these via:

    uses arch_interface;

  The actual implementations are NASM label aliases in Hardware.asm (e.g.,
  Arch_SpinlockAcquire: before AsmSpinlockAcquire:). No wrapper overhead. }

{ ============================================================================
  I/O Port Operations
  ============================================================================ }
procedure Arch_WritePort8(port: Word; value: Byte); cdecl;
function Arch_ReadPort8(port: Word): Byte; cdecl;
procedure Arch_WritePort16(port: Word; value: Word); cdecl;
function Arch_ReadPort16(port: Word): Word; cdecl;
procedure Arch_WritePort32(port: Word; value: Cardinal); cdecl;
function Arch_ReadPort32(port: Word): Cardinal; cdecl;

{ I/O delay (out to port 0x80) }
procedure Arch_IoWait; cdecl;

{ ============================================================================
  Memory-Mapped I/O
  ============================================================================ }
procedure Arch_WriteMmio32(addr: QWord; value: Cardinal); cdecl;
function Arch_ReadMmio32(addr: QWord): Cardinal; cdecl;

{ ============================================================================
  CPU Control
  ============================================================================ }
procedure Arch_EnableInterrupts; cdecl;
procedure Arch_DisableInterrupts; cdecl;
procedure Arch_Halt; cdecl;
function Arch_InterruptsEnabled: Byte; cdecl;

{ ============================================================================
  Atomic Operations
  ============================================================================ }
function Arch_AtomicExchange(var location: Cardinal; newValue: Cardinal): Cardinal; cdecl;
function Arch_AtomicAdd64(var location: QWord; delta: QWord): QWord; cdecl;
function Arch_CmpXchg(var location: Cardinal; comparand, newValue: Cardinal): Cardinal; cdecl;
procedure Arch_CompilerFence; cdecl;
procedure Arch_StoreFence; cdecl;
procedure Arch_LoadFence; cdecl;
procedure Arch_FullFence; cdecl;

{ ============================================================================
  Spinlocks
  ============================================================================ }
procedure Arch_SpinlockAcquire(lockVar: PCardinal); cdecl;
procedure Arch_SpinlockRelease(lockVar: PCardinal); cdecl;

{ ============================================================================
  Paging & Memory Management
  ============================================================================ }
procedure Arch_LoadPageTable(physAddr: QWord); cdecl;
function Arch_ReadPageTable: QWord; cdecl;
function Arch_GetFaultAddress: QWord; cdecl;
procedure Arch_FlushTLB; cdecl;
procedure Arch_EnableNX; cdecl;

{ ============================================================================
  GDT/IDT/TSS
  ============================================================================ }
procedure Arch_LoadGDT(gdtrAddr: Pointer); cdecl;
procedure Arch_LoadIDT(idtrAddr: Pointer); cdecl;
procedure Arch_LoadTSS(selector: Word); cdecl;
function Arch_GetCS: Word; cdecl;
function Arch_GetSS: Word; cdecl;
function Arch_GetIDTR: QWord; cdecl;

{ ============================================================================
  CPU State & Diagnostics
  ============================================================================ }
function Arch_GetFlags: QWord; cdecl;
function Arch_ReadTimestamp: QWord; cdecl;
procedure Arch_SaveFPU(buffer: Pointer); cdecl;
procedure Arch_RestoreFPU(buffer: Pointer); cdecl;
function Arch_ReadVolatile64(addr: Pointer): QWord; cdecl;

{ ============================================================================
  ISR Entry Points (returns address of asm stub)
  ============================================================================ }
function Arch_GetIsrDiv0: Pointer; cdecl;
function Arch_GetIsrGPF: Pointer; cdecl;
function Arch_GetIsrPageFault: Pointer; cdecl;
function Arch_GetIsrTimer: Pointer; cdecl;
function Arch_GetIsrKeyboard: Pointer; cdecl;
function Arch_GetIsrMouse: Pointer; cdecl;
function Arch_GetIsrSyscall: Pointer; cdecl;
function Arch_GetIsrYield: Pointer; cdecl;

{ ============================================================================
  Scheduler Primitives
  ============================================================================ }
procedure Arch_LockScheduler; cdecl;
procedure Arch_UnlockScheduler; cdecl;
procedure Arch_ForceYield; cdecl;

implementation

{ All Arch_* symbols are implemented in Hardware.asm as NASM label aliases.
  The 'external name' declarations below tell FPC to resolve calls to these
  functions by emitting references to the specified symbol names in the COFF
  object file. LLD will resolve them from Hardware.obj at link time.

  NO 'public name' in the interface → NO wrapper stubs emitted → NO linker
  conflict with C# DllImport references to the same symbols. }

procedure Arch_WritePort8(port: Word; value: Byte); cdecl; external name 'Arch_WritePort8';
function Arch_ReadPort8(port: Word): Byte; cdecl; external name 'Arch_ReadPort8';
procedure Arch_WritePort16(port: Word; value: Word); cdecl; external name 'Arch_WritePort16';
function Arch_ReadPort16(port: Word): Word; cdecl; external name 'Arch_ReadPort16';
procedure Arch_WritePort32(port: Word; value: Cardinal); cdecl; external name 'Arch_WritePort32';
function Arch_ReadPort32(port: Word): Cardinal; cdecl; external name 'Arch_ReadPort32';
procedure Arch_IoWait; cdecl; external name 'Arch_IoWait';

procedure Arch_WriteMmio32(addr: QWord; value: Cardinal); cdecl; external name 'Arch_WriteMmio32';
function Arch_ReadMmio32(addr: QWord): Cardinal; cdecl; external name 'Arch_ReadMmio32';

procedure Arch_EnableInterrupts; cdecl; external name 'Arch_EnableInterrupts';
procedure Arch_DisableInterrupts; cdecl; external name 'Arch_DisableInterrupts';
procedure Arch_Halt; cdecl; external name 'Arch_Halt';
function Arch_InterruptsEnabled: Byte; cdecl; external name 'Arch_InterruptsEnabled';

function Arch_AtomicExchange(var location: Cardinal; newValue: Cardinal): Cardinal; cdecl; external name 'Arch_AtomicExchange';
function Arch_AtomicAdd64(var location: QWord; delta: QWord): QWord; cdecl; external name 'Arch_AtomicAdd64';
function Arch_CmpXchg(var location: Cardinal; comparand, newValue: Cardinal): Cardinal; cdecl; external name 'Arch_CmpXchg';
procedure Arch_CompilerFence; cdecl; external name 'Arch_CompilerFence';
procedure Arch_StoreFence; cdecl; external name 'Arch_StoreFence';
procedure Arch_LoadFence; cdecl; external name 'Arch_LoadFence';
procedure Arch_FullFence; cdecl; external name 'Arch_FullFence';

procedure Arch_SpinlockAcquire(lockVar: PCardinal); cdecl; external name 'Arch_SpinlockAcquire';
procedure Arch_SpinlockRelease(lockVar: PCardinal); cdecl; external name 'Arch_SpinlockRelease';

procedure Arch_LoadPageTable(physAddr: QWord); cdecl; external name 'Arch_LoadPageTable';
function Arch_ReadPageTable: QWord; cdecl; external name 'Arch_ReadPageTable';
function Arch_GetFaultAddress: QWord; cdecl; external name 'Arch_GetFaultAddress';
procedure Arch_FlushTLB; cdecl; external name 'Arch_FlushTLB';
procedure Arch_EnableNX; cdecl; external name 'Arch_EnableNX';

procedure Arch_LoadGDT(gdtrAddr: Pointer); cdecl; external name 'Arch_LoadGDT';
procedure Arch_LoadIDT(idtrAddr: Pointer); cdecl; external name 'Arch_LoadIDT';
procedure Arch_LoadTSS(selector: Word); cdecl; external name 'Arch_LoadTSS';
function Arch_GetCS: Word; cdecl; external name 'Arch_GetCS';
function Arch_GetSS: Word; cdecl; external name 'Arch_GetSS';
function Arch_GetIDTR: QWord; cdecl; external name 'Arch_GetIDTR';

function Arch_GetFlags: QWord; cdecl; external name 'Arch_GetFlags';
function Arch_ReadTimestamp: QWord; cdecl; external name 'Arch_ReadTimestamp';
procedure Arch_SaveFPU(buffer: Pointer); cdecl; external name 'Arch_SaveFPU';
procedure Arch_RestoreFPU(buffer: Pointer); cdecl; external name 'Arch_RestoreFPU';
function Arch_ReadVolatile64(addr: Pointer): QWord; cdecl; external name 'Arch_ReadVolatile64';

function Arch_GetIsrDiv0: Pointer; cdecl; external name 'Arch_GetIsrDiv0';
function Arch_GetIsrGPF: Pointer; cdecl; external name 'Arch_GetIsrGPF';
function Arch_GetIsrPageFault: Pointer; cdecl; external name 'Arch_GetIsrPageFault';
function Arch_GetIsrTimer: Pointer; cdecl; external name 'Arch_GetIsrTimer';
function Arch_GetIsrKeyboard: Pointer; cdecl; external name 'Arch_GetIsrKeyboard';
function Arch_GetIsrMouse: Pointer; cdecl; external name 'Arch_GetIsrMouse';
function Arch_GetIsrSyscall: Pointer; cdecl; external name 'Arch_GetIsrSyscall';
function Arch_GetIsrYield: Pointer; cdecl; external name 'Arch_GetIsrYield';

procedure Arch_LockScheduler; cdecl; external name 'Arch_LockScheduler';
procedure Arch_UnlockScheduler; cdecl; external name 'Arch_UnlockScheduler';
procedure Arch_ForceYield; cdecl; external name 'Arch_ForceYield';

end.
