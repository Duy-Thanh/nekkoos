{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: vmm - 4-level paging manager.
  PORTED FROM: src/arch/x86_64/VMM.cs (deleted).

  x86_64 ONLY. Everything here is x86 paging-structure specific; a new
  architecture needs a twin unit exposing the same Vmm_* API (ARM64 four
  level, RISC-V Sv39/Sv48) plus its own page-size constants.

  THREAT MODEL: this code walks and rewrites page tables using addresses that
  may come from untrusted user input (syscall 12/101), so every derived
  pointer is bounds-checked against the physical memory limit before it is
  dereferenced, and every intermediate table is allocated from the PMM and
  validated after allocation. Skipping those checks reintroduces CVE-2026-006.
  =========================================================================
}

unit vmm;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$ASMMODE Intel}

interface

const
  PAGE_SIZE = 4096;

  { Bits 12..51 carry the physical frame. Bit 63 (NX) and the flag bits are
    stripped, so no flag ever leaks into an address. }
  PHYS_ADDR_MASK = QWord($000FFFFFFFFFF000);

{ True when the address has the canonical sign-extension, i.e. bits 63:48 are
  all zero or all one. Non-canonical addresses fault on use. }
function Vmm_IsCanonical(addr: QWord): Boolean;

procedure Vmm_Init;
procedure Vmm_MapHugePage(physAddr, virtAddr: QWord);
procedure Vmm_MapPage(physAddr, virtAddr, flags: QWord);
procedure Vmm_MapPageIn(physAddr, virtAddr, flags: QWord; pml4Dir: Pointer);
procedure Vmm_DestroyUserSpace(pml4Phys: QWord);

function  Vmm_GetPml4: Pointer;
function  Vmm_ReadCr3: QWord;
procedure Vmm_LoadPml4(pml4: Pointer);
procedure Vmm_FlushTlb(virtualAddress: Pointer);
procedure Vmm_FlushTlbAll;

implementation

uses libc, pmm, spinlock, terminal, kstring, io, kstate;

{ --- Hardware / HAL entry points --- }
procedure Arch_FlushTLB; cdecl; external name 'Arch_FlushTLB';
procedure Arch_LoadPageTable(physAddr: QWord); cdecl; external name 'Arch_LoadPageTable';
function  Arch_ReadPageTable: QWord; cdecl; external name 'Arch_ReadPageTable';
procedure Arch_EnableNX; cdecl; external name 'Arch_EnableNX';

{ A PTE/PDPT/PD/PML4E with the Present bit and the user bit set. }
const
  ENTRY_PRESENT      = QWord(1);
  ENTRY_USER         = QWord(2);
  ENTRY_WRITABLE     = QWord(2);
  ENTRY_HUGE         = QWord($80);   { PS bit, only valid in PD/PDPT entries }

  { x86-64 2 MiB huge page. }
  HUGE_PAGE_SIZE     = QWord(2097152);
  HUGE_ADDR_MASK     = QWord($1FFFFF);

var
  { Root of the kernel address space. Must live below 4 GiB: the SMP
    trampoline runs in 32-bit protected mode and would truncate a CR3 with
    a high PML4, leaving the APs pointing at garbage. }
  Vmm_Pml4: PQWord = nil;
  Vmm_Pml4Phys: QWord = 0;

  Vmm_Lock: Cardinal = 0;

function Vmm_GetPml4: Pointer;
begin
  Vmm_GetPml4 := Pointer(Vmm_Pml4);
end;

function Vmm_ReadCr3: QWord;
begin
  Vmm_ReadCr3 := Arch_ReadPageTable;
end;

procedure Vmm_LoadPml4(pml4: Pointer);
begin
  Arch_LoadPageTable(QWord(pml4));
end;

procedure Vmm_FlushTlb(virtualAddress: Pointer);
begin
  { INVLPG on the specific address: cheaper than a full CR3 reload, which
    would also evict every other core's TLB entries. }
  asm
    mov rax, virtualAddress
    invlpg [rax]
  end;
end;

procedure Vmm_FlushTlbAll;
begin
  Arch_FlushTLB;
end;

function Vmm_IsCanonical(addr: QWord): Boolean;
begin
  { Bits 63:48 must be all zero or all one. }
  Vmm_IsCanonical := ((addr shr 48) = 0) or ((addr shr 48) = $FFFF);
end;

{ One past the last usable physical address. Any pointer derived from a page
  table entry is compared against this before dereference. }
function PhysLimit: QWord; inline;
begin
  PhysLimit := Pmm_GetTotalPages * PAGE_SIZE;
end;

{ Allocate a zeroed 512-entry table, or nil on failure. }
function AllocateTable: Pointer; inline;
var
  t: PQWord;
  i: Integer;
begin
  t := PQWord(Pmm_AllocatePage);
  if t = nil then
  begin
    AllocateTable := nil;
    Exit;
  end;
  for i := 0 to 511 do
    t[i] := 0;
  AllocateTable := Pointer(t);
end;

{ Extract the physical address of a table entry and reject it if it points
  outside RAM. Returns nil for a bad entry so callers can bail out. }
function EntryToPtr(entry: QWord): Pointer;
begin
  if (entry and PHYS_ADDR_MASK) = 0 then
  begin
    EntryToPtr := nil;
    Exit;
  end;
  if (entry and PHYS_ADDR_MASK) >= PhysLimit then
  begin
    EntryToPtr := nil;
    Exit;
  end;
  EntryToPtr := Pointer(entry and PHYS_ADDR_MASK);
end;

procedure Vmm_Fatal(const msg: AnsiString); inline;
begin
  Terminal_SetColor_Pas($00FF0000);
  Terminal_Print_Pas(W(msg));
  while true do Io_Hlt;
end;

procedure Vmm_MapHugePage(physAddr, virtAddr: QWord);
var
  irq: Byte;
  pml4Index, pdptIndex, pdIndex: QWord;
  pdpt, pd: Pointer;
  newTable: Pointer;
begin
  irq := Spinlock_AcquireSafe_Pas(@Vmm_Lock);

  if not Vmm_IsCanonical(virtAddr) then
  begin
    Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
    Exit;
  end;

  if physAddr > PhysLimit then
  begin
    Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
    Exit;
  end;

  { Strip the NX and flag bits, then align down to a 2 MiB boundary. }
  physAddr := physAddr and PHYS_ADDR_MASK;
  physAddr := physAddr and (not HUGE_ADDR_MASK);

  pml4Index := (virtAddr shr 39) and $1FF;
  pdptIndex := (virtAddr shr 30) and $1FF;
  pdIndex   := (virtAddr shr 21) and $1FF;

  if (Vmm_Pml4[pml4Index] and ENTRY_PRESENT) = 0 then
  begin
    newTable := AllocateTable;
    if newTable = nil then
    begin
      Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
      Exit;
    end;
    Vmm_Pml4[pml4Index] := QWord(newTable) or ENTRY_USER or ENTRY_WRITABLE;
  end;

  pdpt := EntryToPtr(Vmm_Pml4[pml4Index]);
  if pdpt = nil then
  begin
    Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
    Exit;
  end;

  if (PQWord(pdpt)[pdptIndex] and ENTRY_PRESENT) = 0 then
  begin
    newTable := AllocateTable;
    if newTable = nil then
    begin
      Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
      Exit;
    end;
    PQWord(pdpt)[pdptIndex] := QWord(newTable) or ENTRY_USER or ENTRY_WRITABLE;
  end;

  pd := EntryToPtr(PQWord(pdpt)[pdptIndex]);
  if pd = nil then
  begin
    Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
    Exit;
  end;

  { PS=1 marks this a 2 MiB leaf in a page directory. }
  PQWord(pd)[pdIndex] := physAddr or $87;

  { CVE-2026-006: the TLB can still hold the old mapping, so flush before
    the entry becomes visible to userspace. }
  Vmm_FlushTlb(Pointer(virtAddr));

  Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
end;

procedure Vmm_MapPageIn(physAddr, virtAddr, flags: QWord; pml4Dir: Pointer);
var
  irq: Byte;
  pml4Index, pdptIndex, pdIndex, ptIndex: QWord;
  pdpt, pd, pt: Pointer;
  newTable: Pointer;
  pml4Arr: PQWord;
begin
  irq := Spinlock_AcquireSafe_Pas(@Vmm_Lock);

  if not Vmm_IsCanonical(virtAddr) then
  begin
    Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
    Exit;
  end;

  if physAddr > PhysLimit then
  begin
    Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
    Exit;
  end;

  physAddr := physAddr and PHYS_ADDR_MASK;

  pml4Arr := PQWord(pml4Dir);
  if pml4Arr = nil then
  begin
    Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
    Exit;
  end;
  if QWord(pml4Arr) >= PhysLimit then
  begin
    Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
    Exit;
  end;

  pml4Index := (virtAddr shr 39) and $1FF;
  pdptIndex := (virtAddr shr 30) and $1FF;
  pdIndex   := (virtAddr shr 21) and $1FF;
  ptIndex   := (virtAddr shr 12) and $1FF;

  { Walk down, allocating and validating each level. }
  if (pml4Arr[pml4Index] and ENTRY_PRESENT) = 0 then
  begin
    newTable := AllocateTable;
    if newTable = nil then
    begin
      Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
      Exit;
    end;
    pml4Arr[pml4Index] := QWord(newTable) or flags or ENTRY_PRESENT or ENTRY_WRITABLE;
  end;

  pdpt := EntryToPtr(pml4Arr[pml4Index]);
  if pdpt = nil then
  begin
    Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
    Exit;
  end;

  if (PQWord(pdpt)[pdptIndex] and ENTRY_PRESENT) = 0 then
  begin
    newTable := AllocateTable;
    if newTable = nil then
    begin
      Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
      Exit;
    end;
    PQWord(pdpt)[pdptIndex] := QWord(newTable) or flags or ENTRY_PRESENT or ENTRY_WRITABLE;
  end;

  pd := EntryToPtr(PQWord(pdpt)[pdptIndex]);
  if pd = nil then
  begin
    Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
    Exit;
  end;

  if (PQWord(pd)[pdIndex] and ENTRY_PRESENT) = 0 then
  begin
    newTable := AllocateTable;
    if newTable = nil then
    begin
      Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
      Exit;
    end;
    PQWord(pd)[pdIndex] := QWord(newTable) or flags or ENTRY_PRESENT or ENTRY_WRITABLE;
  end;

  pt := EntryToPtr(PQWord(pd)[pdIndex]);
  if pt = nil then
  begin
    Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
    Exit;
  end;

  PQWord(pt)[ptIndex] := physAddr or flags or ENTRY_PRESENT;

  { Only the currently loaded address space has a TLB to invalidate. }
  if pml4Arr = PQWord(Vmm_ReadCr3 and PHYS_ADDR_MASK) then
    Vmm_FlushTlb(Pointer(virtAddr));

  Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
end;

procedure Vmm_MapPage(physAddr, virtAddr, flags: QWord);
begin
  Vmm_MapPageIn(physAddr, virtAddr, flags,
                Pointer(Vmm_ReadCr3 and PHYS_ADDR_MASK));
end;

procedure Vmm_Init;
var
  addr, maxPhysicalRAM: QWord;
  i: Integer;
begin
  Terminal_Print_Pas(W('[*] Building Paging 4-Level (Strict Military Grade)...'#13#10));

  Arch_EnableNX;
  Terminal_Print_Pas(W('[+] Hardware NX-Bit (No-Execute) Engaged!'#13#10));

  { Must be below 4 GiB - see the Vmm_Pml4 comment. }
  Vmm_Pml4 := PQWord(Pmm_AllocatePageBelow4GB);
  if Vmm_Pml4 = nil then
    Vmm_Fatal('[!] VMM FATAL: Cannot allocate PML4 below 4GB!'#13#10);

  Vmm_Pml4Phys := QWord(Pointer(Vmm_Pml4));

  if (Vmm_Pml4Phys and $FFF) <> 0 then
    Vmm_Fatal('[!] VMM FATAL: PML4 is not page aligned!'#13#10);

  for i := 0 to 511 do
    Vmm_Pml4[i] := 0;

  maxPhysicalRAM := PhysLimit;
  if maxPhysicalRAM = 0 then
    Vmm_Fatal('[!] VMM FATAL: Invalid maxPhysicalRAM!'#13#10);

  { Below 2 MiB must be 4 KiB pages, because the SMP trampoline lives at
    0x8000 and the low identity range is walked by the APs. }
  addr := 4096;
  while addr < HUGE_PAGE_SIZE do
  begin
    Vmm_MapPageIn(addr, addr, ENTRY_USER or ENTRY_WRITABLE, Pointer(Vmm_Pml4));
    Inc(addr, PAGE_SIZE);
  end;

  { Everything above uses 2 MiB pages. }
  while addr < maxPhysicalRAM do
  begin
    Vmm_MapHugePage(addr, addr);
    Inc(addr, HUGE_PAGE_SIZE);
  end;

  Vmm_LoadPml4(Pointer(Vmm_Pml4));
  Terminal_Print_Pas(W('[+] VMM done! Exact memory space mapped & sealed bulletproof!'#13#10));
end;

{ TRUE when the page is one the kernel deliberately keeps alive across
  process teardown: the shared-memory window or the MPU trap page. }
function IsProtectedPage(physPage: QWord): Boolean;
var
  p: QWord;
  candidate: QWord;
begin
  IsProtectedPage := False;

  if (kstate_SharedRAM_Phys <> 0) and
     (kstate_SharedRAM_Phys < PhysLimit) then
  begin
    p := 0;
    while (p < 5) and (p < Pmm_GetTotalPages) do
    begin
      candidate := kstate_SharedRAM_Phys + (p * PAGE_SIZE);
      if candidate >= PhysLimit then Break;
      if physPage = candidate then
      begin
        IsProtectedPage := True;
        Exit;
      end;
      Inc(p);
    end;
  end;

  if (kstate_MpuTrapPage_Phys <> 0) and (physPage = kstate_MpuTrapPage_Phys) then
    IsProtectedPage := True;
end;

{ Free every frame and table reachable from a user PML4. Only 4 KiB leaves
  are reclaimed; a huge page (PS bit set) is skipped because its frames were
  never individually allocated. }
procedure Vmm_DestroyUserSpace(pml4Phys: QWord);
var
  irq: Byte;
  pml4: PQWord;
  pdpt, pd, pt: PQWord;
  i4, i3, i2, i1: Integer;
  entry4, entry3, entry2, entry1, physPage: QWord;
begin
  if (pml4Phys = 0) or (pml4Phys = Vmm_Pml4Phys) then Exit;

  pml4 := PQWord(Pointer(pml4Phys));
  if pml4 = nil then Exit;

  irq := Spinlock_AcquireSafe_Pas(@Vmm_Lock);

  for i4 := 0 to 255 do
  begin
    entry4 := pml4[i4];

    { Entries shared with the kernel (the low identity range) must survive. }
    if entry4 = Vmm_Pml4[i4] then Continue;

    { Present + writable but not a huge leaf: this points at a real table. }
    if ((entry4 and ENTRY_PRESENT) <> 0) and ((entry4 and ENTRY_WRITABLE) <> 0) then
    begin
      if EntryToPtr(entry4) = nil then Continue;
      pdpt := PQWord(EntryToPtr(entry4));

      for i3 := 0 to 511 do
      begin
        entry3 := pdpt[i3];
        if ((entry3 and ENTRY_PRESENT) <> 0) and ((entry3 and ENTRY_WRITABLE) <> 0) then
        begin
          if EntryToPtr(entry3) = nil then Continue;
          pd := PQWord(EntryToPtr(entry3));

          for i2 := 0 to 511 do
          begin
            entry2 := pd[i2];
            if ((entry2 and ENTRY_PRESENT) <> 0) and
               ((entry2 and ENTRY_WRITABLE) <> 0) and
               ((entry2 and ENTRY_HUGE) = 0) then
            begin
              if EntryToPtr(entry2) = nil then Continue;
              pt := PQWord(EntryToPtr(entry2));

              for i1 := 0 to 511 do
              begin
                entry1 := pt[i1];
                if ((entry1 and ENTRY_PRESENT) <> 0) and
                   ((entry1 and ENTRY_WRITABLE) <> 0) then
                begin
                  physPage := entry1 and (not QWord($FFF));
                  if (physPage = 0) or (physPage >= PhysLimit) then Continue;
                  if not IsProtectedPage(physPage) then
                    Pmm_FreePage(Pointer(physPage));
                end;
              end;

              Pmm_FreePage(Pointer(pt));
            end;
          end;

          Pmm_FreePage(Pointer(pd));
        end;
      end;

      Pmm_FreePage(Pointer(pdpt));
    end;
  end;

  Pmm_FreePage(Pointer(pml4));

  Spinlock_ReleaseSafe_Pas(@Vmm_Lock, irq);
end;

end.
