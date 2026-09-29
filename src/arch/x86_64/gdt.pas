{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: gdt - Global Descriptor Table & Ring 3 TSS "jail" manager.
  PORTED FROM: src/arch/x86_64/GDT.cs (deleted).

  x86_64 ONLY. For another architecture, provide a twin unit exposing the
  same Gdt_* API built on that architecture's segment model; no other code
  in the tree may depend on the record layouts declared here.

  Records are declared in the implementation section and marked
  {$PACKRECORDS 1} so FPC emits no RTTI (AGENTS.md §2.4). GDTDescriptor is
  the only record that escapes across a cdecl boundary, so it is declared in
  the interface with an explicit packed record.

  The TSS IOPB is 8 KiB, hence the large static allocation below.
  =========================================================================
}

unit gdt;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}
{$ASMMODE Intel}

interface

{ Records are deliberately NOT exposed here. Exposing a record type in the
  interface forces FPC to emit RTTI for it, which lld cannot resolve
  (AGENTS.md §6.3). The layout crosses the boundary only through raw
  pointers; see the implementation section for the authoritative definition.
  Gdt_GetDescriptor returns *Gdt_Desc, a packed Size(2)+Offset(8) record. }

{ --- GDT manager state, shared with the scheduler (TSS.Rsp0 per core) --- }
function Gdt_GetTss: Pointer;
function Gdt_GetTssRsp0: QWord;
function Gdt_GetIopbOffset: Word;
function Gdt_GetDescriptor: Pointer;

{ Core 0 also owns the IO permission bitmap, so it must be the one wired
  up first. Secondary cores are told about the shared IOPB by SMP. }
procedure Gdt_SetCoreTss(coreIndex: Cardinal; tssPtr: Pointer);
function Gdt_GetCoreTss(coreIndex: Cardinal): Pointer;
function Gdt_GetCoreCount: Cardinal;
procedure Gdt_SetCoreCount(c: Cardinal);

procedure Gdt_Init;
procedure Gdt_GrantPortAccess(port: Word);

implementation

uses libc, kstring, arch_interface, pmm, terminal, io;

{ --- Hardware primitives implemented in Hardware.asm --- }
procedure Arch_LoadGDT(gdtPtr: Pointer); cdecl; external name 'Arch_LoadGDT';
procedure Arch_LoadTSS(selector: Word); cdecl; external name 'Arch_LoadTSS';

{ --- Records: implementation only, no RTTI (AGENTS.md §2.4) --- }
type
  { Layout handed to LGDT. Packed: Size(2) + Offset(8) = 10 bytes, matching
    the C# GDTDescriptor this replaces. }
  PGdtDescriptor = ^TGdtDescriptor;
  TGdtDescriptor = packed record
    Size:   Word;
    Offset: QWord;
  end;

  PGdtEntry = ^TGdtEntry;
  TGdtEntry = packed record
    LimitLow:  Word;
    BaseLow:   Word;
    BaseMiddle: Byte;
    Access:    Byte;
    Flags:     Byte;
    BaseHigh:  Byte;
  end;

  TTssEntry = packed record
    Reserved0:  Cardinal;
    Rsp0:       QWord;
    Rsp1:       QWord;
    Rsp2:       QWord;
    Reserved1:  QWord;
    Ist1:       QWord;
    Ist2:       QWord;
    Ist3:       QWord;
    Ist4:       QWord;
    Ist5:       QWord;
    Ist6:       QWord;
    Ist7:       QWord;
    Reserved2:  QWord;
    Reserved3:  Word;
    IopbOffset: Word;
    Iopb:       array[0..8191] of Byte;
    EndMarker:  Byte;
  end;

  PTssEntry = ^TTssEntry;

  PTssDescriptor = ^TTssDescriptor;
  TTssDescriptor = packed record
    LimitLow:    Word;
    BaseLow:     Word;
    BaseMiddle:  Byte;
    Access:      Byte;
    Flags:       Byte;
    BaseHigh:    Byte;
    BaseUpper32: Cardinal;
    Reserved:    Cardinal;
  end;

const
  IOPB_SIZE   = 8192;
  IOPB_ALL_ON = $FF;
  TSS_MIN     = 104 + IOPB_SIZE;   { guards the IOPB fitting in the TSS }

var
  Gdt_Tss: PTssEntry = nil;
  Gdt_Desc: TGdtDescriptor;

  { Per-core TSS list. BSP owns slot 0; AP cores are registered by SMP.
    Static storage is zero-initialised, which is the nil state we want. }
  Gdt_CoreTss: array[0..63] of Pointer;
  Gdt_CoreCnt: Cardinal = 1;

function Gdt_GetTss: Pointer;
begin
  Gdt_GetTss := Pointer(Gdt_Tss);
end;

function Gdt_GetTssRsp0: QWord;
begin
  if Gdt_Tss = nil then Gdt_GetTssRsp0 := 0
  else Gdt_GetTssRsp0 := Gdt_Tss^.Rsp0;
end;

function Gdt_GetIopbOffset: Word;
begin
  if Gdt_Tss = nil then Gdt_GetIopbOffset := 0
  else Gdt_GetIopbOffset := Gdt_Tss^.IopbOffset;
end;

function Gdt_GetDescriptor: Pointer;
begin
  Gdt_GetDescriptor := @Gdt_Desc;
end;

procedure Gdt_SetCoreTss(coreIndex: Cardinal; tssPtr: Pointer);
begin
  if coreIndex > 63 then Exit;
  Gdt_CoreTss[coreIndex] := tssPtr;
end;

function Gdt_GetCoreTss(coreIndex: Cardinal): Pointer;
begin
  if coreIndex > 63 then Gdt_GetCoreTss := nil
  else Gdt_GetCoreTss := Gdt_CoreTss[coreIndex];
end;

function Gdt_GetCoreCount: Cardinal;
begin
  Gdt_GetCoreCount := Gdt_CoreCnt;
end;

procedure Gdt_SetCoreCount(c: Cardinal);
begin
  if c = 0 then c := 1;
  if c > 64 then c := 64;
  Gdt_CoreCnt := c;
end;

{ Fatal helper: every validation failure below halts the same way, matching
  the original C# behaviour (print then Hlt). }
procedure Gdt_Fatal(const msg: AnsiString); inline;
begin
  Terminal_SetColor_Pas($00FF0000);
  Terminal_Print_Pas(W(msg));
  IO_Hlt;
end;

procedure SetEntry(entry: PGdtEntry; baseAddr, limit: Cardinal; access, flags: Byte); inline;
begin
  entry^.BaseLow    := Word(baseAddr and $FFFF);
  entry^.BaseMiddle := Byte((baseAddr shr 16) and $FF);
  entry^.BaseHigh   := Byte((baseAddr shr 24) and $FF);
  entry^.LimitLow   := Word(limit and $FFFF);
  entry^.Flags      := Byte((limit shr 16) and $0F) or Byte(flags and $F0);
  entry^.Access     := access;
end;

{ GrantRing3Port: clear the IOPB bit for `port` on the BSP TSS and on every
  registered AP TSS, so all cores get the permission at the same time.
  Fences matter here: the bitmap lives in RAM that other cores read. }
procedure Gdt_GrantPortAccess(port: Word);
var
  byteIndex: Cardinal;
  bitIndex: Cardinal;
  mask: Byte;
  i: Cardinal;
  apTss: PTssEntry;
begin
  if port > $FFFF then
  begin
    Gdt_Fatal('[!] FATAL: Invalid port number!'#13#10);
    Exit;
  end;

  byteIndex := port div 8;
  bitIndex  := port mod 8;

  if byteIndex >= IOPB_SIZE then
  begin
    Gdt_Fatal('[!] FATAL: Port access out of IOPB range!'#13#10);
    Exit;
  end;

  mask := Byte(not (1 shl bitIndex));

  { Tell the compiler this sequence mutates memory, then publish. }
  Arch_CompilerFence;

  if Gdt_Tss <> nil then
    Gdt_Tss^.Iopb[byteIndex] := Gdt_Tss^.Iopb[byteIndex] and mask;

  for i := 1 to Gdt_CoreCnt - 1 do
  begin
    if Gdt_CoreTss[i] <> nil then
    begin
      apTss := PTssEntry(Gdt_CoreTss[i]);
      Arch_CompilerFence;
      apTss^.Iopb[byteIndex] := apTss^.Iopb[byteIndex] and mask;
    end;
  end;

  { MFENCE: flush every core's store buffer so the app cannot issue IN/OUT
    before the bitmap is globally visible. }
  Arch_FullFence;
end;

procedure Gdt_Init;
var
  gdtMem: PByte;
  entries: PGdtEntry;
  tssDesc: PTssDescriptor;
  tssBase: QWord;
  tssLimit: Cardinal;
  rsp0Page: PByte;
  i: Integer;
begin
  gdtMem := PByte(Pmm_AllocatePage);
  if gdtMem = nil then
  begin
    Gdt_Fatal('[!] FATAL: Cannot allocate memory for GDT!'#13#10);
    Exit;
  end;

  if (QWord(gdtMem) and $7) <> 0 then
  begin
    Gdt_Fatal('[!] FATAL: GDT is not 8-byte aligned!'#13#10);
    Exit;
  end;

  Gdt_Tss := PTssEntry(Pmm_AllocateContiguousPages(3));
  if Gdt_Tss = nil then
  begin
    Gdt_Fatal('[!] FATAL: Cannot allocate contiguous memory for TSS!'#13#10);
    Exit;
  end;

  if (QWord(Gdt_Tss) and $F) <> 0 then
  begin
    Gdt_Fatal('[!] FATAL: TSS is not 16-byte aligned!'#13#10);
    Exit;
  end;

  MemSet(Pointer(Gdt_Tss), 0, SizeOf(TTssEntry));

  if SizeOf(TTssEntry) < TSS_MIN then
  begin
    Gdt_Fatal('[!] FATAL: TSS size is too small for IOPB!'#13#10);
    Exit;
  end;

  for i := 0 to IOPB_SIZE - 1 do
    Gdt_Tss^.Iopb[i] := IOPB_ALL_ON;
  Gdt_Tss^.EndMarker := IOPB_ALL_ON;

  entries := PGdtEntry(Pointer(gdtMem));

  SetEntry(@entries[0], 0, 0,       $00, $00);   { Null }
  SetEntry(@entries[1], 0, $FFFFF, $9A, $A0);   { Ring 0 Code }
  SetEntry(@entries[2], 0, $FFFFF, $92, $A0);   { Ring 0 Data }
  SetEntry(@entries[3], 0, $FFFFF, $F2, $A0);   { Ring 3 Data }
  SetEntry(@entries[4], 0, $FFFFF, $FA, $A0);   { Ring 3 Code }

  tssDesc := PTssDescriptor(Pointer(@entries[5]));
  tssBase := QWord(Gdt_Tss);
  tssLimit := Cardinal(SizeOf(TTssEntry) - 1);

  if tssLimit > $0FFFFF then
  begin
    Gdt_Fatal('[!] FATAL: TSS size exceeds limit!'#13#10);
    Exit;
  end;

  tssDesc^.LimitLow    := Word(tssLimit and $FFFF);
  tssDesc^.BaseLow     := Word(tssBase and $FFFF);
  tssDesc^.BaseMiddle  := Byte((tssBase shr 16) and $FF);
  tssDesc^.Access      := $89;
  tssDesc^.Flags       := Byte((tssLimit shr 16) and $0F);
  tssDesc^.BaseHigh    := Byte((tssBase shr 24) and $FF);
  tssDesc^.BaseUpper32 := Cardinal(tssBase shr 32);
  tssDesc^.Reserved    := 0;

  Gdt_Tss^.IopbOffset := 104;

  if Gdt_Tss^.IopbOffset >= IOPB_SIZE then
  begin
    Gdt_Fatal('[!] FATAL: IOPB offset out of range!'#13#10);
    Exit;
  end;

  Gdt_Desc.Size   := 55;
  Gdt_Desc.Offset := QWord(gdtMem);

  rsp0Page := PByte(Pmm_AllocatePage);
  if rsp0Page = nil then
  begin
    Gdt_Fatal('[!] FATAL: Cannot allocate memory for Rsp0!'#13#10);
    Exit;
  end;

  Gdt_Tss^.Rsp0 := QWord(rsp0Page) + 4096;

  if (Gdt_Tss^.Rsp0 < QWord(rsp0Page)) or
     (Gdt_Tss^.Rsp0 > QWord(rsp0Page) + 4096) then
  begin
    Gdt_Fatal('[!] FATAL: Invalid Rsp0 address!'#13#10);
    Exit;
  end;

  { Hard fence before LGDT/LTR: the descriptor must be retired out of the
    store buffer into RAM before the CPU reads it. }
  Arch_StoreFence;

  Arch_LoadGDT(@Gdt_Desc);
  Arch_LoadTSS($28);

  Terminal_SetColor_Pas($0000FF00);
  Terminal_Print_Pas(W('[+] Core GDT and Ring 3 TSS Jail Forged in Steel!'#13#10));
end;

end.
