{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: program_loader - start a user program from a file image, whatever
  its executable format.

  x86_64 programs are PE (pe_loader), ARM64 programs are ELF (elf_loader).
  Callers (kernel boot, the internal shell's `run`, logout, sudo) hand over
  the raw file; this unit picks the loader by the file's magic and refuses a
  format or machine the running architecture cannot execute.
  =========================================================================
}
unit program_loader;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ True when `raw` (size bytes) is a program this architecture can run. }
function Program_IsRunnable(raw: PByte; size: Cardinal): Boolean;

{ Start it. Same parameters as PELoader_LoadAndRun; returns the thread id or
  -1. The caller keeps ownership of `raw`. }
function Program_LoadAndRun(raw: PByte; size: Cardinal; runInBackground, isJailed,
  forceRoot: Boolean; name: PWord; priority: Byte): Integer;

implementation

uses arch_hal, pe_loader, elf_loader;

function IsElf(raw: PByte; size: Cardinal): Boolean;
begin
  IsElf := (size >= 20) and (raw[0] = $7F) and (raw[1] = Ord('E')) and
           (raw[2] = Ord('L')) and (raw[3] = Ord('F')) and
           ((Word(raw[18]) or (Word(raw[19]) shl 8)) = Hal_ElfMachine);
end;

function IsPe(raw: PByte; size: Cardinal): Boolean;
var
  lfanew: Cardinal;
begin
  IsPe := False;
  if (Hal_PeMachine = 0) or (size < 64) then Exit;
  if (raw[0] <> Ord('M')) or (raw[1] <> Ord('Z')) then Exit;
  lfanew := PCardinal(raw + 60)^;
  if (lfanew > size - 6) or (lfanew > size) then Exit;
  IsPe := (raw[lfanew] = Ord('P')) and (raw[lfanew + 1] = Ord('E')) and
          ((Word(raw[lfanew + 4]) or (Word(raw[lfanew + 5]) shl 8)) = Hal_PeMachine);
end;

function Program_IsRunnable(raw: PByte; size: Cardinal): Boolean;
begin
  Program_IsRunnable := (raw <> nil) and (IsElf(raw, size) or IsPe(raw, size));
end;

function Program_LoadAndRun(raw: PByte; size: Cardinal; runInBackground, isJailed,
  forceRoot: Boolean; name: PWord; priority: Byte): Integer;
begin
  Program_LoadAndRun := -1;
  if raw = nil then Exit;
  if IsElf(raw, size) then
    Program_LoadAndRun := ElfLoader_Spawn(raw, size, runInBackground, isJailed,
      forceRoot, name, priority)
  else if IsPe(raw, size) then
    Program_LoadAndRun := PELoader_LoadAndRun(raw, runInBackground, isJailed,
      forceRoot, name, priority);
end;

end.
