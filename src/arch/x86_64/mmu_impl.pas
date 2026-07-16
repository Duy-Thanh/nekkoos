unit mmu_impl;

{ x86_64 Implementation of HAL MMU/Paging Interface

  Implements low-level MMU control for x86_64:
  - CR3 register management (Load/Read page table)
  - CR2 register reading (Page fault virtual address)
  - TLB invalidation (INVLPG, CR3 reload)
  - NX (No-Execute) hardware enablement

  This provides the implementation for the HAL MMU interface
  documented in src/arch/hal/mmu.pas }

{$MODE FPC}
{$ASMMODE Intel}
{$M-}

interface

procedure HAL_InitMMU; cdecl; public name 'HAL_InitMMU';
function  HAL_GetPhysicalAddressMask: QWord; cdecl; public name 'HAL_GetPhysicalAddressMask';
procedure HAL_LoadPageTable(pageTable: Pointer); cdecl; public name 'HAL_LoadPageTable';
function  HAL_GetCurrentPageTable: Pointer; cdecl; public name 'HAL_GetCurrentPageTable';
procedure HAL_FlushTLB; cdecl; public name 'HAL_FlushTLB';
procedure HAL_FlushTLBAddress(virtualAddr: QWord); cdecl; public name 'HAL_FlushTLBAddress';
function  HAL_GetFaultAddress: QWord; cdecl; public name 'HAL_GetFaultAddress';

implementation

{ AAL Layer 1 primitives from Hardware.asm }
procedure Arch_EnableNX; cdecl; external name 'Arch_EnableNX';
procedure Arch_LoadPageTable(physAddr: QWord); cdecl; external name 'Arch_LoadPageTable';
function  Arch_ReadPageTable: QWord; cdecl; external name 'Arch_ReadPageTable';
procedure Arch_FlushTLB(addr: QWord); cdecl; external name 'Arch_FlushTLB';
function  Arch_GetFaultAddress: QWord; cdecl; external name 'Arch_GetFaultAddress';

const
  PHYS_ADDR_MASK = $000FFFFFFFFFF000;

procedure HAL_InitMMU; cdecl;
begin
  Arch_EnableNX();
end;

function HAL_GetPhysicalAddressMask: QWord; cdecl;
begin
  HAL_GetPhysicalAddressMask := PHYS_ADDR_MASK;
end;

procedure HAL_LoadPageTable(pageTable: Pointer); cdecl;
begin
  Arch_LoadPageTable(QWord(pageTable));
end;

function HAL_GetCurrentPageTable: Pointer; cdecl;
begin
  HAL_GetCurrentPageTable := Pointer(Arch_ReadPageTable() and PHYS_ADDR_MASK);
end;

procedure HAL_FlushTLB; cdecl;
begin
  { Reloading CR3 flushes all non-global TLB entries on x86_64 }
  Arch_LoadPageTable(Arch_ReadPageTable());
end;

procedure HAL_FlushTLBAddress(virtualAddr: QWord); cdecl;
begin
  Arch_FlushTLB(virtualAddr);
end;

function HAL_GetFaultAddress: QWord; cdecl;
begin
  HAL_GetFaultAddress := Arch_GetFaultAddress();
end;

end.
