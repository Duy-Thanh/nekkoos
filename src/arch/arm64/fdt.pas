{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: fdt - just enough flattened-device-tree reading to find RAM.

  The firmware/QEMU hands the kernel a device tree in x0. We only need the
  /memory node's `reg` (base, size). All FDT integers are big-endian.
  =========================================================================
}
unit fdt;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

{ Finds the first /memory node. False when the blob is not a valid FDT or has
  no usable memory node. }
function Fdt_FindMemory(blob: PByte; out base, size: QWord): Boolean;

implementation

const
  FDT_MAGIC = $D00DFEED;
  TOK_BEGIN = 1;
  TOK_END_NODE = 2;
  TOK_PROP = 3;
  TOK_NOP = 4;
  TOK_END = 9;

function Be32(p: PByte): Cardinal;
begin
  Be32 := (Cardinal(p[0]) shl 24) or (Cardinal(p[1]) shl 16) or
          (Cardinal(p[2]) shl 8) or Cardinal(p[3]);
end;

function StartsWith(s, prefix: PChar): Boolean;
begin
  while prefix^ <> #0 do
  begin
    if s^ <> prefix^ then begin StartsWith := False; Exit; end;
    Inc(s);
    Inc(prefix);
  end;
  StartsWith := True;
end;

function Equals(s, other: PChar): Boolean;
begin
  while (s^ <> #0) and (s^ = other^) do begin Inc(s); Inc(other); end;
  Equals := s^ = other^;
end;

function ReadCells(p: PByte; cells: Cardinal): QWord;
var
  i: Cardinal;
  v: QWord;
begin
  v := 0;
  for i := 0 to cells - 1 do v := (v shl 32) or Be32(p + i * 4);
  ReadCells := v;
end;

function Fdt_FindMemory(blob: PByte; out base, size: QWord): Boolean;
var
  structOff, strOff, total, off, tok, len, nameOff: Cardinal;
  depth: Integer;
  addrCells, sizeCells: Cardinal;
  inMemory: Boolean;
  name: PChar;
  data: PByte;
begin
  Fdt_FindMemory := False;
  base := 0;
  size := 0;
  if (blob = nil) or (Be32(blob) <> FDT_MAGIC) then Exit;
  total := Be32(blob + 4);
  structOff := Be32(blob + 8);
  strOff := Be32(blob + 12);
  addrCells := 2;
  sizeCells := 1;     { the DT default when the root omits them }
  depth := 0;
  inMemory := False;
  off := structOff;

  while off < total do
  begin
    tok := Be32(blob + off);
    Inc(off, 4);
    case tok of
      TOK_BEGIN:
        begin
          name := PChar(blob + off);
          Inc(depth);
          if (depth = 2) and StartsWith(name, 'memory') then inMemory := True;
          len := 0;
          while name[len] <> #0 do Inc(len);
          off := (off + len + 1 + 3) and not Cardinal(3);
        end;
      TOK_END_NODE:
        begin
          if (depth = 2) then inMemory := False;
          Dec(depth);
        end;
      TOK_PROP:
        begin
          len := Be32(blob + off);
          nameOff := Be32(blob + off + 4);
          data := blob + off + 8;
          name := PChar(blob + strOff + nameOff);
          if (depth = 1) and Equals(name, '#address-cells') then addrCells := Be32(data)
          else if (depth = 1) and Equals(name, '#size-cells') then sizeCells := Be32(data)
          else if inMemory and Equals(name, 'reg') and
                  (len >= (addrCells + sizeCells) * 4) then
          begin
            base := ReadCells(data, addrCells);
            size := ReadCells(data + addrCells * 4, sizeCells);
            Fdt_FindMemory := size <> 0;
            Exit;
          end;
          off := (off + 8 + len + 3) and not Cardinal(3);
        end;
      TOK_NOP: ;
      TOK_END: Break;
    else
      Exit;
    end;
  end;
end;

end.
