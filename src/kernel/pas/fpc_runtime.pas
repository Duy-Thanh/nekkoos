{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: FPC Runtime - Platform-Neutral Constants
  PURPOSE: PE/FAT16 magic constants and shared offset constants used across
           all Pascal protocol modules. Prevents duplicate definitions.

           NOTE: No record/struct types or custom type aliases are defined
           here — all existing Pascal modules use built-in FPC types (Pointer,
           PByte, PCardinal, UInt32, etc.) in their function signatures to
           avoid RTTI generation (lld cannot resolve FPC-generated $indirect
           typeinfo symbols). See src/kernel/pas/heap.pas for precedent.
  =========================================================================
}

unit fpc_runtime;

{$mode objfpc}
{$h+}
{$inline on}
{$packrecords c}
{$TYPEINFO OFF}

interface

{ ========================================================================
  PE CONSTANTS — used by pe_loader.pas for header parsing
  All offsets are relative to the NT headers start (PE signature position).
  ======================================================================== }
const
  { DOS header }
  IMAGE_DOS_SIGNATURE: Word = $5A4D; { "MZ" }
  OFFSET_E_LFANEW: Cardinal = $3C; { DOS header offset to PE header pointer }

  { NT headers }
  IMAGE_NT_SIGNATURE: Cardinal = $00004550; { "PE\0\0" }
  NT_PE_SIG_SIZE: Cardinal = 4;
  NT_NUM_SECTIONS_OFFSET: Cardinal = 6;  { COFF header +2 (after Machine) }
  NT_OPT_HEADER_SIZE_OFFSET: Cardinal = 20; { COFF header +16 }
  NT_OPT_HEADER_OFFSET: Cardinal = 24; { PE sig + COFF header = 4+20 }

  { Optional header64 field offsets (from opt header start) }
  OPT64_SIZE_OF_IMAGE: Cardinal = 56; { 0x38 }
  OPT64_SIZE_OF_HEADERS: Cardinal = 60; { 0x3C }

  { Data directory entry for export table: index 0 }
  { Data directory starts at optHeader+0x70 (112) }
  DATA_DIR_OFFSET: Cardinal = 112; { 0x70 }
  DATA_DIR_ENTRY_SIZE: Cardinal = 8; { RVA(4) + Size(4) }
  EXPORT_DIR_INDEX: Cardinal = 0;
  BASERELOC_DIR_INDEX: Cardinal = 5;

  { Section header constants }
  SIZEOF_SECTION_HEADER: Cardinal = 40;

  { Export directory field offsets (from export directory start) }
  EXPORT_NUM_NAMES_OFFSET: Cardinal = 24;
  EXPORT_ADDR_OF_FUNCS_OFFSET: Cardinal = 28;
  EXPORT_ADDR_OF_NAMES_OFFSET: Cardinal = 32;
  EXPORT_ADDR_OF_ORDS_OFFSET: Cardinal = 36;

  { Relocation types }
  REL_BASE_DIR64: Word = $000A;

  { Security limits }
  MAX_PE_SECTIONS: Cardinal = 96;
  MAX_PE_PAGES: UInt64 = 131072; { 512 MB }

  { KASLR magic signature }
  KASLR_MAGIC_SIGNATURE: UInt64 = $1337BEEFCAFE8BAD;

  { ========================================================================
    AML / ACPI CONSTANTS — used by acpi_parse.pas
    ======================================================================== }
  AML_NAME_PREFIX_LEN: Cardinal = 4; { signature is always 4 chars }
  MADT_HEADER_SIZE: Cardinal = 12; { ACPISDTHeader(36) + LocalApicAddress(4) + Flags(4) = wait... }

  { MADT sub-table types }
  MADT_TYPE_PROCESSOR: Byte = 0;
  MADT_TYPE_IOAPIC: Byte = 1;

  { AML S5 parsing }
  AML_S5_NAME_LEN: Cardinal = 4; { "_S5_" }

  { ========================================================================
    THREAD STRUCT OFFSETS (Pack=1, from Thread.cs)
    Used by scheduler_dispatch.pas for VRuntime-based thread selection.
    ======================================================================== }
  THREAD_SIZE: Cardinal = 656;
  THREAD_ACTIVE_OFFSET: Cardinal = 8;
  THREAD_EXEC_CORE_OFFSET: Cardinal = 16;
  THREAD_WAKEUP_TICK_OFFSET: Cardinal = 112;
  THREAD_VRUNTIME_OFFSET: Cardinal = 120;
  THREAD_PRIORITY_OFFSET: Cardinal = 128;
  THREAD_RSP_OFFSET: Cardinal = 0;

  { EFI_MEMORY_DESCRIPTOR layout (LayoutKind.Sequential, no Pack)
    Type(4) + Pad(4) + PhysicalStart(8) + VirtualStart(8) + NumberOfPages(8) + Attribute(8) = 40 bytes
    DescriptorSize from GetMemoryMap is typically 48 bytes (with trailing padding) }
  EFI_MEM_DESC_SIZE: Cardinal = 48;
  EFI_DESC_TYPE_OFFSET: Cardinal = 0;
  EFI_PHYS_START_OFFSET: Cardinal = 8; { aligned: 4-byte Type + 4-byte pad }
  EFI_NUM_PAGES_OFFSET: Cardinal = 24; { 8 + 8 + 8 = 24 }
  EFI_MEM_TYPE_CONVENTIONAL: Cardinal = 7;
  PAGE_SIZE: Cardinal = 4096;

implementation

end.
