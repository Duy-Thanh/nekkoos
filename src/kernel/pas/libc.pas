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
function FatNameValid(input: PWord): Cardinal; cdecl; public name 'FatNameValid_Pas';
function OctalStrToUInt(str: PWord): Cardinal; cdecl; public name 'OctalStrToUInt_Pas';
function SplitTwoArgs(rest: PWord; outFirst: PWord; firstCap: Integer; outSecond: PWord; secondCap: Integer): Byte; cdecl; public name 'SplitTwoArgs_Pas';

function Atoi(str: PWord): Cardinal; cdecl; public name 'Atoi_Pas';

{ Char classification: returns 1 if byte is printable ASCII (32-126, \n, \t),
  0 if not. Used by cat builtin to filter non-printable bytes. }
function IsPrintableChar(c: Word): Byte; cdecl; public name 'IsPrintableChar_Pas';

{ Compare wide string against fixed-byte ASCII buffer (e.g. Scheduler.Threads[].Name).
  Returns 1 if both strings have same length and all bytes match, 0 otherwise.
  Used by syscall 14 (find PID by name). }
function StrEqWideBytes(wideStr: PWord; byteStr: PByte): Byte; cdecl; public name 'StrEqWideBytes_Pas';

{ Copy wide string from src to dest up to cap-1 chars, then null-terminate.
  Returns number of chars copied (not counting terminator). }
function StrCpyLimited(dest: PWord; src: PWord; cap: Cardinal): Cardinal; cdecl; public name 'StrCpyLimited_Pas';

{ Decimal conversion: converts a Cardinal to decimal string representation
  writing into buf starting at position *idx, advancing idx. Returns nothing.
  Ported from Shell.cs AppendDecimalToBuffer — shared across kernel and apps. }
procedure AppendDecimal_Pas(num: Cardinal; buf: PByte; idx: PInteger); cdecl; public name 'AppendDecimal_Pas';

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


{ FatNameValid: kiem tra ten co nam trong gioi han FAT16 8.3 khong.
  Tra ve 1 = hop le (base <= 8 ky tu, duoi <= 3 ky tu), 0 = qua dai. }
function FatNameValid(input: PWord): Cardinal; cdecl;
var
  mb, me, k: Integer;
begin
  FatNameValid := 0;
  if input = nil then Exit;

  mb := 0;
  while (input[mb] <> 0) and (input[mb] <> Ord('.')) do Inc(mb);

  me := -1;
  if input[mb] = Ord('.') then
  begin
    me := 0;
    k := mb + 1;
    while input[k] <> 0 do begin Inc(me); Inc(k); end;
  end;

  if (mb <= 8) and (me <= 3) then FatNameValid := 1;
end;


{ OctalStrToUInt: doc chuoi so he 8 ("755") thanh gia tri Cardinal. Dung lai
  o dau khong phai chu so thi dung va tra ket qua tich luy den do. }
function OctalStrToUInt(str: PWord): Cardinal; cdecl;
var
  i: Integer;
begin
  OctalStrToUInt := 0;
  if str = nil then Exit;
  i := 0;
  while str[i] <> 0 do
  begin
    if (str[i] < Ord('0')) or (str[i] > Ord('7')) then Break;
    OctalStrToUInt := OctalStrToUInt * 8 + Cardinal(str[i]) - Ord('0');
    Inc(i);
  end;
end;

{ SplitTwoArgs: tach token dau tien (den khoang trang) vao outFirst,
  phan con lai (co the chua khoang trang) vao outSecond.
  Tra ve 1 khi du 2 token, 0 neu thieu. }
function SplitTwoArgs(rest: PWord; outFirst: PWord; firstCap: Integer; outSecond: PWord; secondCap: Integer): Byte; cdecl;
var
  i, f, sec: Integer;
begin
  SplitTwoArgs := 0;
  if (rest = nil) or (outFirst = nil) or (outSecond = nil) then Exit;

  i := 0; f := 0;
  while (rest[i] <> 0) and (rest[i] <> Ord(' ')) and (f < firstCap - 1) do
  begin outFirst[f] := rest[i]; Inc(f); Inc(i); end;
  outFirst[f] := 0;
  if f = 0 then Exit;

  while rest[i] = Ord(' ') do Inc(i);
  if rest[i] = 0 then Exit;

  sec := 0;
  while (rest[i] <> 0) and (sec < secondCap - 1) do
  begin outSecond[sec] := rest[i]; Inc(sec); Inc(i); end;
  outSecond[sec] := 0;
  SplitTwoArgs := 1;
end;

{ AppendDecimal_Pas: converts a Cardinal to decimal string representation,
  writing ASCII bytes into buf starting at *idx, advancing idx. }
procedure AppendDecimal_Pas(num: Cardinal; buf: PByte; idx: PInteger); cdecl;
var
  rev: array[0..15] of Byte;
  c, i: Integer;
  digit: Byte;
begin
  if (buf = nil) or (idx = nil) then
    Exit;

  c := 0;
  if num = 0 then
  begin
    buf[idx^] := Ord('0');
    Inc(idx^);
    Exit;
  end;

  while num > 0 do
  begin
    digit := Byte(num mod 10);
    rev[c] := Ord('0') + digit;
    Inc(c);
    num := num div 10;
  end;

  for i := c - 1 downto 0 do
  begin
    buf[idx^] := rev[i];
    Inc(idx^);
  end;
end;

{ Atoi_Pas: converts a decimal string to Cardinal (base 10). Stops at first non-digit. }
function Atoi(str: PWord): Cardinal; cdecl;
var
  i: Integer;
begin
  Atoi := 0;
  if str = nil then Exit;
  i := 0;
  while str[i] <> 0 do
  begin
    if (str[i] < Ord('0')) or (str[i] > Ord('9')) then Break;
    Atoi := Atoi * 10 + Cardinal(str[i]) - Ord('0');
    Inc(i);
  end;
end;

{ IsPrintableChar: returns 1 if char is printable ASCII (32..126, \n, \t), else 0. }
function IsPrintableChar(c: Word): Byte; cdecl;
begin
  if c = 10 then IsPrintableChar := 1
  else if c = 9 then IsPrintableChar := 1
  else if (c >= 32) and (c <= 126) then IsPrintableChar := 1
  else IsPrintableChar := 0;
end;

{ StrEqWideBytes: compares a wide-char string against a fixed ASCII byte buffer.
  Returns 1 if lengths match and all bytes are equal, 0 otherwise. }
function StrEqWideBytes(wideStr: PWord; byteStr: PByte): Byte; cdecl;
var
  wideLen, i: Integer;
  matched: Boolean;
begin
  StrEqWideBytes := 0;
  if (wideStr = nil) or (byteStr = nil) then Exit;

  wideLen := 0;
  while wideStr[wideLen] <> 0 do Inc(wideLen);

  matched := True;
  for i := 0 to wideLen - 1 do
  begin
    if PByte(byteStr)[i] <> PWord(wideStr)[i] then
    begin
      matched := False;
      Break;
    end;
  end;
  if matched and (PByte(byteStr)[wideLen] <> 0) then matched := False;

  if matched then StrEqWideBytes := 1;
end;

{ StrCpyLimited: copy wide string from src to dest, capped at cap-1 chars + null terminator. }
function StrCpyLimited(dest: PWord; src: PWord; cap: Cardinal): Cardinal; cdecl;
var
  i: Cardinal;
begin
  StrCpyLimited := 0;
  if (dest = nil) or (src = nil) or (cap = 0) then Exit;

  i := 0;
  while (i < cap - 1) and (PWord(src)[i] <> 0) do
  begin
    PWord(dest)[i] := PWord(src)[i];
    Inc(i);
  end;
  PWord(dest)[i] := 0;
  StrCpyLimited := i;
end;

end.