{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: kstring - UTF-16 string literal support for the full-Pascal port.
  PURPOSE: C# `char*` is UTF-16 (2 bytes/char), which is what the terminal
           and all C#-side string APIs expect. FPC string literals are ANSI
           (1 byte/char), so ported code needs a way to materialise a
           zero-terminated UTF-16 buffer from a literal at runtime.

  USAGE (replaces C# `fixed (char* s = "text\0")`):
      Terminal_Print_Pas(W('hello'#13#10));
      Fatal(W('[!] cannot allocate'#13#10));

  DESIGN NOTES:
  - Rotating static buffer pool. A literal passed to W() stays valid only
    until WS_SLOTS further W() calls have been made. This is safe for the
    actual call sites (arguments are consumed immediately, before any
    nested W() call), but a stored PWord must be copied with StrCpyLimited.
  - No heap, no exceptions, no RTTI - safe to use before PMM/Heap init.
  =========================================================================
}

unit kstring;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

const
  { Number of rotating literal slots. Deep enough that no realistic nesting
    of W() calls exceeds it. }
  WS_SLOTS = 8;

  { Max characters (not bytes) per slot, including the terminator. }
  WS_SLOT_CHARS = 256;

{ Materialise an ANSI literal as a NUL-terminated UTF-16 buffer.
  Returns a pointer valid until WS_SLOTS subsequent W() calls. }
function W(const s: AnsiString): PWord; inline;

implementation

var
  { One contiguous arena keeps the buffers stable so returned pointers never
    move when other slots advance. }
  WS_Arena: array[0..WS_SLOTS - 1, 0..WS_SLOT_CHARS] of Word;
  WS_Next: Integer = 0;

function W(const s: AnsiString): PWord; inline;
var
  slot: PWord;
  i: Cardinal;
  n: Cardinal;
begin
  if WS_Next >= WS_SLOTS then WS_Next := 0;
  slot := @WS_Arena[WS_Next, 0];
  Inc(WS_Next);

  n := Length(s);
  if n > WS_SLOT_CHARS - 1 then n := WS_SLOT_CHARS - 1;

  for i := 0 to n - 1 do
    slot[i] := Word(Byte(s[i + 1]));

  slot[n] := 0;
  W := slot;
end;

end.
