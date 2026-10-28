{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: blktest - ARM64 test client for the disk daemon (vblk_daemon).

  Talks to the daemon exactly as the FAT16 daemon talks to ATA.EXE: sector
  requests over IPC, data through the shared window. The kernel lets only the
  thread it trusts as the filesystem daemon do this; boot_arm64 marks this
  program as that thread.
  =========================================================================
}
unit blktest;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

procedure AppMain; cdecl;

implementation

uses uapi, kstring;

const
  RAW_OFFSET = 4096 + 4096 + 8192;
  WAIT_TRIES = 2000;

var
  Daemon: Cardinal;
  Raw: PByte;
  DaemonName: array[0..4] of Word = (86, 66, 76, 75, 0);     { VBLK }

{ Send one request and wait for the matching reply type (or 111). }
function Request(kind, okKind: Cardinal; lba: QWord): Boolean;
var
  msg: array[0..MSG_SIZE - 1] of Byte;
  tries: Integer;
begin
  Request := False;
  if not U_SendIPC(Daemon, kind, lba) then Exit;
  for tries := 1 to WAIT_TRIES do
  begin
    if U_ReceiveIPC(@msg[0]) and (U_MsgSender(@msg[0]) = Daemon) then
    begin
      Request := U_MsgType(@msg[0]) = okKind;
      Exit;
    end;
    U_Yield;
  end;
end;

procedure AppMain; cdecl; public name 'AppMain';
var
  id: Int64;
  tries, i: Integer;
  ok: Boolean;
  sig: array[0..16] of Word;
begin
  Raw := PByte(U_GetSharedMem + RAW_OFFSET);
  id := -1;
  for tries := 1 to WAIT_TRIES do
  begin
    id := U_PidByName(@DaemonName[0]);
    if id > 0 then Break;
    U_Yield;
  end;
  if id <= 0 then
  begin
    U_Print(W('blktest: disk daemon not found'#13#10));
    U_Exit;
  end;
  Daemon := Cardinal(id);

  if Request(10, 11, 0) then
  begin
    for i := 0 to 14 do sig[i] := Raw[i];
    sig[15] := 0;
    U_Print(W('blktest: sector 0 via daemon: '));
    U_Print(@sig[0]);
    U_Print(W(#13#10));
  end
  else
    U_Print(W('blktest: read via daemon FAILED'#13#10));

  for i := 0 to 511 do Raw[i] := Byte(i * 5 + 1);
  ok := Request(12, 13, 2);
  for i := 0 to 511 do Raw[i] := 0;
  ok := ok and Request(10, 11, 2);
  for i := 0 to 511 do ok := ok and (Raw[i] = Byte(i * 5 + 1));
  { Past the end of the disk: the daemon must answer with an error. }
  ok := ok and (not Request(10, 11, QWord(1) shl 40));
  if ok then U_Print(W('blktest: write/read-back via daemon OK'#13#10))
  else U_Print(W('blktest: write/read-back via daemon FAILED'#13#10));
  U_Exit;
end;

end.
