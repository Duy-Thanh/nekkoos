{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: platform_bootstrap - x86_64 legacy hardware wiring.
  PORTED FROM: src/arch/x86_64/PlatformBootstrap.cs (deleted).

  ARCH: x86_64 ONLY.

  Kernel-generic code (KernelMain) must never name a legacy device - not the
  COM1 UART, not the i8253 PIT, not the 8042 PS/2 controller. All of that lives
  here so that porting to another architecture means replacing exactly this
  one unit: PL011 or USB instead of the UART, an architecture timer instead of
  the PIT, a different input controller instead of PS/2.

  CALL ORDER IS PART OF THE CONTRACT. The sequence is:
      EarlySerial()            before any diagnostic print
      ...                      IDT must be live
      HookPs2IsrGates()        installs the PS/2 vectors
      ...                      scheduler must be running
      InitLegacyTimer()        the legacy tick source
  Reordering these fails in ways that are hard to read: printing before COM1
  is configured loses the message, and installing gates before the IDT exists
  writes into an unmapped table.
  =========================================================================
}

unit platform_bootstrap;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Bring up COM1. Must run before any diagnostic output. }
procedure Platform_EarlySerial;

{ Install the PS/2 interrupt vectors. Requires a live IDT. }
procedure Platform_HookPs2IsrGates;

{ Program the legacy PIT tick source. Requires the scheduler to be running. }
procedure Platform_InitLegacyTimer(targetFrequencyHz: Cardinal);

{ Discard anything the 8042 buffered while the kernel was booting, so stale
  keystrokes are not delivered to the first shell. }
procedure Platform_DrainPs2Buffers;

implementation

uses arch_interface, serial, idt, pit, io, libc;

{ PS/2 controller ports. }
const
  PS2_DATA_PORT   = $60;   { read/write data }
  PS2_STATUS_PORT = $64;   { status/command }

  { Status bit 0: a byte is waiting in the output buffer. }
  PS2_STATUS_OBF = 1;

  { Vector numbers chosen to match the IOAPIC routing set up in ioapic.pas:
    IRQ1 -> 33, IRQ12 -> 44. The IDT gate and the IOAPIC redirect must agree
    or a keystroke vector would have no handler. }
  PS2_KEYBOARD_VECTOR = 33;
  PS2_MOUSE_VECTOR    = 44;

procedure Platform_EarlySerial;
begin
  Serial_Init;
end;

procedure Platform_HookPs2IsrGates;
begin
  Idt_SetGate(PS2_KEYBOARD_VECTOR, Arch_GetIsrKeyboard);
  Idt_SetGate(PS2_MOUSE_VECTOR, Arch_GetIsrMouse);
end;

procedure Platform_InitLegacyTimer(targetFrequencyHz: Cardinal);
begin
  Pit_Init(targetFrequencyHz);
end;

procedure Platform_DrainPs2Buffers;
begin
  { Read the data port to clear the buffer. The compiler fence keeps the
    status re-read from being hoisted out of the loop, which would make this
    spin forever on a stale "data ready" bit. }
  while (Io_In8(PS2_STATUS_PORT) and PS2_STATUS_OBF) <> 0 do
  begin
    Arch_CompilerFence;
    Io_In8(PS2_DATA_PORT);
  end;
end;

end.
