{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: dsrv_app - Ring-3 display server / window compositor (The Compositor).
  PORTED FROM: src/apps/dsrv.cs (deleted once this unit is linked).

  WINDOW MEMORY CONTRACT
  Every window is a shared buffer whose first 248 bytes are a TWindowHeader
  (geometry + 32-byte title + padding) and whose pixels start at byte 256.
  Explorer is not special-cased: it registers through IPC type 10 and lands
  in slot 0, which is blitted first as the desktop backdrop.

  ALL DRAWING IS CLIPPED AGAINST SIGNED COORDINATES
  Every rect routine takes LongInt, not Cardinal. A window dragged past the
  left or top edge produces negative x/y, and an unsigned compare would wrap
  to a huge value and let the loop scribble across the whole framebuffer.
  The C# comments call this out ("FIX TƯƠNG TỰ"); the signed types below are
  the fix and must not be "simplified" to QWord.

  MemCopy is libc's, whose count is a Cardinal. That is a byte count and it
  is orders of magnitude larger than any framebuffer this app can be handed,
  so the 32-bit width is not a limit in practice.
  =========================================================================
}

unit dsrv_app;

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
  { IPC types this server dispatches on. 3 arrives from Mouse.exe with the
    packed cursor delta, 10/11 register a window, 20 notifies Explorer. }
  IPC_MOUSE_MOVE   = 3;
  IPC_DESKTOP      = 10;
  IPC_WINDOW       = 11;
  IPC_CLICK_NOTIFY = 20;

  { "close window" - privileged, so only a root sender is allowed to send it;
    see Syscall.cs case 5. }
  IPC_KILL_WINDOW  = $DEAD;

  { Window slots. Slot 0 is reserved for the desktop backdrop. }
  WINDOW_SLOTS = 32;

  { A TWindowHeader is 8 bytes of geometry + 32 title + 208 padding = 248,
    and client pixels start on the next 8-byte boundary at 256. }
  PIXEL_OFFSET = 256;

  { The crosshair is a 20x3 bar and a 3x20 bar drawn +/- 10 px, and the
    region uncovered under an old cursor is 21x21. }
  CURSOR_RADIUS = 10;
  CURSOR_BAR    = 20;
  CURSOR_THICK  = 3;

  { The cursor is kept this far inside each edge. }
  CURSOR_MARGIN = 5;

  { Window frame geometry, all relative to the client origin (x, y). }
  FRAME_PAD     = 4;    { frame thickness around the client area }
  TITLE_FRAME   = 26;   { client origin minus this is the frame top   }
  TITLE_BAR_DY  = 22;   { title bar top, relative to the client origin }
  TITLE_TEXT_DY = 16;   { title text baseline row                    }
  TITLE_H       = 20;   { title bar height                           }

  { Close button: 24 px in from the right edge of the title bar and 20 px
    above the client origin; the hit box spans 0..18 in both axes. }
  CLOSE_BTN_DX   = 24;
  CLOSE_BTN_DY   = 20;
  CLOSE_BTN_SIZE = 18;

  TASKBAR_COLOR   = $00C0C0C0;
  TITLE_BAR_COLOR = $00000080;
  BORDER_LIGHT    = $00FFFFFF;
  BORDER_DARK     = $00000000;

  CURSOR_PRESSED = $00FF0000;
  CURSOR_IDLE    = $00FFFFFF;

type
  { Both records live in the implementation section: a record reachable
    from the interface makes FPC emit RTTI and lld then fails to resolve it
    (AGENTS.md §6.3b). Pack = 1 to match the C# originals byte for byte. }
  PWindowHeader = ^TWindowHeader;
  TWindowHeader = packed record
    X:       LongInt;
    Y:       LongInt;
    Width:   Cardinal;
    Height:  Cardinal;
    Title:   array[0..31] of Byte;
    Padding: array[0..207] of Byte;
  end;

  PWindow = ^TWindow;
  TWindow = packed record
    ID:           Cardinal;
    OwnerPID:     Cardinal;
    IsActive:     Byte;
    IsExplorer:   Byte;
    BackingStore: QWord;
  end;

var
  Framebuffer: PCardinal = nil;
  Backbuffer:  PCardinal = nil;

  ScreenWidth:  QWord = 0;
  ScreenHeight: QWord = 0;
  ScanLine:     QWord = 0;

  Windows: PWindow = nil;

  MouseX:      LongInt = 0;
  MouseY:      LongInt = 0;
  MouseClicks: Byte = 0;

  DraggedWindow: LongInt = -1;
  DragOffsetX:   LongInt = 0;
  DragOffsetY:   LongInt = 0;

{ ------------------------------------------------------------------ }
{ Font                                                                 }
{ ------------------------------------------------------------------ }

{ 8x8 glyphs, one byte per row, MSB leftmost. Same table as the C#
  original, punctuation included. }
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
    '!': GetFontBitmap := $0018001818181818;
    '@': GetFontBitmap := $003C425A56524C38;
    '#': GetFontBitmap := $00247E24247E2400;
    '$': GetFontBitmap := $00183E083E143E18;
    '%': GetFontBitmap := $0046261008646200;
    '^': GetFontBitmap := $0000000042241800;
    '&': GetFontBitmap := $003A443A14281020;
    '*': GetFontBitmap := $0000663CFF3C6600;
    '(': GetFontBitmap := $0008102020100800;
    ')': GetFontBitmap := $0010080404081000;
    '-': GetFontBitmap := $000000007E000000;
    '_': GetFontBitmap := $007E000000000000;
    '=': GetFontBitmap := $0000007E007E0000;
    '+': GetFontBitmap := $000018187E181800;
    '[': GetFontBitmap := $003C202020203C00;
    ']': GetFontBitmap := $003C040404043C00;
    '{': GetFontBitmap := $000E1030100E0000;
    '}': GetFontBitmap := $0070080C08700000;
    '\': GetFontBitmap := $0004081020400000;
    '|': GetFontBitmap := $0018181818181800;
    ';': GetFontBitmap := $2010100010100000;
    ':': GetFontBitmap := $0000101000101000;
    '''': GetFontBitmap := $0000000000081030;
    '"': GetFontBitmap := $0000000000242466;
    ',': GetFontBitmap := $2010100000000000;
    '<': GetFontBitmap := $0008102040201008;
    '.': GetFontBitmap := $0000101000000000;
    '>': GetFontBitmap := $0010080402040810;
    '/': GetFontBitmap := $0040201008040000;
    '?': GetFontBitmap := $0018001804443800;
    '`': GetFontBitmap := $0000000000201008;
    '~': GetFontBitmap := $00000000324C0000;
    ' ': GetFontBitmap := $0000000000000000;
  else
    GetFontBitmap := $0000000000000000;
  end;
end;

{ ------------------------------------------------------------------ }
{ Backbuffer primitives                                               }
{ ------------------------------------------------------------------ }

procedure DrawCharBackbuffer(c: Word; x, y: LongInt; color: Cardinal);
var
  fontData: QWord;
  row, col, px, py: LongInt;
  b: Byte;
begin
  fontData := GetFontBitmap(c);
  for row := 0 to 7 do
  begin
    b := Byte(fontData and $FF);
    fontData := fontData shr 8;
    for col := 0 to 7 do
    begin
      if (b and (1 shl (7 - col))) <> 0 then
      begin
        px := x + col;
        py := y + row;
        if (px >= 0) and (px < LongInt(ScreenWidth)) and
           (py >= 0) and (py < LongInt(ScreenHeight)) then
          Backbuffer[QWord(py) * ScanLine + QWord(px)] := color;
      end;
    end;
  end;
end;

procedure DrawStringBackbuffer(str: PByte; x, y: LongInt; color: Cardinal);
var
  cx: LongInt;
begin
  cx := x;
  while str^ <> 0 do
  begin
    DrawCharBackbuffer(Word(str^), cx, y, color);
    cx := cx + 8;
    Inc(str);
  end;
end;

procedure DrawRectBackbuffer(x, y, width, height: LongInt; color: Cardinal);
var
  startX, startY, endX, endY, r, c, w: LongInt;
begin
  startX := x;
  startY := y;
  endX := x + width;
  endY := y + height;

  if startX < 0 then startX := 0;
  if startY < 0 then startY := 0;
  if endX > LongInt(ScreenWidth) then endX := LongInt(ScreenWidth);
  if endY > LongInt(ScreenHeight) then endY := LongInt(ScreenHeight);
  if (endX <= startX) or (endY <= startY) then Exit;

  w := endX - startX;
  for r := startY to endY - 1 do
  begin
    c := 0;
    while c < w do
    begin
      Backbuffer[QWord(r) * ScanLine + QWord(startX) + QWord(c)] := color;
      Inc(c);
    end;
  end;
end;

{ ------------------------------------------------------------------ }
{ Framebuffer primitives (direct - no backbuffer round trip)         }
{ ------------------------------------------------------------------ }

procedure DrawRectDirect(x, y, width, height: LongInt; color: Cardinal);
var
  startX, startY, endX, endY, r, c, w: LongInt;
begin
  startX := x;
  startY := y;
  endX := x + width;
  endY := y + height;

  if startX < 0 then startX := 0;
  if startY < 0 then startY := 0;
  if endX > LongInt(ScreenWidth) then endX := LongInt(ScreenWidth);
  if endY > LongInt(ScreenHeight) then endY := LongInt(ScreenHeight);
  if (endX <= startX) or (endY <= startY) then Exit;

  w := endX - startX;
  for r := startY to endY - 1 do
  begin
    c := 0;
    while c < w do
    begin
      Framebuffer[QWord(r) * ScanLine + QWord(startX) + QWord(c)] := color;
      Inc(c);
    end;
  end;
end;

procedure DrawCrosshairDirect(cx, cy: LongInt; color: Cardinal);
begin
  DrawRectDirect(cx - CURSOR_RADIUS, cy - 1, CURSOR_BAR, CURSOR_THICK, color);
  DrawRectDirect(cx - 1, cy - CURSOR_RADIUS, CURSOR_THICK, CURSOR_BAR, color);
end;

{ Copy the patch the cursor used to cover out of the backbuffer, so the
  window content underneath shows through again. }
procedure RestoreMouseRect(cx, cy: LongInt);
var
  startX, startY, endX, endY, y, widthToCopy: LongInt;
  offset: QWord;
begin
  startX := cx - CURSOR_RADIUS;
  startY := cy - CURSOR_RADIUS;
  endX := cx + CURSOR_RADIUS;
  endY := cy + CURSOR_RADIUS;

  if startX < 0 then startX := 0;
  if startY < 0 then startY := 0;
  if endX > LongInt(ScreenWidth) then endX := LongInt(ScreenWidth);
  if endY > LongInt(ScreenHeight) then endY := LongInt(ScreenHeight);
  if (endX <= startX) or (endY <= startY) then Exit;

  widthToCopy := endX - startX;
  for y := startY to endY - 1 do
  begin
    offset := QWord(y) * ScanLine + QWord(startX);
    MemCopy(PByte(Framebuffer) + offset, PByte(Backbuffer) + offset,
            Cardinal(widthToCopy * 4));
  end;
end;

{ ------------------------------------------------------------------ }
{ Full compositing pass                                               }
{ ------------------------------------------------------------------ }

{ The pixel blit is done as 64-byte blocks plus a remainder tail, which is
  a whole number of QWords only because the remainder is counted in QWords
  and multiplied by 8 before being handed to a byte-wise copy. }
procedure RenderFullFrame;
var
  i: Integer;
  header: PWindowHeader;
  appPixels: PCardinal;
  w, h, x, y: LongInt;
  startX, startY, endX, endY: LongInt;
  srcXOffset, srcYOffset: LongInt;
  copyW, row, col: LongInt;
  finalDst, finalSrc: PQWord;
  maxF, blks, r: QWord;
  d, s: PQWord;
  maxFast, blocks, rem: QWord;
  cursorColor: Cardinal;
begin
  { Slot 0 is the desktop backdrop: a straight QWord blit of the whole
    framebuffer. }
  if Windows[0].IsActive <> 0 then
  begin
    finalDst := PQWord(Backbuffer);
    finalSrc := PQWord(Pointer(Windows[0].BackingStore));
    maxF := (ScanLine * ScreenHeight) div 2;
    blks := maxF div 8;
    r := maxF mod 8;
    MemCopy(finalDst, finalSrc, Cardinal(blks * 8 * 8));
    MemCopy(finalDst + blks * 8, finalSrc + blks * 8, Cardinal(r * 8));
  end;

  for i := 1 to WINDOW_SLOTS - 1 do
  begin
    if Windows[i].IsActive <> 0 then
    begin
      header := PWindowHeader(Pointer(Windows[i].BackingStore));
      appPixels := PCardinal(PByte(Pointer(Windows[i].BackingStore)) + PIXEL_OFFSET);

      w := LongInt(header^.Width);
      h := LongInt(header^.Height);
      x := header^.X;
      y := header^.Y;

      { Frame, bevels and title bar go into the backbuffer; each call
        clips itself, so a window off the top-left is safe here too. }
      DrawRectBackbuffer(x - FRAME_PAD, y - TITLE_FRAME,
                         w + 2 * FRAME_PAD, h + TITLE_FRAME - TITLE_H + 2 * FRAME_PAD,
                         TASKBAR_COLOR);
      DrawRectBackbuffer(x - FRAME_PAD, y - TITLE_FRAME, w + 2 * FRAME_PAD, 2, BORDER_LIGHT);
      DrawRectBackbuffer(x - FRAME_PAD, y - TITLE_FRAME, 2, h + TITLE_FRAME - TITLE_H + 2 * FRAME_PAD, BORDER_LIGHT);
      DrawRectBackbuffer(x - FRAME_PAD, y + h + 2, w + 2 * FRAME_PAD, 2, BORDER_DARK);
      DrawRectBackbuffer(x + w + 2, y - TITLE_FRAME, 2, h + TITLE_FRAME - TITLE_H + 2 * FRAME_PAD, BORDER_DARK);
      DrawRectBackbuffer(x, y - TITLE_BAR_DY, w, TITLE_H, TITLE_BAR_COLOR);
      DrawStringBackbuffer(@header^.Title[0], x + FRAME_PAD, y - TITLE_TEXT_DY, BORDER_LIGHT);

      { ---- client-area blit, clipped row by row ---- }
      startX := x;
      startY := y;
      endX := x + w;
      endY := y + h;

      { Entirely off-screen: draw nothing at all. }
      if (startX >= LongInt(ScreenWidth)) or (startY >= LongInt(ScreenHeight)) or
         (endX <= 0) or (endY <= 0) then
        Continue;

      { Partially off the top-left: skip the source rows and columns that
        fell off, and move the destination origin to 0. }
      srcXOffset := 0;
      srcYOffset := 0;
      if startX < 0 then
      begin
        srcXOffset := -startX;
        startX := 0;
      end;
      if startY < 0 then
      begin
        srcYOffset := -startY;
        startY := 0;
      end;

      if endX > LongInt(ScreenWidth) then endX := LongInt(ScreenWidth);
      if endY > LongInt(ScreenHeight) then endY := LongInt(ScreenHeight);

      copyW := endX - startX;
      if copyW <= 0 then Continue;

      for row := startY to endY - 1 do
        for col := 0 to copyW - 1 do
          Backbuffer[QWord(row) * ScanLine + QWord(startX + col)] :=
            appPixels[QWord(srcYOffset + (row - startY)) * QWord(w) +
                       QWord(srcXOffset + col)];
    end;
  end;

  { Push the backbuffer to the real framebuffer, same 64-byte blocking. }
  d := PQWord(Framebuffer);
  s := PQWord(Backbuffer);
  maxFast := (ScanLine * ScreenHeight) div 2;
  blocks := maxFast div 8;
  rem := maxFast mod 8;
  MemCopy(d, s, Cardinal(blocks * 8 * 8));
  MemCopy(d + blocks * 8, s + blocks * 8, Cardinal(rem * 8));

  if (MouseClicks and 1) <> 0 then
    cursorColor := CURSOR_PRESSED
  else
    cursorColor := CURSOR_IDLE;
  DrawCrosshairDirect(MouseX, MouseY, cursorColor);
end;

{ ------------------------------------------------------------------ }
{ IPC handlers                                                        }
{ ------------------------------------------------------------------ }

function CursorPressed: Boolean; inline;
begin
  CursorPressed := (MouseClicks and 1) <> 0;
end;

{ IPC type 3: mouse motion plus button state, packed by Mouse.exe as
  dy:16 | dx:16 | clicks:8. Both deltas are SIGNED 16-bit. }
procedure HandleMouseMove(payload: QWord);
var
  dx, dy: LongInt;
  oldClicks: Byte;
  isDown, wasDown: Boolean;
  oldX, oldY: LongInt;
  i, j, topSlot: Integer;
  header: PWindowHeader;
  wx, wy, ww: LongInt;
  btnX, btnY: LongInt;
  tmp: TWindow;
  cursorColor: Cardinal;
begin
  dy := LongInt(SmallInt(payload and $FFFF));
  dx := LongInt(SmallInt((payload shr 16) and $FFFF));

  oldClicks := MouseClicks;
  MouseClicks := Byte((payload shr 32) and $FF);

  oldX := MouseX;
  oldY := MouseY;

  MouseX := MouseX + dx;
  MouseY := MouseY + dy;

  if MouseX < 0 then MouseX := 0;
  if MouseX > LongInt(ScreenWidth) - CURSOR_MARGIN then
    MouseX := LongInt(ScreenWidth) - CURSOR_MARGIN;
  if MouseY < 0 then MouseY := 0;
  if MouseY > LongInt(ScreenHeight) - CURSOR_MARGIN then
    MouseY := LongInt(ScreenHeight) - CURSOR_MARGIN;

  { Uncover whatever the cursor was sitting on before interpreting the
    click - the hit test below is about window geometry, not pixels. }
  RestoreMouseRect(oldX, oldY);

  isDown := CursorPressed;
  wasDown := (oldClicks and 1) <> 0;

  if isDown and (not wasDown) then
  begin
    { Topmost window first: a click goes to the highest active slot. }
    for i := WINDOW_SLOTS - 1 downto 1 do
    begin
      if Windows[i].IsActive <> 0 then
      begin
        header := PWindowHeader(Pointer(Windows[i].BackingStore));
        wx := header^.X;
        wy := header^.Y;
        ww := LongInt(header^.Width);
        { header^.Height is intentionally unread - the C# read it into a
          local and never used it either. }

        btnX := wx + ww - CLOSE_BTN_DX;
        btnY := wy - CLOSE_BTN_DY;

        if (MouseX >= btnX) and (MouseX <= btnX + CLOSE_BTN_SIZE) and
           (MouseY >= btnY) and (MouseY <= btnY + CLOSE_BTN_SIZE) then
        begin
          App_SendIPC(Windows[i].OwnerPID, IPC_KILL_WINDOW, 0);
          Windows[i].IsActive := 0;
          RenderFullFrame;
          Break;
        end
        else if (MouseX >= wx - FRAME_PAD) and (MouseX <= wx + ww + FRAME_PAD) and
                (MouseY >= wy - TITLE_FRAME) and (MouseY <= wy) then
        begin
          { Title bar: start a drag and raise to the top of the z-order. }
          DraggedWindow := i;
          DragOffsetX := MouseX - wx;
          DragOffsetY := MouseY - wy;

          topSlot := i;
          for j := i + 1 to WINDOW_SLOTS - 1 do
            if Windows[j].IsActive <> 0 then topSlot := j;

          if topSlot <> i then
          begin
            tmp := Windows[i];
            Windows[i] := Windows[topSlot];
            Windows[topSlot] := tmp;
            DraggedWindow := topSlot;
          end;

          RenderFullFrame;
          Break;
        end;
      end;
    end;
  end
  else if (not isDown) and wasDown then
    DraggedWindow := -1
  else if isDown and (DraggedWindow <> -1) then
  begin
    header := PWindowHeader(Pointer(Windows[DraggedWindow].BackingStore));
    header^.X := MouseX - DragOffsetX;
    header^.Y := MouseY - DragOffsetY;
    RenderFullFrame;
  end;

  if CursorPressed then
    cursorColor := CURSOR_PRESSED
  else
    cursorColor := CURSOR_IDLE;
  DrawCrosshairDirect(MouseX, MouseY, cursorColor);

  { Tell Explorer about any button change so it can raise its button. }
  if (oldClicks <> MouseClicks) and (Windows[0].IsActive <> 0) then
    App_SendIPC(Windows[0].OwnerPID, IPC_CLICK_NOTIFY,
                (QWord(MouseClicks) shl 32) or
                (QWord(LongWord(MouseY)) shl 16) or QWord(LongWord(MouseX)));
end;

{ IPC type 10: Explorer publishing the desktop backdrop. }
procedure HandleDesktopRegister(sender: Cardinal; backingStore: QWord);
begin
  Windows[0].OwnerPID := sender;
  Windows[0].BackingStore := backingStore;
  Windows[0].IsActive := 1;
  RenderFullFrame;
end;

{ IPC type 11: an ordinary window. Reuse the sender's existing slot if it
  already has one, otherwise take the first free slot. }
procedure HandleWindowRegister(sender: Cardinal; backingStore: QWord);
var
  i, slot: Integer;
begin
  slot := -1;

  for i := 1 to WINDOW_SLOTS - 1 do
  begin
    if (Windows[i].IsActive <> 0) and (Windows[i].OwnerPID = sender) then
    begin
      slot := i;
      Break;
    end;
  end;

  if slot = -1 then
    for i := 1 to WINDOW_SLOTS - 1 do
    begin
      if Windows[i].IsActive = 0 then
      begin
        slot := i;
        Break;
      end;
    end;

  if slot <> -1 then
  begin
    Windows[slot].OwnerPID := sender;
    Windows[slot].BackingStore := backingStore;
    Windows[slot].IsActive := 1;
    RenderFullFrame;
  end;
end;

{ ------------------------------------------------------------------ }

procedure AppMain; cdecl;
var
  fbVirt, backPages: QWord;
  i: Integer;
  { TMessage is 24 bytes. app_api keeps the record private and hands out
    field accessors, so the buffer is raw storage and every field below is
    read through App_Msg*. }
  msg: array[0..2] of QWord;
begin
  AppApi_Init;

  if (App_GetScreenInfo(ScreenWidth, ScreenHeight, ScanLine) <> 1) or
     (ScreenWidth = 0) then
  begin
    App_Exit;
    while True do App_WaitIPC;
  end;

  fbVirt := App_RequestFramebuffer;
  if fbVirt = 0 then
  begin
    App_Exit;
    while True do App_WaitIPC;
  end;
  Framebuffer := PCardinal(Pointer(fbVirt));

  { Same page count the C# asked for: ScanLine*Height*4 bytes rounded up to
    whole pages. }
  backPages := ((ScanLine * ScreenHeight * 4) + 4095) div 4096;
  Backbuffer := PCardinal(Pointer(App_AllocMem(backPages)));

  { 32 slots * 18 bytes = 576, so one page is ample. }
  Windows := PWindow(Pointer(App_AllocMem(1)));

  if (Windows = nil) or (Backbuffer = nil) or (Framebuffer = nil) then
  begin
    App_Exit;
    while True do App_WaitIPC;
  end;

  for i := 0 to WINDOW_SLOTS - 1 do
    Windows[i].IsActive := 0;

  MouseX := LongInt(ScreenWidth div 2);
  MouseY := LongInt(ScreenHeight div 2);

  { Drop anything already queued - Mouse.exe can already be sending motion
    by the time this loop starts. }
  while App_ReceiveIPC(@msg[0]) = 1 do
    begin end;

  while True do
  begin
    if App_ReceiveIPC(@msg[0]) = 1 then
    begin
      case App_MsgType(@msg[0]) of
        IPC_MOUSE_MOVE:
          HandleMouseMove(App_MsgPayload(@msg[0]));

        IPC_DESKTOP:
          HandleDesktopRegister(App_MsgSender(@msg[0]), App_MsgPayload(@msg[0]));

        IPC_WINDOW:
          HandleWindowRegister(App_MsgSender(@msg[0]), App_MsgPayload(@msg[0]));
      end;
    end
    else
      App_WaitIPC;
  end;
end;

end.
