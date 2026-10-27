{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: traps_arm64 - IRQ and supervisor-call entry from the vector table.

  Both entries receive the address of the saved trap frame and return the
  frame to resume. Returning the same one resumes the interrupted thread;
  returning another thread's frame is a context switch. This is the same
  contract as the x86 handlers (they return the RSP to resume on).
  =========================================================================
}
unit traps_arm64;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

function Arm64Irq(frame: QWord): QWord; cdecl;
function Arm64Sync(frame: QWord): QWord; cdecl;

implementation

uses arch_interface, arch_hal, scheduler, terminal, serial;

const
  EC_SVC64 = $15;

procedure Fault(esr, elr, far: QWord); cdecl; external name 'Arm64Fault';
function ReadEsr: QWord; cdecl; external name 'Arch_ReadEsr';
function ReadFar: QWord; cdecl; external name 'Arch_ReadFar';

function Arm64Irq(frame: QWord): QWord; cdecl; public name 'Arm64Irq';
var
  iar: Cardinal;
begin
  Arm64Irq := frame;
  iar := Arm64_IrqAcknowledge;
  if (iar and $3FF) = ARM64_TIMER_INTID then
  begin
    Arm64_TimerTick;
    if Sched_IsReady then Arm64Irq := Sched_SwitchTask(frame);
  end;
  Arm64_IrqEnd(iar);
end;

{ Print a NUL-terminated UTF-16 user string, re-checking the mapping at every
  page so a string running off its mapping stops instead of faulting the kernel. }
function PrintUser(tid: Integer; str: QWord): QWord;
const
  MAX_CHARS = 8192;
var
  c: Word;
  n: Integer;
  space: QWord;
begin
  PrintUser := 0;
  space := Sched_GetThreadAddrSpaceRaw(tid);
  n := 0;
  while n < MAX_CHARS do
  begin
    if ((n = 0) or ((str and 4095) < 2)) and
       ((not Hal_IsUserPageMapped(space, str)) or
        (not Hal_IsUserPageMapped(space, str + 1))) then Exit;
    c := PWord(str)^;
    if c = 0 then Break;
    Terminal_DrawChar_Pas(c);
    Inc(str, 2);
    Inc(n);
  end;
  PrintUser := 1;
end;

{ Syscalls from EL0. Numbers follow the x86 table (AGENTS.md section 4.1); the
  first argument is "arg 1" (x1), as in the x86 dispatcher. Everything returns
  `frame` except calls that switch threads. }
function UserSyscall(frame: QWord): QWord;
const
  SYS_EXIT   = 0;
  SYS_PRINT  = 1;
  SYS_UPTIME = 19;
  SYS_YIELD  = 100;
var
  ctx: PQWord;
  tid: Integer;
begin
  ctx := PQWord(frame);
  tid := Sched_GetCurrentThreadId;
  UserSyscall := frame;
  case Ctx_GetNumber(ctx) of
    SYS_EXIT:
      begin
        { Tears down this thread's address space, then yields away for good. }
        Sched_TerminateCurrentTask;
      end;
    SYS_PRINT:  Ctx_SetRet(ctx, PrintUser(tid, Ctx_GetArg(ctx, 1)));
    SYS_UPTIME: Ctx_SetRet(ctx, Hal_Ticks);
    SYS_YIELD:  UserSyscall := Sched_YieldHandler(frame);
  else
    Ctx_SetRet(ctx, QWord(-1));
  end;
end;

function Arm64Sync(frame: QWord): QWord; cdecl; public name 'Arm64Sync';
var
  esr, spsr: QWord;
  fromUser: Boolean;
begin
  esr := ReadEsr;
  spsr := PQWord(frame)[33];
  fromUser := (spsr and $F) = 0;            { M[3:0] = 0000: EL0t }
  if (esr shr 26) = EC_SVC64 then
  begin
    if fromUser then Arm64Sync := UserSyscall(frame)
    else Arm64Sync := Sched_YieldHandler(frame);   { svc #0 in the kernel = Arch_ForceYield }
  end
  else if fromUser then
  begin
    { A user program faulted: report it and end that program, not the machine. }
    Serial_WriteChar(10);
    Serial_WriteChar(Ord('['));
    Serial_WriteChar(Ord('!'));
    Serial_WriteChar(Ord(']'));
    Serial_WriteChar(Ord(' '));
    Serial_WriteHex(esr);
    Serial_WriteChar(Ord(' '));
    Serial_WriteHex(PQWord(frame)[32]);
    Serial_WriteChar(Ord(' '));
    Serial_WriteHex(ReadFar);
    Serial_WriteChar(10);
    Sched_TerminateCurrentTask;
    Arm64Sync := frame;
  end
  else
  begin
    Fault(esr, PQWord(frame)[32], ReadFar);
    Arm64Sync := frame;
  end;
end;

end.
