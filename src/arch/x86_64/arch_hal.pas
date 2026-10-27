{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: arch_hal - the platform contract the generic kernel codes against.

  Generic kernel units (scheduler, pe_loader, power, kernel_main, ...) must
  not name apic, gdt, vmm or any other architecture unit. They `uses arch_hal`
  and call Hal_* only. Each architecture supplies its own unit called
  `arch_hal` with the SAME interface section (src/arch/<arch>/arch_hal.pas);
  the build picks the implementation by directory.

  The interface below is the contract. Keep it free of x86 concepts: an
  "address space" is an opaque handle (a PML4 physical address here, a TTBR0
  value on ARM64, a satp value on RISC-V); a "core id" is whatever number the
  interrupt controller uses to name a CPU.

  This x86_64 implementation only forwards to the existing arch units.
  =========================================================================
}
unit arch_hal;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

const
  { Mapping permission sets for Hal_MapPageIn. The numeric values are the
    architecture's own page-table bits; generic code only uses the names. }
  HAL_MAP_KERNEL_RW = QWord($03);   { present + writable, supervisor only }
  HAL_MAP_USER_RW   = QWord($07);   { present + writable + user }
  HAL_MAP_USER_RO   = QWord($05);   { present + user, read-only }
  HAL_MAP_USER_GUARD = QWord($04);  { user, NOT present: a guard page }
  HAL_PAGE_SIZE     = 4096;

{ ── Syscall register frame ────────────────────────────────────────────────── }
{ ctx points at the saved register frame of the trapping thread. Argument and
  return registers are the architecture's calling convention for syscalls
  (x86_64: args RBX, RCX, RDX, R8, R9; return RAX, second return RBX). }
function  Ctx_GetNumber(ctx: PQWord): QWord;
function  Ctx_GetArg(ctx: PQWord; i: Integer): QWord;
procedure Ctx_SetRet(ctx: PQWord; v: QWord);
procedure Ctx_SetRet2(ctx: PQWord; v: QWord);

{ ── Boot sequence ─────────────────────────────────────────────────────────── }
{ kernel_main calls these in order; each does whatever its architecture needs
  for that phase and nothing else. }

{ Make diagnostics possible at all (x86: COM1). Must run before any output. }
procedure Hal_EarlyInit;

{ Build and switch to the kernel's own virtual memory layout. Needs the page
  allocator. `maxPhysicalAddr` is the top of RAM that must stay addressable. }
procedure Hal_InitMemory(maxPhysicalAddr: QWord);

{ Install exception, device-interrupt and syscall entry points; quiet the
  legacy interrupt hardware and stop devices DMAing into kernel memory. After
  this the kernel can safely take interrupts, once Hal_StartTimer ran. }
procedure Hal_InitInterrupts;

{ Start the scheduler tick at roughly `hz`. Needs the scheduler. }
procedure Hal_StartTimer(hz: Cardinal);

{ Build the user-mode API page (x86: the vDSO). Needs the page allocator. }
procedure Hal_InitUserApi;

{ Allow interrupts on this CPU. }
procedure Hal_EnableInterrupts;

{ Platform authenticity gate; may block the boot until satisfied. }
procedure Hal_PlatformGate;

{ Has the firmware-table daemon told the kernel where the interrupt controllers
  are? Until it has, secondary cores cannot be started. }
function Hal_InterruptControllersKnown: Boolean;

{ Bring up the I/O interrupt controller and start every other CPU. }
procedure Hal_StartSecondaryCores;

{ ── Time ──────────────────────────────────────────────────────────────────── }

{ Monotonic tick counter since Hal_StartTimer, and its rate. }
function Hal_Ticks: QWord;
function Hal_TickFrequency: Cardinal;
function Hal_MsToTicks(ms: QWord): QWord;

{ Seconds since midnight of the battery-backed clock, and a human-readable
  print of the current date and time to the console. }
function Hal_WallClockSeconds: QWord;
procedure Hal_PrintWallClock;

{ ── Cores ─────────────────────────────────────────────────────────────────── }

{ True once more than the boot CPU's interrupt controller is live, i.e. once
  Hal_CurrentCoreId can return something other than 0. }
function Hal_MultiCoreActive: Boolean;

{ Id of the CPU executing this call (0 on the boot CPU, and always 0 before
  Hal_MultiCoreActive). Not range-checked: callers bound it themselves. }
function Hal_CurrentCoreId: Cardinal;

{ Stop every CPU except the caller, for good. Used on the way to power-off or
  reset and in panics, so nothing keeps running over the final output or a
  half-finished disk transfer. Does nothing before Hal_MultiCoreActive. }
procedure Hal_FreezeOtherCores;

{ ── Address spaces ────────────────────────────────────────────────────────── }

{ Handle of the kernel's own address space; every user space is a copy of it. }
function Hal_KernelAddressSpace: QWord;

{ Create a new user address space that already contains the kernel's own
  mappings (so syscalls and interrupts still work inside it). Returns 0 when
  out of memory. }
function Hal_CreateUserAddressSpace: QWord;

{ Release only the root structure of an address space nothing was mapped into
  yet (or whose pages the caller frees itself). For a load that failed half-way. }
procedure Hal_DiscardAddressSpaceRoot(space: QWord);

{ Physical address of the page of user-mode API stubs (the vDSO). Each process
  gets a private copy of it mapped at a randomised address. }
function Hal_UserApiPage: QWord;

{ Can this be a valid virtual address on this architecture? }
function Hal_IsCanonical(addr: QWord): Boolean;

{ Map one 4 KiB page into the address space `space` (not necessarily the
  loaded one). `perms` is HAL_MAP_*. }
procedure Hal_MapPageIn(phys, virt, perms: QWord; space: QWord);

{ The address space currently loaded on this core. }
function Hal_CurrentAddressSpace: QWord;

{ Is `space` a handle that could plausibly name an address space (non-zero,
  canonical, inside RAM)? Guards against corrupt thread records. }
function Hal_AddressSpaceValid(space: QWord): Boolean;

{ Make `space` the loaded address space (also flushes stale translations). }
procedure Hal_ActivateAddressSpace(space: QWord);

{ Free every page and table reachable from a user address space, then the
  root itself. The kernel space must never be passed. }
procedure Hal_DestroyAddressSpace(space: QWord);

{ ── Thread start frames ───────────────────────────────────────────────────── }
{ A new thread starts by being "returned into": the scheduler switches to the
  stack pointer these functions return, and the architecture's exception-return
  path pops the frame and jumps to `entry`. `kernelStackTop` is the (aligned)
  top of the thread's kernel stack. The frame is written just below it. }

{ A thread that runs in kernel mode with interrupts enabled. }
function Hal_BuildKernelFrame(kernelStackTop, entry: QWord): QWord;

{ A thread that starts in user mode at `entry` with `userStackTop`. `privileged`
  grants direct hardware I/O (x86: IOPL 3), for root daemons. }
function Hal_BuildUserFrame(kernelStackTop, entry, userStackTop: QWord;
  privileged: Boolean): QWord;

{ Are device interrupts currently enabled on this CPU? }
function Hal_InterruptsEnabled: Boolean;

{ ── Kernel stacks ─────────────────────────────────────────────────────────── }

{ Top of the stack the boot CPU enters the kernel on from user mode. }
function Hal_BootKernelStackTop: QWord;

{ Make `core` enter the kernel on `stackTop` the next time it leaves user mode
  (x86: the TSS ring-0 stack pointer). No-op for an unknown core. }
procedure Hal_SetKernelStack(core: Cardinal; stackTop: QWord);

implementation

uses arch_interface, apic, gdt, idt, vmm, vdso, pic, pit, pci, ioapic, smp,
  platform_bootstrap, hardware_checks, pmm, libc, rtc;

const
  { RegisterContext slots (u64 each) counted from the saved RSP. }
  CTX_R9  = 6;
  CTX_R8  = 7;
  CTX_RBX = 11;
  CTX_RDX = 12;
  CTX_RCX = 13;
  CTX_RAX = 14;


function Ctx_GetNumber(ctx: PQWord): QWord;
begin
  Ctx_GetNumber := ctx[CTX_RAX];
end;

function Ctx_GetArg(ctx: PQWord; i: Integer): QWord;
begin
  case i of
    0: Ctx_GetArg := ctx[CTX_RBX];
    1: Ctx_GetArg := ctx[CTX_RCX];
    2: Ctx_GetArg := ctx[CTX_RDX];
    3: Ctx_GetArg := ctx[CTX_R8];
    4: Ctx_GetArg := ctx[CTX_R9];
  else
    Ctx_GetArg := 0;
  end;
end;

procedure Ctx_SetRet(ctx: PQWord; v: QWord);
begin
  ctx[CTX_RAX] := v;
end;

procedure Ctx_SetRet2(ctx: PQWord; v: QWord);
begin
  ctx[CTX_RBX] := v;
end;

function HAL_GetTickCount: QWord; cdecl; external name 'HAL_GetTickCount';

function Hal_WallClockSeconds: QWord;
begin
  Hal_WallClockSeconds := RTC_GetSeconds;
end;

procedure Hal_PrintWallClock;
begin
  RTC_PrintCurrentTime;
end;

function Hal_MultiCoreActive: Boolean;
begin
  Hal_MultiCoreActive := Apic_IsAwake;
end;

procedure Hal_EarlyInit;
begin
  Platform_EarlySerial;
end;

procedure Hal_InitMemory(maxPhysicalAddr: QWord);
var
  addr: QWord;
begin
  Vmm_Init;
  { Everything above the first 2 MiB is identity-mapped with huge pages. }
  addr := 2097152;
  while addr < maxPhysicalAddr do
  begin
    Vmm_MapHugePage(addr, addr);
    Inc(addr, 2097152);
  end;
end;

procedure Hal_InitInterrupts;
var
  dummyIsr: Pointer;
  i: Integer;
begin
  Gdt_Init;
  Idt_Init;

  { Every vector from 32 up lands on a harmless yield stub until a real
    handler replaces it. }
  dummyIsr := Arch_GetIsrYield;
  for i := 32 to 255 do Idt_SetGate(i, dummyIsr);

  Idt_SetGateWithRing3(128, Arch_GetIsrSyscall);    { INT 0x80: syscalls }

  Idt_SetGate(0, Arch_GetIsrDiv0);
  Idt_SetGate(13, Arch_GetIsrGPF);
  Idt_SetGate(14, Arch_GetIsrPageFault);
  Idt_SetGate(32, Arch_GetIsrTimer);
  Platform_HookPs2IsrGates;
  Idt_SetGate(129, dummyIsr);                       { INT 0x81: yield }

  Pic_Remap;
  Pci_DisableAllBusMastering;

  Platform_DrainPs2Buffers;
  Pic_MaskAllIrqs;
end;

procedure Hal_StartTimer(hz: Cardinal);
begin
  Platform_InitLegacyTimer(hz);
end;

procedure Hal_InitUserApi;
begin
  Vdso_Init;
end;

procedure Hal_EnableInterrupts;
begin
  Arch_EnableInterrupts;
end;

procedure Hal_PlatformGate;
begin
  HwChecks_CheckHardwareError;
end;

function Hal_InterruptControllersKnown: Boolean;
begin
  Hal_InterruptControllersKnown := (Apic_GetIoApicBase <> 0) and (Apic_GetBaseVirt <> 0);
end;

procedure Hal_StartSecondaryCores;
begin
  Ioapic_Init;
  Smp_InitAndWakeCores;
end;

function Hal_Ticks: QWord;
begin
  Hal_Ticks := HAL_GetTickCount;
end;

function Hal_TickFrequency: Cardinal;
begin
  Hal_TickFrequency := Pit_GetFrequency;
end;

function Hal_MsToTicks(ms: QWord): QWord;
begin
  Hal_MsToTicks := Pit_MsToTicks(ms);
end;

procedure Hal_FreezeOtherCores;
begin
  if not Apic_IsAwake then Exit;
  { INIT IPI to all-excluding-self (not NMI: there is no IDT vector 2). The
    other cores drop into wait-for-SIPI and never come back. }
  Apic_Write($300, $000C4500);
end;

function Hal_CurrentCoreId: Cardinal;
begin
  if Apic_IsAwake then Hal_CurrentCoreId := Apic_Read($020) shr 24
  else Hal_CurrentCoreId := 0;
end;

function Hal_KernelAddressSpace: QWord;
begin
  Hal_KernelAddressSpace := QWord(Vmm_GetPml4);
end;

function Hal_IsCanonical(addr: QWord): Boolean;
begin
  Hal_IsCanonical := Vmm_IsCanonical(addr);
end;

procedure Hal_MapPageIn(phys, virt, perms: QWord; space: QWord);
begin
  Vmm_MapPageIn(phys, virt, perms, Pointer(space));
end;

function Hal_CurrentAddressSpace: QWord;
begin
  Hal_CurrentAddressSpace := Vmm_ReadCr3 and QWord($000FFFFFFFFFF000);
end;

function Hal_AddressSpaceValid(space: QWord): Boolean;
begin
  Hal_AddressSpaceValid := (space <> 0) and (space < Pmm_GetTotalPages * HAL_PAGE_SIZE)
    and Vmm_IsCanonical(space);
end;

procedure Hal_ActivateAddressSpace(space: QWord);
begin
  Arch_LoadPageTable(space);
end;

procedure Hal_DestroyAddressSpace(space: QWord);
begin
  Vmm_DestroyUserSpace(space);
end;

function Hal_CreateUserAddressSpace: QWord;
var
  root: Pointer;
begin
  root := Pmm_AllocatePage;
  if root = nil then
  begin
    Hal_CreateUserAddressSpace := 0;
    Exit;
  end;
  { The kernel PML4 is copied wholesale: every user space shares the kernel's
    top-level entries. Page 0 stays unmapped as the NULL-dereference trap. }
  MemCopy(root, Vmm_GetPml4, 4096);
  Hal_CreateUserAddressSpace := QWord(root);
end;

procedure Hal_DiscardAddressSpaceRoot(space: QWord);
begin
  Pmm_FreePage(Pointer(space));
end;

function Hal_UserApiPage: QWord;
begin
  Hal_UserApiPage := Vdso_GetPhysPage;
end;

function Hal_InterruptsEnabled: Boolean;
begin
  Hal_InterruptsEnabled := (Arch_GetFlags and $200) <> 0;
end;

procedure Push(var p: PQWord; v: QWord); inline;
begin
  Dec(p);
  p^ := v;
end;

{ IRETQ frame (SS, RSP, RFLAGS, CS, RIP) plus the 15 saved GP registers the
  ISR stubs pop. The 8-byte pad above SS makes RSP land on 8 (mod 16), what a
  compiled prologue expects after a CALL; a movaps as first SSE op faults
  otherwise. }
function Hal_BuildKernelFrame(kernelStackTop, entry: QWord): QWord;
var
  p: PQWord;
  rsp0: QWord;
  i: Integer;
begin
  p := PQWord(kernelStackTop);
  Push(p, 0);
  rsp0 := QWord(p);
  Push(p, Arch_GetSS);
  Push(p, rsp0);
  Push(p, $202);
  Push(p, Arch_GetCS);
  Push(p, entry);
  for i := 1 to 15 do Push(p, 0);
  Hal_BuildKernelFrame := QWord(p);
end;

function Hal_BuildUserFrame(kernelStackTop, entry, userStackTop: QWord;
  privileged: Boolean): QWord;
var
  p: PQWord;
  rflags: QWord;
  i: Integer;
begin
  rflags := $202;
  { IOPL=3 lets a root daemon reach IN/OUT through the vDSO without an IOPB. }
  if privileged then rflags := $3202;
  p := PQWord(kernelStackTop);
  Push(p, 0);
  Push(p, $1B);
  Push(p, userStackTop);
  Push(p, rflags);
  Push(p, $23);
  Push(p, entry);
  for i := 1 to 15 do Push(p, 0);
  Hal_BuildUserFrame := QWord(p);
end;

function Hal_BootKernelStackTop: QWord;
begin
  Hal_BootKernelStackTop := Gdt_GetTssRsp0;
end;

procedure Hal_SetKernelStack(core: Cardinal; stackTop: QWord);
var
  tss: Pointer;
begin
  if core = 0 then tss := Gdt_GetTss
  else tss := Gdt_GetCoreTss(core);
  { Rsp0 sits at byte offset 4 of the TSS (a 4-byte reserved field first). }
  if tss <> nil then PQWord(PByte(tss) + 4)^ := stackTop;
end;

end.
