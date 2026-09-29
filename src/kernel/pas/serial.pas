{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: serial - COM1 (0x3F8) 16550 UART driver.
  PORTED FROM: src/drivers/x86-legacy/Serial.cs (deleted).

  The kernel's debug channel. QEMU redirects this to a file, so anything
  written here is the primary diagnostic when a boot or syscall path
  misbehaves (AGENTS.md §8.4 step 1: read the serial log first).

  x86_64 specific (port I/O), but isolated here so a new architecture only
  needs to provide a twin unit with the same API.
  =========================================================================
}

unit serial;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

const
  SERIAL_COM1 = $3F8;

procedure Serial_Init;
function  Serial_Received: Boolean;
function  Serial_ReadChar: Word;                 { blocking }
function  Serial_ReadCharNonBlocking: Word;      { $0000 when nothing pending }
procedure Serial_WriteChar(c: Word);
procedure Serial_WriteString(str: PWord);
procedure Serial_WriteHex(number: QWord);

implementation

procedure Arch_WritePort8(port: Word; value: Byte); cdecl; external name 'Arch_WritePort8';
function  Arch_ReadPort8(port: Word): Byte; cdecl; external name 'Arch_ReadPort8';

var
  Serial_Initialised: Boolean = False;

{ Line Status Register bit 5 = Transmitter Holding Register Empty. }
function IsTransmitEmpty: Boolean; inline;
begin
  IsTransmitEmpty := (Arch_ReadPort8(SERIAL_COM1 + 5) and $20) <> 0;
end;

procedure Serial_Init;
begin
  Arch_WritePort8(SERIAL_COM1 + 1, $00);   { disable interrupts }
  Arch_WritePort8(SERIAL_COM1 + 3, $80);   { DLAB on }
  Arch_WritePort8(SERIAL_COM1 + 0, $03);   { divisor lo -> 38400 baud }
  Arch_WritePort8(SERIAL_COM1 + 1, $00);   { divisor hi }
  Arch_WritePort8(SERIAL_COM1 + 3, $03);   { 8N1, DLAB off }
  Arch_WritePort8(SERIAL_COM1 + 2, $C7);   { FIFO on, cleared, 14-byte threshold }
  Arch_WritePort8(SERIAL_COM1 + 4, $0B);   { IRQs on, RTS/DSR set }
  Serial_Initialised := True;
end;

{ LSR bit 0 = Data Ready. }
function Serial_Received: Boolean;
begin
  Serial_Received := (Arch_ReadPort8(SERIAL_COM1 + 5) and $01) <> 0;
end;

function Serial_ReadChar: Word;
begin
  while not Serial_Received do
    Arch_ReadPort8(SERIAL_COM1);   { polled, result discarded; just re-read LSR }
  Serial_ReadChar := Word(Arch_ReadPort8(SERIAL_COM1));
end;

function Serial_ReadCharNonBlocking: Word;
begin
  if Serial_Received then
    Serial_ReadCharNonBlocking := Word(Arch_ReadPort8(SERIAL_COM1))
  else
    Serial_ReadCharNonBlocking := 0;
end;

procedure Serial_WriteChar(c: Word);
begin
  while not IsTransmitEmpty do
    Arch_ReadPort8(SERIAL_COM1);
  Arch_WritePort8(SERIAL_COM1, Byte(c and $FF));
end;

{ Emits CR before LF so the log stays readable in a raw terminal. }
procedure Serial_WriteString(str: PWord);
var
  i: Integer;
begin
  if str = nil then Exit;
  i := 0;
  while str[i] <> 0 do
  begin
    if str[i] = 10 then Serial_WriteChar(13);
    Serial_WriteChar(str[i]);
    Inc(i);
  end;
end;

procedure Serial_WriteHex(number: QWord);
const
  HexChars: array[0..15] of Char = '0123456789ABCDEF';
var
  buffer: array[0..15] of Word;
  index: Integer;
  temp: QWord;
  i: Integer;
begin
  Serial_WriteChar(Ord('0'));
  Serial_WriteChar(Ord('x'));
  if number = 0 then
  begin
    Serial_WriteChar(Ord('0'));
    Exit;
  end;

  index := 0;
  temp := number;
  while (temp > 0) and (index < 16) do
  begin
    buffer[index] := Ord(HexChars[temp mod 16]);
    temp := temp div 16;
    Inc(index);
  end;

  for i := index - 1 downto 0 do
    Serial_WriteChar(buffer[i]);
end;

end.
