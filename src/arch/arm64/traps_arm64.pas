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
    { Core 0 owns scheduler time (sleep deadlines are counted in these ticks). }
    if Sched_IsReady and (Hal_CurrentCoreId = 0) then Sched_BumpSystemTicks(1);
    if Sched_IsReady then Arm64Irq := Sched_SwitchTask(frame);
  end;
  Arm64_IrqEnd(iar);
end;

{ The generic syscall switch (syscall_dispatch.pas). Returns the frame to resume. }
function SyscallHandler(frame: QWord): QWord; cdecl; external name 'SyscallHandler';

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
    if fromUser then Arm64Sync := SyscallHandler(frame)
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
