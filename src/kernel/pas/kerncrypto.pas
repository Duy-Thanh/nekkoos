{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: KernCrypto - Baremetal SHA-256 + Hex Utilities (Pascal Implementation)
  PURPOSE: Pure-algorithm, architecture-independent crypto primitives ported
           from src/KernCrypto.cs so they can be reused when the OS is
           ported to other CPU architectures.
  =========================================================================
}

unit kerncrypto;

{$mode objfpc}
{$h+}
{$inline on}

interface

{ NOTE: C# `char` is a 2-byte UTF-16 code unit, so all "char*" parameters
  here use PWord (16-bit) rather than PByte/PAnsiChar to keep the exact
  same binary layout the Kernel.cs/Syscall.cs callers already expect. }

procedure SHA256_Compute(data: PByte; len: QWord; outputHash: PByte); cdecl; public name 'SHA256_Compute_Pas';
function HexToBytes(hex: PWord; outBytes: PByte; maxOutBytes: LongInt): LongInt; cdecl; public name 'HexToBytes_Pas';
procedure BytesToHex(bytes: PByte; len: LongInt; outHex: PWord); cdecl; public name 'BytesToHex_Pas';
function ConstantTimeEq(a: PWord; b: PWord; maxLen: LongInt): Byte; cdecl; public name 'ConstantTimeEq_Pas';
procedure ZeroMemChar(buf: PWord; len: LongInt); cdecl; public name 'ZeroMemChar_Pas';
procedure ZeroMemByte(buf: PByte; len: LongInt); cdecl; public name 'ZeroMemByte_Pas';

implementation

const
  SHA256_K: array[0..63] of Cardinal = (
    $428a2f98, $71374491, $b5c0fbcf, $e9b5dba5, $3956c25b, $59f111f1, $923f82a4, $ab1c5ed5,
    $d807aa98, $12835b01, $243185be, $550c7dc3, $72be5d74, $80deb1fe, $9bdc06a7, $c19bf174,
    $e49b69c1, $efbe4786, $0fc19dc6, $240ca1cc, $2de92c6f, $4a7484aa, $5cb0a9dc, $76f988da,
    $983e5152, $a831c66d, $b00327c8, $bf597fc7, $c6e00bf3, $d5a79147, $06ca6351, $14292967,
    $27b70a85, $2e1b2138, $4d2c6dfc, $53380d13, $650a7354, $766a0abb, $81c2c92e, $92722c85,
    $a2bfe8a1, $a81a664b, $c24b8b70, $c76c51a3, $d192e819, $d6990624, $f40e3585, $106aa070,
    $19a4c116, $1e376c08, $2748774c, $34b0bcb5, $391c0cb3, $4ed8aa4a, $5b9cca4f, $682e6ff3,
    $748f82ee, $78a5636f, $84c87814, $8cc70208, $90befffa, $a4506ceb, $bef9a3f7, $c67178f2
  );

  SHA256_H0: array[0..7] of Cardinal = (
    $6a09e667, $bb67ae85, $3c6ef372, $a54ff53a, $510e527f, $9b05688c, $1f83d9ab, $5be0cd19
  );

function ROTR(x: Cardinal; n: Integer): Cardinal; inline;
begin
  ROTR := (x shr n) or (x shl (32 - n));
end;

function CH(x, y, z: Cardinal): Cardinal; inline;
begin
  CH := (x and y) xor ((not x) and z);
end;

function MAJ(x, y, z: Cardinal): Cardinal; inline;
begin
  MAJ := (x and y) xor (x and z) xor (y and z);
end;

function EP0(x: Cardinal): Cardinal; inline;
begin
  EP0 := ROTR(x, 2) xor ROTR(x, 13) xor ROTR(x, 22);
end;

function EP1(x: Cardinal): Cardinal; inline;
begin
  EP1 := ROTR(x, 6) xor ROTR(x, 11) xor ROTR(x, 25);
end;

function SIG0(x: Cardinal): Cardinal; inline;
begin
  SIG0 := ROTR(x, 7) xor ROTR(x, 18) xor (x shr 3);
end;

function SIG1(x: Cardinal): Cardinal; inline;
begin
  SIG1 := ROTR(x, 17) xor ROTR(x, 19) xor (x shr 10);
end;

{ SHA256_Compute: baremetal SHA-256, stack-only (no Heap usage) }
procedure SHA256_Compute(data: PByte; len: QWord; outputHash: PByte); cdecl;
var
  H: array[0..7] of Cardinal;
  W: array[0..63] of Cardinal;
  blk: array[0..63] of Byte;
  totalBits, paddedLen, offset: QWord;
  i, t: Integer;
  a, b, c, d, e, f, g, hh: Cardinal;
  T1, T2: Cardinal;
begin
  if (data = nil) or (outputHash = nil) or (len = 0) then Exit;
  if len > $10000000 then Exit; { Giới hạn 256MB }

  for i := 0 to 7 do H[i] := SHA256_H0[i];

  totalBits := len * 8;
  paddedLen := len + 1;
  while paddedLen mod 64 <> 56 do Inc(paddedLen);
  paddedLen := paddedLen + 8;

  offset := 0;
  while offset < paddedLen do
  begin
    for i := 0 to 63 do
    begin
      if offset + QWord(i) < len then blk[i] := data[offset + QWord(i)]
      else if offset + QWord(i) = len then blk[i] := $80
      else blk[i] := $00;
    end;

    if offset + 64 >= paddedLen then
    begin
      for i := 0 to 7 do
        blk[63 - i] := Byte((totalBits shr (i * 8)) and $FF);
    end;

    for t := 0 to 15 do
      W[t] := (Cardinal(blk[t * 4]) shl 24) or (Cardinal(blk[t * 4 + 1]) shl 16) or
              (Cardinal(blk[t * 4 + 2]) shl 8) or Cardinal(blk[t * 4 + 3]);
    for t := 16 to 63 do
      W[t] := SIG1(W[t - 2]) + W[t - 7] + SIG0(W[t - 15]) + W[t - 16];

    a := H[0]; b := H[1]; c := H[2]; d := H[3];
    e := H[4]; f := H[5]; g := H[6]; hh := H[7];

    for t := 0 to 63 do
    begin
      T1 := hh + EP1(e) + CH(e, f, g) + SHA256_K[t] + W[t];
      T2 := EP0(a) + MAJ(a, b, c);
      hh := g; g := f; f := e; e := d + T1;
      d := c; c := b; b := a; a := T1 + T2;
    end;

    H[0] := H[0] + a; H[1] := H[1] + b; H[2] := H[2] + c; H[3] := H[3] + d;
    H[4] := H[4] + e; H[5] := H[5] + f; H[6] := H[6] + g; H[7] := H[7] + hh;

    offset := offset + 64;
  end;

  for i := 0 to 7 do
  begin
    outputHash[i * 4]     := Byte((H[i] shr 24) and $FF);
    outputHash[i * 4 + 1] := Byte((H[i] shr 16) and $FF);
    outputHash[i * 4 + 2] := Byte((H[i] shr 8) and $FF);
    outputHash[i * 4 + 3] := Byte(H[i] and $FF);
  end;
end;

function HexNibble(c: Word): Integer; inline;
begin
  if (c >= Word(Ord('0'))) and (c <= Word(Ord('9'))) then Exit(c - Word(Ord('0')));
  if (c >= Word(Ord('a'))) and (c <= Word(Ord('f'))) then Exit(c - Word(Ord('a')) + 10);
  if (c >= Word(Ord('A'))) and (c <= Word(Ord('F'))) then Exit(c - Word(Ord('A')) + 10);
  HexNibble := -1;
end;

function HexToBytes(hex: PWord; outBytes: PByte; maxOutBytes: LongInt): LongInt; cdecl;
var
  i, o, hi, lo: LongInt;
begin
  i := 0; o := 0;
  while (hex[i] <> 0) and (hex[i + 1] <> 0) and (o < maxOutBytes) do
  begin
    hi := HexNibble(hex[i]);
    lo := HexNibble(hex[i + 1]);
    if (hi < 0) or (lo < 0) then Break;
    outBytes[o] := Byte((hi shl 4) or lo);
    Inc(o);
    i := i + 2;
  end;
  HexToBytes := o;
end;

procedure BytesToHex(bytes: PByte; len: LongInt; outHex: PWord); cdecl;
const
  digits: array[0..15] of Word = (
    Word(Ord('0')), Word(Ord('1')), Word(Ord('2')), Word(Ord('3')),
    Word(Ord('4')), Word(Ord('5')), Word(Ord('6')), Word(Ord('7')),
    Word(Ord('8')), Word(Ord('9')), Word(Ord('a')), Word(Ord('b')),
    Word(Ord('c')), Word(Ord('d')), Word(Ord('e')), Word(Ord('f'))
  );
var
  i: LongInt;
begin
  for i := 0 to len - 1 do
  begin
    outHex[i * 2]     := digits[(bytes[i] shr 4) and $F];
    outHex[i * 2 + 1] := digits[bytes[i] and $F];
  end;
  outHex[len * 2] := 0;
end;

{ ConstantTimeEq: returns 1 (true) / 0 (false); byte return keeps the ABI
  unambiguous across the cdecl boundary (C# bool is a single byte anyway). }
function ConstantTimeEq(a: PWord; b: PWord; maxLen: LongInt): Byte; cdecl;
var
  diff: Word;
  endedA, endedB: Boolean;
  ca, cb: Word;
  i: LongInt;
begin
  diff := 0;
  endedA := False; endedB := False;
  for i := 0 to maxLen - 1 do
  begin
    if endedA then ca := 0 else ca := a[i];
    if endedB then cb := 0 else cb := b[i];
    if a[i] = 0 then endedA := True;
    if b[i] = 0 then endedB := True;
    diff := diff or (ca xor cb);
  end;
  if diff = 0 then ConstantTimeEq := 1 else ConstantTimeEq := 0;
end;

procedure ZeroMemChar(buf: PWord; len: LongInt); cdecl;
var
  i: LongInt;
begin
  for i := 0 to len - 1 do buf[i] := 0;
end;

procedure ZeroMemByte(buf: PByte; len: LongInt); cdecl;
var
  i: LongInt;
begin
  for i := 0 to len - 1 do buf[i] := 0;
end;

end.
