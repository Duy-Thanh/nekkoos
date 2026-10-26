{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: StrandScheduler - Zero-Context Strand Scheduler (Pascal Implementation)
  PURPOSE: Architecture-independent round-robin scheduling algorithm extracted
           from C# StrandScheduler. Function pointer storage/execution stays
           in C# since that's inherently language/ABI-specific.
  =========================================================================
}

unit strandscheduler;

{$mode objfpc}
{$h+}
{$M-}

interface

const
  STRAND_DEAD = 0;
  STRAND_READY = 1;
  STRAND_RUNNING = 2;

{ Strand struct layout (must match C# exactly: 16 bytes)
  - Action: QWord (8 bytes) - function pointer (opaque to Pascal)
  - Active: Byte (1 byte) - state: 0=Dead, 1=Ready, 2=Running
  - Padding: 7 bytes
}
const
  STRAND_ACTION_OFFSET = 0;   { 8 bytes }
  STRAND_ACTIVE_OFFSET = 8;   { 1 byte }
  STRAND_SIZE = 16;           { Total struct size }

{ Core scheduling algorithm: find next Ready strand using round-robin.
  Parameters:
    strands: pointer to strand array (16 bytes per strand)
    strandCount: total number of strands in array
    currentStrand: pointer to current position (updated by this function)
  Returns: index of next Ready strand, or -1 if none found
}
function Strand_FindNextReady(strands: Pointer; strandCount: Integer; currentStrand: PInteger): Integer; cdecl; public name 'Strand_FindNextReady_Pas';

{ Strand engine (ported from StrandScheduler.cs): a table of tiny run-to-
  completion routines the boot thread's idle loop cycles through. }
procedure Strand_Init;
procedure Strand_Create(action: Pointer);
procedure Strand_RunCycle;

implementation

uses kstring, pmm, libc, spinlock, terminal;

function Strand_FindNextReady(strands: Pointer; strandCount: Integer; currentStrand: PInteger): Integer; cdecl;
var
  checkedCount, i: Integer;
  strandPtr: PByte;
  active: Byte;
begin
  Strand_FindNextReady := -1;

  if (strands = nil) or (currentStrand = nil) then Exit;
  if strandCount <= 0 then Exit;

  checkedCount := 0;

  { Round-robin search starting from currentStrand^ }
  while checkedCount < strandCount do
  begin
    i := currentStrand^;

    { Bounds check }
    if (i < 0) or (i >= strandCount) then
    begin
      currentStrand^ := 0;
      Exit;
    end;

    { Get pointer to strand[i] and read Active byte }
    strandPtr := PByte(strands) + (i * STRAND_SIZE);
    active := strandPtr[STRAND_ACTIVE_OFFSET];

    if active = STRAND_READY then
    begin
      { Found a Ready strand! }
      Strand_FindNextReady := i;
      { Advance currentStrand for next call }
      currentStrand^ := (i + 1) mod strandCount;
      Exit;
    end;

    { Not ready, advance to next }
    currentStrand^ := (i + 1) mod strandCount;
    Inc(checkedCount);
  end;

  { No Ready strand found }
end;

{ ── Engine state and API ──────────────────────────────────────────────────── }

const
  MAX_STRANDS = 256;

type
  TStrandAction = procedure;

var
  Strands: PByte = nil;
  StrandCount: Integer = 0;
  CurrentStrand: Integer = 0;
  StrandLock: Cardinal = 0;

procedure Strand_Init;
begin
  StrandCount := 0;
  Strands := PByte(Pmm_AllocatePage);       { zeroed by the allocator }
  Terminal_SetColor_Pas($00FF00FF);
  Terminal_Print_Pas(W('[+] Zero-Context Strands Engine Forged in Steel!'#13#10));
end;

procedure Strand_Create(action: Pointer);
var
  irq: Byte;
  i: Integer;
  entry: PByte;
begin
  if action = nil then Exit;
  irq := Spinlock_AcquireSafe_Pas(@StrandLock);

  { Reuse a dead slot before growing the table. }
  for i := 0 to StrandCount - 1 do
  begin
    entry := Strands + i * STRAND_SIZE;
    if entry[STRAND_ACTIVE_OFFSET] = STRAND_DEAD then
    begin
      PPointer(entry)^ := action;
      entry[STRAND_ACTIVE_OFFSET] := STRAND_READY;
      Spinlock_ReleaseSafe_Pas(@StrandLock, irq);
      Exit;
    end;
  end;

  if StrandCount < MAX_STRANDS then
  begin
    entry := Strands + StrandCount * STRAND_SIZE;
    PPointer(entry)^ := action;
    entry[STRAND_ACTIVE_OFFSET] := STRAND_READY;
    Inc(StrandCount);
  end;
  Spinlock_ReleaseSafe_Pas(@StrandLock, irq);
end;

procedure Strand_RunCycle;
var
  irq: Byte;
  selected: Integer;
  entry: PByte;
  action: Pointer;
begin
  irq := Spinlock_AcquireSafe_Pas(@StrandLock);

  if StrandCount = 0 then
  begin
    Spinlock_ReleaseSafe_Pas(@StrandLock, irq);
    Exit;
  end;

  selected := Strand_FindNextReady(Strands, StrandCount, @CurrentStrand);
  if selected <> -1 then
  begin
    entry := Strands + selected * STRAND_SIZE;
    entry[STRAND_ACTIVE_OFFSET] := STRAND_RUNNING;
  end;

  Spinlock_ReleaseSafe_Pas(@StrandLock, irq);

  { The routine runs outside the lock: it may itself create strands. }
  if selected <> -1 then
  begin
    entry := Strands + selected * STRAND_SIZE;
    action := PPointer(entry)^;
    if action <> nil then TStrandAction(action)();

    irq := Spinlock_AcquireSafe_Pas(@StrandLock);
    { Only go back to Ready if nothing killed it while it ran. }
    if entry[STRAND_ACTIVE_OFFSET] = STRAND_RUNNING then
      entry[STRAND_ACTIVE_OFFSET] := STRAND_READY;
    Spinlock_ReleaseSafe_Pas(@StrandLock, irq);
  end;
end;

end.
