{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: apic - Local APIC driver, calibration, and EOI/IPI dispatch.
  PORTED FROM: src/arch/x86_64/APIC.cs (deleted).

  x86_64 ONLY. Every address below is the Local APIC MMIO window; a new
  architecture replaces this unit and the IOAPIC one wholesale.

  MMIO ACCESS DISCIPLINE
  The Local APIC registers are NOT cacheable and the silicon requires strict
  ordering: a read must not be hoisted before a preceding write, and a write
  (EOI, timer count) must be visible immediately rather than sitting in the
  store buffer. Hence LoadFence after every read and FullFence after every
  write - a missing fence here produces interrupts that are silently lost.

  DEPENDENCY NOTE
  Initialisation must map the APIC window into every live thread's address
  space, so it walks the thread table - but the scheduler already calls back
  into this unit. The thread table pointer and the scheduler lock are
  therefore published through kstate, which both sides may read.
  =========================================================================
}

unit apic;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ --- State --- }
function Apic_GetBaseVirt: QWord;
function Apic_IsAwake: Boolean;
procedure Apic_SetIsAwake(v: Boolean);
function Apic_GetCoreCount: Cardinal;
procedure Apic_SetCoreCount(c: Cardinal);
function Apic_GetIoApicBase: QWord;
procedure Apic_SetIoApicBase(b: QWord);
function Apic_GetCalibratedTicksPerQuantum: Cardinal;

{ --- Register access --- }
procedure Apic_Write(offset: Cardinal; value: Cardinal);
function  Apic_Read(offset: Cardinal): Cardinal;

{ --- Control --- }
procedure Apic_Init(physAddress: QWord);
procedure Apic_SendEOI;
procedure Apic_SendIpi(targetCore: Cardinal; vector: Byte);
procedure Apic_BroadcastIpi(vector: Byte);

implementation

uses arch_interface, vmm, pmm, kstate, io, terminal, kstring, pic, pit, timer_impl, serial;

{ HAL interrupt-controller entry points (src/arch/x86_64/interrupt_impl.pas). }
procedure HAL_SetLocalApicBase(base: QWord); cdecl; external name 'HAL_SetLocalApicBase';
procedure HAL_InitInterruptController; cdecl; external name 'HAL_InitInterruptController';
procedure HAL_SendEOI(vector: Byte); cdecl; external name 'HAL_SendEOI';
procedure HAL_SendIPI(targetCore: Cardinal; vector: Byte); cdecl; external name 'HAL_SendIPI';
procedure HAL_BroadcastIPI(vector: Byte); cdecl; external name 'HAL_BroadcastIPI';

{ HAL timer entry points (src/arch/x86_64/timer_impl.pas). }
procedure HAL_SetTimerFrequencies(tsc: QWord; apicTicksPerMs: Cardinal); cdecl;
  external name 'HAL_SetTimerFrequencies';
procedure HAL_InitTimer; cdecl; external name 'HAL_InitTimer';

{ Read a live thread's address-space root. Bound by symbol rather than a uses
  clause: the scheduler depends on this unit, so importing it here would be a
  cycle. Returns 0 for an inactive or unaddressed thread. }
function Sched_GetThreadAddrSpace(index: Integer): QWord; cdecl;
  external name 'Sched_GetThreadAddrSpace_Pas';

{ Local APIC register offsets. }
const
  APIC_ID           = $020;
  APIC_VERSION      = $030;
  APIC_TPR          = $080;
  APIC_EOI          = $0B0;
  APIC_SVR          = $0F0;
  APIC_LVT_TIMER    = $320;
  APIC_TIMER_INIT   = $380;
  APIC_TIMER_CURR   = $390;
  APIC_TIMER_DIV    = $3E0;

  { The window is 4 KiB; anything past 0x3FF is not a register. }
  APIC_WINDOW_SIZE  = $400;

  { High half canonical address the APIC window is mapped at. }
  APIC_WINDOW_VIRT  = QWord($FFFF800000000000);

  { PTE flags for the mapping: present + writable + user. It must be
    user-accessible so ring 3 threads that keep the address space alive do
    not fault on it. }
  APIC_MAP_FLAGS    = QWord($13);

  APIC_MAX_CORES    = 256;

{ LVT delivery mode / mask bits. }
const
  LVT_MASKED        = $10000;   { bit 16: suppress delivery }
  LVT_TIMER_VECTOR  = 32;

var
  Apic_BaseVirt: QWord = 0;
  Apic_Awake: Boolean = False;
  Apic_CoreCount: Cardinal = 1;
  Apic_IoApicBase: QWord = 0;
  Apic_TicksPerQuantum: Cardinal = 0;

function Apic_GetBaseVirt: QWord;
begin Apic_GetBaseVirt := Apic_BaseVirt; end;

function Apic_IsAwake: Boolean;
begin Apic_IsAwake := Apic_Awake; end;

procedure Apic_SetIsAwake(v: Boolean);
begin Apic_Awake := v; end;

function Apic_GetCoreCount: Cardinal;
begin Apic_GetCoreCount := Apic_CoreCount; end;

procedure Apic_SetCoreCount(c: Cardinal);
begin Apic_CoreCount := c; end;

function Apic_GetIoApicBase: QWord;
begin Apic_GetIoApicBase := Apic_IoApicBase; end;

procedure Apic_SetIoApicBase(b: QWord);
begin Apic_IoApicBase := b; end;

function Apic_GetCalibratedTicksPerQuantum: Cardinal;
begin Apic_GetCalibratedTicksPerQuantum := Apic_TicksPerQuantum; end;

procedure Apic_Fatal(const msg: AnsiString); inline;
begin
  Terminal_SetColor_Pas($00FF0000);
  Terminal_Print_Pas(W(msg));
end;

procedure Apic_Write(offset: Cardinal; value: Cardinal);
begin
  if Apic_BaseVirt = 0 then
  begin
    Apic_Fatal('[!] FATAL: APIC not initialized in Write!'#13#10);
    Exit;
  end;

  if offset >= APIC_WINDOW_SIZE then
  begin
    Apic_Fatal('[!] FATAL: Invalid APIC write offset!'#13#10);
    Exit;
  end;

  { Do not let the compiler reorder the write ahead of earlier work. }
  Arch_CompilerFence;
  PCardinal(Pointer(Apic_BaseVirt + offset))^ := value;
  { MFENCE: APIC writes such as EOI must reach the silicon immediately,
    not linger in the store buffer. }
  Arch_FullFence;
end;

function Apic_Read(offset: Cardinal): Cardinal;
begin
  Apic_Read := 0;

  if Apic_BaseVirt = 0 then
  begin
    Apic_Fatal('[!] FATAL: APIC not initialized in Read!'#13#10);
    Exit;
  end;

  if offset >= APIC_WINDOW_SIZE then
  begin
    Apic_Fatal('[!] FATAL: Invalid APIC read offset!'#13#10);
    Exit;
  end;

  { Read straight from the device: the register is uncacheable, so a cached
    or hoisted read would return stale data. }
  Arch_CompilerFence;
  Apic_Read := PCardinal(Pointer(Apic_BaseVirt + offset))^;
  { Wait for the read to complete before the next instruction uses it. }
  Arch_LoadFence;
end;

procedure Apic_SendEOI;
begin
  { Before the APIC is up, the legacy 8259 is the one that needs the EOI. }
  if Apic_Awake then
    HAL_SendEOI(0)
  else
    Pic_SendEOI;
end;

procedure Apic_SendIpi(targetCore: Cardinal; vector: Byte);
begin
  HAL_SendIPI(targetCore, vector);
end;

procedure Apic_BroadcastIpi(vector: Byte);
begin
  HAL_BroadcastIPI(vector);
end;

{ Map the APIC window into one address space, if the root looks sane. }
procedure MapApicInto(root: QWord; physAddress: QWord);
begin
  if root = 0 then Exit;
  { A root that is not a canonical address and inside RAM is corrupt; mapping
    through it would build page tables over arbitrary memory. }
  if Vmm_IsCanonical(root) and (root < Pmm_GetTotalPages * PAGE_SIZE) then
    Vmm_MapPageIn(physAddress, APIC_WINDOW_VIRT, APIC_MAP_FLAGS, Pointer(root))
  else
  begin
    Terminal_SetColor_Pas($00FFFF00);
    Terminal_Print_Pas(W('[WARN] Skipping invalid thread PML4 during APIC init'#13#10));
  end;
end;

procedure Apic_Init(physAddress: QWord);
var
  irqSched: Byte;
  syncTick, startTicks, tscStart, tscEnd: QWord;
  endCount, ticksIn40ms, ticksPerMs: Cardinal;
  picMask: Byte;
  i: Integer;
begin
  Terminal_SetColor_Pas($0000FFFF);
  Terminal_Print_Pas(W('[+] Kernel APIC Driver: Awakening the Beast...'#13#10));

  { The APIC MMIO window is mapped at a fixed high half address, so a
    physical address above 4 GiB could never be reached. }
  if (physAddress = 0) or (physAddress > QWord($FFFFFFFF)) then
  begin
    Apic_Fatal('[!] FATAL: Invalid APIC physical address!'#13#10);
    Exit;
  end;

  Apic_BaseVirt := APIC_WINDOW_VIRT;

  { Kernel address space. }
  if Vmm_GetPml4 <> nil then
    Vmm_MapPageIn(physAddress, APIC_WINDOW_VIRT, APIC_MAP_FLAGS, Vmm_GetPml4);

  irqSched := Kstate_AcquireSchedLock;

  if (kstate_ThreadCount < 1) or (kstate_ThreadCount > APIC_MAX_CORES) then
  begin
    Apic_Fatal('[!] FATAL: Invalid thread count in APIC Init!'#13#10);
    Kstate_ReleaseSchedLock(irqSched);
    Exit;
  end;

  { Every thread keeps its own address space, so each needs its own mapping
    of the window. The record layout stays private to the scheduler, which
    exposes one accessor for it. }
  for i := 0 to kstate_ThreadCount - 1 do
    MapApicInto(Sched_GetThreadAddrSpace(i), physAddress);

  Kstate_ReleaseSchedLock(irqSched);

  { And the currently loaded address space. }
  Vmm_MapPageIn(physAddress, APIC_WINDOW_VIRT, APIC_MAP_FLAGS,
                Pointer(Vmm_ReadCr3 and PHYS_ADDR_MASK));

  HAL_SetLocalApicBase(APIC_WINDOW_VIRT);
  HAL_InitInterruptController;

  Apic_Write(APIC_TIMER_DIV, $03);
  { Mask the timer LVT and load a full count while calibrating, so no
    interrupt is delivered until the rate is known. }
  Apic_Write(APIC_LVT_TIMER, LVT_MASKED or $FF);
  Apic_Write(APIC_TIMER_INIT, $FFFFFFFF);

  Io_EnableInterrupts;

  { ── Calibration ────────────────────────────────────────────────────────
    Run the Local APIC timer from 0xFFFFFFFF and count down over a measured
    PIT interval. The counter is read twice, at the start and after ~40 ms,
    and the difference gives ticks per millisecond.

    The `while` waits are fences as well as delays: without a compiler
    barrier the loop condition would be hoisted and the wait would become an
    infinite spin. }

  syncTick := HAL_GetTickCount;
  if syncTick = 0 then
  begin
    Apic_Fatal('[!] FATAL: Invalid PIT sync tick value!'#13#10);
    Exit;
  end;

  while HAL_GetTickCount = syncTick do
  begin
    Arch_CompilerFence;
    Io_Hlt;
  end;

  startTicks := HAL_GetTickCount;
  if startTicks = 0 then
  begin
    Apic_Fatal('[!] FATAL: Invalid PIT start tick value!'#13#10);
    Exit;
  end;

  tscStart := Arch_ReadTimestamp;
  Apic_Write(APIC_TIMER_INIT, $FFFFFFFF);

  while (HAL_GetTickCount - startTicks) < 10 do
  begin
    Arch_CompilerFence;
    Io_Hlt;
  end;

  tscEnd := Arch_ReadTimestamp;
  endCount := Apic_Read(APIC_TIMER_CURR);

  { The counter is 32-bit and cannot exceed 0xFFFFFFFF; anything larger
    means we read something that is not a timer count. }
  if endCount > $FFFFFFFF then
  begin
    Apic_Fatal('[!] FATAL: Invalid APIC timer end count!'#13#10);
    Exit;
  end;

  ticksIn40ms := $FFFFFFFF - endCount;
  if ticksIn40ms > $FFFFFFFF then
  begin
    Apic_Fatal('[!] FATAL: Invalid APIC ticks in 40ms calculation!'#13#10);
    Exit;
  end;

  ticksPerMs := ticksIn40ms div 40;

  { A zero rate would divide by zero in the scheduler; an implausibly high
    rate means the measurement is wrong. Both are fatal. }
  if (ticksPerMs = 0) or (ticksPerMs > 1000000) then
  begin
    Apic_Fatal('[!] FATAL: Invalid APIC ticks per ms calculation!'#13#10);
    Exit;
  end;

  Apic_TicksPerQuantum := ticksPerMs * 4;

  { Sanity-bound the quantum; fall back to a known-good rate rather than
    programming a divider the scheduler cannot work with. }
  if (Apic_TicksPerQuantum < 10000) or (Apic_TicksPerQuantum > 10000000) then
    Apic_TicksPerQuantum := 60000;

  HAL_SetTimerFrequencies((tscEnd - tscStart) * 25, ticksPerMs);
  HAL_InitTimer;

  Terminal_Print_Pas(W('[+] APIC Calibrated! CPU APIC Ticks per 1ms: '));
  Terminal_PrintDec_Pas(ticksPerMs);
  Terminal_Print_Pas(W(#13#10));

  { Mask IRQ0 on the legacy PIC: the Local APIC timer now delivers vector 32
    for the same interrupt, and letting both fire would double the tick. }
  picMask := Io_In8($21);
  if picMask > $FF then
  begin
    Apic_Fatal('[!] FATAL: Invalid PIC mask value!'#13#10);
    Exit;
  end;
  Io_Out8($21, picMask or $01);

  Apic_Awake := True;

  { Unmask the LVT and start the periodic timer. }
  Apic_Write(APIC_LVT_TIMER, LVT_TIMER_VECTOR);
  Apic_Write(APIC_TIMER_INIT, Apic_TicksPerQuantum);

  Terminal_Print_Pas(W('[+] Multi-Core Timer Engaged at 250Hz! The PIT is Officially DEAD!'#13#10));
  Terminal_SetColor_Pas($00FFFFFF);
end;

end.
