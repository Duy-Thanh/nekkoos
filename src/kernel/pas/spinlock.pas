{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: Spinlock - Interrupt-safe spinlock primitives (Pascal port)
  PURPOSE: Wraps Arch_Spinlock* and Arch_GetFlags/fences so C# Spinlock
           struct can delegate to Pascal. The C# struct owns the uint
           _lockStatus field; Pascal receives a PCardinal to it.
  =========================================================================
}

unit spinlock;

{$mode objfpc}
{$h+}
{$inline on}
{$TYPEINFO OFF}

interface

uses arch_interface;

function Spinlock_AcquireSafe_Pas(lockVar: PCardinal): Byte; cdecl;
procedure Spinlock_ReleaseSafe_Pas(lockVar: PCardinal; intsWereEnabled: Byte); cdecl;
function Spinlock_IsLocked_Pas(lockVar: PCardinal): Byte; cdecl;
procedure Spinlock_Acquire_Pas(lockVar: PCardinal); cdecl;
procedure Spinlock_Release_Pas(lockVar: PCardinal); cdecl;

implementation

function Spinlock_AcquireSafe_Pas(lockVar: PCardinal): Byte; cdecl;
  public name 'Spinlock_AcquireSafe_Pas';
var
  intsEnabled: Byte;
begin
  { Arch_InterruptsEnabled, not a test of RFLAGS bit 9: that bit is not the
    interrupt flag on other architectures (ARM64: bit 9 is the debug mask). }
  if Arch_InterruptsEnabled() <> 0 then intsEnabled := 1 else intsEnabled := 0;
  Arch_DisableInterrupts();
  Arch_SpinlockAcquire(lockVar);
  Arch_CompilerFence();
  Result := intsEnabled;
end;

procedure Spinlock_ReleaseSafe_Pas(lockVar: PCardinal; intsWereEnabled: Byte); cdecl;
  public name 'Spinlock_ReleaseSafe_Pas';
begin
  Arch_CompilerFence();
  Arch_StoreFence();
  Arch_SpinlockRelease(lockVar);
  if intsWereEnabled <> 0 then Arch_EnableInterrupts();
end;

function Spinlock_IsLocked_Pas(lockVar: PCardinal): Byte; cdecl;
  public name 'Spinlock_IsLocked_Pas';
begin
  if lockVar^ <> 0 then Result := 1 else Result := 0;
end;

procedure Spinlock_Acquire_Pas(lockVar: PCardinal); cdecl;
  public name 'Spinlock_Acquire_Pas';
begin
  Arch_SpinlockAcquire(lockVar);
  Arch_CompilerFence();
end;

procedure Spinlock_Release_Pas(lockVar: PCardinal); cdecl;
  public name 'Spinlock_Release_Pas';
begin
  Arch_CompilerFence();
  Arch_StoreFence();
  Arch_SpinlockRelease(lockVar);
end;

end.
