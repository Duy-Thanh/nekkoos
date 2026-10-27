{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: terminal (ARM64, headless) - same API as the framebuffer terminal in
  src/kernel/pas/terminal.pas, but every character goes to the serial UART.
  Colours, framebuffer and cursor calls are accepted and ignored until this
  port has a display.
  =========================================================================
}
unit terminal;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

procedure Terminal_SetFB_Pas(aFb: Pointer; aWidth, aHeight, aScanLine: Cardinal);
  cdecl; public name 'Terminal_SetFB_Pas';
procedure Terminal_SetBackbuffer_Pas(aBuf: Pointer);
  cdecl; public name 'Terminal_SetBackbuffer_Pas';
procedure Terminal_SetCallbacks_Pas(aSerialWriteChar, aGetColor, aSetColor: Pointer);
  cdecl; public name 'Terminal_SetCallbacks_Pas';
procedure Terminal_SetColor_Pas(fg: Cardinal);
  cdecl; public name 'Terminal_SetColor_Pas';
procedure Terminal_Clear_Pas(color: Cardinal);
  cdecl; public name 'Terminal_Clear_Pas';
procedure Terminal_DrawChar_Pas(c: Word);
  cdecl; public name 'Terminal_DrawChar_Pas';
procedure Terminal_Print_Pas(str: PWord);
  cdecl; public name 'Terminal_Print_Pas';
procedure Terminal_PrintHex_Pas(val: QWord);
  cdecl; public name 'Terminal_PrintHex_Pas';
procedure Terminal_PrintDec_Pas(val: QWord);
  cdecl; public name 'Terminal_PrintDec_Pas';
procedure Terminal_PrintObfuscated_Pas(encryptedBytes: PByte; length: Integer);
  cdecl; public name 'Terminal_PrintObfuscated_Pas';
procedure Terminal_SyncRect_Pas(startX, startY, rectWidth, rectHeight: Cardinal);
  cdecl; public name 'Terminal_SyncRect_Pas';
procedure Terminal_GetCursor_Pas(out outX, outY: Cardinal);
  cdecl; public name 'Terminal_GetCursor_Pas';
procedure Terminal_SetCursor_Pas(aX, aY: Cardinal);
  cdecl; public name 'Terminal_SetCursor_Pas';

implementation

uses serial;

procedure Terminal_SetFB_Pas(aFb: Pointer; aWidth, aHeight, aScanLine: Cardinal); cdecl;
begin
end;

procedure Terminal_SetBackbuffer_Pas(aBuf: Pointer); cdecl;
begin
end;

procedure Terminal_SetCallbacks_Pas(aSerialWriteChar, aGetColor, aSetColor: Pointer); cdecl;
begin
end;

procedure Terminal_SetColor_Pas(fg: Cardinal); cdecl;
begin
end;

procedure Terminal_Clear_Pas(color: Cardinal); cdecl;
begin
end;

procedure Terminal_DrawChar_Pas(c: Word); cdecl;
begin
  if c = 10 then Serial_WriteChar(13);
  Serial_WriteChar(c);
end;

procedure Terminal_Print_Pas(str: PWord); cdecl;
begin
  if str = nil then Exit;
  while str^ <> 0 do
  begin
    Terminal_DrawChar_Pas(str^);
    Inc(str);
  end;
end;

procedure Terminal_PrintHex_Pas(val: QWord); cdecl;
begin
  Serial_WriteHex(val);
end;

procedure Terminal_PrintDec_Pas(val: QWord); cdecl;
var
  buf: array[0..19] of Byte;
  n: Integer;
begin
  n := 0;
  repeat
    buf[n] := Ord('0') + (val mod 10);
    val := val div 10;
    Inc(n);
  until val = 0;
  while n > 0 do
  begin
    Dec(n);
    Serial_WriteChar(buf[n]);
  end;
end;

procedure Terminal_PrintObfuscated_Pas(encryptedBytes: PByte; length: Integer); cdecl;
var
  i: Integer;
begin
  if encryptedBytes = nil then Exit;
  if length > 255 then Exit;
  for i := 0 to length - 1 do
    Terminal_DrawChar_Pas(Word(encryptedBytes[i] xor Byte((i * 13) + 7)));
end;

procedure Terminal_SyncRect_Pas(startX, startY, rectWidth, rectHeight: Cardinal); cdecl;
begin
end;

procedure Terminal_GetCursor_Pas(out outX, outY: Cardinal); cdecl;
begin
  outX := 0;
  outY := 0;
end;

procedure Terminal_SetCursor_Pas(aX, aY: Cardinal); cdecl;
begin
end;

end.
