{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: top_app - Ring-3 realtime resource monitor (NekkoTop).
  PORTED FROM: src/apps/top.cs (deleted once this unit is linked).

  Rebuilds the whole text frame into one wide-char buffer and hands it to
  the terminal in a single print, which is what the C# original did: the
  monitor redraws from scratch every tick, so partial writes would flicker.

  TProcessInfo is redeclared here rather than borrowed from app_api, because
  app_api exposes accessors for every field EXCEPT IsJailed and IsPhantomDead
  - and both appear in the STATE column. The layout below must stay byte
  identical to app_api's private copy; see PASCAL_PORTING.md §12.
  =========================================================================
}

unit top_app;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}

interface

{ PE entry point. The loader looks for this symbol by name. }
procedure AppMain; cdecl; public name 'AppMain';

implementation

uses app_api, libc;

const
  { Slot count the kernel exposes. C# looped 0..31 over GetProcessInfo. }
  MAX_SLOTS = 32;

  { Append guard. The C# AppendChar used 4000 and StrAppend_Pas was called
    with cap 4000, so the frame can never exceed 4000 characters and the
    NUL terminator lands at most at index 4000. }
  BUF_CAP  = 4000;
  BUF_SIZE = 4096;   { C# stackalloc'd 4096 wide chars }

  { Backdrop the C# cleared the screen with before entering the loop. }
  CLEAR_COLOR = $00111111;

  { A thread counts as listable when Active is 1 (running) or 2 (sleeping). }
  ACT_RUN   = 1;
  ACT_SLEEP = 2;

  { Byte offsets inside TProcInfo that the C# stringified as a char. }
  CRLF = #10;         { C# literals used a bare \n; DrawCharUnsafe treats
                        \n as CR+LF, so no \r is needed }

type
  { Kernel TProcessInfo, Pack = 1. Kept in the implementation section: a
    record reachable from the interface makes FPC emit RTTI (AGENTS.md
    §6.3b). app_api keeps the authoritative copy - this one only exists so
    the two unread fields can be reached. }
  PProcInfo = ^TProcInfo;
  TProcInfo = packed record
    ID:            Cardinal;
    UID:           Cardinal;
    GID:           Cardinal;
    Active:        Byte;
    IsJailed:      Byte;
    IsPhantomDead: Byte;
    HeapMemory:    QWord;
    Name:          array[0..15] of Byte;
    CpuTicks:      QWord;
    PhysPages:     Cardinal;
    VirtPages:     Cardinal;
  end;

var
  { C# kept BufIndex in a static; the frame is rebuilt from index 0 each
    pass, so the unit-level variable is the same thing. }
  BufIndex: Integer = 0;

  { C# stackalloc'd these inside AppMain. Zero-filled statics match. }
  LastTicks:   array[0..MAX_SLOTS - 1] of QWord;
  Deltas:      array[0..MAX_SLOTS - 1] of QWord;
  FrameBuffer: array[0..BUF_SIZE - 1] of Word;

  { Reused by Emit. AppendStr copies out of it before returning, so a single
    buffer is enough and nothing survives past the statement. }
  Scratch: array[0..127] of Word;

{ Copy an ASCII literal into a NUL-terminated UTF-16 buffer. C# used
  `fixed (char* s = "...")` for this, which becomes a local Word array. }
procedure FillWide(dest: PWord; const s: AnsiString);
var
  i: Integer;
begin
  for i := 1 to Length(s) do
    dest[i - 1] := Word(Byte(s[i]));
  dest[Length(s)] := 0;
end;

procedure AppendChar(buf: PWord; c: Word);
begin
  if BufIndex < BUF_CAP then
  begin
    buf[BufIndex] := c;
    Inc(BufIndex);
  end;
end;

{ Append a NUL-terminated wide string at BufIndex, capped at BUF_CAP.
  Mirrors C# AppendStr, which shelled out to libc StrAppend_Pas with a
  local index and wrote it back afterwards. }
procedure AppendStr(buf: PWord; s: PWord);
var
  localIdx: Integer;
begin
  localIdx := BufIndex;
  StrAppend_Pas(buf, s, @localIdx, BUF_CAP);
  BufIndex := localIdx;
end;

{ Append an ASCII literal to the frame. The scratch buffer is filled and
  consumed inside the same call. }
procedure Emit(const s: AnsiString);
begin
  FillWide(@Scratch[0], s);
  AppendStr(@FrameBuffer[0], @Scratch[0]);
end;

{ Render `num` followed by `suffix` (empty string = the C# null case), then
  pad with spaces until `width` characters have been emitted. }
procedure AppendNumAligned(buf: PWord; num: QWord; const suffix: AnsiString; width: Integer);
var
  temp: array[0..32] of Word;
  idx: Integer;
  i: Integer;
begin
  idx := 0;

  { C# cast a wide buffer to byte* before calling AppendDecimal_Pas, so the
    digits landed in the low byte of every other slot and the string came
    out as one digit followed by NULs. libc already provides the wide form
    of the same conversion; use it. }
  AppendDecimalWide_Pas(@temp[0], @idx, 32, Cardinal(num));

  if suffix <> '' then
  begin
    FillWide(@Scratch[0], suffix);
    StrAppend_Pas(@temp[0], @Scratch[0], @idx, 32);
  end;

  for i := 0 to idx - 1 do
    AppendChar(buf, temp[i]);
  for i := idx to width - 1 do
    AppendChar(buf, Ord(' '));
end;

{ Is this thread worth printing a row for? }
function IsListed(info: PProcInfo): Boolean; inline;
begin
  IsListed := (info^.Active = ACT_RUN) or (info^.Active = ACT_SLEEP);
end;

{ Fetch one thread record, or nil when the slot is empty / not running /
  sleeping - the three-way test the C# spelled out inline at every call
  site. app_api's GetProcessInfo takes a raw Pointer by design, because
  TProcessInfo is private to that unit; it is an `out` parameter, so the
  destination is passed as a plain variable, not as @p. }
function FetchInfo(id: Cardinal): PProcInfo;
var
  p: Pointer;
begin
  FetchInfo := nil;
  p := nil;
  if App_GetProcessInfo(id, p) <> 1 then Exit;
  FetchInfo := PProcInfo(p);
  if (FetchInfo = nil) or (not IsListed(FetchInfo)) then FetchInfo := nil;
end;

procedure AppMain; cdecl;
var
  info: PProcInfo;
  totalDelta: QWord;
  cpuPercent: QWord;
  resKb: QWord;
  virtKb: QWord;
  nameLen: Integer;
  k: Integer;
  i: Cardinal;
  wait: Integer;
  c: Word;
begin
  AppApi_Init;

  { Prime the delta baseline so the first frame does not count the entire
    uptime as a single slice of CPU. }
  for i := 0 to MAX_SLOTS - 1 do
  begin
    info := FetchInfo(i);
    if info <> nil then
      LastTicks[i] := info^.CpuTicks;
  end;

  App_Clear(CLEAR_COLOR);

  while True do
  begin
    totalDelta := 0;
    for i := 0 to MAX_SLOTS - 1 do
    begin
      info := FetchInfo(i);
      if info <> nil then
      begin
        if LastTicks[i] = 0 then
          Deltas[i] := 0
        else if info^.CpuTicks >= LastTicks[i] then
          Deltas[i] := info^.CpuTicks - LastTicks[i]
        else
          Deltas[i] := 0;
        LastTicks[i] := info^.CpuTicks;
        totalDelta := totalDelta + Deltas[i];
      end
      else
      begin
        LastTicks[i] := 0;
        Deltas[i] := 0;
      end;
    end;
    if totalDelta = 0 then totalDelta := 1;

    BufIndex := 0;

    Emit('================================================================================' + #10);
    Emit('                     NEKKOTOP - REALTIME RESOURCE MONITOR                       ' + #10);
    Emit('================================================================================' + #10);
    Emit('PID  NAME             CPU%   RES(KB)  VIRT(KB)  UID   STATE' + #10);
    Emit('--------------------------------------------------------------------------------' + #10);

    for i := 0 to MAX_SLOTS - 1 do
    begin
      info := FetchInfo(i);
      if info <> nil then
      begin
        AppendNumAligned(@FrameBuffer[0], info^.ID, '', 5);

        { Name is a fixed 16-byte field, not NUL-guaranteed. }
        nameLen := 0;
        for k := 0 to 15 do
        begin
          if info^.Name[k] = 0 then Break;
          AppendChar(@FrameBuffer[0], Word(info^.Name[k]));
          Inc(nameLen);
        end;
        for k := nameLen to 16 do
          AppendChar(@FrameBuffer[0], Ord(' '));

        cpuPercent := (Deltas[i] * 100) div totalDelta;
        if cpuPercent > 100 then cpuPercent := 100;
        AppendNumAligned(@FrameBuffer[0], cpuPercent, '%', 7);

        { PhysPages / VirtPages are 4 KiB pages. }
        resKb := QWord(info^.PhysPages) * 4;
        virtKb := QWord(info^.VirtPages) * 4;

        AppendNumAligned(@FrameBuffer[0], resKb, ' K', 9);
        AppendNumAligned(@FrameBuffer[0], virtKb, ' K', 10);

        AppendNumAligned(@FrameBuffer[0], info^.UID, '', 6);

        { Order preserved from the C#, including the inverted IsJailed test. }
        if info^.IsPhantomDead = 1 then
          Emit('[DEAD]      ')
        else if info^.Active = ACT_SLEEP then
          Emit('[SLEEP]     ')
        else if info^.IsJailed = 1 then
          Emit('[NORMAL]    ')
        else if info^.UID = 0 then
          Emit('[ROOT]      ')
        else
          Emit('[USER]      ');

        AppendChar(@FrameBuffer[0], Ord(CRLF));
      end;
    end;

    Emit(#10 + '================================================================================' + #10);
    Emit('                 Press ''q'' to Quit NekkoTop and return to Shell            ' + #10);
    Emit('                                                                                ' + #10);
    Emit('                                                                                ' + #10);
    Emit('                                                                                ' + #10);

    { BufIndex is capped at BUF_CAP, so this is always in range. }
    FrameBuffer[BufIndex] := 0;

    App_ResetCursor;
    App_Print(@FrameBuffer[0]);

    { Non-blocking key poll: 100 short yields per frame (~1 s of redraw)
      so the monitor does not starve the rest of the system while waiting
      for a keypress. }
    for wait := 0 to 99 do
    begin
      c := App_GetChar and $FF;
      if (c = Ord('q')) or (c = Ord('Q')) then
      begin
        App_Clear(CLEAR_COLOR);
        App_Exit;
        while True do App_WaitIPC;
      end;
      App_WaitIPC;
    end;
  end;
end;

end.
