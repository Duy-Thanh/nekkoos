{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: serial (ARM64) - PL011 UART at 0x09000000 (QEMU virt).

  Twin of src/kernel/pas/serial.pas (the COM1 driver) with the same API.
  =========================================================================
}
unit serial;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

procedure Serial_Init;
function  Serial_Received: Boolean;
function  Serial_ReadChar: Word;                 { blocking }
function  Serial_ReadCharNonBlocking: Word;      { $0000 when nothing pending }
procedure Serial_WriteChar(c: Word);
procedure Serial_WriteString(str: PWord);
procedure Serial_WriteHex(number: QWord);

implementation

uses arch_interface;

const
  UART = QWord($09000000);
  FR   = $18;
  FR_TXFF = $20;
  FR_RXFE = $10;

procedure Serial_Init;
begin
  { QEMU leaves the PL011 enabled with usable defaults. }
end;

function Serial_Received: Boolean;
begin
  Serial_Received := (Arch_ReadMmio32(UART + FR) and FR_RXFE) = 0;
end;

function Serial_ReadCharNonBlocking: Word;
begin
  if Serial_Received then Serial_ReadCharNonBlocking := Word(Arch_ReadMmio32(UART) and $FF)
  else Serial_ReadCharNonBlocking := 0;
end;

function Serial_ReadChar: Word;
begin
  while not Serial_Received do ;
  Serial_ReadChar := Word(Arch_ReadMmio32(UART) and $FF);
end;

procedure Serial_WriteChar(c: Word);
begin
  while (Arch_ReadMmio32(UART + FR) and FR_TXFF) <> 0 do ;
  Arch_WriteMmio32(UART, c and $FF);
end;

procedure Serial_WriteString(str: PWord);
begin
  if str = nil then Exit;
  while str^ <> 0 do
  begin
    if str^ = 10 then Serial_WriteChar(13);
    Serial_WriteChar(str^);
    Inc(str);
  end;
end;

procedure Serial_WriteHex(number: QWord);
var
  i: Integer;
  d: Byte;
begin
  for i := 15 downto 0 do
  begin
    d := (number shr (i * 4)) and $F;
    if d < 10 then Serial_WriteChar(Ord('0') + d) else Serial_WriteChar(Ord('a') + d - 10);
  end;
end;

end.
