{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: Terminal - Framebuffer Text Renderer (Pascal Implementation)
  PURPOSE: Architecture-independent framebuffer rendering. Writes directly
           to a memory-mapped pixel buffer — no x86 instructions needed.
           Serial output and per-thread color are abstracted as callbacks
           so this module is portable to ARM64/RISC-V framebuffers too.
  =========================================================================
}

unit terminal;

{$mode objfpc}
{$h+}
{$M-}

interface

const
  TERM_SCALE        = 2;
  TERM_CHAR_WIDTH   = 8 * TERM_SCALE;   { 16 pixels }
  TERM_CHAR_HEIGHT  = 8 * TERM_SCALE;   { 16 pixels }
  TERM_LINE_SPACING = 2 * TERM_SCALE;   { 4 pixels  }

{ --- State setters (called from C# Init / EnableShadowBuffer) --- }
procedure Terminal_SetFB_Pas(aFb: Pointer; aWidth, aHeight, aScanLine: Cardinal);
  cdecl; public name 'Terminal_SetFB_Pas';

procedure Terminal_SetBackbuffer_Pas(aBuf: Pointer);
  cdecl; public name 'Terminal_SetBackbuffer_Pas';

procedure Terminal_SetCallbacks_Pas(
    aSerialWriteChar : Pointer;   { procedure(c: Byte) cdecl }
    aGetColor        : Pointer;   { function: Cardinal cdecl }
    aSetColor        : Pointer    { procedure(color: Cardinal) cdecl }
  );
  cdecl; public name 'Terminal_SetCallbacks_Pas';

{ --- Core render API --- }
procedure Terminal_SetColor_Pas(fg: Cardinal);
  cdecl; public name 'Terminal_SetColor_Pas';

procedure Terminal_Clear_Pas(color: Cardinal);
  cdecl; public name 'Terminal_Clear_Pas';

procedure Terminal_DrawChar_Pas(c: Word);
  cdecl; public name 'Terminal_DrawChar_Pas';

procedure Terminal_Print_Pas(str: PWord);
  cdecl; public name 'Terminal_Print_Pas';

procedure Terminal_PrintHex_Pas(val: QWord);
  cdecl; public name 'Terminal_PrintHex_Pas';

procedure Terminal_PrintDec_Pas(val: QWord);
  cdecl; public name 'Terminal_PrintDec_Pas';

procedure Terminal_PrintObfuscated_Pas(encryptedBytes: PByte; length: Integer);
  cdecl; public name 'Terminal_PrintObfuscated_Pas';

procedure Terminal_SyncRect_Pas(startX, startY, rectWidth, rectHeight: Cardinal);
  cdecl; public name 'Terminal_SyncRect_Pas';

procedure Terminal_GetCursor_Pas(out outX, outY: Cardinal);
  cdecl; public name 'Terminal_GetCursor_Pas';

procedure Terminal_SetCursor_Pas(aX, aY: Cardinal);
  cdecl; public name 'Terminal_SetCursor_Pas';

implementation

{ External libc primitives already in libc.pas }
procedure MemSet_Pas(dest: Pointer; value: Byte; count: Cardinal);
  cdecl; external name 'MemSet_Pas';
procedure MemCpy_Pas(dest, src: Pointer; count: Cardinal);
  cdecl; external name 'MemCopy_Pas';

{ ------------------------------------------------------------------ }
{ Module state                                                        }
{ ------------------------------------------------------------------ }
var
  Fb         : PCardinal = nil;   { real framebuffer (BGRA pixels)   }
  Backbuffer : PCardinal = nil;   { shadow buffer (nil = direct mode) }
  FbWidth    : Cardinal  = 0;
  FbHeight   : Cardinal  = 0;
  ScanLine   : Cardinal  = 0;

  CursorX    : Cardinal  = 0;
  CursorY    : Cardinal  = 0;
  BgColor    : Cardinal  = 0;
  BootColor  : Cardinal  = $00FFFFFF;

  { Callbacks — set by C# via Terminal_SetCallbacks_Pas }
  CbSerialWriteChar : procedure(c: Byte); cdecl = nil;
  CbGetColor        : function: Cardinal; cdecl = nil;
  CbSetColor        : procedure(color: Cardinal); cdecl = nil;

{ ------------------------------------------------------------------ }
{ Helpers                                                             }
{ ------------------------------------------------------------------ }

function GetFgColor: Cardinal; inline;
begin
  if Assigned(CbGetColor) then
    GetFgColor := CbGetColor()
  else
    GetFgColor := BootColor;
end;

procedure SetFgColor(color: Cardinal); inline;
begin
  BootColor := color;           { always update boot fallback }
  if Assigned(CbSetColor) then
    CbSetColor(color);
end;

{ ------------------------------------------------------------------ }
{ Font — 8x8 bitmap packed as QWord, one byte per row (top = LSB)    }
{ Identical bitmaps to the C# GetFontBitmap switch.                  }
{ ------------------------------------------------------------------ }
function GetFontBitmap(c: Word): QWord; inline;
begin
  if (c < $20) or (c > $7E) then begin GetFontBitmap := 0; Exit; end;
  case c of
    Ord('A'): GetFontBitmap := QWord($0042427E42422418);
    Ord('B'): GetFontBitmap := QWord($0078444478444478);
    Ord('C'): GetFontBitmap := QWord($003C42404040423C);
    Ord('D'): GetFontBitmap := QWord($0078444242424478);
    Ord('E'): GetFontBitmap := QWord($007E40407C40407E);
    Ord('F'): GetFontBitmap := QWord($004040407C40407E);
    Ord('G'): GetFontBitmap := QWord($003C42424E40423C);
    Ord('H'): GetFontBitmap := QWord($004242427E424242);
    Ord('I'): GetFontBitmap := QWord($003C18181818183C);
    Ord('J'): GetFontBitmap := QWord($003048480808081C);
    Ord('K'): GetFontBitmap := QWord($0044485060504844);
    Ord('L'): GetFontBitmap := QWord($007E404040404040);
    Ord('M'): GetFontBitmap := QWord($00424242425A6642);
    Ord('N'): GetFontBitmap := QWord($004242464A526242);
    Ord('O'): GetFontBitmap := QWord($003C42424242423C);
    Ord('P'): GetFontBitmap := QWord($004040407C42427C);
    Ord('Q'): GetFontBitmap := QWord($003A444A4242423C);
    Ord('R'): GetFontBitmap := QWord($004448507C42427C);
    Ord('S'): GetFontBitmap := QWord($003C42023C40423C);
    Ord('T'): GetFontBitmap := QWord($001818181818187E);
    Ord('U'): GetFontBitmap := QWord($003C424242424242);
    Ord('V'): GetFontBitmap := QWord($0018242442424242);
    Ord('W'): GetFontBitmap := QWord($0042665A42424242);
    Ord('X'): GetFontBitmap := QWord($0042241818182442);
    Ord('Y'): GetFontBitmap := QWord($0018181818182442);
    Ord('Z'): GetFontBitmap := QWord($007E40201008047E);
    Ord('a'): GetFontBitmap := QWord($003F423E023C0000);
    Ord('b'): GetFontBitmap := QWord($005C6242625C4040);
    Ord('c'): GetFontBitmap := QWord($003C4240423C0000);
    Ord('d'): GetFontBitmap := QWord($003B4642463A0202);
    Ord('e'): GetFontBitmap := QWord($003C407E423C0000);
    Ord('f'): GetFontBitmap := QWord($001010107C10120C);
    Ord('g'): GetFontBitmap := QWord($3844023E463A0000);
    Ord('h'): GetFontBitmap := QWord($00424242625C4040);
    Ord('i'): GetFontBitmap := QWord($0038101010300010);
    Ord('j'): GetFontBitmap := QWord($38440404040C0004);
    Ord('k'): GetFontBitmap := QWord($0044487048444040);
    Ord('l'): GetFontBitmap := QWord($000C121010101018);
    Ord('m'): GetFontBitmap := QWord($00525252526C0000);
    Ord('n'): GetFontBitmap := QWord($00424242625C0000);
    Ord('o'): GetFontBitmap := QWord($003C4242423C0000);
    Ord('p'): GetFontBitmap := QWord($405C6242625C0000);
    Ord('q'): GetFontBitmap := QWord($023A4642463A0000);
    Ord('r'): GetFontBitmap := QWord($0040404064580000);
    Ord('s'): GetFontBitmap := QWord($003C023C403C0000);
    Ord('t'): GetFontBitmap := QWord($000C121010103C10);
    Ord('u'): GetFontBitmap := QWord($003B464242420000);
    Ord('v'): GetFontBitmap := QWord($0018242442420000);
    Ord('w'): GetFontBitmap := QWord($00245A5A5A420000);
    Ord('x'): GetFontBitmap := QWord($0042241824420000);
    Ord('y'): GetFontBitmap := QWord($3844023E42420000);
    Ord('z'): GetFontBitmap := QWord($007E2010087E0000);
    Ord('0'): GetFontBitmap := QWord($003C4262524A463C);
    Ord('1'): GetFontBitmap := QWord($003E080808083808);
    Ord('2'): GetFontBitmap := QWord($007E40300C02423C);
    Ord('3'): GetFontBitmap := QWord($003C42021C02423C);
    Ord('4'): GetFontBitmap := QWord($0004047E4424140C);
    Ord('5'): GetFontBitmap := QWord($003C4202027C407E);
    Ord('6'): GetFontBitmap := QWord($003C42427C40201C);
    Ord('7'): GetFontBitmap := QWord($001010100804027E);
    Ord('8'): GetFontBitmap := QWord($003C42423C42423C);
    Ord('9'): GetFontBitmap := QWord($003804023E42423C);
    Ord('!'): GetFontBitmap := QWord($0018001818181818);
    Ord('@'): GetFontBitmap := QWord($003C425A56524C38);
    Ord('#'): GetFontBitmap := QWord($00247E24247E2400);
    Ord('$'): GetFontBitmap := QWord($00183E083E143E18);
    Ord('%'): GetFontBitmap := QWord($0046261008646200);
    Ord('^'): GetFontBitmap := QWord($0000000042241800);
    Ord('&'): GetFontBitmap := QWord($003A443A14281020);
    Ord('*'): GetFontBitmap := QWord($0000663CFF3C6600);
    Ord('('): GetFontBitmap := QWord($0008102020100800);
    Ord(')'): GetFontBitmap := QWord($0010080404081000);
    Ord('-'): GetFontBitmap := QWord($000000007E000000);
    Ord('_'): GetFontBitmap := QWord($007E000000000000);
    Ord('='): GetFontBitmap := QWord($0000007E007E0000);
    Ord('+'): GetFontBitmap := QWord($000018187E181800);
    Ord('['): GetFontBitmap := QWord($003C202020203C00);
    Ord(']'): GetFontBitmap := QWord($003C040404043C00);
    Ord('{'): GetFontBitmap := QWord($000E1030100E0000);
    Ord('}'): GetFontBitmap := QWord($0070080C08700000);
    Ord('\'): GetFontBitmap := QWord($0004081020400000);
    Ord('|'): GetFontBitmap := QWord($0018181818181800);
    Ord(';'): GetFontBitmap := QWord($2010100010100000);
    Ord(':'): GetFontBitmap := QWord($0000101000101000);
    Ord(''''): GetFontBitmap := QWord($0000000000081030);
    Ord('"'): GetFontBitmap := QWord($0000000000242466);
    Ord(','): GetFontBitmap := QWord($2010100000000000);
    Ord('<'): GetFontBitmap := QWord($0008102040201008);
    Ord('.'): GetFontBitmap := QWord($0000101000000000);
    Ord('>'): GetFontBitmap := QWord($0010080402040810);
    Ord('/'): GetFontBitmap := QWord($0040201008040000);
    Ord('?'): GetFontBitmap := QWord($0018001804443800);
    Ord('`'): GetFontBitmap := QWord($0000000000201008);
    Ord('~'): GetFontBitmap := QWord($00000000324C0000);
    Ord(' '): GetFontBitmap := QWord($0000000000000000);
  else
    GetFontBitmap := 0;
  end;
end;

{ ------------------------------------------------------------------ }
{ SyncRect — flush shadow buffer rectangle to real FB                }
{ ------------------------------------------------------------------ }
procedure DoSyncRect(startX, startY, rectWidth, rectHeight: Cardinal); inline;
var
  y, drawY: Cardinal;
  dest, src: PCardinal;
begin
  if Backbuffer = nil then Exit;
  y := 0;
  while y < rectHeight do
  begin
    drawY := startY + y;
    if drawY >= FbHeight then Break;
    dest := Fb       + (drawY * ScanLine + startX);
    src  := Backbuffer + (drawY * ScanLine + startX);
    MemCpy_Pas(dest, src, rectWidth * 4);
    Inc(y);
  end;
end;

{ ------------------------------------------------------------------ }
{ Scroll — shift framebuffer up by one line height                   }
{ ------------------------------------------------------------------ }
procedure DoScroll; inline;
var
  lineHeight, movePixels, rowPixels, i: Cardinal;
  dest: PCardinal;
begin
  lineHeight := TERM_CHAR_HEIGHT + TERM_LINE_SPACING;
  movePixels := ScanLine * (FbHeight - lineHeight);
  rowPixels  := ScanLine * lineHeight;

  if Backbuffer <> nil then dest := Backbuffer else dest := Fb;

  { Shift pixels up }
  i := 0;
  while i < movePixels do
  begin
    dest[i] := dest[i + rowPixels];
    Inc(i);
  end;

  { Clear last line }
  i := movePixels;
  while i < movePixels + rowPixels do
  begin
    dest[i] := BgColor;
    Inc(i);
  end;

  { Flush shadow buffer to real FB if active }
  if Backbuffer <> nil then
    MemCpy_Pas(Fb, Backbuffer, ScanLine * FbHeight * 4);

  Dec(CursorY, lineHeight);
end;

{ ------------------------------------------------------------------ }
{ DrawCharUnsafe — core glyph renderer, no locking                   }
{ ------------------------------------------------------------------ }
procedure DrawCharUnsafe(c: Word);
var
  lineHeight: Cardinal;
  bitmap: QWord;
  row, col, sy, sx: Integer;
  rowData: Byte;
  drawX, drawY, idx: Cardinal;
  fg: Cardinal;
begin
  if (Fb = nil) or (FbWidth = 0) or (FbHeight = 0) then Exit;

  { Serial output via callback }
  if Assigned(CbSerialWriteChar) then
  begin
    if c = Ord(#10) then CbSerialWriteChar(Ord(#13));
    CbSerialWriteChar(Byte(c));
  end;

  lineHeight := TERM_CHAR_HEIGHT + TERM_LINE_SPACING;
  fg := GetFgColor;

  if c = Ord(#10) then      { \n }
  begin
    CursorX := 0;
    CursorY := CursorY + lineHeight;
  end
  else if c = Ord(#13) then { \r }
  begin
    CursorX := 0;
  end
  else if c = Ord(#8) then  { \b backspace }
  begin
    if CursorX >= TERM_CHAR_WIDTH then
      Dec(CursorX, TERM_CHAR_WIDTH)
    else if CursorY >= lineHeight then
    begin
      Dec(CursorY, lineHeight);
      CursorX := (FbWidth div TERM_CHAR_WIDTH) * TERM_CHAR_WIDTH - TERM_CHAR_WIDTH;
    end;
    { Erase glyph pixels }
    for row := 0 to TERM_CHAR_HEIGHT - 1 do
      for col := 0 to TERM_CHAR_WIDTH - 1 do
      begin
        idx := (CursorY + Cardinal(row)) * ScanLine + (CursorX + Cardinal(col));
        if Backbuffer <> nil then Backbuffer[idx] := BgColor
        else Fb[idx] := BgColor;
      end;
    DoSyncRect(CursorX, CursorY, TERM_CHAR_WIDTH, TERM_CHAR_HEIGHT);
  end
  else
  begin
    bitmap := GetFontBitmap(c);
    for row := 0 to 7 do
    begin
      rowData := Byte((bitmap shr (row * 8)) and $FF);
      for col := 0 to 7 do
      begin
        for sy := 0 to TERM_SCALE - 1 do
          for sx := 0 to TERM_SCALE - 1 do
          begin
            drawX := CursorX + Cardinal(col * TERM_SCALE + sx);
            drawY := CursorY + Cardinal(row * TERM_SCALE + sy);
            if (drawX < FbWidth) and (drawY < FbHeight) then
            begin
              idx := drawY * ScanLine + drawX;
              if ((rowData shr (7 - col)) and 1) = 1 then
              begin
                if Backbuffer <> nil then Backbuffer[idx] := fg
                else Fb[idx] := fg;
              end
              else
              begin
                if Backbuffer <> nil then Backbuffer[idx] := BgColor
                else Fb[idx] := BgColor;
              end;
            end;
          end;
      end;
    end;
    DoSyncRect(CursorX, CursorY, TERM_CHAR_WIDTH, TERM_CHAR_HEIGHT);
    Inc(CursorX, TERM_CHAR_WIDTH);
    if CursorX + TERM_CHAR_WIDTH > FbWidth then
    begin
      CursorX := 0;
      Inc(CursorY, lineHeight);
    end;
  end;

  { Scroll if needed }
  if CursorY + lineHeight > FbHeight then
    DoScroll;
end;

{ ------------------------------------------------------------------ }
{ Exported API                                                        }
{ ------------------------------------------------------------------ }

procedure Terminal_SetFB_Pas(aFb: Pointer; aWidth, aHeight, aScanLine: Cardinal); cdecl;
begin
  Fb       := PCardinal(aFb);
  FbWidth  := aWidth;
  FbHeight := aHeight;
  ScanLine := aScanLine;
end;

procedure Terminal_SetBackbuffer_Pas(aBuf: Pointer); cdecl;
begin
  Backbuffer := PCardinal(aBuf);
end;

procedure Terminal_SetCallbacks_Pas(
    aSerialWriteChar : Pointer;
    aGetColor        : Pointer;
    aSetColor        : Pointer); cdecl;
type
  TSerialWriteChar = procedure(c: Byte); cdecl;
  TGetColor        = function: Cardinal; cdecl;
  TSetColor        = procedure(color: Cardinal); cdecl;
begin
  CbSerialWriteChar := TSerialWriteChar(aSerialWriteChar);
  CbGetColor        := TGetColor(aGetColor);
  CbSetColor        := TSetColor(aSetColor);
end;

procedure Terminal_SetColor_Pas(fg: Cardinal); cdecl;
begin
  SetFgColor(fg);
end;

procedure Terminal_Clear_Pas(color: Cardinal); cdecl;
var
  totalPixels, i: QWord;
  dest: PCardinal;
begin
  BgColor := color;
  if (Fb = nil) or (ScanLine = 0) or (FbHeight = 0) then Exit;
  totalPixels := QWord(ScanLine) * QWord(FbHeight);
  if Backbuffer <> nil then
  begin
    dest := Backbuffer;
    i := 0;
    while i < totalPixels do begin dest[i] := color; Inc(i); end;
    MemCpy_Pas(Fb, Backbuffer, Cardinal(totalPixels * 4));
  end
  else
  begin
    dest := Fb;
    i := 0;
    while i < totalPixels do begin dest[i] := color; Inc(i); end;
  end;
  CursorX := 0;
  CursorY := 0;
end;

procedure Terminal_DrawChar_Pas(c: Word); cdecl;
begin
  { Locking is done in C# ScreenLock wrapper; Pascal just renders }
  DrawCharUnsafe(c);
end;

procedure Terminal_Print_Pas(str: PWord); cdecl;
var
  i: Integer;
begin
  if str = nil then Exit;
  i := 0;
  while str[i] <> 0 do
  begin
    DrawCharUnsafe(str[i]);
    Inc(i);
  end;
end;

procedure Terminal_PrintHex_Pas(val: QWord); cdecl;
const
  HexChars: array[0..15] of Word = (
    Ord('0'),Ord('1'),Ord('2'),Ord('3'),Ord('4'),Ord('5'),Ord('6'),Ord('7'),
    Ord('8'),Ord('9'),Ord('A'),Ord('B'),Ord('C'),Ord('D'),Ord('E'),Ord('F'));
var
  buffer: array[0..18] of Word;
  i: Integer;
begin
  buffer[0]  := Ord('0');
  buffer[1]  := Ord('x');
  buffer[18] := 0;
  for i := 0 to 15 do
    buffer[17 - i] := HexChars[(val shr (i * 4)) and $F];
  Terminal_Print_Pas(@buffer[0]);
end;

procedure Terminal_PrintDec_Pas(val: QWord); cdecl;
var
  buffer: array[0..20] of Word;
  pos: Integer;
begin
  buffer[20] := 0;
  if val = 0 then
  begin
    buffer[19] := Ord('0');
    buffer[20] := 0;
    Terminal_Print_Pas(@buffer[19]);
    Exit;
  end;
  pos := 20;
  while val > 0 do
  begin
    Dec(pos);
    buffer[pos] := Ord('0') + Word(val mod 10);
    val := val div 10;
  end;
  Terminal_Print_Pas(@buffer[pos]);
end;

procedure Terminal_PrintObfuscated_Pas(encryptedBytes: PByte; length: Integer); cdecl;
var
  i: Integer;
  dynamicKey: Byte;
  c: Word;
begin
  if encryptedBytes = nil then Exit;
  if length > 255 then Exit;
  for i := 0 to length - 1 do
  begin
    dynamicKey := Byte((i * 13) + 7);
    c := Word(encryptedBytes[i] xor dynamicKey);
    DrawCharUnsafe(c);
  end;
end;

procedure Terminal_SyncRect_Pas(startX, startY, rectWidth, rectHeight: Cardinal); cdecl;
begin
  DoSyncRect(startX, startY, rectWidth, rectHeight);
end;

procedure Terminal_GetCursor_Pas(out outX, outY: Cardinal); cdecl;
begin
  outX := CursorX;
  outY := CursorY;
end;

procedure Terminal_SetCursor_Pas(aX, aY: Cardinal); cdecl;
begin
  CursorX := aX;
  CursorY := aY;
end;

end.
