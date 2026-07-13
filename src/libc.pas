{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: LibC - Standard C Library Functions (Pascal Implementation)
  PURPOSE: Memory operations, string operations ported from C# to Pascal
  =========================================================================
}

unit libc;

{$mode objfpc}
{$h+}
{$inline on}
{$modeswitch advancedrecords}
{$modeswitch typehelpers}

interface

{ Memory operations }
procedure MemSet(dest: Pointer; val: Byte; count: Cardinal); cdecl; public name 'MemSet_Pas';
procedure MemCopy(dest: Pointer; src: Pointer; count: Cardinal); cdecl; public name 'MemCopy_Pas';
function MemCmp(ptr1: Pointer; ptr2: Pointer; count: Cardinal): Integer; cdecl; public name 'MemCmp_Pas';

implementation

{ MemSet: Fill memory region with a byte value }
procedure MemSet(dest: Pointer; val: Byte; count: Cardinal); cdecl;
var
  p: PByte;
  i: Cardinal;
begin
  p := PByte(dest);
  for i := 0 to count - 1 do
  begin
    p^ := val;
    Inc(p);
  end;
end;

{ MemCopy: Copy memory region from src to dest }
procedure MemCopy(dest: Pointer; src: Pointer; count: Cardinal); cdecl;
var
  dst: PByte;
  s: PByte;
  i: Cardinal;
begin
  dst := PByte(dest);
  s := PByte(src);

  { Simple byte-by-byte copy }
  for i := 0 to count - 1 do
  begin
    dst^ := s^;
    Inc(dst);
    Inc(s);
  end;
end;

{ MemCmp: Compare two memory regions }
function MemCmp(ptr1: Pointer; ptr2: Pointer; count: Cardinal): Integer; cdecl;
var
  p1: PByte;
  p2: PByte;
  i: Cardinal;
begin
  p1 := PByte(ptr1);
  p2 := PByte(ptr2);

  for i := 0 to count - 1 do
  begin
    if p1^ < p2^ then
    begin
      MemCmp := -1;
      Exit;
    end
    else if p1^ > p2^ then
    begin
      MemCmp := 1;
      Exit;
    end;
    Inc(p1);
    Inc(p2);
  end;

  MemCmp := 0;
end;

end.