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

uses arch_interface, arch_hal, scheduler, terminal, serial, ipc_kernel;

const
  EC_SVC64 = $15;

procedure Fault(esr, elr, far: QWord); cdecl; external name 'Arm64Fault';
function ReadEsr: QWord; cdecl; external name 'Arch_ReadEsr';
function ReadFar: QWord; cdecl; external name 'Arch_ReadFar';

{ Keyboard input on this platform is the serial console. Each received byte
  becomes an IPC message (type 1, sender KBD_SENDER) for Disp_KeyboardRead,
  the same channel the x86 keyboard interrupt uses (there the sender is 33 and
  the payload a scancode; here it is already a character). }
const
  KBD_SENDER = 34;

procedure UartInput;
var
  b: Byte;
  c: Word;
begin
  { Clear the interrupt BEFORE draining the FIFO. Clearing afterwards loses a
    byte that lands between the last read and the clear: its interrupt is
    cleared with the rest, nothing re-asserts it, and input stalls (seen once
    in five soak runs of the ARM64 extra test: typing stopped mid-command). }
  Arm64_UartClearInterrupt;
  while Arm64_UartReadByte(b) do
  begin
    c := b;
    if c = 13 then c := 10;          { Enter: the x86 keymap delivers LF }
    if c = 127 then c := 8;          { DEL from a terminal = backspace }
    IpcK_SendFromInterrupt(1, KBD_SENDER, 0, c);
  end;
end;

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
  if (iar and $3FF) = ARM64_UART_INTID then UartInput;
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
