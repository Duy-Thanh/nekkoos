{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: input_drv - PS/2 keyboard scancode translation and mouse state.
  PORTED FROM: src/drivers/x86-legacy/KeyboardDriver.cs, MouseDriver.cs and
  the packet assembly that lived in InterruptHandlers.cs.

  The keyboard ISR only forwards raw scancodes into the IPC mailbox. The
  syscall layer translates them to characters here when a program asks for
  one, so modifier state is tracked at read time, not interrupt time.
  =========================================================================
}
unit input_drv;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Translate one scancode (set 1). Returns 0 for modifiers, key releases and
  anything unmapped. }
function Kbd_ProcessScanCode(sc: Byte): Word;

{ Busy-poll the controller for one character. For use before the scheduler
  runs (panic screens, early boot). }
function Kbd_PollChar: Word;

{ The mouse is served by a Ring-3 daemon once it announces itself. }
function  Mouse_GetUseDaemon: Boolean;
procedure Mouse_SetUseDaemon(v: Boolean);
function  Mouse_GetDaemonId: Cardinal;
procedure Mouse_SetDaemonId(v: Cardinal);

{ Feed one byte from port 0x60 into the 3-byte packet assembler. When a whole
  packet is ready it returns True and the packed payload
  (byte2 << 16 | byte1 << 8 | byte0). }
function Mouse_FeedByte(data: Byte; out payload: QWord): Boolean;

implementation

uses arch_interface, io;

var
  LeftShift: Boolean = False;
  RightShift: Boolean = False;
  CapsLock: Boolean = False;

  MouseUseDaemon: Boolean = False;
  MouseDaemonId: Cardinal = 0;
  MouseCycle: Integer = 0;
  MouseByte0, MouseByte1, MouseByte2: Byte;

function Pick(cond: Boolean; a, b: Char): Word; inline;
begin
  if cond then Pick := Ord(a) else Pick := Ord(b);
end;

function Kbd_ProcessScanCode(sc: Byte): Word;
var
  isBreak, shift, upper: Boolean;
  makeCode: Byte;
begin
  isBreak := (sc and $80) <> 0;
  makeCode := sc and $7F;

  Kbd_ProcessScanCode := 0;

  if makeCode = $2A then begin LeftShift := not isBreak; Exit; end;
  if makeCode = $36 then begin RightShift := not isBreak; Exit; end;
  if (makeCode = $3A) and (not isBreak) then begin CapsLock := not CapsLock; Exit; end;

  if isBreak then Exit;

  shift := LeftShift or RightShift;
  { Caps on plus Shift held gives lower case. }
  upper := CapsLock xor shift;

  case makeCode of
    $29: Kbd_ProcessScanCode := Pick(shift, '~', '`');
    $02: Kbd_ProcessScanCode := Pick(shift, '!', '1');
    $03: Kbd_ProcessScanCode := Pick(shift, '@', '2');
    $04: Kbd_ProcessScanCode := Pick(shift, '#', '3');
    $05: Kbd_ProcessScanCode := Pick(shift, '$', '4');
    $06: Kbd_ProcessScanCode := Pick(shift, '%', '5');
    $07: Kbd_ProcessScanCode := Pick(shift, '^', '6');
    $08: Kbd_ProcessScanCode := Pick(shift, '&', '7');
    $09: Kbd_ProcessScanCode := Pick(shift, '*', '8');
    $0A: Kbd_ProcessScanCode := Pick(shift, '(', '9');
    $0B: Kbd_ProcessScanCode := Pick(shift, ')', '0');
    $0C: Kbd_ProcessScanCode := Pick(shift, '_', '-');
    $0D: Kbd_ProcessScanCode := Pick(shift, '+', '=');
    $0E: Kbd_ProcessScanCode := 8;      { backspace }
    $0F: Kbd_ProcessScanCode := 9;      { tab }

    $10: Kbd_ProcessScanCode := Pick(upper, 'Q', 'q');
    $11: Kbd_ProcessScanCode := Pick(upper, 'W', 'w');
    $12: Kbd_ProcessScanCode := Pick(upper, 'E', 'e');
    $13: Kbd_ProcessScanCode := Pick(upper, 'R', 'r');
    $14: Kbd_ProcessScanCode := Pick(upper, 'T', 't');
    $15: Kbd_ProcessScanCode := Pick(upper, 'Y', 'y');
    $16: Kbd_ProcessScanCode := Pick(upper, 'U', 'u');
    $17: Kbd_ProcessScanCode := Pick(upper, 'I', 'i');
    $18: Kbd_ProcessScanCode := Pick(upper, 'O', 'o');
    $19: Kbd_ProcessScanCode := Pick(upper, 'P', 'p');
    $1A: Kbd_ProcessScanCode := Pick(shift, '{', '[');
    $1B: Kbd_ProcessScanCode := Pick(shift, '}', ']');
    $1C: Kbd_ProcessScanCode := 10;     { enter }

    $1E: Kbd_ProcessScanCode := Pick(upper, 'A', 'a');
    $1F: Kbd_ProcessScanCode := Pick(upper, 'S', 's');
    $20: Kbd_ProcessScanCode := Pick(upper, 'D', 'd');
    $21: Kbd_ProcessScanCode := Pick(upper, 'F', 'f');
    $22: Kbd_ProcessScanCode := Pick(upper, 'G', 'g');
    $23: Kbd_ProcessScanCode := Pick(upper, 'H', 'h');
    $24: Kbd_ProcessScanCode := Pick(upper, 'J', 'j');
    $25: Kbd_ProcessScanCode := Pick(upper, 'K', 'k');
    $26: Kbd_ProcessScanCode := Pick(upper, 'L', 'l');
    $27: Kbd_ProcessScanCode := Pick(shift, ':', ';');
    $28: Kbd_ProcessScanCode := Pick(shift, '"', '''');

    $2B: Kbd_ProcessScanCode := Pick(shift, '|', '\');
    $2C: Kbd_ProcessScanCode := Pick(upper, 'Z', 'z');
    $2D: Kbd_ProcessScanCode := Pick(upper, 'X', 'x');
    $2E: Kbd_ProcessScanCode := Pick(upper, 'C', 'c');
    $2F: Kbd_ProcessScanCode := Pick(upper, 'V', 'v');
    $30: Kbd_ProcessScanCode := Pick(upper, 'B', 'b');
    $31: Kbd_ProcessScanCode := Pick(upper, 'N', 'n');
    $32: Kbd_ProcessScanCode := Pick(upper, 'M', 'm');
    $33: Kbd_ProcessScanCode := Pick(shift, '<', ',');
    $34: Kbd_ProcessScanCode := Pick(shift, '>', '.');
    $35: Kbd_ProcessScanCode := Pick(shift, '?', '/');
    $39: Kbd_ProcessScanCode := 32;     { space }
  end;
end;

function Kbd_PollChar: Word;
begin
  { The fence keeps the compiler from hoisting the status read out of the
    loop (the port value changes behind its back). }
  while (Io_In8($64) and 1) = 0 do
  begin
    Arch_CompilerFence;
    Io_In8($80);     { ~1 microsecond of bus delay }
  end;
  Kbd_PollChar := Kbd_ProcessScanCode(Io_In8($60));
end;

function  Mouse_GetUseDaemon: Boolean;
begin
  Mouse_GetUseDaemon := MouseUseDaemon;
end;

procedure Mouse_SetUseDaemon(v: Boolean);
begin
  MouseUseDaemon := v;
end;

function  Mouse_GetDaemonId: Cardinal;
begin
  Mouse_GetDaemonId := MouseDaemonId;
end;

procedure Mouse_SetDaemonId(v: Cardinal);
begin
  MouseDaemonId := v;
end;

function Mouse_FeedByte(data: Byte; out payload: QWord): Boolean;
begin
  Mouse_FeedByte := False;
  payload := 0;

  if MouseCycle = 0 then
  begin
    { Bit 3 is always set in a first byte; anything else is out of sync. }
    if (data and $08) <> 0 then
    begin
      MouseByte0 := data;
      Inc(MouseCycle);
    end;
  end
  else if MouseCycle = 1 then
  begin
    MouseByte1 := data;
    Inc(MouseCycle);
  end
  else if MouseCycle = 2 then
  begin
    MouseByte2 := data;
    MouseCycle := 0;
    payload := (QWord(MouseByte2) shl 16) or (QWord(MouseByte1) shl 8) or QWord(MouseByte0);
    Mouse_FeedByte := True;
  end;
end;

{ ── cdecl exports for the C# glue ── }

function Kbd_ProcessScanCode_Pas(sc: Byte): Word; cdecl; public name 'Kbd_ProcessScanCode_Pas';
begin
  Kbd_ProcessScanCode_Pas := Kbd_ProcessScanCode(sc);
end;

function Kbd_PollChar_Pas: Word; cdecl; public name 'Kbd_PollChar_Pas';
begin
  Kbd_PollChar_Pas := Kbd_PollChar;
end;

function Mouse_GetUseDaemon_Pas: Byte; cdecl; public name 'Mouse_GetUseDaemon_Pas';
begin
  Mouse_GetUseDaemon_Pas := Ord(MouseUseDaemon);
end;

procedure Mouse_SetUseDaemon_Pas(v: Byte); cdecl; public name 'Mouse_SetUseDaemon_Pas';
begin
  MouseUseDaemon := v <> 0;
end;

function Mouse_GetDaemonId_Pas: Cardinal; cdecl; public name 'Mouse_GetDaemonId_Pas';
begin
  Mouse_GetDaemonId_Pas := MouseDaemonId;
end;

procedure Mouse_SetDaemonId_Pas(v: Cardinal); cdecl; public name 'Mouse_SetDaemonId_Pas';
begin
  MouseDaemonId := v;
end;

end.
