{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: InternalShell - Syscall 88 Command Parser
  PURPOSE: Parses kernel builtin commands and returns action enum.
           C# shim executes the actions (FAT16, PELoader, etc.).
  =========================================================================
}
unit internal_shell;

{$mode objfpc}
{$h+}
{$inline on}
{$TYPEINFO OFF}
{$PACKRECORDS C}

interface

uses libc;

type
  { Command action types returned by parser }
  TShellAction = (
    SA_NONE = 0,
    SA_CLEAR = 1,
    SA_HELP = 2,
    SA_MEM = 3,
    SA_UPTIME = 4,
    SA_PCI = 5,
    SA_DATE = 6,
    SA_POWEROFF = 7,
    SA_REBOOT = 8,
    SA_UNAME = 9,
    SA_CAT = 10,
    SA_RUN = 11,
    SA_DAEMON = 12,
    SA_LOGOUT = 13,
    SA_UNKNOWN = 255
  );

  { Parsed command result - use simple types, no record }
  { Action: Byte; Arg: PWord; ArgLen: Word }

{ Initialize - no-op for now }
procedure InternalShell_SetSchedulerState(threads: Pointer; threadCount: Integer;
  currentThreadIdPtr: PInteger; foregroundTaskPtr: PInteger; systemTicksPtr: PQWord); cdecl;
  public name 'InternalShell_SetSchedulerState';

{ Parse command string into action + argument }
function InternalShell_ParseCommand_Pas(cmdStr: PWord; outAction: PByte; outArg: PWord; outArgLen: PWord): Byte; cdecl;
  public name 'InternalShell_ParseCommand_Pas';

implementation

{ Initialize - no-op }
procedure InternalShell_SetSchedulerState(threads: Pointer; threadCount: Integer;
  currentThreadIdPtr: PInteger; foregroundTaskPtr: PInteger; systemTicksPtr: PQWord); cdecl;
begin
  { State no longer needed in parser }
end;

{ Compare wide string against fixed wide string }
function StrCmpWide(s1, s2: PWord): Boolean; inline;
var
  i: Integer;
begin
  StrCmpWide := False;
  if (s1 = nil) or (s2 = nil) then Exit;
  i := 0;
  while (s1[i] <> 0) and (s2[i] <> 0) do
  begin
    if s1[i] <> s2[i] then Exit;
    Inc(i);
  end;
  StrCmpWide := (s1[i] = 0) and (s2[i] = 0);
end;

{ Check if wide string starts with prefix }
function StrStartsWithWide(str, prefix: PWord): Boolean; inline;
var
  i: Integer;
begin
  StrStartsWithWide := False;
  if (str = nil) or (prefix = nil) then Exit;
  i := 0;
  while prefix[i] <> 0 do
  begin
    if str[i] <> prefix[i] then Exit;
    Inc(i);
  end;
  StrStartsWithWide := True;
end;

{ Copy wide string argument }
procedure CopyWideArg(src: PWord; dest: PWord; var destLen: Word; maxLen: Word); inline;
var
  i: Word;
begin
  destLen := 0;
  if src = nil then Exit;
  i := 0;
  while (src[i] <> 0) and (i < maxLen) do
  begin
    dest[i] := src[i];
    Inc(i);
  end;
  destLen := i;
end;

{ Builtin command strings (wide char) }
const
  CMD_CLEAR    : array[0..5] of Word = (Ord('c'), Ord('l'), Ord('e'), Ord('a'), Ord('r'), 0);
  CMD_HELP     : array[0..4] of Word = (Ord('h'), Ord('e'), Ord('l'), Ord('p'), 0);
  CMD_MEM      : array[0..3] of Word = (Ord('m'), Ord('e'), Ord('m'), 0);
  CMD_UPTIME   : array[0..5] of Word = (Ord('u'), Ord('p'), Ord('t'), Ord('i'), Ord('m'), Ord('e'));
  CMD_PCI      : array[0..3] of Word = (Ord('p'), Ord('c'), Ord('i'), 0);
  CMD_DATE     : array[0..4] of Word = (Ord('d'), Ord('a'), Ord('t'), Ord('e'), 0);
  CMD_UNAME    : array[0..5] of Word = (Ord('u'), Ord('n'), Ord('a'), Ord('m'), Ord('e'), 0);
  CMD_RUN      : array[0..4] of Word = (Ord('r'), Ord('u'), Ord('n'), Ord(' '), 0);
  CMD_DAEMON   : array[0..6] of Word = (Ord('d'), Ord('a'), Ord('e'), Ord('m'), Ord('o'), Ord('n'), Ord(' '));
  CMD_POWEROFF : array[0..8] of Word = (Ord('s'), Ord('h'), Ord('u'), Ord('t'), Ord('d'), Ord('o'), Ord('w'), Ord('n'), 0);
  CMD_LOGOUT   : array[0..6] of Word = (Ord('l'), Ord('o'), Ord('g'), Ord('o'), Ord('u'), Ord('t'), 0);
  CMD_REBOOT   : array[0..6] of Word = (Ord('r'), Ord('e'), Ord('b'), Ord('o'), Ord('o'), Ord('t'), 0);
  CMD_CAT      : array[0..4] of Word = (Ord('c'), Ord('a'), Ord('t'), Ord(' '), 0);

{ Parse command string - outputs via pointer parameters to avoid record RTTI }
function InternalShell_ParseCommand_Pas(cmdStr: PWord; outAction: PByte; outArg: PWord; outArgLen: PWord): Byte; cdecl;
var
  action: TShellAction;
  argLen: Word;
begin
  InternalShell_ParseCommand_Pas := 0;
  if (cmdStr = nil) or (outAction = nil) or (outArg = nil) or (outArgLen = nil) then Exit;

  argLen := 0;
  action := SA_NONE;

  if StrCmpWide(cmdStr, @CMD_CLEAR) then
  begin
    action := SA_CLEAR;
  end
  else if StrCmpWide(cmdStr, @CMD_HELP) then
  begin
    action := SA_HELP;
  end
  else if StrCmpWide(cmdStr, @CMD_MEM) then
  begin
    action := SA_MEM;
  end
  else if StrCmpWide(cmdStr, @CMD_UPTIME) then
  begin
    action := SA_UPTIME;
  end
  else if StrCmpWide(cmdStr, @CMD_PCI) then
  begin
    action := SA_PCI;
  end
  else if StrCmpWide(cmdStr, @CMD_DATE) then
  begin
    action := SA_DATE;
  end
  else if StrCmpWide(cmdStr, @CMD_POWEROFF) then
  begin
    action := SA_POWEROFF;
  end
  else if StrCmpWide(cmdStr, @CMD_REBOOT) then
  begin
    action := SA_REBOOT;
  end
  else if StrCmpWide(cmdStr, @CMD_UNAME) then
  begin
    action := SA_UNAME;
  end
  else if StrStartsWithWide(cmdStr, @CMD_CAT) then
  begin
    action := SA_CAT;
    CopyWideArg(cmdStr + 4, outArg, argLen, 255);
  end
  else if StrStartsWithWide(cmdStr, @CMD_RUN) then
  begin
    action := SA_RUN;
    CopyWideArg(cmdStr + 4, outArg, argLen, 255);
  end
  else if StrStartsWithWide(cmdStr, @CMD_DAEMON) then
  begin
    action := SA_DAEMON;
    CopyWideArg(cmdStr + 7, outArg, argLen, 255);
  end
  else if StrCmpWide(cmdStr, @CMD_LOGOUT) then
  begin
    action := SA_LOGOUT;
  end
  else
  begin
    action := SA_UNKNOWN;
    { Copy whole command as argument for error display }
    CopyWideArg(cmdStr, outArg, argLen, 255);
  end;

  outAction^ := Byte(action);
  outArgLen^ := argLen;
  InternalShell_ParseCommand_Pas := 1;
end;

end.