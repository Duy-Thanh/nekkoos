{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: MemmapScan - EFI memory map analysis (Pascal Implementation)
  PURPOSE: Scans EFI_MEMORY_DESCRIPTOR array to compute:
    - totalPages: sum of all memory descriptor NumberOfPages
    - freePages: pages in EfiConventionalMemory (Type==7)
    - largestFreeStart: physical address of largest free region
    - largestFreePages: page count of largest free region
    - maxPhysicalAddr: highest physical address in memory map + framebuffer

  Pure logic — no I/O, no kernel infrastructure calls.
  Ported from Kernel.cs Phase 2 memory scanning (lines ~179-205).
  =========================================================================
}

unit memmap_scan;

{$mode objfpc}
{$h+}
{$inline on}

interface

uses fpc_runtime;

{ [SCAN] Walks EFI memory map, computes total/free pages and largest region.
  Returns: 1 = success, 0 = invalid input
  out params:
    outTotalPages      — total pages across all descriptors
    outFreePages       — free pages (Type==7 conventional memory)
    outLargestStart    — physical base of largest free region
    outLargestPages    — page count of largest free region
    outMaxPhysAddr     — highest physical address (rounded up to 2MB) }
function ScanMemmap_Pas(mapPtr: Pointer; numEntries: UInt64; descSize: UInt64;
  fbBase: UInt64; fbSize: UInt64;
  out outTotalPages: UInt64; out outFreePages: UInt64;
  out outLargestStart: UInt64; out outLargestPages: UInt64;
  out outMaxPhysAddr: UInt64): Byte; cdecl; public name 'ScanMemmap_Pas';

implementation

function ScanMemmap_Pas(mapPtr: Pointer; numEntries: UInt64; descSize: UInt64;
  fbBase: UInt64; fbSize: UInt64;
  out outTotalPages: UInt64; out outFreePages: UInt64;
  out outLargestStart: UInt64; out outLargestPages: UInt64;
  out outMaxPhysAddr: UInt64): Byte; cdecl;
var
  i: UInt64;
  desc: Pointer;
  memType: Cardinal;
  physStart: UInt64;
  numPages: UInt64;
  endAddr: UInt64;
begin
  outTotalPages := 0;
  outFreePages := 0;
  outLargestStart := 0;
  outLargestPages := 0;
  outMaxPhysAddr := 0;

  if mapPtr = nil then
  begin
    ScanMemmap_Pas := 0;
    Exit;
  end;

  for i := 0 to numEntries - 1 do
  begin
    desc := Pointer(UInt64(mapPtr) + i * descSize);
    memType := PCardinal(UInt64(desc) + EFI_DESC_TYPE_OFFSET)^;
    physStart := PUInt64(UInt64(desc) + EFI_PHYS_START_OFFSET)^;
    numPages := PUInt64(UInt64(desc) + EFI_NUM_PAGES_OFFSET)^;

    outTotalPages += numPages;

    endAddr := physStart + numPages * PAGE_SIZE;
    if endAddr > outMaxPhysAddr then
      outMaxPhysAddr := endAddr;

    { Type 7 = EfiConventionalMemory — free RAM available for allocation }
    if memType = EFI_MEM_TYPE_CONVENTIONAL then
    begin
      outFreePages += numPages;
      if numPages > outLargestPages then
      begin
        outLargestPages := numPages;
        outLargestStart := physStart;
      end;
    end;
  end;

  { Account for framebuffer as a physical memory consumer }
  if fbSize > 0 then
  begin
    endAddr := fbBase + fbSize;
    if endAddr > outMaxPhysAddr then
      outMaxPhysAddr := endAddr;
  end;

  { Extend to 4GB boundary + round up to 2MB }
  outMaxPhysAddr += UInt64($100000000);
  outMaxPhysAddr := (outMaxPhysAddr + 2097151) and not UInt64(2097151);

  ScanMemmap_Pas := 1;
end;

end.
