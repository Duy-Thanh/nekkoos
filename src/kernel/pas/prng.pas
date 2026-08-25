{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: PRNG - Pseudo-Random Number Generator (Pascal Implementation)
  PURPOSE: Xorshift64* calling native assembly procedures from Hardware.obj
  =========================================================================
}

unit prng;

{$mode objfpc}
{$h+}

interface

{ Gọi trực tiếp các hàm Assembly gốc từ Hardware.obj }
function Arch_ReadTimestamp: QWord; cdecl; external name 'Arch_ReadTimestamp';
procedure Arch_SpinlockAcquire(var lockStatus: Cardinal); cdecl; external name 'Arch_SpinlockAcquire';
procedure Arch_SpinlockRelease(var lockStatus: Cardinal); cdecl; external name 'Arch_SpinlockRelease';

procedure PRNG_Init(pitTicks: QWord); cdecl; public name 'PRNG_Init_Pas';
function PRNG_Next: QWord; cdecl; public name 'PRNG_Next_Pas';
function PRNG_Next_Range(min: QWord; max: QWord): QWord; cdecl; public name 'PRNG_Next_Range_Pas';

implementation

var
  state: QWord = 0;
  lockStatus: Cardinal = 0;

{ Dựng hằng số $1337CAFE8BADBEEF }
function GetConst_Seed: QWord; inline;
begin
  GetConst_Seed := (QWord($1337CAFE) shl 32) or $8BADBEEF;
end;

{ Dựng hằng số $bf58476d1ce4e5b9 }
function GetConst_Mul1: QWord; inline;
begin
  GetConst_Mul1 := (QWord($bf58476d) shl 32) or $1ce4e5b9;
end;

{ Dựng hằng số $94d049bb133111eb }
function GetConst_Mul2: QWord; inline;
begin
  GetConst_Mul2 := (QWord($94d049bb) shl 32) or $133111eb;
end;

{ Dựng hằng số $2545F4914F6CDD1D }
function GetConst_Mul3: QWord; inline;
begin
  GetConst_Mul3 := (QWord($2545F491) shl 32) or $4F6CDD1D;
end;

function HAL_GetHardwareRandom(buffer: Pointer; length: Cardinal): Cardinal; cdecl; external name 'HAL_GetHardwareRandom';

{ PRNG_Init: Initialize the state seed }
procedure PRNG_Init(pitTicks: QWord); cdecl;
var
  hwRandom: QWord;
begin
  Arch_SpinlockAcquire(lockStatus);

  hwRandom := 0;
  if HAL_GetHardwareRandom(@hwRandom, 8) = 8 then
    state := hwRandom
  else
    state := Arch_ReadTimestamp;

  if state = 0 then
    state := GetConst_Seed;

  state := state xor (pitTicks shl 16);

  state := (state xor (state shr 30)) * GetConst_Mul1;
  state := (state xor (state shr 27)) * GetConst_Mul2;

  if state = 0 then
    state := GetConst_Seed;

  Arch_SpinlockRelease(lockStatus);
end;

{ PRNG_Next: Generate next 64-bit pseudo-random number }
function PRNG_Next: QWord; cdecl;
var
  resultVal: QWord;
  tsc: QWord;
begin
  Arch_SpinlockAcquire(lockStatus);

  { Guard against early calls before Init }
  if state = 0 then
  begin
    tsc := Arch_ReadTimestamp;
    if tsc = 0 then
      tsc := GetConst_Seed;
    state := tsc or 1;
  end;

  state := state xor (state shr 12);
  state := state xor (state shl 25);
  state := state xor (state shr 27);

  resultVal := state * GetConst_Mul3;

  Arch_SpinlockRelease(lockStatus);
  PRNG_Next := resultVal;
end;

{ PRNG_Next_Range: Generate random number within a range }
function PRNG_Next_Range(min: QWord; max: QWord): QWord; cdecl;
var
  range: QWord;
begin
  if min >= max then
  begin
    PRNG_Next_Range := min;
    Exit;
  end;

  range := max - min;
  if range = not QWord(0) then
  begin
    PRNG_Next_Range := PRNG_Next;
    Exit;
  end;

  range := range + 1;
  PRNG_Next_Range := min + (PRNG_Next mod range);
end;

end.