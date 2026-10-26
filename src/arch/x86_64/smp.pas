{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: smp - bring up the application processors (APs).
  PORTED FROM: src/arch/x86_64/SMP.cs.

  x86_64 ONLY. Sequence, per AP:
    1. The BSP copies SMP.BIN (a real-mode trampoline) to 0x8000 and fills
       three mailboxes at 0x8F00: PML4, entry point, stack.
    2. INIT IPI, a delay, then a STARTUP IPI at vector 0x08 (= 0x8000).
    3. The trampoline climbs to long mode, takes its stack out of the
       mailbox (zeroing it as the acknowledgement) and jumps to ApEntryPoint.
    4. ApEntryPoint builds the AP's own GDT, TSS and idle task and arms its
       timer, then signals "forged" (ack = 2) and waits for the BSP's go (the
       BSP's own ack slot becoming non-zero).

  Every shared flag lives in a page of u32 acks accessed through the MMIO
  accessors, which fence, so neither compiler nor CPU may reorder around them.
  =========================================================================
}
unit smp;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Wake every AP the ACPI daemon reported. No-op if SMP.BIN is missing. }
procedure Smp_InitAndWakeCores;

function Smp_GetCoreCountAwake: Cardinal;

implementation

uses arch_interface, io, kstring, libc, pmm, console, terminal, serial, vmm,
  apic, gdt, scheduler, heap, fat16_kernel, spinlock;

procedure GetIdtr(p: Pointer); cdecl; external name 'Arch_GetIDTR';

const
  ICR_LOW  = $300;
  ICR_HIGH = $310;

  TRAMPOLINE_BASE = $8000;
  MAILBOX_PML4    = $8F00;
  MAILBOX_ENTRY   = $8F08;
  MAILBOX_STACK   = $8F10;

  { TSS: 104-byte header, then the 8 KiB I/O bitmap and its terminator. }
  TSS_IOPB_OFFSET = 104;
  TSS_IOPB_BYTES  = 8192;
  TSS_BYTES       = TSS_IOPB_OFFSET + TSS_IOPB_BYTES + 1;
  TSS_PAGES       = 3;

  AP_KERNEL_STACK_PAGES = 4;

var
  CoreCountAwake: Cardinal = 1;
  CoreReadyAcks: PCardinal = nil;
  SharedIdtr: Pointer = nil;
  SmpLock: Cardinal = 0;

function Smp_GetCoreCountAwake: Cardinal;
begin
  Smp_GetCoreCountAwake := CoreCountAwake;
end;

procedure Fatal(const msg: AnsiString);
begin
  Con_SetColor($00FF0000);
  Con_Print(W(msg));
end;

procedure AckWrite(index, value: Cardinal);
begin
  Arch_WriteMmio32(QWord(@CoreReadyAcks[index]), value);
end;

function AckRead(index: Cardinal): Cardinal;
begin
  AckRead := Arch_ReadMmio32(QWord(@CoreReadyAcks[index]));
end;

{ ── Application processor entry ──────────────────────────────────────────── }

procedure ApEntryPoint; cdecl;
var
  myId: Cardinal;
  gdtPage: PQWord;
  tss: PByte;
  gdtDesc: PWord;
  tssAddr, limitLow, baseLow, baseMid, flags, baseHigh: QWord;
  tssLimit: Cardinal;
  i: Integer;
  irq: Byte;
  quantum: Cardinal;
begin
  Vmm_LoadPml4(Vmm_GetPml4);

  myId := Apic_Read($020) shr 24;

  if myId >= 256 then
  begin
    Fatal('[!] FATAL: Invalid CPU core ID in ApEntryPoint!'#13#10);
    while True do Arch_Halt;
  end;

  { The local APIC ID can read 0 for a moment right after reset. }
  while myId = 0 do
  begin
    Arch_CompilerFence;
    myId := Apic_Read($020) shr 24;
  end;

  if CoreReadyAcks = nil then
  begin
    Fatal('[!] FATAL: CoreReadyAcks not initialized in ApEntryPoint!'#13#10);
    while True do Arch_Halt;
  end;

  AckWrite(myId, 1);
  Arch_StoreFence;

  Apic_Write($0F0, $1FF);     { enable the local APIC, spurious vector 0xFF }
  Arch_LoadIDT(SharedIdtr);

  gdtPage := PQWord(Pmm_AllocatePage);
  if gdtPage = nil then
  begin
    Fatal('[!] FATAL: Failed to allocate GDT page in APEntryPoint!'#13#10);
    while True do Arch_Halt;
  end;

  gdtPage[0] := 0;
  gdtPage[1] := QWord($00209A0000000000);   { ring 0 code }
  gdtPage[2] := QWord($0000920000000000);   { ring 0 data }
  gdtPage[3] := QWord($0000F20000000000);   { ring 3 data }
  gdtPage[4] := QWord($0020FA0000000000);   { ring 3 code }
  gdtPage[5] := 0;

  tss := PByte(Pmm_AllocateContiguousPages(TSS_PAGES));
  if tss = nil then
  begin
    Fatal('[!] FATAL: Failed to allocate TSS pages in APEntryPoint!'#13#10);
    while True do Arch_Halt;
  end;
  MemSet(tss, 0, TSS_BYTES);
  for i := 0 to TSS_IOPB_BYTES - 1 do tss[TSS_IOPB_OFFSET + i] := $FF;
  tss[TSS_IOPB_OFFSET + TSS_IOPB_BYTES] := $FF;

  tssAddr := QWord(tss);
  PWord(tss + 102)^ := TSS_IOPB_OFFSET;       { IopbOffset }

  { The scheduler finds this core's TSS (to set Rsp0 on every switch) and the
    port-grant syscall finds it (to open I/O ports on every core) by id. }
  Gdt_SetCoreTss(myId, tss);

  tssLimit := TSS_BYTES - 1;
  limitLow := tssLimit and $FFFF;
  baseLow := tssAddr and $FFFF;
  baseMid := (tssAddr shr 16) and $FF;
  flags := (tssLimit shr 16) and $0F;
  baseHigh := (tssAddr shr 24) and $FF;

  gdtPage[6] := limitLow or (baseLow shl 16) or (baseMid shl 32) or
                (QWord($89) shl 40) or (flags shl 48) or (baseHigh shl 56);
  gdtPage[7] := tssAddr shr 32;

  { LGDT operand: 16-bit limit then 64-bit base, parked in the same page. }
  gdtDesc := PWord(PByte(gdtPage) + 2048);
  gdtDesc[0] := 8 * 8 - 1;
  PQWord(gdtDesc + 1)^ := QWord(gdtPage);

  Arch_LoadGDT(gdtDesc);

  Arch_FullFence;
  Arch_CompilerFence;

  Arch_LoadTSS($30);

  Arch_FullFence;
  Arch_CompilerFence;

  { The idle task has to exist BEFORE interrupts are enabled: a timer tick on
    an AP with no idle task would index the thread table with -1. }
  Sched_CreateIdleTaskForCore(myId);

  Apic_Write($3E0, $03);
  Apic_Write($320, $20000 or 32);

  quantum := Apic_GetCalibratedTicksPerQuantum;
  if quantum <> 0 then Apic_Write($380, quantum)
  else Apic_Write($380, 200000);

  irq := Spinlock_AcquireSafe_Pas(@SmpLock);
  Inc(CoreCountAwake);
  Con_SetColor($00FF00FF);
  Con_Print(W('[+] CPU Core Online! GDT & TSS Forged! Unleashed into Scheduler!'#13#10));
  Spinlock_ReleaseSafe_Pas(@SmpLock, irq);

  AckWrite(myId, 2);
  Arch_StoreFence;

  Arch_EnableInterrupts;

  { Wait for the BSP's go signal. }
  while AckRead(0) = 0 do
  begin
    Arch_CompilerFence;
    Arch_Halt;
  end;

  Arch_LoadFence;

  while True do
  begin
    Arch_Halt;
    Arch_ForceYield;
  end;
end;

{ ── BSP side ─────────────────────────────────────────────────────────────── }

{ Hand-build the first frame an AP's idle thread resumes from. }
procedure BuildIdleFrame(id: Integer; coreIdx: Cardinal);
var
  kStackTop: PQWord;
  originalTop: QWord;
  j: Integer;
  name: PByte;
begin
  { 16 KiB: the APIC interrupt pushes 120 bytes of registers and SaveFPU needs
    another 528, which together with call depth overflows a single page. }
  kStackTop := PQWord(PByte(Pmm_AllocateContiguousPages(AP_KERNEL_STACK_PAGES)) +
    AP_KERNEL_STACK_PAGES * 4096);
  if kStackTop = nil then
  begin
    Fatal('[!] FATAL: Failed to allocate kernel stack for core!'#13#10);
    Exit;
  end;

  Sched_SetThreadKernelStackTop(id, QWord(kStackTop));

  { Two zero words keep the IRETQ frame 16-byte aligned. }
  Dec(kStackTop); kStackTop^ := 0;
  Dec(kStackTop); kStackTop^ := 0;
  originalTop := QWord(kStackTop);

  Dec(kStackTop); kStackTop^ := Sched_GetSS;
  Dec(kStackTop); kStackTop^ := originalTop;
  Dec(kStackTop); kStackTop^ := $202;
  Dec(kStackTop); kStackTop^ := Sched_GetCS;
  Dec(kStackTop); kStackTop^ := QWord(Sched_GetIdleLoop);

  for j := 1 to 15 do
  begin
    Dec(kStackTop); kStackTop^ := 0;
  end;

  Sched_SetThreadRsp(id, QWord(kStackTop));

  name := Sched_GetThreadName(id);
  if name <> nil then
  begin
    name[0] := Ord('I');
    name[1] := Ord('D');
    name[2] := Byte(Ord('0') + coreIdx);
    name[3] := 0;
  end;

  MemCopy(Sched_GetThreadFpuState(id), Sched_GetThreadFpuState(0), 512);
end;

procedure Smp_InitAndWakeCores;
var
  smpBinSize: Cardinal;
  payload, trampoline: PByte;
  pml4Mailbox, entryMailbox, stackMailbox: PQWord;
  i, d: Cardinal;
  id: Integer;
  irq: Boolean;
  apStackPhys, apStack: QWord;
  p: Integer;
  stackTimeout, timeout: Integer;
  scrIrq: Boolean;
  idleIds, curIds: PInteger;
begin
  if Apic_GetBaseVirt = 0 then
  begin
    Fatal('[!] FATAL: APIC not initialized in InitAndWakeCores!'#13#10);
    Exit;
  end;

  Con_SetColor($00FFFF00);
  Con_Print(W('[*] SMP Controller: Reading Trampoline Payload...'#13#10));

  smpBinSize := 0;
  payload := Fat16K_ReadFile(W('SMP.BIN'), @smpBinSize, -1);
  if (payload = nil) or (smpBinSize = 0) then Exit;

  Vmm_MapPage(TRAMPOLINE_BASE, TRAMPOLINE_BASE, $07);
  trampoline := PByte(TRAMPOLINE_BASE);
  for i := 0 to smpBinSize - 1 do trampoline[i] := payload[i];

  pml4Mailbox := PQWord(MAILBOX_PML4);
  entryMailbox := PQWord(MAILBOX_ENTRY);
  stackMailbox := PQWord(MAILBOX_STACK);

  pml4Mailbox^ := QWord(Vmm_GetPml4);
  entryMailbox^ := QWord(@ApEntryPoint);

  Heap_Free(payload);

  SharedIdtr := Pmm_AllocatePage;
  if SharedIdtr = nil then
  begin
    Fatal('[!] FATAL: Failed to allocate SharedIdtr page!'#13#10);
    Exit;
  end;
  GetIdtr(SharedIdtr);

  CoreReadyAcks := PCardinal(Pmm_AllocatePage);
  if CoreReadyAcks = nil then
  begin
    Fatal('[!] FATAL: Failed to allocate CoreReadyAcks page!'#13#10);
    Pmm_FreePage(SharedIdtr);
    Exit;
  end;
  for i := 0 to 255 do CoreReadyAcks[i] := 0;

  if (Apic_GetCoreCount = 0) or (Apic_GetCoreCount > 256) then
  begin
    Fatal('[!] FATAL: Invalid APIC core count!'#13#10);
    Exit;
  end;

  { Fill each AP's idle thread under the scheduler lock, activating it LAST.
    A timer tick on the BSP between "Active := 1" and "Rsp := ..." would
    otherwise switch to a half-built thread and jump to RIP 0. }
  idleIds := Sched_GetIdleThreadIds;
  curIds := Sched_GetCurrentThreadIds;

  irq := Sched_AcquireSchedLockSafe;
  for i := 1 to Apic_GetCoreCount - 1 do
  begin
    id := Sched_GetFreeThreadSlot;
    if (id < 0) or (id >= Sched_GetThreadCount) then
    begin
      Fatal('[!] FATAL: Failed to allocate thread slot for core!'#13#10);
      Sched_ReleaseSchedLockSafe(irq);
      Exit;
    end;

    idleIds[i] := id;
    curIds[i] := id;
    Sched_SetThreadPriority(id, SCHED_IDLE_PRIORITY);
    Sched_SetThreadCore(id, Integer(i));
    Sched_SetThreadAddrSpace(id, QWord(Vmm_GetPml4));

    BuildIdleFrame(id, i);

    Sched_SetThreadActive(id, 1);
  end;
  Sched_ReleaseSchedLockSafe(irq);

  Con_Print(W('[*] SMP Controller: Trampoline Armed at 0x8000. Sending SIPI Sequence...'#13#10));

  for i := 1 to Apic_GetCoreCount - 1 do
  begin
    apStackPhys := QWord(Pmm_AllocateContiguousPages(4));
    for p := 0 to 3 do
      Vmm_MapPage(apStackPhys + QWord(p) * 4096, apStackPhys + QWord(p) * 4096, $03);
    apStack := apStackPhys + 4 * 4096 - 4096;

    AckWrite(i, 0);
    stackMailbox^ := apStack;

    { Mailbox and ack writes must be globally visible before the IPI. }
    Arch_FullFence;

    Apic_Write(ICR_HIGH, i shl 24);
    Apic_Write(ICR_LOW, $00004500);       { INIT }

    for d := 0 to 9999 do Io_In8($80);

    Apic_Write(ICR_HIGH, i shl 24);
    Apic_Write(ICR_LOW, $00004608);       { STARTUP, vector 0x08 }

    { The AP zeroes the stack mailbox once it has taken its stack. Waiting for
      that keeps two APs from racing on the single mailbox. }
    stackTimeout := 10000000;
    while (stackMailbox^ <> 0) and (stackTimeout > 0) do
    begin
      Arch_CompilerFence;
      Io_In8($80);
      Dec(stackTimeout);
    end;

    if stackMailbox^ <> 0 then
    begin
      Fatal('[!] SMP Error: Core failed to grab its Stack!'#13#10);
      Con_SetColor($00FFFFFF);
      Continue;
    end;

    Arch_LoadFence;

    timeout := 10000000;
    while (AckRead(i) < 2) and (timeout > 0) do
    begin
      Arch_CompilerFence;
      Io_In8($80);
      Dec(timeout);
    end;

    if timeout <= 0 then
    begin
      Fatal('[!] FATAL: GDT/TSS forge timeout for core!'#13#10);
      Con_SetColor($00FFFFFF);
      Continue;
    end;

    Arch_LoadFence;

    if AckRead(i) < 2 then
    begin
      Fatal('[!] SMP Error: Core failed to forge GDT/TSS in time!'#13#10);
      Con_SetColor($00FFFFFF);
    end;

    Arch_LoadFence;
  end;

  scrIrq := Con_ScreenLockAcquire;
  Terminal_SetColor_Pas($0000FF00);
  Terminal_Print_Pas(W('[+] SMP Initialization Complete! CPU Cores online: '));
  Terminal_PrintDec_Pas(CoreCountAwake);
  Terminal_Print_Pas(W(#13#10));
  Con_ScreenLockRelease(scrIrq);

  { Release the APs. }
  AckWrite(0, 1);
  Arch_StoreFence;
end;

{ ── cdecl exports for SMP.cs ── }

procedure Smp_InitAndWakeCores_Pas; cdecl; public name 'Smp_InitAndWakeCores_Pas';
begin
  Smp_InitAndWakeCores;
end;

end.
