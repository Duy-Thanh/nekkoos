{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: explorer_app - Ring-3 desktop / window manager.
  PORTED FROM: src/apps/explorer.cs (deleted once this unit is linked).

  Explorer owns a shared buffer that the display server blits as slot 0, the
  desktop backdrop. It paints that buffer once, then repaints only the START
  button on button-down, and re-sends the buffer over IPC type 10 so the
  server composites the change. Everything here is therefore plain writes
  into shared memory - no drawing syscalls.

  BOUNDS CHECKS ARE AGAINST A PIXEL COUNT, NOT A RECTANGLE
  Every primitive takes maxPixels = ScanLine*ScreenHeight and tests the flat
  index. That is what makes the desktop safe to paint at any window size
  without tracking a real clip rect, and it is preserved exactly: changing
  it to per-axis bounds would change what gets clipped.
  =========================================================================
}

unit explorer_app;

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
  { IPC type 10: hand the compositor a buffer to blit as the backdrop. }
  IPC_DESKTOP = 10;

  { IPC type 20: cursor position + button state, from the compositor. }
  IPC_CLICK   = 20;

  { The display server this desktop attaches to. }
  DSRV_NAME = 'DSRV.EXE';

  { Glyph cell. Fixed-pitch 8x8, so advancing the pen is always +8. }
  GLYPH_W = 8;
  GLYPH_H = 8;

  { Start button geometry, relative to taskbarY. }
  BTN_X         = 2;
  BTN_W         = 60;
  BTN_H         = 24;
  BTN_DY        = 4;
  BTN_BEVEL     = 2;
  BTN_TEXT_DY   = 12;   { unpressed text origin, relative to taskbarY }
  BTN_TEXT_DY_P = 13;   { pressed text origin, relative to taskbarY     }
  BTN_HIT_MIN_X = 2;
  BTN_HIT_MAX_X = 62;
  BTN_HIT_MIN_DY = 4;
  BTN_HIT_MAX_DY = 28;

  TASKBAR_H = 32;

  { Desktop icon grid. Icons are 32x32; the click box is 20..52 on each
    axis, i.e. 33 wide, and rows are 70 px apart. }
  ICON_X       = 20;
  ICON_Y       = 20;
  ICON_SIZE    = 32;
  ICON_SPACING = 70;
  ICON_HIT_MIN = 20;
  ICON_HIT_MAX = 52;

  { Rows, kept as offsets from ICON_Y so the hit boxes and the drawing stay
    in step. }
  ICON_ROW0 = 0;     { Terminal }
  ICON_ROW1 = 70;    { NekkoTop }
  ICON_ROW2 = 140;   { My PC     }
  ICON_ROW3 = 210;   { Settings  }

  { Shared buffer request: 2048 pages = 8 MiB, which is also the cap the
    pixel-count check below implies. }
  BACKDROP_PAGES = 2048;

  { Never paint past this many pixels even if the screen is huge. }
  MAX_PIXELS = 2000000;

  DESKTOP_COLOR  = $00008080;
  TASKBAR_COLOR  = $00C0C0C0;
  START_BTN_COLOR = $00C0C0C0;
  BORDER_LIGHT   = $00FFFFFF;
  BORDER_DARK    = $00000000;
  TEXT_WHITE     = $00FFFFFF;
  TEXT_BLACK     = $00000000;
  ICON_COLOR     = $00FFFF00;

var
  { Icon labels and the START caption, as wide strings. Filled once at
    startup; never stored as a raw literal, because C# char* is UTF-16 and
    FPC literals are ANSI. }
  NameTerminal: array[0..15] of Word;
  NameTop:      array[0..15] of Word;
  NameMyPc:     array[0..15] of Word;
  NameSettings: array[0..15] of Word;
  TextStart:    array[0..7] of Word;

  { "daemon <prog>" command lines, NUL-terminated. }
  CmdShell:   array[0..31] of Word;
  CmdTop:     array[0..31] of Word;
  CmdMyPc:    array[0..31] of Word;
  CmdSetting: array[0..31] of Word;

{ Copy an ASCII literal into a NUL-terminated UTF-16 buffer. This is what
  C# `fixed (char* s = "...")` did. }
procedure FillWide(dest: PWord; const s: AnsiString);
var
  i: Integer;
begin
  for i := 1 to Length(s) do
    dest[i - 1] := Word(Byte(s[i]));
  dest[Length(s)] := 0;
end;

{ ------------------------------------------------------------------ }
{ 3-argument shared-buffer syscall                                    }
{ ------------------------------------------------------------------ }

{ app_api exposes App_CreateSharedBuffer with two parameters, but slot 27
  really takes three: target PID, page count, and an out pointer for the
  TARGET's view of the mapping (Syscall.cs case 101 reads all three, and the
  target address is what gets sent to the compositor). Casting the slot
  keeps the first argument instead of silently dropping it. }
function CreateSharedBuffer(targetPid: Cardinal; numPages: QWord;
                           out targetVAddr: QWord): QWord;
type
  TFn = function(f: Cardinal; n: QWord; out v: QWord): QWord; cdecl;
begin
  CreateSharedBuffer := TFn(AppApi_Slot(APP_SLOT_CREATE_SHARED_BUFFER))
                           (targetPid, numPages, targetVAddr);
end;

{ ------------------------------------------------------------------ }
{ Font                                                                 }
{ ------------------------------------------------------------------ }

{ 8x8 glyphs, one byte per row, MSB leftmost. Same table as the C#
  original. }
function GetFontBitmap(c: Word): QWord;
begin
  case Chr(c) of
    'A': GetFontBitmap := $0042427E42422418;
    'B': GetFontBitmap := $0078444478444478;
    'C': GetFontBitmap := $003C42404040423C;
    'D': GetFontBitmap := $0078444242424478;
    'E': GetFontBitmap := $007E40407C40407E;
    'F': GetFontBitmap := $004040407C40407E;
    'G': GetFontBitmap := $003C42424E40423C;
    'H': GetFontBitmap := $004242427E424242;
    'I': GetFontBitmap := $003C18181818183C;
    'J': GetFontBitmap := $003048480808081C;
    'K': GetFontBitmap := $0044485060504844;
    'L': GetFontBitmap := $007E404040404040;
    'M': GetFontBitmap := $00424242425A6642;
    'N': GetFontBitmap := $004242464A526242;
    'O': GetFontBitmap := $003C42424242423C;
    'P': GetFontBitmap := $004040407C42427C;
    'Q': GetFontBitmap := $003A444A4242423C;
    'R': GetFontBitmap := $004448507C42427C;
    'S': GetFontBitmap := $003C42023C40423C;
    'T': GetFontBitmap := $001818181818187E;
    'U': GetFontBitmap := $003C424242424242;
    'V': GetFontBitmap := $0018242442424242;
    'W': GetFontBitmap := $0042665A42424242;
    'X': GetFontBitmap := $0042241818182442;
    'Y': GetFontBitmap := $0018181818182442;
    'Z': GetFontBitmap := $007E40201008047E;
    'a': GetFontBitmap := $003F423E023C0000;
    'b': GetFontBitmap := $005C6242625C4040;
    'c': GetFontBitmap := $003C4240423C0000;
    'd': GetFontBitmap := $003B4642463A0202;
    'e': GetFontBitmap := $003C407E423C0000;
    'f': GetFontBitmap := $001010107C10120C;
    'g': GetFontBitmap := $3844023E463A0000;
    'h': GetFontBitmap := $00424242625C4040;
    'i': GetFontBitmap := $0038101010300010;
    'j': GetFontBitmap := $38440404040C0004;
    'k': GetFontBitmap := $0044487048444040;
    'l': GetFontBitmap := $000C121010101018;
    'm': GetFontBitmap := $00525252526C0000;
    'n': GetFontBitmap := $00424242625C0000;
    'o': GetFontBitmap := $003C4242423C0000;
    'p': GetFontBitmap := $405C6242625C0000;
    'q': GetFontBitmap := $023A4642463A0000;
    'r': GetFontBitmap := $0040404064580000;
    's': GetFontBitmap := $003C023C403C0000;
    't': GetFontBitmap := $000C121010103C10;
    'u': GetFontBitmap := $003B464242420000;
    'v': GetFontBitmap := $0018242442420000;
    'w': GetFontBitmap := $00245A5A5A420000;
    'x': GetFontBitmap := $0042241824420000;
    'y': GetFontBitmap := $3844023E42420000;
    'z': GetFontBitmap := $007E2010087E0000;
    '0': GetFontBitmap := $003C4262524A463C;
    '1': GetFontBitmap := $003E080808083808;
    '2': GetFontBitmap := $007E40300C02423C;
    '3': GetFontBitmap := $003C42021C02423C;
    '4': GetFontBitmap := $0004047E4424140C;
    '5': GetFontBitmap := $003C4202027C407E;
    '6': GetFontBitmap := $003C42427C40201C;
    '7': GetFontBitmap := $001010100804027E;
    '8': GetFontBitmap := $003C42423C42423C;
    '9': GetFontBitmap := $003804023E42423C;
    ' ': GetFontBitmap := $0000000000000000;
  else
    GetFontBitmap := $0000000000000000;
  end;
end;

{ ------------------------------------------------------------------ }
{ Drawing - every primitive bounds-checks against maxPixels           }
{ ------------------------------------------------------------------ }

procedure DrawChar(buffer: PCardinal; scanLine, maxPixels: QWord;
                  c: Word; x, y: QWord; color: Cardinal);
var
  fontData: QWord;
  row, col: QWord;
  b: Byte;
  idx: QWord;
begin
  fontData := GetFontBitmap(c);
  for row := 0 to GLYPH_H - 1 do
  begin
    b := Byte(fontData and $FF);
    fontData := fontData shr 8;
    for col := 0 to GLYPH_W - 1 do
    begin
      if (b and (1 shl (7 - col))) <> 0 then
      begin
        idx := (y + row) * scanLine + (x + col);
        if idx < maxPixels then
          buffer[idx] := color;
      end;
    end;
  end;
end;

procedure DrawString(buffer: PCardinal; scanLine, maxPixels: QWord;
                    str: PWord; x, y: QWord; color: Cardinal);
var
  currentX: QWord;
begin
  currentX := x;
  while str^ <> 0 do
  begin
    DrawChar(buffer, scanLine, maxPixels, str^, currentX, y, color);
    currentX := currentX + GLYPH_W;
    Inc(str);
  end;
end;

procedure DrawRect(buffer: PCardinal; scanLine, maxPixels: QWord;
                   x, y, w, h: QWord; color: Cardinal);
var
  row, col, idx: QWord;
begin
  for row := 0 to h - 1 do
  begin
    for col := 0 to w - 1 do
    begin
      idx := (y + row) * scanLine + (x + col);
      if idx < maxPixels then
        buffer[idx] := color;
    end;
  end;
end;

{ Square shortcut icon with the filename centred underneath. }
procedure DrawIcon(buffer: PCardinal; scanLine, maxPixels: QWord;
                   x, y: QWord; name: PWord);
var
  nameLen: Cardinal;
  textWidth, textX: QWord;
begin
  DrawRect(buffer, scanLine, maxPixels, x, y, ICON_SIZE, ICON_SIZE, BORDER_LIGHT);
  DrawRect(buffer, scanLine, maxPixels, x + 2, y + 2, ICON_SIZE - 4, ICON_SIZE - 4, ICON_COLOR);

  nameLen := StrLen(name);
  textWidth := QWord(nameLen) * GLYPH_W;

  { Centre the label. An over-long label (wider than the icon) is centred
    by pulling it left by half its overflow, but never past x = 0. }
  if textWidth < ICON_SIZE then
    textX := x + ((ICON_SIZE - textWidth) div 2)
  else if x + 16 > textWidth div 2 then
    textX := x + 16 - (textWidth div 2)
  else
    textX := 0;

  DrawString(buffer, scanLine, maxPixels, name, textX, y + ICON_SIZE + 4, TEXT_WHITE);
end;

{ Windows-style raised / sunken button. Note the C# passed the literal 60 as
  the x of the right-hand bevel instead of BTN_X + BTN_W - BTN_BEVEL; that is
  reproduced here rather than "corrected", because the result is what ships. }
procedure DrawStartButton(buffer: PCardinal; scanLine, maxPixels, y: QWord;
                          isPressed: Boolean);
begin
  DrawRect(buffer, scanLine, maxPixels, BTN_X, y + BTN_DY, BTN_W, BTN_H, START_BTN_COLOR);

  if isPressed then
  begin
    DrawRect(buffer, scanLine, maxPixels, BTN_X, y + BTN_DY, BTN_W, BTN_BEVEL, BORDER_DARK);
    DrawRect(buffer, scanLine, maxPixels, BTN_X, y + BTN_DY, BTN_BEVEL, BTN_H, BORDER_DARK);
    DrawRect(buffer, scanLine, maxPixels, BTN_X, y + BTN_DY + BTN_H, BTN_W, BTN_BEVEL, BORDER_LIGHT);
    DrawRect(buffer, scanLine, maxPixels, BTN_W, y + BTN_DY, BTN_BEVEL, BTN_H, BORDER_LIGHT);
    DrawString(buffer, scanLine, maxPixels, @TextStart[0],
               BTN_X + 11, y + BTN_TEXT_DY_P, TEXT_BLACK);
  end
  else
  begin
    DrawRect(buffer, scanLine, maxPixels, BTN_X, y + BTN_DY, BTN_W, BTN_BEVEL, BORDER_LIGHT);
    DrawRect(buffer, scanLine, maxPixels, BTN_X, y + BTN_DY, BTN_BEVEL, BTN_H, BORDER_LIGHT);
    DrawRect(buffer, scanLine, maxPixels, BTN_X, y + BTN_DY + BTN_H, BTN_W, BTN_BEVEL, BORDER_DARK);
    DrawRect(buffer, scanLine, maxPixels, BTN_W, y + BTN_DY, BTN_BEVEL, BTN_H, BORDER_DARK);
    DrawString(buffer, scanLine, maxPixels, @TextStart[0],
               BTN_X + 10, y + BTN_TEXT_DY, TEXT_BLACK);
  end;
end;

{ ------------------------------------------------------------------ }

procedure AppMain; cdecl;
var
  dwmId: LongInt;
  screenWidth, screenHeight, scanLine: QWord;
  targetDwmVAddr, myBuffer, maxPixels: QWord;
  buffer: PCardinal;
  i: QWord;
  taskbarY: QWord;
  iconClicked: Boolean;
  clickX, clickY: QWord;
  isDown: Byte;
  payload: QWord;
  dsrvName: array[0..15] of Word;
  { TMessage is 24 bytes; app_api's accessors own the layout. }
  msg: array[0..2] of QWord;
begin
  AppApi_Init;

  FillWide(@dsrvName[0], DSRV_NAME);

  { Spin until the compositor exists, yielding rather than busy-waiting. }
  dwmId := -1;
  while dwmId = -1 do
  begin
    dwmId := App_GetPIDByName(@dsrvName[0]);
    if dwmId = -1 then App_Yield;
  end;

  screenWidth := 0;
  screenHeight := 0;
  scanLine := 0;
  if (App_GetScreenInfo(screenWidth, screenHeight, scanLine) <> 1) or
     (screenWidth = 0) then
  begin
    App_Exit;
    while True do App_WaitIPC;
  end;

  targetDwmVAddr := 0;
  myBuffer := CreateSharedBuffer(Cardinal(dwmId), BACKDROP_PAGES, targetDwmVAddr);
  if (myBuffer = 0) or (targetDwmVAddr = 0) then
  begin
    App_Exit;
    while True do App_WaitIPC;
  end;

  buffer := PCardinal(Pointer(myBuffer));
  maxPixels := scanLine * screenHeight;
  if maxPixels > MAX_PIXELS then maxPixels := MAX_PIXELS;

  { Labels and commands are prepared before first paint so the draw calls
    below need no string setup. }
  FillWide(@NameTerminal[0], 'Terminal');
  FillWide(@NameTop[0], 'NekkoTop');
  FillWide(@NameMyPc[0], 'My PC');
  FillWide(@NameSettings[0], 'Settings');
  FillWide(@TextStart[0], 'START');
  FillWide(@CmdShell[0], 'daemon SHELL.EXE');
  FillWide(@CmdTop[0], 'daemon TOP.EXE');
  FillWide(@CmdMyPc[0], 'daemon MYPC.EXE');
  FillWide(@CmdSetting[0], 'daemon SETTING.EXE');

  { 1. Fill the backdrop. }
  i := 0;
  while i < maxPixels do
  begin
    buffer[i] := DESKTOP_COLOR;
    Inc(i);
  end;

  { 2. Scatter the shortcut icons. }
  DrawIcon(buffer, scanLine, maxPixels, ICON_X, ICON_Y + ICON_ROW0, @NameTerminal[0]);
  DrawIcon(buffer, scanLine, maxPixels, ICON_X, ICON_Y + ICON_ROW1, @NameTop[0]);
  DrawIcon(buffer, scanLine, maxPixels, ICON_X, ICON_Y + ICON_ROW2, @NameMyPc[0]);
  DrawIcon(buffer, scanLine, maxPixels, ICON_X, ICON_Y + ICON_ROW3, @NameSettings[0]);

  { 3. Taskbar. The C# computed taskbarY before the size guard, so on a
     screen shorter than 32 rows it underflows; it is only ever used inside
     the guard and inside the click test, where an underflowed value simply
     matches nothing. Kept as-is rather than clamped. }
  taskbarY := screenHeight - TASKBAR_H;
  if (screenHeight > 40) and (screenWidth > 100) then
  begin
    DrawRect(buffer, scanLine, maxPixels, 0, taskbarY, screenWidth, TASKBAR_H, TASKBAR_COLOR);
    DrawRect(buffer, scanLine, maxPixels, 0, taskbarY, screenWidth, 2, BORDER_LIGHT);
    DrawStartButton(buffer, scanLine, maxPixels, taskbarY, False);
  end;

  { Hand the compositor the target-side address; it maps and blits it. }
  App_SendIPC(Cardinal(dwmId), IPC_DESKTOP, targetDwmVAddr);

  { Latch so one press launches one app, not one per IPC message. }
  iconClicked := False;

  while True do
  begin
    if App_ReceiveIPC(@msg[0]) = 1 then
    begin
      if App_MsgType(@msg[0]) = IPC_CLICK then
      begin
        payload := App_MsgPayload(@msg[0]);
        clickX := payload and $FFFF;
        clickY := (payload shr 16) and $FFFF;
        isDown := Byte((payload shr 32) and $FF);

        { Start button: repaint in the pressed state and re-send. }
        if (clickX >= BTN_HIT_MIN_X) and (clickX <= BTN_HIT_MAX_X) and
           (clickY >= taskbarY + BTN_HIT_MIN_DY) and
           (clickY <= taskbarY + BTN_HIT_MAX_DY) then
        begin
          DrawStartButton(buffer, scanLine, maxPixels, taskbarY, isDown = 1);
          App_SendIPC(Cardinal(dwmId), IPC_DESKTOP, targetDwmVAddr);
        end;

        if isDown = 1 then
        begin
          if not iconClicked then
          begin
            if (clickX >= ICON_HIT_MIN) and (clickX <= ICON_HIT_MAX) then
            begin
              if (clickY >= ICON_Y + ICON_ROW0) and (clickY <= ICON_Y + ICON_ROW0 + ICON_HIT_MAX) then
              begin
                App_RunCmd(@CmdShell[0], 0);
                iconClicked := True;
              end
              else if (clickY >= ICON_Y + ICON_ROW1) and (clickY <= ICON_Y + ICON_ROW1 + ICON_HIT_MAX) then
              begin
                App_RunCmd(@CmdTop[0], 0);
                iconClicked := True;
              end
              else if (clickY >= ICON_Y + ICON_ROW2) and (clickY <= ICON_Y + ICON_ROW2 + ICON_HIT_MAX) then
              begin
                App_RunCmd(@CmdMyPc[0], 0);
                iconClicked := True;
              end
              else if (clickY >= ICON_Y + ICON_ROW3) and (clickY <= ICON_Y + ICON_ROW3 + ICON_HIT_MAX) then
              begin
                App_RunCmd(@CmdSetting[0], 0);
                iconClicked := True;
              end;
            end;
          end;
        end
        else
          { Release clears the latch so the next press registers. }
          iconClicked := False;
      end;
    end
    else
      App_WaitIPC;
  end;
end;

end.
