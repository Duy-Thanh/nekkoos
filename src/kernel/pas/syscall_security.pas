{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: SyscallSecurity - User pointer validation logic (Pascal Implementation)
  PURPOSE: Pure logic for validating user-space pointers before Ring0
           dereference. Walks PML4/PDPT/PD/PT page tables to verify that
           a virtual address is mapped WITH Present + User bits set.

           Ported from Syscall.cs IsPageMappedForUser() and IsValidUserPtr().
           This prevents a user-space process from triggering #GP or
           page faults in Ring 0 via unmapped but canonical pointers.

           Kernel infrastructure (Scheduler.Threads, PMM.TotalPages,
           Arch.ReadPageTable) stays in the C# shim layer.
  =========================================================================
}

unit syscall_security;

{$mode objfpc}
{$h+}
{$inline on}

interface

{ [SECURITY] Validates that a user-space virtual address is safe for the
  kernel to dereference. Checks canonical range + page-table mapping
  with Present (bit 0) and User (bit 2) bits.

  Inputs:
    threadId    — scheduler thread index to look up address space
    virtAddr    — virtual address to validate
    pml4Phys    — physical address of the thread's PML4 table (passed from C#)
    totalPages  — total physical pages (from PMM) for bounds check
  Returns: 1 = valid mapped user page, 0 = invalid/unmapped }

function IsValidUserPtr_Pas(threadId: Int32; virtAddr: UInt64; pml4Phys: UInt64; totalPages: UInt64): Byte; cdecl; public name 'IsValidUserPtr_Pas';

implementation

{ Standard x86-64 canonical address masks }
const
  PHYS_ADDR_MASK: UInt64 = $000FFFFFFFFFF000;
  USER_VIRT_MAX: UInt64 = $00007FFFFFFFFFFF;

function IsValidUserPtr_Pas(threadId: Int32; virtAddr: UInt64; pml4Phys: UInt64; totalPages: UInt64): Byte; cdecl;
var
  pml4: PUInt64;
  pml4Index, pdptIndex, pdIndex, ptIndex: UInt64;
  e4, e3, e2, e1: UInt64;
  pdpt, pd, pt: PUInt64;
begin
  { Bounds check: canonical user range }
  if (threadId < 0) or (virtAddr < $1000) or (virtAddr > USER_VIRT_MAX) then
  begin
    IsValidUserPtr_Pas := 0;
    Exit;
  end;

  { Validate PML4 physical address }
  if (pml4Phys = 0) or (pml4Phys >= totalPages * 4096) then
  begin
    IsValidUserPtr_Pas := 0;
    Exit;
  end;

  pml4 := PUInt64(pml4Phys);

  { Extract page-table indices from the virtual address }
  pml4Index := (virtAddr >> 39) and $1FF;
  pdptIndex := (virtAddr >> 30) and $1FF;
  pdIndex   := (virtAddr >> 21) and $1FF;
  ptIndex   := (virtAddr >> 12) and $1FF;

  { Level 4: PML4 }
  e4 := pml4[pml4Index];
  if ((e4 and 1) = 0) or ((e4 and 4) = 0) then
  begin
    IsValidUserPtr_Pas := 0;
    Exit;
  end;

  { Level 3: PDPT }
  pdpt := PUInt64(e4 and PHYS_ADDR_MASK);
  if (UInt64(pdpt) = 0) or (UInt64(pdpt) >= totalPages * 4096) then
  begin
    IsValidUserPtr_Pas := 0;
    Exit;
  end;

  e3 := pdpt[pdptIndex];
  if ((e3 and 1) = 0) or ((e3 and 4) = 0) then
  begin
    IsValidUserPtr_Pas := 0;
    Exit;
  end;

  { Level 2: PD }
  pd := PUInt64(e3 and PHYS_ADDR_MASK);
  if (UInt64(pd) = 0) or (UInt64(pd) >= totalPages * 4096) then
  begin
    IsValidUserPtr_Pas := 0;
    Exit;
  end;

  e2 := pd[pdIndex];
  if ((e2 and 1) = 0) or ((e2 and 4) = 0) then
  begin
    IsValidUserPtr_Pas := 0;
    Exit;
  end;

  { Check for 2MB huge page — if set, page is mapped at PD level }
  if (e2 and $80) <> 0 then
  begin
    IsValidUserPtr_Pas := 1;
    Exit;
  end;

  { Level 1: PT }
  pt := PUInt64(e2 and PHYS_ADDR_MASK);
  if (UInt64(pt) = 0) or (UInt64(pt) >= totalPages * 4096) then
  begin
    IsValidUserPtr_Pas := 0;
    Exit;
  end;

  e1 := pt[ptIndex];
  if ((e1 and 1) = 0) or ((e1 and 4) = 0) then
  begin
    IsValidUserPtr_Pas := 0;
    Exit;
  end;

  IsValidUserPtr_Pas := 1;
end;

end.
