{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: arch_hal (ARM64, QEMU "virt") - first bring-up.

  Same interface as src/arch/x86_64/arch_hal.pas; read the contract there.
  Platform constants are those of QEMU's virt machine: PL011 UART at
  0x09000000, GICv2 at 0x08000000, ARM generic timer.

  STATUS: only the parts below are real. Everything marked UNIMPLEMENTED
  stops the machine with a message on the UART rather than pretending to
  succeed, so a half-ported kernel fails loudly instead of corrupting memory.
    real:          UART diagnostics, ticks (CNTPCT), core id (MPIDR),
                   syscall frame accessors, canonical-address test
    UNIMPLEMENTED: MMU / address spaces, GIC + timer interrupts, user API
                   page, secondary cores (PSCI), kernel stacks
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

{ Make diagnostics possible at all (x86: COM1, arm64: PL011). Must run before any output. }
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

{ ── Kernel stacks ─────────────────────────────────────────────────────────── }

{ Top of the stack the boot CPU enters the kernel on from user mode. }
function Hal_BootKernelStackTop: QWord;

{ Make `core` enter the kernel on `stackTop` the next time it leaves user mode
  (x86: the TSS ring-0 stack pointer). No-op for an unknown core. }
procedure Hal_SetKernelStack(core: Cardinal; stackTop: QWord);

implementation

uses arch_interface;

const
  UART_BASE = QWord($09000000);
  UART_FR   = $18;
  UART_FR_TXFF = $20;

  { Saved register frame, in QWords from the frame pointer: x0..x30 at 0..30.
    Syscall number in x8, arguments x0..x4, results x0 and x1. }
  CTX_X8 = 8;

  TICK_HZ = 250;

var
  BootCounter: QWord;

procedure UartPutc(c: Byte);
begin
  while (Arch_ReadMmio32(UART_BASE + UART_FR) and UART_FR_TXFF) <> 0 do ;
  Arch_WriteMmio32(UART_BASE, c);
end;

procedure UartPuts(s: PChar);
begin
  while s^ <> #0 do
  begin
    if s^ = #10 then UartPutc(13);
    UartPutc(Ord(s^));
    Inc(s);
  end;
end;

{ A contract function this port has not written yet. Never returns. }
procedure Unimplemented(what: PChar);
begin
  UartPuts('arm64 arch_hal: UNIMPLEMENTED ');
  UartPuts(what);
  UartPuts(#10);
  while True do Arch_Halt;
end;

{ ── Syscall register frame ───────────────────────────────────────────────── }

function Ctx_GetNumber(ctx: PQWord): QWord;
begin
  Ctx_GetNumber := ctx[CTX_X8];
end;

function Ctx_GetArg(ctx: PQWord; i: Integer): QWord;
begin
  if (i >= 0) and (i <= 4) then Ctx_GetArg := ctx[i]
  else Ctx_GetArg := 0;
end;

procedure Ctx_SetRet(ctx: PQWord; v: QWord);
begin
  ctx[0] := v;
end;

procedure Ctx_SetRet2(ctx: PQWord; v: QWord);
begin
  ctx[1] := v;
end;

{ ── Boot sequence ────────────────────────────────────────────────────────── }

procedure Hal_EarlyInit;
begin
  { The PL011 is already usable with QEMU's defaults. }
  BootCounter := Arch_ReadTimestamp;
  UartPuts('NekkoOS arm64: early init'#10);
end;

procedure Hal_InitMemory(maxPhysicalAddr: QWord);
begin
  Unimplemented('Hal_InitMemory (MMU)');
end;

procedure Hal_InitInterrupts;
begin
  Unimplemented('Hal_InitInterrupts (GIC, exception vectors)');
end;

procedure Hal_StartTimer(hz: Cardinal);
begin
  Unimplemented('Hal_StartTimer (generic timer interrupt)');
end;

procedure Hal_InitUserApi;
begin
  Unimplemented('Hal_InitUserApi');
end;

procedure Hal_EnableInterrupts;
begin
  Arch_EnableInterrupts;
end;

procedure Hal_PlatformGate;
begin
  { No firmware authenticity gate on this platform yet. }
end;

function Hal_InterruptControllersKnown: Boolean;
begin
  Hal_InterruptControllersKnown := False;
end;

procedure Hal_StartSecondaryCores;
begin
  Unimplemented('Hal_StartSecondaryCores (PSCI CPU_ON)');
end;

{ ── Time ─────────────────────────────────────────────────────────────────── }

function Hal_Ticks: QWord;
var
  f, d: QWord;
begin
  f := Arch_ReadCounterFrequency;
  if f = 0 then begin Hal_Ticks := 0; Exit; end;
  d := Arch_ReadTimestamp - BootCounter;
  Hal_Ticks := (d div f) * TICK_HZ + ((d mod f) * TICK_HZ) div f;
end;

function Hal_TickFrequency: Cardinal;
begin
  Hal_TickFrequency := TICK_HZ;
end;

function Hal_MsToTicks(ms: QWord): QWord;
var
  t: QWord;
begin
  t := (ms * TICK_HZ + 999) div 1000;
  if t = 0 then t := 1;
  Hal_MsToTicks := t;
end;

{ ── Cores ────────────────────────────────────────────────────────────────── }

function Hal_WallClockSeconds: QWord;
begin
  Unimplemented('Hal_WallClockSeconds (PL031 RTC)');
  Hal_WallClockSeconds := 0;
end;

procedure Hal_PrintWallClock;
begin
  Unimplemented('Hal_PrintWallClock (PL031 RTC)');
end;

function Hal_MultiCoreActive: Boolean;
begin
  Hal_MultiCoreActive := False;
end;

function Hal_CurrentCoreId: Cardinal;
begin
  Hal_CurrentCoreId := Cardinal(Arch_ReadCpuId and $FF);
end;

procedure Hal_FreezeOtherCores;
begin
  { Single core until PSCI bring-up exists: nothing else is running. }
end;

{ ── Address spaces ───────────────────────────────────────────────────────── }

function Hal_KernelAddressSpace: QWord;
begin
  Unimplemented('Hal_KernelAddressSpace');
  Hal_KernelAddressSpace := 0;
end;

function Hal_CreateUserAddressSpace: QWord;
begin
  Unimplemented('Hal_CreateUserAddressSpace');
  Hal_CreateUserAddressSpace := 0;
end;

procedure Hal_DiscardAddressSpaceRoot(space: QWord);
begin
  Unimplemented('Hal_DiscardAddressSpaceRoot');
end;

function Hal_UserApiPage: QWord;
begin
  Unimplemented('Hal_UserApiPage');
  Hal_UserApiPage := 0;
end;

function Hal_IsCanonical(addr: QWord): Boolean;
var
  top: QWord;
begin
  { 48-bit VA: bits 63..47 must all be equal. }
  top := addr shr 47;
  Hal_IsCanonical := (top = 0) or (top = QWord($1FFFF));
end;

procedure Hal_MapPageIn(phys, virt, perms: QWord; space: QWord);
begin
  Unimplemented('Hal_MapPageIn');
end;

function Hal_CurrentAddressSpace: QWord;
begin
  Unimplemented('Hal_CurrentAddressSpace');
  Hal_CurrentAddressSpace := 0;
end;

function Hal_AddressSpaceValid(space: QWord): Boolean;
begin
  Hal_AddressSpaceValid := (space <> 0) and Hal_IsCanonical(space);
end;

procedure Hal_ActivateAddressSpace(space: QWord);
begin
  Unimplemented('Hal_ActivateAddressSpace');
end;

procedure Hal_DestroyAddressSpace(space: QWord);
begin
  Unimplemented('Hal_DestroyAddressSpace');
end;

{ ── Kernel stacks ────────────────────────────────────────────────────────── }

function Hal_BootKernelStackTop: QWord;
begin
  Unimplemented('Hal_BootKernelStackTop');
  Hal_BootKernelStackTop := 0;
end;

procedure Hal_SetKernelStack(core: Cardinal; stackTop: QWord);
begin
  Unimplemented('Hal_SetKernelStack');
end;

end.
