{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: LibC - Standard C Library Functions (Pascal Implementation)
  PURPOSE: Memory operations, string operations ported from C# to Pascal.
           C# char is UTF-16 (2 bytes), so PWord is used for char* params.
  =========================================================================
}

unit libc;

{$mode objfpc}
{$h+}
{$inline on}

interface

{ Memory operations }
procedure MemSet(dest: Pointer; val: Byte; count: Cardinal); cdecl; public name 'MemSet_Pas';
procedure MemCopy(dest: Pointer; src: Pointer; count: Cardinal); cdecl; public name 'MemCopy_Pas';
function MemCmp(ptr1: Pointer; ptr2: Pointer; count: Cardinal): Integer; cdecl; public name 'MemCmp_Pas';

{ String operations - Note: C# char* is UTF-16 (2 bytes), use PWord }
function StrCmp(str1: PWord; str2: PWord): Byte; cdecl; public name 'StrCmp_Pas';
function StrStartsWith(str: PWord; prefix: PWord): Byte; cdecl; public name 'StrStartsWith_Pas';
procedure FormatFATName(input: PWord; output: PByte); cdecl; public name 'FormatFATName_Pas';

implementation

{ Helper: convert char to lowercase (inline, not exported) }
function ToLowerCase(c: Word): Word; inline;
begin
  if (c >= Ord('A')) and (c <= Ord('Z')) then
    ToLowerCase := c + 32
  else
    ToLowerCase := c;
end;

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

{ StrCmp: Case-insensitive string comparison. Returns 1 if equal, 0 if not. }
function StrCmp(str1: PWord; str2: PWord): Byte; cdecl;
var
  i: Integer;
begin
  StrCmp := 0;
  if (str1 = nil) or (str2 = nil) then Exit;

  i := 0;
  while (str1[i] <> 0) and (str2[i] <> 0) do
  begin
    if ToLowerCase(str1[i]) <> ToLowerCase(str2[i]) then
      Exit;
    Inc(i);
  end;

  if (str1[i] = 0) and (str2[i] = 0) then
    StrCmp := 1;
end;

{ StrStartsWith: Check if str starts with prefix (case-insensitive). Returns 1 if yes, 0 if no. }
function StrStartsWith(str: PWord; prefix: PWord): Byte; cdecl;
var
  i: Integer;
begin
  StrStartsWith := 0;
  if (str = nil) or (prefix = nil) then Exit;

  i := 0;
  while prefix[i] <> 0 do
  begin
    if str[i] = 0 then Exit;
    if ToLowerCase(str[i]) <> ToLowerCase(prefix[i]) then Exit;
    Inc(i);
  end;

  StrStartsWith := 1;
end;

{ FormatFATName: Convert filename to FAT 8.3 format (11 bytes: 8 name + 3 ext, space-padded, uppercase) }
procedure FormatFATName(input: PWord; output: PByte); cdecl;
var
  i, inPos, outPos: Integer;
  c: Word;
begin
  if (input = nil) or (output = nil) then Exit;

  { Initialize output with spaces }
  for i := 0 to 10 do
    output[i] := Ord(' ');

  inPos := 0;
  outPos := 0;

  { Copy name part (up to 8 chars or dot) }
  while (input[inPos] <> 0) and (input[inPos] <> Ord('.')) and (outPos < 8) do
  begin
    c := input[inPos];
    Inc(inPos);

    { Convert lowercase to uppercase }
    if (c >= Ord('a')) and (c <= Ord('z')) then
      c := c - 32;

    output[outPos] := Byte(c);
    Inc(outPos);
  end;

  { Skip to dot }
  while (input[inPos] <> 0) and (input[inPos] <> Ord('.')) do
    Inc(inPos);

  { Process extension if dot found }
  if input[inPos] = Ord('.') then
  begin
    Inc(inPos);
    outPos := 8;

    while (input[inPos] <> 0) and (outPos < 11) do
    begin
      c := input[inPos];
      Inc(inPos);

      { Convert lowercase to uppercase }
      if (c >= Ord('a')) and (c <= Ord('z')) then
        c := c - 32;

      output[outPos] := Byte(c);
      Inc(outPos);
    end;
  end;
end;

end.
