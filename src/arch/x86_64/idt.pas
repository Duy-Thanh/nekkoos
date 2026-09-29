{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: idt - Interrupt Descriptor Table manager.
  PORTED FROM: src/arch/x86_64/IDT.cs (deleted).

  x86_64 ONLY. The interrupt gate layout below is architecture specific; a
  new architecture needs its own twin unit exposing the same Idt_* API.

  The 256-entry table is backed by a full PMM page (256 * 16 = 4096 bytes),
  so no separate allocation sizing is needed.
  =========================================================================
}

unit idt;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}

interface

{ Records stay in the implementation section: exposing a record in the
  interface makes FPC emit RTTI that lld cannot resolve (AGENTS.md §6.3).
  Idt_GetTable returns a pointer to TIdtEntry (16 bytes, packed) and
  Idt_GetPointer to TIdtPtr (Limit: Word + Base: QWord, packed). }

function Idt_GetTable: Pointer;
function Idt_GetPointer: Pointer;

procedure Idt_Init;
procedure Idt_SetGate(interruptNumber: Integer; handlerAddress: Pointer);

{ Ring 3 accessible gate (DPL 3). Used for the syscall entry so user threads
  can trigger it via INT. The Present flag is written LAST, after a full
  store fence, so no window exists where the gate is reachable but its
  address fields are not yet visible to other cores. }
procedure Idt_SetGateWithRing3(interruptNumber: Integer; handlerAddress: Pointer);

implementation

uses arch_interface, pmm, terminal, kstring, io;

procedure Arch_LoadIDT(idtrAddr: Pointer); cdecl; external name 'Arch_LoadIDT';

{ --- Records: implementation only, no RTTI (AGENTS.md §2.4) --- }
type
  PIdtEntry = ^TIdtEntry;
  TIdtEntry = packed record
    BaseLow:  Word;
    Selector: Word;
    Ist:      Byte;
    Flags:    Byte;
    BaseMid:  Word;
    BaseHigh: Cardinal;
    Reserved: Cardinal;
  end;

  PIdtPtr = ^TIdtPtr;
  TIdtPtr = packed record
    Limit: Word;
    Base:  QWord;
  end;

const
  IDT_ENTRY_SIZE = 16;
  IDT_ENTRIES    = 256;
  IDT_PAGE_SIZE  = IDT_ENTRY_SIZE * IDT_ENTRIES;   { 4096 }

var
  Idt_Table: PIdtEntry = nil;
  Idt_Ptr:   PIdtPtr   = nil;

function Idt_GetTable: Pointer;
begin
  Idt_GetTable := Pointer(Idt_Table);
end;

function Idt_GetPointer: Pointer;
begin
  Idt_GetPointer := Pointer(Idt_Ptr);
end;

procedure Idt_Fatal(const msg: AnsiString); inline;
begin
  Terminal_SetColor_Pas($00FF0000);
  Terminal_Print_Pas(W(msg));
  Io_Hlt;
end;

procedure Idt_Init;
var
  p: PByte;
  i: Integer;
begin
  Idt_Table := PIdtEntry(Pmm_AllocatePage);
  if Idt_Table = nil then
  begin
    Idt_Fatal('[!] FATAL: Cannot allocate memory for IDT!'#13#10);
    Exit;
  end;

  if (QWord(Idt_Table) and $7) <> 0 then
  begin
    Idt_Fatal('[!] FATAL: IDT is not 8-byte aligned!'#13#10);
    Exit;
  end;

  p := PByte(Pointer(Idt_Table));
  for i := 0 to IDT_PAGE_SIZE - 1 do
    p[i] := 0;

  Idt_Ptr := PIdtPtr(Pmm_AllocatePage);
  if Idt_Ptr = nil then
  begin
    Idt_Fatal('[!] FATAL: Cannot allocate memory for IDTR!'#13#10);
    Exit;
  end;

  if (QWord(Idt_Ptr) and $7) <> 0 then
  begin
    Idt_Fatal('[!] FATAL: IDTR is not 8-byte aligned!'#13#10);
    Exit;
  end;

  Idt_Ptr^.Limit := $0FFF;
  Idt_Ptr^.Base  := QWord(Pointer(Idt_Table));

  { LIDT reads straight from RAM, so Limit/Base must be retired out of the
    store buffer before the instruction executes. }
  Arch_StoreFence;

  Arch_LoadIDT(Pointer(Idt_Ptr));

  Terminal_SetColor_Pas($0000FF00);
  Terminal_Print_Pas(W('[+] Multicore IDT (Interrupt Descriptor Table) Forged in PMM!'#13#10));
end;

procedure Idt_SetGateCommon(interruptNumber: Integer; handlerAddress: Pointer; flags: Byte);
var
  addr: QWord;
  entry: PIdtEntry;
begin
  if (interruptNumber < 0) or (interruptNumber > 255) then
  begin
    Terminal_SetColor_Pas($00FF0000);
    Terminal_Print_Pas(W('[!] FATAL: Invalid interrupt number!'#13#10));
    Exit;
  end;

  if handlerAddress = nil then
  begin
    Terminal_SetColor_Pas($00FF0000);
    Terminal_Print_Pas(W('[!] FATAL: Null handler address!'#13#10));
    Exit;
  end;

  addr := QWord(handlerAddress);
  entry := @Idt_Table[interruptNumber];

  { Write address + selector first, WITHOUT setting Present. A gate that is
    reachable but not yet populated would jump to a garbage address. }
  entry^.BaseLow  := Word(addr and $FFFF);
  entry^.Selector := $08;
  entry^.Ist      := 0;
  entry^.BaseMid  := Word((addr shr 16) and $FFFF);
  entry^.BaseHigh := Cardinal(addr shr 32);
  entry^.Reserved := 0;

  if entry^.Selector <> $08 then
  begin
    Terminal_SetColor_Pas($00FF0000);
    Terminal_Print_Pas(W('[!] FATAL: Invalid selector!'#13#10));
    Exit;
  end;

  Arch_CompilerFence;
  Arch_StoreFence;

  entry^.Flags := flags;

  { Publish: other cores must observe the fully-formed gate. }
  Arch_StoreFence;
end;

procedure Idt_SetGate(interruptNumber: Integer; handlerAddress: Pointer);
begin
  Idt_SetGateCommon(interruptNumber, handlerAddress, $8E);
end;

procedure Idt_SetGateWithRing3(interruptNumber: Integer; handlerAddress: Pointer);
begin
  Idt_SetGateCommon(interruptNumber, handlerAddress, $EE);
end;

end.
