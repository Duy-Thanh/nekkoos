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
  HAL_MAP_KERNEL_RW = QWord(1);     { kernel read/write, never executable }
  HAL_MAP_USER_RW   = QWord(2);     { user read/write/execute }
  HAL_MAP_USER_RO   = QWord(3);     { user read-only }
  HAL_MAP_USER_GUARD = QWord(4);    { user, NOT present: a guard page }
  HAL_MAP_USER_DEVICE = QWord(5);  { user read/write device memory (MMIO), never executable }
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

{ Remove the 4 KiB mapping of `virt` in `space` and return the frame it mapped
  (0 if there was none). The caller owns that frame's reference and must
  release it with Pmm_FreePage. }
function Hal_UnmapPage(space, virt: QWord): QWord;

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

{ Is `virt` mapped in `space` as a page user mode may access? Used to vet
  pointers handed to the kernel by user programs. }
function Hal_IsUserPageMapped(space, virt: QWord): Boolean;

{ Name of this architecture as `uname` prints it (UTF-16, static). }
function Hal_ArchName: PWord;

{ Does this architecture have x86-style I/O ports (IN/OUT)? Code that drives
  legacy PC hardware directly (the kernel's IDE fallback) checks this first;
  on ARM64 a port access would stop the machine. }
function Hal_HasPortIo: Boolean;

{ ── User images ───────────────────────────────────────────────────────────── }

{ ELF e_machine value of this architecture's user programs (x86_64: 62,
  AArch64: 183). }
function Hal_ElfMachine: Word;

{ PE Machine value of this architecture's PE programs, or 0 when it runs none. }
function Hal_PeMachine: Word;

{ Lowest virtual address user mappings may use; below it the kernel owns the
  address space. }
function Hal_UserVaMin: QWord;

{ One past the highest address user mappings may use. }
function Hal_UserVaMax: QWord;

{ Make freshly written code at [addr, addr+len) visible to instruction fetch
  (ARM64 needs data-cache clean + instruction-cache invalidate; x86 is coherent). }
procedure Hal_SyncCode(addr, len: QWord);

{ ── Kernel stacks ─────────────────────────────────────────────────────────── }

{ Top of the stack the boot CPU enters the kernel on from user mode. }
function Hal_BootKernelStackTop: QWord;

{ Make `core` enter the kernel on `stackTop` the next time it leaves user mode
  (x86: the TSS ring-0 stack pointer). No-op for an unknown core. }
procedure Hal_SetKernelStack(core: Cardinal; stackTop: QWord);

{ ARM64-only, for bring-up tests: timer interrupts taken so far. }
function Arm64_TimerInterrupts: QWord;

{ Interrupt controller steps for the trap handlers (traps_arm64.pas):
  acknowledge returns the raw IAR (interrupt id in the low 10 bits), end signals
  completion, timer tick counts and re-arms the scheduler timer. }
const
  ARM64_TIMER_INTID = 30;
function Arm64_IrqAcknowledge: Cardinal;
procedure Arm64_IrqEnd(iar: Cardinal);
procedure Arm64_TimerTick;

const
  ARM64_UART_INTID = 33;   { PL011 on QEMU virt: SPI 1 }
{ Next byte the UART received, if any. Called from the UART interrupt. }
function Arm64_UartReadByte(out b: Byte): Boolean;
procedure Arm64_UartClearInterrupt;

implementation

uses arch_interface, pmm, terminal;

const
  UART_BASE = QWord($09000000);
  UART_FR   = $18;
  UART_FR_TXFF = $20;
  UART_FR_RXFE = $10;
  UART_IMSC = $038;
  UART_ICR  = $044;
  UART_RXIM = $10;
  UART_RTIM = $40;

  { Saved register frame, in QWords from the frame pointer: x0..x30 at 0..30.
    Syscall number in x8, arguments x0..x4, results x0 and x1. }
  CTX_X8 = 8;

  TICK_HZ = 250;

  GICD_BASE = QWord($08000000);
  GICD_CTLR = $000;
  GICD_ISENABLER0 = $100;
  GICC_BASE = QWord($08010000);
  GICC_CTLR = $000;
  GICC_PMR  = $004;
  GICC_IAR  = $00C;
  GICC_EOIR = $010;
  TIMER_INTID = 30;      { EL1 physical timer, a private peripheral interrupt }

  { Translation tables: 4 KiB granule, 48-bit VA, TTBR0 only. }
  PTE_VALID = QWord(1);
  PTE_TABLE = QWord(3);              { bits[1:0] = 11 at levels 0..2 }
  PTE_BLOCK = QWord(1);              { bits[1:0] = 01 at levels 1..2 }
  PTE_AF    = QWord(1) shl 10;
  PTE_SH_INNER = QWord(3) shl 8;
  PTE_ATTR_DEVICE = QWord(0) shl 2;  { MAIR index 0 }
  PTE_ATTR_NORMAL = QWord(1) shl 2;  { MAIR index 1 }
  PTE_XN    = (QWord(1) shl 53) or (QWord(1) shl 54);
  PTE_PXN   = QWord(1) shl 53;
  PTE_PAGE  = QWord(3);              { bits[1:0] = 11 at level 3 }
  PTE_AP_EL0 = QWord(1) shl 6;       { AP[1]: EL0 may access }
  PTE_AP_RO  = QWord(1) shl 7;       { AP[2]: read-only }
  PTE_GUARD  = QWord(1) shl 55;      { software bit on an invalid entry }
  ADDR_MASK  = QWord($0000FFFFFFFFF000);
  MAIR_VALUE = QWord($FF00);         { idx0 Device-nGnRnE, idx1 Normal write-back }
  { T0SZ=16, IRGN0/ORGN0 write-back, inner shareable, 4K granule, 40-bit PA,
    TTBR1 walks disabled. }
  TCR_VALUE = QWord(16) or (QWord(1) shl 8) or (QWord(1) shl 10) or
              (QWord(3) shl 12) or (QWord(2) shl 32) or (QWord(1) shl 23);
  GIB = QWord($40000000);

var
  BootStackTop: Byte; external name '__stack_top';
  KernelRoot: QWord;
  BootCounter: QWord;
  TimerInterval: QWord;
  IrqTicks: QWord;

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

function NewTable: PQWord;
var
  t: PQWord;
  i: Integer;
begin
  t := PQWord(Pmm_AllocatePage);
  if t = nil then Unimplemented('page table allocation (out of memory)');
  for i := 0 to 511 do t[i] := 0;
  NewTable := t;
end;

{ Identity-map [0, maxPhysicalAddr) with 1 GiB blocks: the first GiB (UART,
  GIC, ...) as device memory, the rest as normal cacheable RAM. User spaces
  later live above this, so the kernel never shares a GiB slot with them. }
procedure Hal_InitMemory(maxPhysicalAddr: QWord);
var
  l0, l1: PQWord;
  slot, slots: QWord;
begin
  l0 := NewTable;
  l1 := NewTable;
  l0[0] := QWord(l1) or PTE_TABLE;
  slots := (maxPhysicalAddr + GIB - 1) div GIB;
  if slots < 2 then slots := 2;
  for slot := 0 to slots - 1 do
    if slot = 0 then
      l1[slot] := (slot * GIB) or PTE_BLOCK or PTE_AF or PTE_ATTR_DEVICE or PTE_XN
    else
      l1[slot] := (slot * GIB) or PTE_BLOCK or PTE_AF or PTE_SH_INNER or PTE_ATTR_NORMAL;
  KernelRoot := QWord(l0);
  Arch_EnableMmu(KernelRoot, MAIR_VALUE, TCR_VALUE);
end;

procedure Hal_InitInterrupts;
begin
  Arch_InstallVectors;
  { GICv2 on QEMU virt: distributor 0x08000000, CPU interface 0x08010000. }
  Arch_WriteMmio32(GICD_BASE + GICD_CTLR, 0);
  { Enable the EL1 physical timer PPI (INTID 30) in the banked ISENABLER0. }
  Arch_WriteMmio32(GICD_BASE + GICD_ISENABLER0, Cardinal(1) shl TIMER_INTID);
  { UART receive interrupt: enable SPI 33, route it to CPU 0 (ITARGETSR byte
    33 = bit 0), then unmask receive and receive-timeout in the PL011. }
  Arch_WriteMmio32(GICD_BASE + GICD_ISENABLER0 + 4, Cardinal(1) shl (ARM64_UART_INTID - 32));
  Arch_WriteMmio32(GICD_BASE + $800 + 32,
    Arch_ReadMmio32(GICD_BASE + $800 + 32) or (Cardinal(1) shl 8));
  Arch_WriteMmio32(UART_BASE + UART_ICR, $7FF);
  Arch_WriteMmio32(UART_BASE + UART_IMSC, UART_RXIM or UART_RTIM);
  Arch_WriteMmio32(GICD_BASE + GICD_CTLR, 1);
  Arch_WriteMmio32(GICC_BASE + GICC_PMR, $FF);
  Arch_WriteMmio32(GICC_BASE + GICC_CTLR, 1);
end;

procedure Hal_StartTimer(hz: Cardinal);
begin
  TimerInterval := Arch_ReadCounterFrequency div hz;
  Arch_TimerProgram(TimerInterval);
end;

function Arm64_TimerInterrupts: QWord;
begin
  Arm64_TimerInterrupts := IrqTicks;
end;

function Arm64_IrqAcknowledge: Cardinal;
begin
  Arm64_IrqAcknowledge := Arch_ReadMmio32(GICC_BASE + GICC_IAR);
end;

procedure Arm64_IrqEnd(iar: Cardinal);
begin
  if (iar and $3FF) < 1020 then Arch_WriteMmio32(GICC_BASE + GICC_EOIR, iar);
end;

function Arm64_UartReadByte(out b: Byte): Boolean;
begin
  b := 0;
  Arm64_UartReadByte := (Arch_ReadMmio32(UART_BASE + UART_FR) and UART_FR_RXFE) = 0;
  if Arm64_UartReadByte then b := Byte(Arch_ReadMmio32(UART_BASE) and $FF);
end;

procedure Arm64_UartClearInterrupt;
begin
  Arch_WriteMmio32(UART_BASE + UART_ICR, UART_RXIM or UART_RTIM);
end;

procedure Arm64_TimerTick;
begin
  Inc(IrqTicks);
  Arch_TimerRearm(TimerInterval);
end;

procedure PutHex(v: QWord);
var
  i: Integer;
  d: Byte;
begin
  for i := 15 downto 0 do
  begin
    d := (v shr (i * 4)) and $F;
    if d < 10 then UartPutc(Ord('0') + d) else UartPutc(Ord('a') + d - 10);
  end;
end;

{ Any exception we do not handle: report and stop. }
procedure Arm64Fault(esr, elr, far: QWord); cdecl; public name 'Arm64Fault';
begin
  UartPuts(#10'arm64: FATAL exception  ESR=');
  PutHex(esr);
  UartPuts(' ELR=');
  PutHex(elr);
  UartPuts(' FAR=');
  PutHex(far);
  UartPuts(#10);
  while True do Arch_Halt;
end;

procedure Hal_InitUserApi;
begin
  { No user mode yet, so no user API page to build. Hal_UserApiPage stops the
    machine if anything asks for one before EL0 support exists. }
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

function HAL_GetTickCount: QWord; cdecl; public name 'HAL_GetTickCount';
begin
  HAL_GetTickCount := Hal_Ticks;
end;

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

const
  RtcLabel: array[0..23] of Word = (91, 42, 93, 32, 72, 97, 114, 100, 119, 97, 114, 101, 32, 82, 84, 67, 32, 84, 105, 109, 101, 58, 32, 0);

{ PL031 real-time clock at 0x09010000: RTCDR is seconds since 1970-01-01 UTC. }
const
  RTC_BASE = QWord($09010000);
  TZ_HOURS = 7;                       { same GMT+7 the x86 CMOS reader applies }

function Hal_WallClockSeconds: QWord;
begin
  { x86 returns the RTC's seconds field (0-59); keep that meaning. }
  Hal_WallClockSeconds := QWord(Arch_ReadMmio32(RTC_BASE)) mod 60;
end;

procedure PrintTwo(v: QWord);
begin
  if v < 10 then Terminal_DrawChar_Pas(Ord('0'));
  Terminal_PrintDec_Pas(v);
end;

{ Same format as the x86 CMOS reader: "dd/mm/yyyy  hh:mm:ss". }
procedure Hal_PrintWallClock;
var
  t, days, secs, y, m, d, era, doe, yoe, doy, mp: QWord;
  z: Int64;
begin
  t := QWord(Arch_ReadMmio32(RTC_BASE)) + TZ_HOURS * 3600;
  days := t div 86400;
  secs := t mod 86400;
  { Civil date from days since 1970-01-01 (Howard Hinnant's algorithm). }
  z := Int64(days) + 719468;
  era := QWord(z div 146097);
  doe := QWord(z - Int64(era) * 146097);
  yoe := (doe - doe div 1460 + doe div 36524 - doe div 146096) div 365;
  y := yoe + era * 400;
  doy := doe - (365 * yoe + yoe div 4 - yoe div 100);
  mp := (5 * doy + 2) div 153;
  d := doy - (153 * mp + 2) div 5 + 1;
  if mp < 10 then m := mp + 3 else m := mp - 9;
  if m <= 2 then Inc(y);
  Terminal_Print_Pas(PWord(@RtcLabel[0]));
  PrintTwo(d);  Terminal_DrawChar_Pas(Ord('/'));
  PrintTwo(m);  Terminal_DrawChar_Pas(Ord('/'));
  Terminal_PrintDec_Pas(y);
  Terminal_DrawChar_Pas(Ord(' '));  Terminal_DrawChar_Pas(Ord(' '));
  PrintTwo(secs div 3600);  Terminal_DrawChar_Pas(Ord(':'));
  PrintTwo((secs div 60) mod 60);  Terminal_DrawChar_Pas(Ord(':'));
  PrintTwo(secs mod 60);
  Terminal_DrawChar_Pas(10);
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
  Hal_KernelAddressSpace := KernelRoot;
end;

function Hal_CreateUserAddressSpace: QWord;
var
  l0, l1, kl1: PQWord;
  i: Integer;
begin
  Hal_CreateUserAddressSpace := 0;
  l0 := PQWord(Pmm_AllocatePage);
  if l0 = nil then Exit;
  l1 := PQWord(Pmm_AllocatePage);
  if l1 = nil then begin Pmm_FreePage(l0); Exit; end;
  { Page 0 of the user space shares the kernel's 1 GiB blocks (copied, so a
    user mapping in another slot never touches the kernel's own table). }
  kl1 := PQWord(PQWord(KernelRoot)[0] and ADDR_MASK);
  for i := 0 to 511 do l1[i] := kl1[i];
  for i := 0 to 511 do l0[i] := 0;
  l0[0] := QWord(l1) or PTE_TABLE;
  Hal_CreateUserAddressSpace := QWord(l0);
end;

procedure Hal_DiscardAddressSpaceRoot(space: QWord);
var
  l0: PQWord;
begin
  if (space = 0) or (space = KernelRoot) then Exit;
  l0 := PQWord(space);
  if (l0[0] and PTE_VALID) <> 0 then Pmm_FreePage(Pointer(l0[0] and ADDR_MASK));
  Pmm_FreePage(l0);
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

{ Table at `entry`, allocating it when absent. nil if the slot holds a block. }
function TableAt(var entry: QWord): PQWord;
var
  t: PQWord;
begin
  if (entry and PTE_VALID) = 0 then
  begin
    t := PQWord(Pmm_AllocatePage);
    if t = nil then begin TableAt := nil; Exit; end;
    entry := QWord(t) or PTE_TABLE;
  end
  else if (entry and 3) <> 3 then
  begin
    TableAt := nil;
    Exit;
  end;
  TableAt := PQWord(entry and ADDR_MASK);
end;

procedure Hal_MapPageIn(phys, virt, perms: QWord; space: QWord);
var
  l0, l1, l2, l3: PQWord;
  pte: QWord;
begin
  if (space = 0) or not Hal_IsCanonical(virt) then Exit;
  l0 := PQWord(space);
  l1 := TableAt(l0[(virt shr 39) and 511]);
  if l1 = nil then Exit;
  l2 := TableAt(l1[(virt shr 30) and 511]);
  if l2 = nil then Unimplemented('Hal_MapPageIn into a kernel-owned 1 GiB block');
  l3 := TableAt(l2[(virt shr 21) and 511]);
  if l3 = nil then Exit;
  pte := (phys and ADDR_MASK) or PTE_PAGE or PTE_AF or PTE_SH_INNER or PTE_ATTR_NORMAL;
  case perms of
    HAL_MAP_KERNEL_RW: pte := pte or PTE_XN;
    HAL_MAP_USER_RW:   pte := pte or PTE_AP_EL0 or PTE_PXN;
    HAL_MAP_USER_RO:   pte := pte or PTE_AP_EL0 or PTE_AP_RO or PTE_PXN;
    HAL_MAP_USER_DEVICE:
      { Device-nGnRnE, not shareable-cacheable: MMIO must never be cached. }
      pte := (phys and ADDR_MASK) or PTE_PAGE or PTE_AF or PTE_ATTR_DEVICE or
             PTE_AP_EL0 or PTE_XN;
  else
    pte := PTE_GUARD;
  end;
  l3[(virt shr 12) and 511] := pte;
  Arch_FlushTLB;
end;

function Hal_UnmapPage(space, virt: QWord): QWord;
var
  l1, l2, l3: PQWord;
  e: QWord;
begin
  Hal_UnmapPage := 0;
  if (not Hal_AddressSpaceValid(space)) or (virt < Hal_UserVaMin) or
     (not Hal_IsCanonical(virt)) then Exit;
  e := PQWord(space)[(virt shr 39) and 511];
  if (e and 3) <> 3 then Exit;
  l1 := PQWord(e and ADDR_MASK);
  e := l1[(virt shr 30) and 511];
  if (e and 3) <> 3 then Exit;
  l2 := PQWord(e and ADDR_MASK);
  e := l2[(virt shr 21) and 511];
  if (e and 3) <> 3 then Exit;
  l3 := PQWord(e and ADDR_MASK);
  e := l3[(virt shr 12) and 511];
  if (e and 3) <> 3 then Exit;
  Hal_UnmapPage := e and ADDR_MASK;
  l3[(virt shr 12) and 511] := 0;
  { Single-threaded process: only this core can hold the translation. }
  Arch_FlushTLB;
end;

function Hal_CurrentAddressSpace: QWord;
begin
  Hal_CurrentAddressSpace := Arch_ReadPageTable;
end;

function Hal_AddressSpaceValid(space: QWord): Boolean;
begin
  Hal_AddressSpaceValid := (space <> 0) and (space < Pmm_GetTotalPages * HAL_PAGE_SIZE)
    and Hal_IsCanonical(space);
end;

procedure Hal_ActivateAddressSpace(space: QWord);
begin
  Arch_LoadPageTable(space);
end;

{ Free the tables below `table` (level 1 or 2), and at level 3 the pages too. }
procedure FreeTree(table: PQWord; level: Integer);
var
  i: Integer;
  e: QWord;
begin
  for i := 0 to 511 do
  begin
    e := table[i];
    if (e and PTE_VALID) = 0 then Continue;
    if level = 3 then
      Pmm_FreePage(Pointer(e and ADDR_MASK))     { reference counted, see pmm }
    else if (e and 3) = 3 then
      FreeTree(PQWord(e and ADDR_MASK), level + 1);
  end;
  Pmm_FreePage(table);
end;

procedure Hal_DestroyAddressSpace(space: QWord);
var
  l0, l1: PQWord;
  i, slot: Integer;
  e: QWord;
begin
  if (space = 0) or (space = KernelRoot) or (space = Hal_CurrentAddressSpace) then Exit;
  l0 := PQWord(space);
  { Every L0 slot can hold user mappings (stacks and images live far apart, in
    different slots). Slot 0 also carries the copy of the kernel's L1, whose
    1 GiB blocks are shared and must stay; tables below a block-free L1 entry
    are freed. }
  for slot := 0 to 511 do
  begin
    if (l0[slot] and 3) <> 3 then Continue;
    l1 := PQWord(l0[slot] and ADDR_MASK);
    for i := 0 to 511 do
    begin
      e := l1[i];
      if (e and 3) = 3 then FreeTree(PQWord(e and ADDR_MASK), 2);
    end;
    Pmm_FreePage(l1);
  end;
  Pmm_FreePage(l0);
end;

{ ── Kernel stacks ────────────────────────────────────────────────────────── }

function Hal_InterruptsEnabled: Boolean;
begin
  Hal_InterruptsEnabled := Arch_InterruptsEnabled <> 0;
end;

{ Trap frame layout, see SAVE_FRAME in hardware_arm64.S: x0..x30, SP_EL0, ELR,
  SPSR (QWord indexes 0..33, 36 reserved so the frame is 288 bytes). }
const
  FRAME_QWORDS = 36;
  FRAME_SP_EL0 = 31;
  FRAME_ELR    = 32;
  FRAME_SPSR   = 33;
  SPSR_EL1H    = QWord($5);     { EL1 using SP_EL1, DAIF clear: IRQs on }
  SPSR_EL0T    = QWord($0);     { EL0, IRQs on }

function BuildFrame(kernelStackTop, entry, userSp, spsr: QWord): QWord;
var
  f: PQWord;
  i: Integer;
begin
  f := PQWord(kernelStackTop - FRAME_QWORDS * 8);
  for i := 0 to FRAME_QWORDS - 1 do f[i] := 0;
  f[FRAME_SP_EL0] := userSp;
  f[FRAME_ELR]    := entry;
  f[FRAME_SPSR]   := spsr;
  BuildFrame := QWord(f);
end;

function Hal_BuildKernelFrame(kernelStackTop, entry: QWord): QWord;
begin
  Hal_BuildKernelFrame := BuildFrame(kernelStackTop and not QWord(15), entry, 0, SPSR_EL1H);
end;

function Hal_BuildUserFrame(kernelStackTop, entry, userStackTop: QWord;
  privileged: Boolean): QWord;
begin
  { `privileged` has no ARM64 meaning: there is no port I/O to grant. }
  Hal_BuildUserFrame := BuildFrame(kernelStackTop and not QWord(15), entry,
    userStackTop and not QWord(15), SPSR_EL0T);
end;

function Hal_IsUserPageMapped(space, virt: QWord): Boolean;
var
  l1, l2, l3: PQWord;
  e: QWord;
begin
  Hal_IsUserPageMapped := False;
  if (not Hal_AddressSpaceValid(space)) or (virt < Hal_UserVaMin) or
     (not Hal_IsCanonical(virt)) then Exit;
  e := PQWord(space)[(virt shr 39) and 511];
  if (e and 3) <> 3 then Exit;
  l1 := PQWord(e and ADDR_MASK);
  e := l1[(virt shr 30) and 511];
  if (e and 3) <> 3 then Exit;
  l2 := PQWord(e and ADDR_MASK);
  e := l2[(virt shr 21) and 511];
  if (e and 3) <> 3 then Exit;
  l3 := PQWord(e and ADDR_MASK);
  e := l3[(virt shr 12) and 511];
  Hal_IsUserPageMapped := ((e and 3) = 3) and ((e and PTE_AP_EL0) <> 0);
end;

const
  ArchNameStr: array[0..7] of Word = (Ord('a'), Ord('a'), Ord('r'), Ord('c'), Ord('h'), Ord('6'), Ord('4'), 0);

function Hal_ArchName: PWord;
begin
  Hal_ArchName := @ArchNameStr[0];
end;

function Hal_HasPortIo: Boolean;
begin
  Hal_HasPortIo := False;
end;

function Hal_UserVaMax: QWord;
begin
  Hal_UserVaMax := QWord($0000800000000000);
end;

function Hal_PeMachine: Word;
begin
  Hal_PeMachine := 0;   { no PE programs on this architecture }
end;

function Hal_ElfMachine: Word;
begin
  Hal_ElfMachine := 183;
end;

function Hal_UserVaMin: QWord;
begin
  { The kernel's identity map owns the low 1 GiB blocks; users start at 4 GiB. }
  Hal_UserVaMin := QWord($100000000);
end;

procedure Hal_SyncCode(addr, len: QWord);
begin
  Arch_SyncCode(addr, len);
end;

function Hal_BootKernelStackTop: QWord;
begin
  Hal_BootKernelStackTop := QWord(@BootStackTop);
end;

procedure Hal_SetKernelStack(core: Cardinal; stackTop: QWord);
begin
  { Nothing to do: on ARM64 an exception from EL0 simply continues on SP_EL1,
    which is wherever the frame pop left it (the thread's kernel stack top). }
end;

end.
