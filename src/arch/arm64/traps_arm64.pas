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

uses arch_interface, arch_hal, scheduler;

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

function Arm64Sync(frame: QWord): QWord; cdecl; public name 'Arm64Sync';
var
  esr: QWord;
begin
  esr := ReadEsr;
  if (esr shr 26) = EC_SVC64 then
    { svc #0 from kernel mode is Arch_ForceYield. }
    Arm64Sync := Sched_YieldHandler(frame)
  else
  begin
    Fault(esr, PQWord(frame)[32], ReadFar);
    Arm64Sync := frame;
  end;
end;

end.
