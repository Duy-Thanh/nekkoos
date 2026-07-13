{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: Arch - Architecture Abstraction Layer Interface (Pascal)
  PURPOSE: Abstract CPU features and link static assembly implementations
  =========================================================================
}

unit arch;

{$mode objfpc}
{$h+}

{ Link static object file compiled by NASM to resolve symbols natively }
{$link ../../Hardware.obj}

interface

{ CPU Management }
function Arch_ReadTimestamp: QWord; cdecl; external name 'ReadTSC';
procedure Arch_Pause; cdecl; external name 'HltCPU';

{ Atomic Operations }
function Arch_AtomicCompareExchange(var target: Cardinal; newVal: Cardinal; expectedVal: Cardinal): Cardinal; cdecl; external name 'InterlockedCompareExchange';
procedure Arch_AtomicExchange(var target: Cardinal; value: Cardinal); cdecl; external name 'AtomicExchange';

implementation

end.