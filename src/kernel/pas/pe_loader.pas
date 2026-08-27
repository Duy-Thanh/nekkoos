{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: PELoader - Portable Executable loader (Pascal Implementation)
  PURPOSE: Pure PE32+ header validation, section copying, relocation
           processing, and export-directory scanning. All architecture-
           independent logic — kernel infrastructure (PMM, Mem, Scheduler,
           Heap, Terminal) stays in the C# shim layer.

           Ported from src/kernel/PELoader.cs. Uses raw byte-level pointer
           access (no record types) to avoid RTTI generation.
  =========================================================================
}

unit pe_loader;

{$mode objfpc}
{$h+}
{$inline on}

interface

{ [VALIDATE] Checks MZ/PE signature, extracts SizeOfImage and SizeOfHeaders.
  Returns: 1 = valid PE, 0 = invalid signature, 2 = SizeOfImage too large }
function PELoader_ValidateHeaders_Pas(rawFile: Pointer; rawSize: UInt64; out sizeOfImage: UInt32; out sizeOfHeaders: UInt32; out numSections: Word; out optHeaderSize: Word): Byte; cdecl; public name 'PELoader_ValidateHeaders_Pas';

{ [COPY] Copies each section's raw data from rawFile to appBasePhys.
  Returns: 0 = success, 1 = section exceeds image bounds }
function PELoader_CopySections_Pas(appBasePhys: Pointer; rawFile: Pointer; sizeOfImage: UInt32; numSections: Word; optHeaderSize: Word; ntHeader: Pointer): Byte; cdecl; public name 'PELoader_CopySections_Pas';

{ [RELOC] Applies base relocations when the image is loaded at a non-
  preferred base address. Scans relocation blocks of type 0xA (DIR64).
  Returns: 0 = success }
function PELoader_ApplyRelocations_Pas(appBasePhys: Pointer; sizeOfImage: UInt32; relocRVA: UInt32; relocSize: UInt32; delta: Int64): Byte; cdecl; public name 'PELoader_ApplyRelocations_Pas';

{ [EXPORTS] Scans export directory for an entry named "AppMain".
  Returns: 1 = found (addressOfEntryPoint set), 0 = not found }
function PELoader_FindAppMainExport_Pas(appBasePhys: Pointer; sizeOfImage: UInt32; exportRVA: UInt32; exportSize: UInt32; out addressOfEntryPoint: UInt32): Byte; cdecl; public name 'PELoader_FindAppMainExport_Pas';

implementation

uses fpc_runtime;

{ ========================================================================
  [VALIDATE] — validates PE header and extracts key fields
  ======================================================================== }
function PELoader_ValidateHeaders_Pas(rawFile: Pointer; rawSize: UInt64; out sizeOfImage: UInt32; out sizeOfHeaders: UInt32; out numSections: Word; out optHeaderSize: Word): Byte; cdecl;
var
  e_lfanew: UInt32;
  ntHeader: Pointer;
begin
  sizeOfImage := 0;
  sizeOfHeaders := 0;
  numSections := 0;
  optHeaderSize := 0;

  if rawFile = nil then
  begin
    PELoader_ValidateHeaders_Pas := 0;
    Exit;
  end;

  { Check DOS magic "MZ" = 0x5A4D }
  if PWord(UInt64(rawFile) + 0)^ <> IMAGE_DOS_SIGNATURE then
  begin
    PELoader_ValidateHeaders_Pas := 0;
    Exit;
  end;

  { Read e_lfanew (offset 0x3C in DOS header) }
  e_lfanew := PCardinal(UInt64(rawFile) + OFFSET_E_LFANEW)^;
  ntHeader := Pointer(UInt64(rawFile) + e_lfanew);

  { Check PE signature "PE\0\0" = 0x00004550 }
  if PWord(ntHeader)^ <> IMAGE_NT_SIGNATURE then
  begin
    PELoader_ValidateHeaders_Pas := 0;
    Exit;
  end;

  { Read numSections (Word at ntHeader+6) }
  numSections := PWord(UInt64(ntHeader) + NT_NUM_SECTIONS_OFFSET)^;
  { Read optHeaderSize (Word at ntHeader+20) }
  optHeaderSize := PWord(UInt64(ntHeader) + NT_OPT_HEADER_SIZE_OFFSET)^;

  { Read SizeOfImage (Cardinal at ntHeader+24+56) }
  sizeOfImage := PCardinal(UInt64(ntHeader) + NT_OPT_HEADER_OFFSET + OPT64_SIZE_OF_IMAGE)^;
  { Read SizeOfHeaders (Cardinal at ntHeader+24+60) }
  sizeOfHeaders := PCardinal(UInt64(ntHeader) + NT_OPT_HEADER_OFFSET + OPT64_SIZE_OF_HEADERS)^;

  { Security: reject images larger than 512MB }
  if (sizeOfImage = 0) or (UInt64(sizeOfImage) > MAX_PE_PAGES * 4096) then
  begin
    PELoader_ValidateHeaders_Pas := 2;
    Exit;
  end;

  { Validate section count }
  if numSections > MAX_PE_SECTIONS then
  begin
    PELoader_ValidateHeaders_Pas := 0;
    Exit;
  end;

  { Validate optional header size }
  if (optHeaderSize = 0) or (optHeaderSize > 1024) then
  begin
    PELoader_ValidateHeaders_Pas := 0;
    Exit;
  end;

  PELoader_ValidateHeaders_Pas := 1;
end;

{ ========================================================================
  [COPY] — copies section data from raw PE file to loaded image
  ======================================================================== }
function PELoader_CopySections_Pas(appBasePhys: Pointer; rawFile: Pointer; sizeOfImage: UInt32; numSections: Word; optHeaderSize: Word; ntHeader: Pointer): Byte; cdecl;
var
  sectionTable: Pointer;
  i: Integer;
  vSize, rawSize, rawPtr, vAddr, copySize: UInt32;
  src, dst: PByte;
  j: UInt32;
begin
  if appBasePhys = nil then
  begin
    PELoader_CopySections_Pas := 1;
    Exit;
  end;

  { Section table starts at ntHeader + 24 (opt header offset) + optHeaderSize }
  sectionTable := Pointer(UInt64(ntHeader) + NT_OPT_HEADER_OFFSET + optHeaderSize);

  for i := 0 to Integer(numSections) - 1 do
  begin
    { Section header fields (40 bytes each):
      +0: Name (8 bytes)
      +8: VirtualSize (4)
      +12: VirtualAddress (4)
      +16: SizeOfRawData (4)
      +20: PointerToRawData (4)
    }
    vSize := PCardinal(UInt64(sectionTable) + UInt64(i) * SIZEOF_SECTION_HEADER + 8)^;
    vAddr := PCardinal(UInt64(sectionTable) + UInt64(i) * SIZEOF_SECTION_HEADER + 12)^;
    rawSize := PCardinal(UInt64(sectionTable) + UInt64(i) * SIZEOF_SECTION_HEADER + 16)^;
    rawPtr := PCardinal(UInt64(sectionTable) + UInt64(i) * SIZEOF_SECTION_HEADER + 20)^;

    copySize := rawSize;
    if copySize > vSize then
      copySize := vSize;

    { Check for section exceeding image bounds — return error }
    if (copySize > 0) and (UInt64(vAddr) + UInt64(copySize) > UInt64(sizeOfImage)) then
    begin
      PELoader_CopySections_Pas := 1;
      Exit;
    end;

    { Inline memcpy }
    if (copySize > 0) and (vAddr + copySize <= sizeOfImage) then
    begin
      src := PByte(UInt64(rawFile) + rawPtr);
      dst := PByte(UInt64(appBasePhys) + vAddr);
      for j := 0 to copySize - 1 do
      begin
        dst^ := src^;
        Inc(dst);
        Inc(src);
      end;
    end;
  end;

  PELoader_CopySections_Pas := 0;
end;

{ ========================================================================
  [RELOC] — applies base relocations for position-independent loading
  ======================================================================== }
function PELoader_ApplyRelocations_Pas(appBasePhys: Pointer; sizeOfImage: UInt32; relocRVA: UInt32; relocSize: UInt32; delta: Int64): Byte; cdecl;
var
  relocDir: Pointer;
  bytesParsed: UInt32;
  pageRva, blockSize, relocCount, i: UInt32;
  entries: PWord;
  entryType, offset: UInt32;
  targetPtr: PUInt64;
  entry: Word;
begin
  if (delta = 0) or (relocRVA = 0) or (appBasePhys = nil) then
  begin
    PELoader_ApplyRelocations_Pas := 0;
    Exit;
  end;

  { Bounds check relocation directory }
  if (relocRVA > sizeOfImage) or (relocSize > sizeOfImage) or
     (UInt64(relocRVA) + relocSize > UInt64(sizeOfImage)) then
  begin
    PELoader_ApplyRelocations_Pas := 0;
    Exit;
  end;

  relocDir := Pointer(UInt64(appBasePhys) + relocRVA);
  bytesParsed := 0;

  while bytesParsed < relocSize do
  begin
    pageRva := PCardinal(UInt64(relocDir) + bytesParsed)^;
    blockSize := PCardinal(UInt64(relocDir) + bytesParsed + 4)^;

    if (blockSize = 0) or (UInt64(blockSize) > UInt64(relocSize) - UInt64(bytesParsed)) then
      Break;

    { Number of relocation entries = (blockSize - 8) / 2 }
    relocCount := (blockSize - 8) div 2;
    entries := PWord(UInt64(relocDir) + bytesParsed + 8);

    { Bounds check for entries array }
    if UInt64(entries) + UInt64(relocCount) * 2 > UInt64(appBasePhys) + UInt64(sizeOfImage) then
      Break;

    for i := 0 to relocCount - 1 do
    begin
      entry := entries[i];
      entryType := entry shr 12;
      offset := entry and $FFF;

      { Type 0xA = DIR64: 8-byte pointer needs base delta applied }
      if entryType = REL_BASE_DIR64 then
      begin
        { Bounds check target pointer }
        if UInt64(pageRva) + UInt64(offset) + 8 <= UInt64(sizeOfImage) then
        begin
          targetPtr := PUInt64(UInt64(appBasePhys) + UInt64(pageRva) + UInt64(offset));
          targetPtr^ := targetPtr^ + UInt64(delta);
        end;
      end;
    end;

    Inc(bytesParsed, blockSize);
  end;

  PELoader_ApplyRelocations_Pas := 0;
end;

{ ========================================================================
  [EXPORTS] — scans export directory for an "AppMain" entry
  ======================================================================== }
function PELoader_FindAppMainExport_Pas(appBasePhys: Pointer; sizeOfImage: UInt32; exportRVA: UInt32; exportSize: UInt32; out addressOfEntryPoint: UInt32): Byte; cdecl;
var
  exportDir: Pointer;
  numberOfNames: UInt32;
  addrOfFuncsRva, addrOfNamesRva, addrOfNameOrdinalsRva: UInt32;
  addressOfFunctions: PCardinal;
  addressOfNames: PCardinal;
  addressOfNameOrdinals: PWord;
  i, nameRva: UInt32;
  name: PByte;
begin
  addressOfEntryPoint := 0;
  PELoader_FindAppMainExport_Pas := 0;

  if (exportRVA = 0) or (appBasePhys = nil) then
    Exit;

  { Bounds checks }
  if (exportRVA > sizeOfImage) or (UInt64(exportRVA) + exportSize > UInt64(sizeOfImage)) then
    Exit;

  exportDir := Pointer(UInt64(appBasePhys) + exportRVA);

  numberOfNames := PCardinal(UInt64(exportDir) + EXPORT_NUM_NAMES_OFFSET)^;
  addrOfFuncsRva := PCardinal(UInt64(exportDir) + EXPORT_ADDR_OF_FUNCS_OFFSET)^;
  addrOfNamesRva := PCardinal(UInt64(exportDir) + EXPORT_ADDR_OF_NAMES_OFFSET)^;
  addrOfNameOrdinalsRva := PCardinal(UInt64(exportDir) + EXPORT_ADDR_OF_ORDS_OFFSET)^;

  { Validate counts and RVAs }
  if (numberOfNames = 0) or (numberOfNames > 10000) then
    Exit;

  if (addrOfFuncsRva > sizeOfImage) or (addrOfNamesRva > sizeOfImage) or
     (addrOfNameOrdinalsRva > sizeOfImage) then
    Exit;

  { Validate array bounds }
  if (UInt64(addrOfFuncsRva) + UInt64(numberOfNames) * 4 > UInt64(sizeOfImage)) or
     (UInt64(addrOfNamesRva) + UInt64(numberOfNames) * 4 > UInt64(sizeOfImage)) or
     (UInt64(addrOfNameOrdinalsRva) + UInt64(numberOfNames) * 2 > UInt64(sizeOfImage)) then
    Exit;

  addressOfFunctions := PCardinal(UInt64(appBasePhys) + addrOfFuncsRva);
  addressOfNames := PCardinal(UInt64(appBasePhys) + addrOfNamesRva);
  addressOfNameOrdinals := PWord(UInt64(appBasePhys) + addrOfNameOrdinalsRva);

  for i := 0 to numberOfNames - 1 do
  begin
    nameRva := addressOfNames[i];

    if (nameRva >= sizeOfImage) or (UInt64(nameRva) + 8 > UInt64(sizeOfImage)) then
      Continue;

    name := PByte(UInt64(appBasePhys) + nameRva);

    { Check for "AppMain\0" }
    if (name[0] = Byte('A')) and (name[1] = Byte('p')) and
       (name[2] = Byte('p')) and (name[3] = Byte('M')) and
       (name[4] = Byte('a')) and (name[5] = Byte('i')) and
       (name[6] = Byte('n')) and (name[7] = Byte(0)) then
    begin
      addressOfEntryPoint := addressOfFunctions[addressOfNameOrdinals[i]];
      PELoader_FindAppMainExport_Pas := 1;
      Exit;
    end;
  end;
end;

end.
