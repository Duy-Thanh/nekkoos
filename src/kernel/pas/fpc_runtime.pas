{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: FPC Runtime - Platform-Neutral Type Definitions & Constants
  PURPOSE: Central type aliases (Win64 calling-convention compatible), PE/
           FAT16 magic constants, and shared structures used across all
           Pascal protocol modules. Prevents duplicate definitions and
           ensures ABI consistency when porting new modules.
  =========================================================================
}

unit fpc_runtime;

{$mode objfpc}
{$h+}
{$inline on}
{$packrecords c}

interface

{ ========================================================================
  TYPE ALIASES — match C# unsafe pointer types for Win64 interop.
  These MUST align with the field order/types seen in C# structs.
  ======================================================================== }
type
  PByte       = ^Byte;
  PWord       = ^Word;
  PCardinal   = ^Cardinal;
  PUInt64     = ^UInt64;
  PInt        = ^Integer;
  PUInt       = ^UInt32;
  Ptr         = Pointer;

  { Raw byte pointer (used for buffers/sector data) }
  BufPtr      = Pointer;

{ ========================================================================
  PE / BINKW CONSTANTS — used by pe_loader.pas for validation
  ======================================================================== }
const
  { PE signature: "PE\0\0" }
  IMAGE_NT_SIGNATURE: Cardinal = $00004550;
  { DOS magic: "MZ" }
  IMAGE_DOS_SIGNATURE: Word  = $5A4D;

  { Optional-header magic for PE32+ (64-bit) }
  IMAGE_NT_OPTIONAL_HDR64_MAGIC: Word = $020B;

  { SizeOf optional header: PE32+ = 224 bytes (0xE0) }
  SIZEOF_OPT_HEADER64: Cardinal = 224;

  { Export directory entry in optional header data-dirs: index 0 }
  EXPORT_TABLE_INDEX: Cardinal = 0;
  { Base reloca entry in optional header data-dirs: index 5 }
  BASERELOC_TABLE_INDEX: Cardinal = 5;

  { NT header offsets (relative to start of NT headers) }
  NT_SIG_OFFSET: Cardinal = 0;
  NT_NUM_SECTIONS_OFFSET: Cardinal = 6;
  NT_OPT_HEADER_SIZE_OFFSET: Cardinal = 20;
  NT_OPT_HEADER_OFFSET: Cardinal = 24;

  { Optional header64 offsets (relative to optional header start) }
  OPT64_MAGIC_OFFSET: Cardinal = 0;
  OPT64_ENTRY_POINT_RVA_OFFSET: Cardinal = 20;
  OPT64_IMAGE_BASE_OFFSET: Cardinal = 24;
  OPT64_SIZE_OF_IMAGE_OFFSET: Cardinal = 24 + 4; { 0x38 }
  OPT64_SIZE_OF_HEADERS_OFFSET: Cardinal = 24 + 8;
  OPT64_DATA_DIRS_OFFSET: Cardinal = 108; { 0x6C — after Standard + NT-specific fields }

  { Data-directory entry size }
  DATA_DIR_ENTRY_SIZE: Cardinal = 8; { each entry: RVA (4 bytes) + Size (4 bytes) }

  { Section header: 40 bytes each }
  SIZEOF_SECTION_HEADER: Cardinal = 40;

  { Relocation types }
  REL_BASE_DST: Word = $0000;
  REL_BASE_HIGH: Word = $0001;
  REL_BASE_HIGHADJ: Word = $0002;
  REL_BASE_HIGHLO: Word = $0003;
  REL_BASE_DIR64: Word = $0000000A;

  { KASLR magic signature used for bootstrap injection }
  KASLR_MAGIC_SIGNATURE: UInt64 = $1337BEEFCAFE8BAD;

  { Security limits }
  MAX_PE_SECTIONS: Cardinal = 96;
  MAX_PE_PAGES: UInt64 = 131072; { 512 MB }

{ ========================================================================
  STRUCTURES — packed records mirroring C# structs (Pack=1)
  ======================================================================== }
type
  { IMAGE_DOS_HEADER (simplified — only the fields we need) }
  PEDosHeader = packed record
    e_magic: Word;            { 0x00: "MZ" }
    e_cblp: Word;             { 0x02 }
    e_cp: Word;               { 0x04 }
    e_crlc: Word;             { 0x06 }
    e_cparhdr: Word;          { 0x08 }
    e_minalloc: Word;         { 0x0A }
    e_maxalloc: Word;         { 0x0C }
    e_ss: Word;               { 0x0E }
    e_sp: Word;               { 0x10 }
    e_csum: Word;             { 0x12 }
    e_ip: Word;               { 0x14 }
    e_cs: Word;               { 0x16 }
    e_lfarlc: Word;           { 0x18 }
    e_ovno: Word;             { 0x1A }
    e_res1: array[0..7] of Word;  { 0x1C-0x2C }
    e_oemid: Word;            { 0x2E }
    e_oeminfo: Word;          { 0x30 }
    e_res2: array[0..9] of Word;  { 0x32-0x49 }
    e_lfanew: Integer;        { 0x3C: file offset to PE header }
  end;

  { IMAGE_FILE_HEADER }
  PEFileHeader = packed record
    Machine: Word;            { 0x00 }
    NumberOfSections: Word;   { 0x02 }
    TimeDateStamp: Cardinal;  { 0x04 }
    PointerToSymbolTable: Cardinal; { 0x08 }
    NumberOfSymbols: Cardinal; { 0x0C }
    SizeOfOptionalHeader: Word; { 0x10 }
    Characteristics: Word;    { 0x12 }
  end;

  { IMAGE_OPTIONAL_HEADER64 }
  PEOptHeader64 = packed record
    Magic: Word;              { 0x00: 0x020B for PE32+ }
    MajorLinkerVersion: Byte;  { 0x02 }
    MinorLinkerVersion: Byte;  { 0x03 }
    SizeOfCode: Cardinal;     { 0x04 }
    SizeOfInitializedData: Cardinal; { 0x08 }
    SizeOfUninitializedData: Cardinal; { 0x0C }
    AddressOfEntryPoint: Cardinal; { 0x10 }
    BaseOfCode: Cardinal;     { 0x14 }
    ImageBase: UInt64;        { 0x18: 8 bytes (0x24 after start) }
    SizeOfImage: Cardinal;    { 0x28 }
    SizeOfHeaders: Cardinal;  { 0x2C }
    CheckSum: Cardinal;       { 0x30 }
    Subsystem: Word;          { 0x34 }
    DllCharacteristics: Word; { 0x36 }
    SizeOfStackReserve: UInt64; { 0x38 }
    SizeOfStackCommit: UInt64;  { 0x40 }
    SizeOfHeapReserve: UInt64;  { 0x48 }
    SizeOfHeapCommit: UInt64;    { 0x50 }
    LoaderFlags: Cardinal;    { 0x58 }
    NumberOfRvaAndDirs: Cardinal; { 0x5C }
    { Data directories follow — array of 8-byte entries }
  end;
  PEOptHeader64Ptr = ^PEOptHeader64;

  { IMAGE_DATA_DIRECTORY }
  PEDataDirectory = packed record
    VirtualAddress: Cardinal; { RVA }
    Size: Cardinal;
  end;

  { IMAGE_SECTION_HEADER }
  PESectionHeader = packed record
    Name: array[0..7] of Byte; { 0x00-0x07: 8-byte section name }
    VirtualSize: Cardinal;     { 0x08 }
    VirtualAddress: Cardinal;  { 0x0C }
    SizeOfRawData: Cardinal;   { 0x10 }
    PointerToRawData: Cardinal; { 0x14 }
    PointerToRelocations: Cardinal; { 0x18 }
    PointerToLinenumbers: Cardinal; { 0x1C }
    NumberOfRelocations: Word;  { 0x20 }
    NumberOfLinenumbers: Word;  { 0x22 }
    Characteristics: Cardinal;  { 0x24 }
  end;
  PESectionHeaderPtr = ^PESectionHeader;

  { IMAGE_EXPORT_DIRECTORY }
  PEExportDirectory = packed record
    Characteristics: Cardinal; { 0x00 }
    TimeDateStamp: Cardinal;   { 0x04 }
    MajorVersion: Word;        { 0x08 }
    MinorVersion: Word;        { 0x0A }
    Name: Cardinal;            { 0x0C: RVA to ASCII name }
    Base: Cardinal;            { 0x10 }
    NumberOfFunctions: Cardinal; { 0x14 }
    NumberOfNames: Cardinal;  { 0x18 }
    AddressOfFunctions: Cardinal; { 0x1C: RVA to EAT }
    AddressOfNames: Cardinal;  { 0x20: RVA to name pointer table }
    AddressOfNameOrdinals: Cardinal; { 0x24: RVA to ordinal table }
  end;
  PEExportDirectoryPtr = ^PEExportDirectory;

  { BASE RELOCATION BLOCK header }
  PERelocBlockHeader = packed record
    VirtualPageRVA: Cardinal;  { 0x00 }
    SizeOfBlock: Cardinal;     { 0x04: including this header }
  end;

implementation

end.
