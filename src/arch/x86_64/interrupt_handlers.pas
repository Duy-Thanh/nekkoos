{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: interrupt_handlers - exception and device interrupt entry points.
  PORTED FROM: src/arch/x86_64/InterruptHandlers.cs.

  x86_64 ONLY. These are the targets of the `call` instructions in the ISR
  stubs of Hardware.asm, so their exported names are part of that ABI:

      DivideByZeroHandler  GPFHandler  PageFaultHandler  TimerHandler
      KeyboardHandler      MouseHandler

  The first three, and TimerHandler/MouseHandler, take the saved RSP and
  return the RSP to resume on (the stub does `mov rsp, rax; iretq`), so they
  can switch threads. KeyboardHandler returns nothing.

  An exception raised in ring 3 only kills the offending process: it is
  turned into a zombie and the core switches away. The same exception in
  ring 0 is a kernel bug and halts the machine after a serial dump.
  =========================================================================
}
unit interrupt_handlers;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

implementation

uses arch_interface, io, kstring, terminal, console, serial, vmm, apic, pic,
  scheduler, ipc_kernel, input_drv, power;

{ Register frame pushed by the ISR stubs, as byte offsets from the saved RSP.
  The layout is the one ContextLayout.cs described: 15 GPRs, an error code
  slot, then the CPU-pushed RIP/CS/RFLAGS/RSP/SS. }
const
  CTX_RBX    = 11;
  CTX_RDX    = 12;
  CTX_RCX    = 13;
  CTX_RAX    = 14;
  CTX_ERROR  = 15;
  CTX_RIP    = 16;
  CTX_CS     = 17;
  CTX_RFLAGS = 18;
  CTX_RSP    = 19;
  CTX_SS     = 20;

  KERNEL_STACK_MIN = $1000;
  KERNEL_STACK_MAX = $7FFFFFFFFFFFF000;

function ReadCR2: QWord; cdecl; external name 'ReadCR2';
procedure HAL_IncrementTicks; cdecl; external name 'HAL_IncrementTicks';

{ ── Halting ──────────────────────────────────────────────────────────────── }

procedure HaltSystemForever;
begin
  Arch_DisableInterrupts;
  while True do Arch_Halt;
end;

{ Freeze every other core so nothing keeps scribbling over the panic output. }
procedure BroadcastApocalypse;
begin
  if Apic_IsAwake then
  begin
    { Panic text must be in RAM before the other cores stop. }
    Arch_StoreFence;
    Apic_Write($300, $000C4500);   { INIT IPI }
  end;
end;

{ ── Serial panic dump ────────────────────────────────────────────────────── }

function CtxAt(frame: PQWord; slot: Integer): QWord; inline;
begin
  CtxAt := frame[slot];
end;

procedure SerialLabel(const name: AnsiString; value: QWord);
begin
  Serial_WriteString(W(name));
  Serial_WriteHex(value);
end;

procedure PanicToSerial(title: PWord; frame: PQWord; extraAddr: QWord);
begin
  Serial_WriteString(W(#13#10'=================================================='#13#10));
  Serial_WriteString(W(' [SERIAL KERNEL PANIC DUMP] '#13#10));
  Serial_WriteString(title);
  Serial_WriteString(W(#13#10'--------------------------------------------------'#13#10));

  if frame <> nil then
  begin
    SerialLabel('   RIP: ', CtxAt(frame, CTX_RIP));
    Serial_WriteString(W(#13#10));
    SerialLabel('   RSP: ', CtxAt(frame, CTX_RSP));
    Serial_WriteString(W(#13#10));
    SerialLabel('   RAX: ', CtxAt(frame, CTX_RAX));
    SerialLabel('   RBX: ', CtxAt(frame, CTX_RBX));
    Serial_WriteString(W(#13#10));
    SerialLabel('   RCX: ', CtxAt(frame, CTX_RCX));
    SerialLabel('   RDX: ', CtxAt(frame, CTX_RDX));
    Serial_WriteString(W(#13#10));
    SerialLabel('   CS : ', CtxAt(frame, CTX_CS));
    SerialLabel('   FLG: ', CtxAt(frame, CTX_RFLAGS));
    Serial_WriteString(W(#13#10));
  end;

  if extraAddr <> 0 then
  begin
    SerialLabel('   CR2: ', extraAddr);
    Serial_WriteString(W(#13#10));
  end;
  Serial_WriteString(W('=================================================='#13#10#13#10));
end;

procedure PrintRegisterDumpToSerial(frame: PQWord);
begin
  SerialLabel('   RIP: ', CtxAt(frame, CTX_RIP));
  SerialLabel('   RSP: ', CtxAt(frame, CTX_RSP));
  Serial_WriteString(W(#13#10));
  SerialLabel('   RAX: ', CtxAt(frame, CTX_RAX));
  SerialLabel('   RBX: ', CtxAt(frame, CTX_RBX));
  Serial_WriteString(W(#13#10));
  SerialLabel('   RCX: ', CtxAt(frame, CTX_RCX));
  SerialLabel('   RDX: ', CtxAt(frame, CTX_RDX));
  Serial_WriteString(W(#13#10));
  SerialLabel('   CS : ', CtxAt(frame, CTX_CS));
  SerialLabel('   FLG: ', CtxAt(frame, CTX_RFLAGS));
  Serial_WriteString(W(#13#10));
end;

function StackPointerBad(rsp: QWord): Boolean; inline;
begin
  StackPointerBad := (rsp = 0) or (rsp < KERNEL_STACK_MIN) or (rsp > KERNEL_STACK_MAX);
end;

{ ── Killing a faulting ring-3 process ────────────────────────────────────── }

procedure AnnounceKill(const msg: AnsiString);
var
  irq: Boolean;
begin
  irq := Con_ScreenLockAcquire;
  Terminal_SetColor_Pas($00FF0000);
  Terminal_Print_Pas(W(msg));
  Terminal_SetColor_Pas($00FFFFFF);
  Con_ScreenLockRelease(irq);
end;

{ Turn the current thread into a zombie and switch away from it.
  `full` also drops the thread's credentials, foreground status and mailbox
  (divide error and #GP); a page fault leaves those to the reaper. }
function KillCurrentRing3(currentRsp: QWord; full: Boolean): QWord;
var
  id: Integer;
  coreId: Cardinal;
  irq: Boolean;
  dying: PInteger;
begin
  id := Sched_GetCurrentThreadId;
  if Apic_IsAwake then coreId := Apic_Read($020) shr 24
  else coreId := 0;

  irq := Sched_AcquireSchedLockSafe;

  if full then
  begin
    if Sched_GetForegroundTask = id then
      Sched_SetForegroundTask(Sched_GetThreadParentId(id));
    Sched_SetThreadUID(id, 9999);
    IpcK_ClearMailbox(Cardinal(id));
  end;

  { Leave the dying address space before touching scheduler structures. The
    reaper (SwitchTask) frees it outside interrupt context. }
  Sched_SetThreadAddrSpace(id, 0);
  Vmm_LoadPml4(Vmm_GetPml4);

  { Zombie, not dead: a dead slot may be recycled by another core while this
    ISR is still running on the stack that belongs to it. }
  Sched_SetThreadActive(id, 4);

  dying := Sched_GetDyingThreadPerCore;
  if (dying <> nil) and (dying[coreId] = -1) then dying[coreId] := id;

  Arch_StoreFence;
  Sched_ReleaseSchedLockSafe(irq);

  KillCurrentRing3 := Sched_SwitchTask(currentRsp);
end;

{ ── Exceptions ───────────────────────────────────────────────────────────── }

function DivideByZeroHandler(currentRsp: QWord): QWord; cdecl; public name 'DivideByZeroHandler';
var
  frame: PQWord;
  cs: QWord;
begin
  if StackPointerBad(currentRsp) then
  begin
    BroadcastApocalypse;
    PanicToSerial(W(' [FATAL EXCEPTION 0x00] INVALID STACK POINTER!'), nil, 0);
    HaltSystemForever;
  end;

  frame := PQWord(Pointer(currentRsp));
  cs := CtxAt(frame, CTX_CS);

  if (cs = 0) or (cs > $FFFFFFFF) then
  begin
    BroadcastApocalypse;
    PanicToSerial(W(' [FATAL EXCEPTION 0x00] INVALID CODE SEGMENT!'), frame, 0);
    HaltSystemForever;
  end;

  if (Sched_GetThreads = nil) or (Sched_GetCurrentThreadId < 0) then
  begin
    BroadcastApocalypse;
    PanicToSerial(W(' [FATAL EXCEPTION 0x00] SCHEDULER NOT INITIALIZED!'), frame, 0);
    HaltSystemForever;
  end;

  if (cs and 3) = 3 then
  begin
    AnnounceKill(#13#10'[!] MPU: DIVIDE BY ZERO IN RING 3 APP! Terminated!'#13#10);
    PanicToSerial(W(' [EXCEPTION 0x00] Ring 3 DIVIDE BY ZERO - App Killed'), frame, 0);
    DivideByZeroHandler := KillCurrentRing3(currentRsp, True);
    Exit;
  end;

  { Ring 0 divide error is a real kernel bug. }
  BroadcastApocalypse;
  PanicToSerial(W(' [FATAL EXCEPTION 0x00] DIVIDE BY ZERO ERROR!'), frame, 0);
  Serial_WriteString(W(#13#10#13#10'   *** KERNEL PANIC ***'#13#10#13#10));
  Serial_WriteString(W('   [FATAL EXCEPTION 0x00] DIVIDE BY ZERO ERROR!'#13#10#13#10));
  PrintRegisterDumpToSerial(frame);
  Serial_WriteString(W(#13#10'   NekkoOS Microkernel halted to prevent system damage.'#13#10));

  Power_HardReboot;
  HaltSystemForever;
  DivideByZeroHandler := currentRsp;
end;

function GPFHandler(currentRsp: QWord): QWord; cdecl; public name 'GPFHandler';
var
  frame: PQWord;
  realCs: QWord;
begin
  if StackPointerBad(currentRsp) then
  begin
    BroadcastApocalypse;
    HaltSystemForever;
  end;

  { Read the frame straight off the stack. The error code shifts everything
    after it, which is exactly what a struct overlay used to get wrong. }
  frame := PQWord(Pointer(currentRsp));
  realCs := CtxAt(frame, CTX_CS);

  if (realCs and 3) = 3 then
  begin
    AnnounceKill(#13#10'[!] MPU: GENERAL PROTECTION FAULT IN RING 3 APP! Terminated!'#13#10);
    PanicToSerial(W(' [EXCEPTION 0x0D] Ring 3 GENERAL PROTECTION FAULT - App Killed'), frame, 0);
    GPFHandler := KillCurrentRing3(currentRsp, True);
    Exit;
  end;

  BroadcastApocalypse;
  PrintRegisterDumpToSerial(frame);
  Serial_WriteHex(CtxAt(frame, CTX_ERROR));

  Power_HardReboot;
  HaltSystemForever;
  GPFHandler := currentRsp;
end;

function PageFaultHandler(currentRsp: QWord): QWord; cdecl; public name 'PageFaultHandler';
var
  frame: PQWord;
  faultAddr, cs: QWord;
begin
  if StackPointerBad(currentRsp) then
  begin
    BroadcastApocalypse;
    Serial_WriteString(W(' [FATAL EXCEPTION 0x0E] INVALID STACK POINTER IN PAGE FAULT!'));
    HaltSystemForever;
  end;

  frame := PQWord(Pointer(currentRsp));
  faultAddr := ReadCR2;
  { CR2 has to be read before speculation can substitute another value. }
  Arch_LoadFence;

  cs := CtxAt(frame, CTX_CS);
  if (cs = 0) or (cs > $FFFFFFFF) then
  begin
    BroadcastApocalypse;
    Serial_WriteString(W(' [FATAL EXCEPTION 0x0E] INVALID CODE SEGMENT IN PAGE FAULT!'));
    HaltSystemForever;
  end;

  if (cs and 3) = 3 then
  begin
    AnnounceKill(#13#10'[!] MPU: SEGMENTATION FAULT IN RING 3 APP! Terminated!'#13#10);
    PanicToSerial(W(' [EXCEPTION 0x0E] Ring 3 PAGE FAULT - App Killed'), frame, faultAddr);
    PageFaultHandler := KillCurrentRing3(currentRsp, False);
    Exit;
  end;

  BroadcastApocalypse;
  PanicToSerial(W(' [FATAL EXCEPTION 0x0E] PAGE FAULT IN RING 0!'), frame, faultAddr);
  Serial_WriteString(W(#13#10#13#10'   *** KERNEL PANIC ***'#13#10#13#10'   [FATAL EXCEPTION 0x0E] PAGE FAULT IN RING 0!'#13#10'   Fault Address: '));
  Serial_WriteHex(faultAddr);
  Serial_WriteString(W(#13#10#13#10));
  PrintRegisterDumpToSerial(frame);
  Serial_WriteString(W(#13#10'   System Halted.'#13#10));

  Power_HardReboot;
  Power_LegacyReboot;
  HaltSystemForever;
  PageFaultHandler := currentRsp;
end;

{ ── Device interrupts ────────────────────────────────────────────────────── }

function TimerHandler(currentRsp: QWord): QWord; cdecl; public name 'TimerHandler';
var
  coreId: Cardinal;
begin
  if not Apic_IsAwake then
  begin
    HAL_IncrementTicks;
    Sched_BumpSystemTicks(1);
    Pic_SendEOI;
    if not Sched_IsReady then
      TimerHandler := currentRsp
    else
      TimerHandler := Sched_SwitchTask(currentRsp);
    Exit;
  end;

  coreId := Apic_Read($020) shr 24;
  if coreId = 0 then
  begin
    HAL_IncrementTicks;
    Sched_BumpSystemTicks(1);
    { Core 0 owns time. Push the new tick out of its store buffer so the
      other cores never read a stale clock. }
    Arch_StoreFence;
  end;

  Apic_SendEOI;

  if not Sched_IsReady then
    TimerHandler := currentRsp
  else
    TimerHandler := Sched_SwitchTask(currentRsp);
end;

procedure KeyboardHandler; cdecl; public name 'KeyboardHandler';
var
  scanCode: Byte;
begin
  scanCode := Io_In8($60);

  { Receiver 0 is a broadcast: syscall 4 (GetChar) scans the whole mailbox,
    while a window-manager style reader asking for its own PID ignores it. }
  IpcK_SendFromInterrupt(1, 33, 0, scanCode);

  if Apic_IsAwake then Apic_SendEOI
  else Pic_SendEOI;
end;

function MouseHandler(currentRsp: QWord): QWord; cdecl; public name 'MouseHandler';
var
  status, data: Byte;
  payload: QWord;
begin
  while True do
  begin
    status := Io_In8($64);
    if (status and $01) = 0 then Break;   { output buffer empty }
    if (status and $20) = 0 then Break;   { not mouse data }

    data := Io_In8($60);

    if Mouse_GetUseDaemon and (Mouse_GetDaemonId <> 0) then
    begin
      if Mouse_FeedByte(data, payload) then
        { The mailbox send is safe from an ISR and cannot kill the stack. }
        IpcK_SendFromInterrupt(2, 44, Mouse_GetDaemonId, payload);
    end;
  end;

  if Apic_IsAwake then Apic_SendEOI
  else Pic_SendEOI;

  { Never switch threads here: the interrupted syscall must resume on the
    same RSP or its frame is lost. }
  MouseHandler := currentRsp;
end;

end.
