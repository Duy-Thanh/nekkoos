{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: PasswdParser - PASSWD / SUDOERS file parsing (Pascal Implementation)
  PURPOSE: Pure logic for parsing /ETC/PASSWD format (user:salt:hash:uid:gid)
           and /ETC/SUDOERS format (one username per line).

           Ported from Syscall.cs case 94 (sudo) inline parser loops.
           Kernel infrastructure (FAT16.ReadFile, Scheduler.Threads, IPC)
           stays in the C# shell layer; this module only handles the
           pure string-parsing step.

           Exports cdecl *_Pas shim for the C# layer.
  =========================================================================
}

unit passwd_parser;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$packrecords c}

interface

{ [PURE LOGIC] Parse one PASSWD line (zero-terminated) into separate buffers.
  Format: user:salt:hash:uid[:gid]
  Stops at line end (either zero terminator or '\n' / '\r').

  Inputs:
    linePtr   - pointer to start of line (UTF-16 chars)
    userOut   - destination for username (null-terminated, max 31 chars)
    userCap   - capacity of userOut (32)
    saltOut   - destination for hex salt (null-terminated, max 63 chars)
    saltCap   - capacity of saltOut (64)
    hashOut   - destination for hex hash (null-terminated, max 79 chars)
    hashCap   - capacity of hashOut (80)
    uidOut    - destination for uid string (null-terminated, max 15 chars)
    uidCap    - capacity of uidOut (16)
  Returns: number of fields parsed (0..4) }
function ParsePasswdLine_Pas(linePtr: PWord; userOut: PWord; userCap: UInt32;
                              saltOut: PWord; saltCap: UInt32;
                              hashOut: PWord; hashCap: UInt32;
                              uidOut: PWord; uidCap: UInt32): UInt32; cdecl; public name 'ParsePasswdLine_Pas';

{ [PURE LOGIC] Match a username in a SUDOERS-format buffer.
  Buffer: newline-separated list of usernames (one per line, no colon).
  Returns: 1 if username found, 0 otherwise. }
function SudoersContains_Pas(buf: PByte; bufLen: UInt32; user: PWord): Byte; cdecl; public name 'SudoersContains_Pas';

implementation

function ParsePasswdLine_Pas(linePtr: PWord; userOut: PWord; userCap: UInt32;
                              saltOut: PWord; saltCap: UInt32;
                              hashOut: PWord; hashCap: UInt32;
                              uidOut: PWord; uidCap: UInt32): UInt32; cdecl;
var
  stage: Integer;
  c: Word;
  u, s, h, ud: UInt32;
  p: PWord;
begin
  u := 0; s := 0; h := 0; ud := 0;
  stage := 0;
  p := linePtr;

  while True do
  begin
    c := p^;
    if (c = 0) or (c = 10) or (c = 13) then Break;

    if c = Ord(':') then
    begin
      Inc(stage);
      if stage > 3 then Break;
    end
    else
    begin
      if (stage = 0) and (u < userCap - 1) then
      begin
        PWord(userOut)[u] := c;
        Inc(u);
      end
      else if (stage = 1) and (s < saltCap - 1) then
      begin
        PWord(saltOut)[s] := c;
        Inc(s);
      end
      else if (stage = 2) and (h < hashCap - 1) then
      begin
        PWord(hashOut)[h] := c;
        Inc(h);
      end
      else if (stage = 3) and (ud < uidCap - 1) then
      begin
        PWord(uidOut)[ud] := c;
        Inc(ud);
      end;
    end;
    Inc(p);
  end;

  PWord(userOut)[u] := 0;
  PWord(saltOut)[s] := 0;
  PWord(hashOut)[h] := 0;
  PWord(uidOut)[ud] := 0;

  Result := UInt32(stage + 1);
  if (stage = 0) and (u = 0) then Result := 0;
end;

function SudoersContains_Pas(buf: PByte; bufLen: UInt32; user: PWord): Byte; cdecl;
var
  i, j, usrLen: UInt32;
  c: Byte;
  matched: Boolean;
  lineStart: UInt32;
  lineLen: UInt32;
  userChar: Word;
begin
  Result := 0;
  if (buf = nil) or (bufLen = 0) or (user = nil) then Exit;

  usrLen := 0;
  while PWord(user)[usrLen] <> 0 do Inc(usrLen);
  if usrLen = 0 then Exit;

  i := 0;
  while i < bufLen do
  begin
    lineStart := i;
    lineLen := 0;
    while (i < bufLen) and (PByte(buf)[i] <> 10) and (PByte(buf)[i] <> 13) do
    begin
      Inc(lineLen);
      Inc(i);
    end;

    matched := False;
    if lineLen = usrLen then
    begin
      matched := True;
      for j := 0 to usrLen - 1 do
      begin
        userChar := PWord(user)[j];
        c := PByte(buf)[lineStart + j];
        if userChar <> c then
        begin
          matched := False;
          Break;
        end;
      end;
    end;

    if matched then
    begin
      Result := 1;
      Exit;
    end;

    while (i < bufLen) and ((PByte(buf)[i] = 10) or (PByte(buf)[i] = 13)) do
      Inc(i);
  end;
end;

end.