{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: AcpiParse - ACPI table parsing (Pascal Implementation)
  PURPOSE: Pure logic for parsing MADT sub-tables and DSDT AML bytecode
           for \_S5_ object extraction. No I/O, no kernel infrastructure.

           Ported from src/apps/acpi.cs AppMain() — the ACPI table
           scanning loop and DSDT \_S5_ parsing block.
  =========================================================================
}

unit acpi_parse;

{$mode objfpc}
{$h+}
{$inline on}

interface

uses fpc_runtime;

{ [MADT] Scans MADT sub-table entries to count CPU cores and I/O APICs.
  Inputs:
    madtBase    — base address of mapped MADT table (including ACPISDTHeader)
    madtLength  — total size of MADT table (header.Length)
  Outputs:
    outCpuCores    — count of enabled processor entries (type 0, flags&1)
    outIoApicCount — count of I/O APIC entries (type 1)
  Returns: 1 = success, 0 = invalid input }
function ScanMadtEntries_Pas(madtBase: Pointer; madtLength: UInt32;
  out outCpuCores: UInt32; out outIoApicCount: UInt32): Byte; cdecl; public name 'ScanMadtEntries_Pas';

{ [ACPI] Parses DSDT AML bytecode to find \_S5_ object and extract
  SLP_TYPa/SLP_TYPb values for software sleep.
  Inputs:
    dsdtBase   — base address of mapped DSDT table (including ACPISDTHeader)
    dsdtLength — total Length field from ACPISDTHeader
  Outputs:
    outSlpTypA — SLP_TYPa value (shifted left by 10 bits)
    outSlpTypB — SLP_TYPb value (shifted left by 10 bits)
  Returns: 1 = S5 found and parsed, 0 = not found/invalid }
function ParseS5FromDsdt_Pas(dsdtBase: Pointer; dsdtLength: UInt32;
  out outSlpTypA: UInt16; out outSlpTypB: UInt16): Byte; cdecl; public name 'ParseS5FromDsdt_Pas';

implementation

{ MADT sub-table entry layout }
const
  MADT_HEADER_SIZE: Cardinal = 36; { sizeof(ACPISDTHeader) }
  MADT_LOCAL_APIC_ADDR_OFFSET: Cardinal = 36; { LocalApicAddress (4 bytes) }
  MADT_FLAGS_OFFSET: Cardinal = 40; { Flags (4 bytes) }
  MADT_ENTRY_START: Cardinal = 44; { first sub-table entry }

  MADT_TYPE_PROCESSOR: Byte = 0;
  MADT_TYPE_IOAPIC: Byte = 1;

  { MADT entry type 0 (Processor Local APIC): }
  { entry: Type(1) + Length(1) + ProcessorID(1) + ApicId(1) + Flags(4) }
  PROC_FLAGS_OFFSET: Cardinal = 4; { offset within the entry }

  { AML opcodes }
  AML_NAME_OP: Byte = $08; { NameOp }
  AML_PACKAGE_OP: Byte = $12; { Package operator }
  AML_BYTE_PREFIX: Byte = $0A; { Byte prefix }
  AML_ROOT_PREFIX: Byte = $5C; { '\' (backslash) }

function ScanMadtEntries_Pas(madtBase: Pointer; madtLength: UInt32;
  out outCpuCores: UInt32; out outIoApicCount: UInt32): Byte; cdecl;
var
  ptr: PByte;
  endPtr: PByte;
  entryType: Byte;
  entryLen: Byte;
  flags: UInt32;
begin
  outCpuCores := 0;
  outIoApicCount := 0;
  ScanMadtEntries_Pas := 0;

  if madtBase = nil then
    Exit;

  ptr := PByte(UInt64(madtBase) + MADT_ENTRY_START);
  endPtr := PByte(UInt64(madtBase) + madtLength);

  while UInt64(ptr) + 2 <= UInt64(endPtr) do
  begin
    entryType := ptr^;
    entryLen := (ptr + 1)^;

    { Prevent infinite loop on zero-length entry }
    if entryLen = 0 then
      Break;

    { Bounds check before accessing entry data }
    if UInt64(ptr) + entryLen > UInt64(endPtr) then
      Break;

    if entryType = MADT_TYPE_PROCESSOR then
    begin
      { Processor entry: type(1) + length(1) + ProcessorID(1) + ApicId(1) + Flags(4) }
      flags := PCardinal(UInt64(ptr) + PROC_FLAGS_OFFSET)^;
      if (flags and 1) <> 0 then
        Inc(outCpuCores);
    end
    else if entryType = MADT_TYPE_IOAPIC then
    begin
      Inc(outIoApicCount);
    end;

    Inc(ptr, entryLen);
  end;

  ScanMadtEntries_Pas := 1;
end;

function ParseS5FromDsdt_Pas(dsdtBase: Pointer; dsdtLength: UInt32;
  out outSlpTypA: UInt16; out outSlpTypB: UInt16): Byte; cdecl;
var
  s5Addr: PByte;
  dsdtContentLen: Int32;
  pkgLenBytes: Byte;
  val: Byte;
begin
  outSlpTypA := 0;
  outSlpTypB := 0;
  ParseS5FromDsdt_Pas := 0;

  if dsdtBase = nil then
    Exit;

  { Start scanning after ACPISDTHeader (36 bytes) }
  s5Addr := PByte(UInt64(dsdtBase) + 36);
  dsdtContentLen := Int32(dsdtLength) - 36;

  { Scan for "_S5_" pattern }
  while dsdtContentLen > 0 do
  begin
    if (s5Addr[0] = Byte('_')) and (s5Addr[1] = Byte('S')) and
       (s5Addr[2] = Byte('5')) and (s5Addr[3] = Byte('_')) then
    begin
      dec(dsdtContentLen, 4);
      Break;
    end;
    Inc(s5Addr);
    Dec(dsdtContentLen);
  end;

  if dsdtContentLen <= 0 then
    Exit;

  { Check pre-conditions before _S5_:
    Either: prev byte is 0x08 (NameOp)
    Or:     prev2 byte is 0x08 and prev byte is '\' (0x5C) }
  if not ((s5Addr[-1] = AML_NAME_OP) or
          ((s5Addr[-2] = AML_NAME_OP) and (s5Addr[-1] = AML_ROOT_PREFIX))) then
    Exit;

  { Also check that S5Addr[4] == 0x12 (PackageOp) }
  if s5Addr[4] <> AML_PACKAGE_OP then
    Exit;

  { S5Addr += 5: skip _S5_ (4 chars) + preceding byte (0x08 or \) }
  s5Addr += 5;

  { Decode AML package length: first byte & 0xC0 >> 6 = number of additional
    length bytes; +2 accounts for length byte itself + one data byte }
  pkgLenBytes := (s5Addr[0] and $C0) shr 6;
  s5Addr += pkgLenBytes + 2;

  { First value: skip Byte prefix (0x0A) if present, then read value }
  if s5Addr[0] = AML_BYTE_PREFIX then
    Inc(s5Addr);

  val := s5Addr[0];
  outSlpTypA := UInt16(val) shl 10;
  Inc(s5Addr);

  { Second value: same pattern }
  if s5Addr[0] = AML_BYTE_PREFIX then
    Inc(s5Addr);

  val := s5Addr[0];
  outSlpTypB := UInt16(val) shl 10;

  ParseS5FromDsdt_Pas := 1;
end;

end.
