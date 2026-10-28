{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: echo_app - ARM64 keyboard check: read a line with App_GetChar
  (syscall 4, fed by the UART interrupt) and print it back.
  =========================================================================
}
unit echo_app;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

procedure AppMain; cdecl;

implementation

uses app_api, kstring;

procedure AppMain; cdecl; public name 'AppMain';
var
  line: array[0..80] of Word;
  n: Integer;
  c: Word;
begin
  AppApi_Init;
  App_Print(W('echo> '));
  n := 0;
  while True do
  begin
    c := App_GetChar;
    if c = 0 then Continue;              { nothing typed yet }
    if c = 10 then Break;
    if (c = 8) and (n > 0) then Dec(n)
    else if (c >= 32) and (n < 80) then
    begin
      line[n] := c;
      Inc(n);
    end;
  end;
  line[n] := 0;
  App_Print(W(#13#10'echo: '));
  App_Print(@line[0]);
  App_Print(W(#13#10));
  App_Exit;
end;

end.
