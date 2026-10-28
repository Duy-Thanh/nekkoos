{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: memtest_app - user-space memory API check (x86 and ARM64): AllocMem, write, FreeMem
  (the frames come back), FreeMem of an unmapped range (0), bad arguments.
  =========================================================================
}
unit memtest_app;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

procedure AppMain; cdecl;

implementation

uses app_api, kstring;

procedure AppMain; cdecl; public name 'AppMain';
var
  block: QWord;
  p: PCardinal;
  ok: Boolean;
begin
  AppApi_Init;
  block := App_AllocMem(4);
  ok := block <> 0;
  if ok then
  begin
    p := PCardinal(block);
    p[0] := $11223344;
    p[4095] := $55667788;                  { last word of the 4th page }
    ok := (p[0] = $11223344) and (p[4095] = $55667788);
  end;
  ok := ok and (App_FreeMem(block, 4) = 4);        { all four were mapped }
  ok := ok and (App_FreeMem(block, 4) = 0);        { now nothing is }
  ok := ok and (App_FreeMem(block + 1, 1) = 0);    { unaligned: refused }
  ok := ok and (App_FreeMem(0, 1) = 0);            { null page: refused }
  ok := ok and (App_FreeMem(block, 100000) = 0);   { absurd length: refused }
  if ok then App_Print(W('memtest: AllocMem/FreeMem OK'#10))
  else App_Print(W('memtest: AllocMem/FreeMem FAILED'#10));
  App_Exit;
end;

end.
