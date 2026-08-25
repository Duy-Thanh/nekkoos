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

implementation

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

end.
