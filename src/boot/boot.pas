{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: boot - UEFI (x86_64) bootloader.
  PORTED FROM: src/boot/Boot.cs (NOT deleted yet - build.sh still links the
  C# version, this unit is the drop-in replacement being validated).

  This runs before the kernel exists: no PMM, no heap, no libc.pas, no
  src/arch unit, no src/kernel/pas unit. The only symbol it imports is
  boot_io.asm's Out8/In8, bound below with `external name`. Everything else
  comes from the UEFI boot services handed to NekkoBoot.

  ABI NOTES
  - The link entry point stays the bare symbol `NekkoBoot` (exported with
    `public name`), so build.sh's `-entry:NekkoBoot` and boot_io.obj keep
    working unchanged.
  - FPC's Win64 target uses the Microsoft x64 register calling convention,
    which is the same one UEFI firmware uses. Every protocol function
    pointer is therefore a raw Pointer field that gets cast to a matching
    procedural type at the call site; the UEFI_* wrappers below do that cast
    in exactly one place each.
  - Every record is a `packed record` with its padding written out by hand.
    FPC is built with the $PACKRECORDS 1 switch, so a C#
    LayoutKind.Sequential struct that leans on CLR auto-padding has to spell
    that padding out itself or the field offsets drift and the bootloader
    decodes firmware structures
    as garbage. The TSizeGuard* aliases turn every expected size into a
    compile error, so a layout edit cannot land silently.
  - Records live in the implementation section only: anything reachable from
    the interface drags RTTI into the link and lld cannot resolve it
    (AGENTS.md 6.3, docs/PASCAL_PORTING.md 4).
  =========================================================================
}

unit boot;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}

interface

{ UEFI image entry point. Signature per the UEFI spec's EFI_IMAGE_ENTRY
  (EFI_HANDLE, EFI_SYSTEM_TABLE*); the return type is widened to QWord
  because EFI_STATUS is 64-bit, but the value is never observed: every exit
  path either loops forever or hands control to the kernel. }
procedure NekkoBoot(imageHandle: Pointer; systemTable: Pointer); cdecl;
  public name 'NekkoBoot';

implementation

{ --- The only imports: COM1 port primitives from src/boot/boot_io.asm --- }
procedure Out8(port: Word; value: Byte); cdecl; external name 'Out8';
function  In8(port: Word): Byte; cdecl; external name 'In8';

const
  COM1 = $3F8;

{ Longest UEFI literal below is the debug-shell help text, 134 characters.
  The converter truncates rather than smashing the caller's stack. }
  UEFI_STR_MAX = 160;

  { Loop bounds kept identical to the C# so the security limits and the
    UEFI banner spacing do not shift. }
  SHELL_PAD_ROWS_MAX   = 4096;

{ ==========================================================================
  TYPES - implementation only (AGENTS.md 6.3 / porting guide 4)
  ========================================================================== }

type
  PEfiTableHeader = ^TEfiTableHeader;
  TEfiTableHeader = packed record
    Signature:  QWord;
    Revision:   Cardinal;
    HeaderSize: Cardinal;
    Crc32:      Cardinal;
    Reserved:   Cardinal;
  end;

  PEfiGuid = ^TEfiGuid;
  TEfiGuid = packed record
    Data1: Cardinal;
    Data2: Word;
    Data3: Word;
    D4_0: Byte;
    D4_1: Byte;
    D4_2: Byte;
    D4_3: Byte;
    D4_4: Byte;
    D4_5: Byte;
    D4_6: Byte;
    D4_7: Byte;
  end;

  PEfiInputKey = ^TEfiInputKey;
  TEfiInputKey = packed record
    ScanCode:    Word;
    UnicodeChar: Word;
  end;

  PEfiSimpleTextInput = ^TEfiSimpleTextInput;
  TEfiSimpleTextInput = packed record
    Reset:         Pointer;
    ReadKeyStroke: Pointer;
    WaitForKey:    Pointer;
  end;

  PEfiSimpleTextOutput = ^TEfiSimpleTextOutput;
  TEfiSimpleTextOutput = packed record
    Reset:             Pointer;
    OutputString:      Pointer;
    TestString:        Pointer;
    QueryMode:         Pointer;
    SetMode:           Pointer;
    SetAttribute:      Pointer;
    ClearScreen:       Pointer;
    SetCursorPosition: Pointer;
    EnableCursor:      Pointer;
    Mode:              Pointer;
  end;

  PEfiGraphicsOutputModeInformation = ^TEfiGraphicsOutputModeInformation;
  TEfiGraphicsOutputModeInformation = packed record
    Version:              Cardinal;
    HorizontalResolution: Cardinal;
    VerticalResolution:   Cardinal;
    PixelFormat:          LongInt;
    RedMask:              Cardinal;
    GreenMask:            Cardinal;
    BlueMask:             Cardinal;
    ReservedMask:         Cardinal;
    PixelsPerScanLine:    Cardinal;
  end;

  PEfiGraphicsOutputMode = ^TEfiGraphicsOutputMode;
  TEfiGraphicsOutputMode = packed record
    MaxMode:         Cardinal;
    Mode:            Cardinal;
    Info:            PEfiGraphicsOutputModeInformation;
    SizeOfInfo:      QWord;
    FrameBufferBase: QWord;
    FrameBufferSize: QWord;
  end;

  PEfiGraphicsOutput = ^TEfiGraphicsOutput;
  TEfiGraphicsOutput = packed record
    QueryMode: Pointer;
    SetMode:   Pointer;
    Blt:       Pointer;
    Mode:      PEfiGraphicsOutputMode;
  end;

  PEfiMemoryDescriptor = ^TEfiMemoryDescriptor;
  TEfiMemoryDescriptor = packed record
    { CLR sequential layout pads this 32-bit Type out to the 8-byte
      PhysicalStart that follows, so NumberOfPages lands at +24. The kernel
      side already assumes that (fpc_runtime.pas EFI_*_OFFSET). }
    MemType:       Cardinal;   { C# calls this field Type }
    Pad0:          Cardinal;
    PhysicalStart: QWord;
    VirtualStart:  QWord;
    NumberOfPages: QWord;
    Attribute:     QWord;
  end;

  PEfiLoadedImage = ^TEfiLoadedImage;
  TEfiLoadedImage = packed record
    Revision:        Cardinal;
    Pad0:            Cardinal;
    ParentHandle:    Pointer;
    SystemTable:     Pointer;
    DeviceHandle:    Pointer;
    FilePath:        Pointer;
    Reserved:        Pointer;
    LoadOptionsSize: Cardinal;
    Pad1:            Cardinal;
    LoadOptions:     Pointer;
    ImageBase:       Pointer;
    ImageSize:       QWord;
  end;

  PEfiTime = ^TEfiTime;
  TEfiTime = packed record
    Year:       Word;
    Month:      Byte;
    Day:        Byte;
    Hour:       Byte;
    Minute:     Byte;
    Second:     Byte;
    Pad1:       Byte;
    Nanosecond: Cardinal;
    TimeZone:   SmallInt;
    Daylight:   Byte;
    Pad2:       Byte;
  end;

  PEfiFileInfo = ^TEfiFileInfo;
  TEfiFileInfo = packed record
    Size:              QWord;
    FileSize:          QWord;
    PhysicalSize:      QWord;
    CreateTime:        TEfiTime;
    LastAccessTime:    TEfiTime;
    ModificationTime:  TEfiTime;
    Attribute:         QWord;
  end;

  PEfiFileProtocol = ^TEfiFileProtocol;
  TEfiFileProtocol = packed record
    Revision:     QWord;
    Open:         Pointer;
    Close:        Pointer;
    Delete:       Pointer;
    Read:         Pointer;
    Write:        Pointer;
    GetPosition:  Pointer;
    SetPosition:  Pointer;
    GetInfo:      Pointer;
    SetInfo:      Pointer;
    Flush:        Pointer;
  end;

  PEfiSimpleFileSystem = ^TEfiSimpleFileSystem;
  TEfiSimpleFileSystem = packed record
    Revision:    QWord;
    OpenVolume:  Pointer;
  end;

  PEfiRuntimeServices = ^TEfiRuntimeServices;
  TEfiRuntimeServices = packed record
    Hdr:                    TEfiTableHeader;
    GetTime:                Pointer;
    SetTime:                Pointer;
    GetWakeupTime:          Pointer;
    SetWakeupTime:          Pointer;
    SetVirtualAddressMap:   Pointer;
    ConvertPointer:         Pointer;
    GetVariable:            Pointer;
    GetNextVariableName:    Pointer;
    SetVariable:            Pointer;
    GetNextHighMonotonicCount: Pointer;
    ResetSystem:            Pointer;
    UpdateCapsule:          Pointer;
    QueryCapsuleCapabilities: Pointer;
    QueryVariableInfo:      Pointer;
  end;

  PEfiConfigurationTable = ^TEfiConfigurationTable;
  TEfiConfigurationTable = packed record
    VendorGuid:   TEfiGuid;
    VendorTable:  Pointer;
  end;

  PEfiBootServices = ^TEfiBootServices;
  TEfiBootServices = packed record
    Hdr:                          TEfiTableHeader;
    RaiseTPL:                     Pointer;
    RestoreTPL:                   Pointer;
    AllocatePages:                 Pointer;
    FreePages:                    Pointer;
    GetMemoryMap:                 Pointer;
    AllocatePool:                 Pointer;
    FreePool:                     Pointer;
    CreateEvent:                  Pointer;
    SetTimer:                     Pointer;
    WaitForEvent:                 Pointer;
    SignalEvent:                  Pointer;
    CloseEvent:                   Pointer;
    CheckEvent:                   Pointer;
    InstallProtocolInterface:     Pointer;
    ReinstallProtocolInterface:   Pointer;
    UninstallProtocolInterface:   Pointer;
    HandleProtocol:               Pointer;
    Reserved:                     Pointer;
    RegisterProtocolNotify:       Pointer;
    LocateHandle:                 Pointer;
    LocateDevicePath:             Pointer;
    InstallConfigurationTable:    Pointer;
    LoadImage:                    Pointer;
    StartImage:                   Pointer;
    Exit:                         Pointer;
    UnloadImage:                  Pointer;
    ExitBootServices:             Pointer;
    GetNextMonotonicCount:        Pointer;
    Stall:                        Pointer;
    SetWatchdogTimer:             Pointer;
    ConnectController:            Pointer;
    DisconnectController:         Pointer;
    OpenProtocol:                 Pointer;
    CloseProtocol:                Pointer;
    OpenProtocolInformation:      Pointer;
    ProtocolsPerHandle:           Pointer;
    LocateHandleBuffer:           Pointer;
    LocateProtocol:               Pointer;
    InstallMultipleProtocolInterfaces: Pointer;
    UninstallMultipleProtocolInterfaces: Pointer;
    CalculateCrc32:               Pointer;
    CopyMem:                      Pointer;
    SetMem:                       Pointer;
    CreateEventEx:                Pointer;
  end;

  PEfiSystemTable = ^TEfiSystemTable;
  TEfiSystemTable = packed record
    Hdr:                TEfiTableHeader;
    FirmwareVendor:     Pointer;
    FirmwareRevision:   Cardinal;
    { CLR aligns BootServices to 8 bytes after the 4-byte FirmwareRevision. }
    Pad0:               Cardinal;
    ConsoleInHandle:    Pointer;
    ConIn:              PEfiSimpleTextInput;
    ConsoleOutHandle:   Pointer;
    ConOut:             PEfiSimpleTextOutput;
    StandardErrorHandle: Pointer;
    StdErr:             PEfiSimpleTextOutput;
    RuntimeServices:    PEfiRuntimeServices;
    BootServices:       PEfiBootServices;
    NumberOfTableEntries: QWord;
    ConfigurationTable: PEfiConfigurationTable;
  end;

  PEfiRngProtocol = ^TEfiRngProtocol;
  TEfiRngProtocol = packed record
    GetInfo: Pointer;
    GetRNG:  Pointer;
  end;

  { --- ACPI / BGRT / BMP. C# declares these with Pack=1, so packed is
    exactly right and no padding fields are needed. --- }
  PAcpiHeader = ^TAcpiHeader;
  TAcpiHeader = packed record
    Signature:       Cardinal;
    Length:          Cardinal;
    Revision:        Byte;
    Checksum:        Byte;
    OEMID:           array[0..5] of Byte;
    OEMTableID:      array[0..7] of Byte;
    OEMRevision:     Cardinal;
    CreatorID:       Cardinal;
    CreatorRevision: Cardinal;
  end;

  PAcpiBgrt = ^TAcpiBgrt;
  TAcpiBgrt = packed record
    Header:       TAcpiHeader;
    Version:      Word;
    Status:       Byte;
    ImageType:    Byte;
    ImageAddress: QWord;
    ImageOffsetX: Cardinal;
    ImageOffsetY: Cardinal;
  end;

  PBmpHeader = ^TBmpHeader;
  TBmpHeader = packed record
    Signature:      Word;
    FileSize:       Cardinal;
    Reserved:       Cardinal;
    DataOffset:     Cardinal;
    HeaderSize:     Cardinal;
    Width:          LongInt;
    Height:         LongInt;
    Planes:         Word;
    Bpp:            Word;
    Compression:    Cardinal;
    ImageSize:      Cardinal;
    XPixelsPerM:    LongInt;
    YPixelsPerM:    LongInt;
    ColorsUsed:     Cardinal;
    ImportantColors: Cardinal;
  end;

  { --- Boot contract with the kernel. Mirrors src/boot/BootContract.cs;
    the kernel reads this struct by pointer, so the layout is an ABI. --- }
  PNekkoBootInfo = ^TNekkoBootInfo;
  TNekkoBootInfo = packed record
    FrameBufferBase:      QWord;
    FrameBufferSize:      QWord;
    HorizontalResolution: Cardinal;
    VerticalResolution:   Cardinal;
    PixelsPerScanLine:    Cardinal;
    { CLR pads PixelsPerScanLine out so MemoryMap is 8-byte aligned. }
    Pad0:                 Cardinal;
    MemoryMap:            Pointer;
    MemoryMapSize:        QWord;
    DescriptorSize:       QWord;
    AcpiRsdp:             QWord;
  end;

{ ==========================================================================
  LAYOUT GUARDS
  Every struct is guarded by a PAIR of aliases, one for each direction:
    TSizeGuardX      = array[0..(SizeOf(TEfiX) - N)]
    TSizeGuardX_Hi  = array[0..(N - SizeOf(TEfiX))]
  Both collapse to a single byte when the Pascal layout matches the C#
  original, and both are hard compile errors ("Upper bound of range is less
  than lower bound") when the record is either too small or too big, so a
  layout edit cannot land silently in either direction.

  N is the CLR LayoutKind.Sequential size: fields in declaration order, each
  at its own natural alignment, struct alignment = widest field, size rounded
  up (1-byte alignment for the three Pack=1 structs). Every N below was
  cross-checked two ways: against a model of the CLR layout algorithm driven
  by the field lists parsed out of Boot.cs / BootContract.cs, and against the
  real SizeOf emitted into a probe object file (porting guide section 12).
  ========================================================================== }
type
  TSizeGuardTableHeader= array[0..(SizeOf(TEfiTableHeader) - 24)] of Byte;
  TSizeGuardTableHeader_Hi= array[0..(24 - SizeOf(TEfiTableHeader))] of Byte;
  TSizeGuardGuid= array[0..(SizeOf(TEfiGuid) - 16)] of Byte;
  TSizeGuardGuid_Hi= array[0..(16 - SizeOf(TEfiGuid))] of Byte;
  TSizeGuardInputKey= array[0..(SizeOf(TEfiInputKey) - 4)] of Byte;
  TSizeGuardInputKey_Hi= array[0..(4 - SizeOf(TEfiInputKey))] of Byte;
  TSizeGuardTextInput= array[0..(SizeOf(TEfiSimpleTextInput) - 24)] of Byte;
  TSizeGuardTextInput_Hi= array[0..(24 - SizeOf(TEfiSimpleTextInput))] of Byte;
  TSizeGuardTextOutput= array[0..(SizeOf(TEfiSimpleTextOutput) - 80)] of Byte;
  TSizeGuardTextOutput_Hi= array[0..(80 - SizeOf(TEfiSimpleTextOutput))] of Byte;
  TSizeGuardModeInfo= array[0..(SizeOf(TEfiGraphicsOutputModeInformation) - 36)] of Byte;
  TSizeGuardModeInfo_Hi= array[0..(36 - SizeOf(TEfiGraphicsOutputModeInformation))] of Byte;
  TSizeGuardGopMode= array[0..(SizeOf(TEfiGraphicsOutputMode) - 40)] of Byte;
  TSizeGuardGopMode_Hi= array[0..(40 - SizeOf(TEfiGraphicsOutputMode))] of Byte;
  TSizeGuardGop= array[0..(SizeOf(TEfiGraphicsOutput) - 32)] of Byte;
  TSizeGuardGop_Hi= array[0..(32 - SizeOf(TEfiGraphicsOutput))] of Byte;
  TSizeGuardMemDesc= array[0..(SizeOf(TEfiMemoryDescriptor) - 40)] of Byte;
  TSizeGuardMemDesc_Hi= array[0..(40 - SizeOf(TEfiMemoryDescriptor))] of Byte;
  TSizeGuardLoadedImage= array[0..(SizeOf(TEfiLoadedImage) - 80)] of Byte;
  TSizeGuardLoadedImage_Hi= array[0..(80 - SizeOf(TEfiLoadedImage))] of Byte;
  TSizeGuardEfiTime= array[0..(SizeOf(TEfiTime) - 16)] of Byte;
  TSizeGuardEfiTime_Hi= array[0..(16 - SizeOf(TEfiTime))] of Byte;
  TSizeGuardFileInfo= array[0..(SizeOf(TEfiFileInfo) - 80)] of Byte;
  TSizeGuardFileInfo_Hi= array[0..(80 - SizeOf(TEfiFileInfo))] of Byte;
  TSizeGuardFileProtocol= array[0..(SizeOf(TEfiFileProtocol) - 88)] of Byte;
  TSizeGuardFileProtocol_Hi= array[0..(88 - SizeOf(TEfiFileProtocol))] of Byte;
  TSizeGuardSimpleFs= array[0..(SizeOf(TEfiSimpleFileSystem) - 16)] of Byte;
  TSizeGuardSimpleFs_Hi= array[0..(16 - SizeOf(TEfiSimpleFileSystem))] of Byte;
  TSizeGuardRuntime= array[0..(SizeOf(TEfiRuntimeServices) - 136)] of Byte;
  TSizeGuardRuntime_Hi= array[0..(136 - SizeOf(TEfiRuntimeServices))] of Byte;
  TSizeGuardConfigTable= array[0..(SizeOf(TEfiConfigurationTable) - 24)] of Byte;
  TSizeGuardConfigTable_Hi= array[0..(24 - SizeOf(TEfiConfigurationTable))] of Byte;
  TSizeGuardBootServices= array[0..(SizeOf(TEfiBootServices) - 376)] of Byte;
  TSizeGuardBootServices_Hi= array[0..(376 - SizeOf(TEfiBootServices))] of Byte;
  TSizeGuardSystemTable= array[0..(SizeOf(TEfiSystemTable) - 120)] of Byte;
  TSizeGuardSystemTable_Hi= array[0..(120 - SizeOf(TEfiSystemTable))] of Byte;
  TSizeGuardRng= array[0..(SizeOf(TEfiRngProtocol) - 16)] of Byte;
  TSizeGuardRng_Hi= array[0..(16 - SizeOf(TEfiRngProtocol))] of Byte;
  TSizeGuardAcpiHeader= array[0..(SizeOf(TAcpiHeader) - 36)] of Byte;
  TSizeGuardAcpiHeader_Hi= array[0..(36 - SizeOf(TAcpiHeader))] of Byte;
  TSizeGuardAcpiBgrt= array[0..(SizeOf(TAcpiBgrt) - 56)] of Byte;
  TSizeGuardAcpiBgrt_Hi= array[0..(56 - SizeOf(TAcpiBgrt))] of Byte;
  TSizeGuardBmpHeader= array[0..(SizeOf(TBmpHeader) - 54)] of Byte;
  TSizeGuardBmpHeader_Hi= array[0..(54 - SizeOf(TBmpHeader))] of Byte;
  TSizeGuardBootInfo= array[0..(SizeOf(TNekkoBootInfo) - 64)] of Byte;
  TSizeGuardBootInfo_Hi= array[0..(64 - SizeOf(TNekkoBootInfo))] of Byte;

{ ==========================================================================
  UEFI SERVICE SIGNATURES
  FPC Win64 == Microsoft x64 ABI == what UEFI firmware expects, so a raw
  Pointer read out of a protocol struct can be cast to the matching
  procedural type and called. Each UEFI_* wrapper does that cast once.
  ========================================================================== }
type
  TfnAllocatePages = function(This: Pointer; AllocType, MemoryType: Cardinal;
                              Pages: QWord; Memory: PQWord): QWord; cdecl;
  TfnGetMemoryMap  = function(This: Pointer; MemoryMapSize: PQWord;
                              MemoryMap: PPointer; MapKey: PQWord;
                              DescriptorSize: PQWord;
                              DescriptorVersion: PCardinal): QWord; cdecl;
  TfnAllocatePool  = function(This: Pointer; PoolType: Cardinal; Size: QWord;
                              Buffer: PPointer): QWord; cdecl;
  TfnFreePool      = function(This: Pointer; Buffer: Pointer): QWord; cdecl;
  TfnStall         = function(This: Pointer; Microseconds: QWord): QWord; cdecl;
  TfnExitBootServices = function(This: Pointer; ImageHandle: Pointer;
                                 MapKey: QWord): QWord; cdecl;
  TfnGetNextMonotonicCount = function(This: Pointer; Count: PCardinal): QWord; cdecl;
  TfnLocateProtocol = function(This: Pointer; Protocol: PEfiGuid;
                               Registration: Pointer;
                               OutInterface: PPointer): QWord; cdecl;
  TfnHandleProtocol = function(This: Pointer; Handle: Pointer;
                               Protocol: PEfiGuid;
                               OutInterface: PPointer): QWord; cdecl;
  TfnGetTime        = function(This: Pointer; Time: PEfiTime;
                               Capabilities: PCardinal): QWord; cdecl;
  TfnResetSystem    = procedure(This: Pointer; ResetType: Cardinal;
                                Data: Pointer; DataSize: QWord;
                                ResetData: Pointer); cdecl;
  TfnOutputString   = function(This: Pointer; Str: PWord): QWord; cdecl;
  TfnSetAttribute   = function(This: Pointer; Attribute: QWord): QWord; cdecl;
  TfnClearScreen    = function(This: Pointer): QWord; cdecl;
  TfnEnableCursor   = function(This: Pointer; Visible: Boolean): QWord; cdecl;
  TfnGetRNG         = function(This: Pointer; Algorithm: PEfiGuid;
                               ValueLength: QWord; Value: PByte): QWord; cdecl;
  TfnFileOpen       = function(This: Pointer; OutFile: PEfiFileProtocol;
                               FileName: PWord; OpenMode: QWord;
                               Attributes: QWord): QWord; cdecl;
  TfnFileClose      = function(This: Pointer): QWord; cdecl;
  TfnFileRead       = function(This: Pointer; Size: PQWord;
                               Buffer: Pointer): QWord; cdecl;
  TfnFileGetInfo    = function(This: Pointer; InformationType: PEfiGuid;
                               BufferSize: PQWord; Buffer: Pointer): QWord; cdecl;
  TfnKernelMain     = procedure(BootInfo: Pointer); cdecl;

{ ==========================================================================
  GUID CONSTANTS
  ========================================================================== }
const
  GUID_RNG: TEfiGuid = (Data1: $3152BCA5; Data2: $EADE; Data3: $433D;
                        D4_0: $86; D4_1: $2E; D4_2: $C0; D4_3: $1C;
                        D4_4: $DC; D4_5: $29; D4_6: $1F; D4_7: $44);
  GUID_ACPI20: TEfiGuid = (Data1: $8868E871; Data2: $E4F1; Data3: $11D3;
                           D4_0: $BC; D4_1: $22; D4_2: $00; D4_3: $80;
                           D4_4: $C7; D4_5: $3C; D4_6: $88; D4_7: $81);
  GUID_ACPI10: TEfiGuid = (Data1: $EB9D2D30; Data2: $2D88; Data3: $11D3;
                           D4_0: $9A; D4_1: $16; D4_2: $00; D4_3: $90;
                           D4_4: $27; D4_5: $3F; D4_6: $C1; D4_7: $4B);
  GUID_GOP: TEfiGuid = (Data1: $9042A9DE; Data2: $23DC; Data3: $4A38;
                        D4_0: $96; D4_1: $FB; D4_2: $7A; D4_3: $DE;
                        D4_4: $D0; D4_5: $80; D4_6: $51; D4_7: $6A);
  GUID_LOADED_IMAGE: TEfiGuid = (Data1: $5B1B31A1; Data2: $9562; Data3: $11D2;
                                 D4_0: $8E; D4_1: $3F; D4_2: $00; D4_3: $A0;
                                 D4_4: $C9; D4_5: $69; D4_6: $72; D4_7: $3B);
  GUID_SIMPLE_FS: TEfiGuid = (Data1: $0964E5B22; Data2: $6459; Data3: $11D2;
                              D4_0: $8E; D4_1: $39; D4_2: $00; D4_3: $A0;
                              D4_4: $C9; D4_5: $69; D4_6: $72; D4_7: $3B);
  GUID_FILE_INFO: TEfiGuid = (Data1: $09576E92; Data2: $6D3F; Data3: $11D2;
                              D4_0: $8E; D4_1: $39; D4_2: $00; D4_3: $A0;
                              D4_4: $C9; D4_5: $69; D4_6: $72; D4_7: $3B);

{ ==========================================================================
  RSA-2048 CONSTANTS
  ========================================================================== }
const
  RSA_LEN = 64;                { 64 x uint32 = 2048 bits = 256 bytes }

  { Serpents constants from the C# source, in hex because they do not fit
    a signed 32/64-bit literal comfortably. }
  RAND_MUL_A = QWord($5851F42D4C957F2D);
  RAND_MUL_B = QWord($14057B7EF767814F);
  RAND_SPLIT_A = QWord($BF58476D1CE4E5B9);
  RAND_SPLIT_B = QWord($94D049BB133111EB);

{ ==========================================================================
  STATE
  ========================================================================== }
var
  { RSA-2048 public modulus, big-endian, injected by build.sh at build time.
    The C# original kept these 256 bytes in a stackalloc inside NekkoBoot;
    a unit-scope initialised array is equivalent and costs no EFI stack.

    WARNING: build.sh rewrites the single line below on every build. Keep the
    declaration on one line and keep the trailing INJECT_PUBKEY marker -
    src/boot/boot.pas is patched by the pubkey-injection step, and the
    literal must use Pascal's $ hex prefix, not C#'s 0x.
    ========================================================== }
  Boot_PublicKeyN: array[0..255] of Byte = ( $EE, $3B, $FF, $8E, $EF, $51, $26, $03, $E1, $9B, $1F, $C0, $62, $B1, $81, $D4, $24, $DF, $55, $D5, $19, $D1, $22, $90, $07, $F9, $1C, $54, $B3, $31, $B9, $BF, $A8, $EF, $50, $F7, $9C, $4B, $14, $0F, $52, $EE, $95, $7C, $07, $C2, $78, $E5, $73, $39, $27, $DC, $AE, $58, $45, $8D, $0E, $E4, $E6, $AD, $31, $61, $52, $AE, $49, $95, $EE, $CE, $04, $19, $B6, $A9, $35, $7B, $F9, $B1, $34, $F5, $5F, $E3, $F2, $D6, $4A, $79, $60, $DF, $2A, $74, $C9, $D4, $D3, $B4, $14, $84, $AB, $3A, $56, $4D, $49, $72, $39, $18, $DA, $56, $44, $34, $6C, $E5, $FD, $02, $C6, $CA, $CC, $EC, $80, $C6, $1A, $7B, $31, $F3, $FA, $90, $22, $7B, $E0, $AA, $06, $4E, $3A, $B0, $ED, $C9, $9A, $F1, $3C, $E7, $A4, $01, $D2, $B3, $3B, $70, $D0, $4A, $09, $EE, $43, $35, $D0, $E6, $C2, $2B, $13, $D5, $1C, $EB, $97, $58, $B5, $15, $4D, $96, $2C, $7F, $70, $C2, $BB, $7F, $2A, $BD, $30, $AC, $6A, $65, $C7, $7E, $36, $3A, $26, $65, $6D, $D5, $86, $76, $EF, $98, $75, $5A, $7D, $E9, $CD, $9E, $04, $44, $B9, $39, $26, $36, $18, $B7, $FA, $0E, $42, $AE, $B5, $85, $7E, $0B, $32, $85, $92, $A5, $00, $8E, $CC, $10, $D9, $83, $1F, $09, $97, $45, $0D, $96, $3C, $1D, $9D, $B6, $92, $BF, $8E, $E3, $84, $B8, $AA, $8B, $A1, $F0, $34, $87, $15, $DA, $95, $84, $7D, $AD, $FD, $68, $D2, $4A, $CF, $8E, $51, $5C, $38, $7B ); { INJECT_PUBKEY }

{ ==========================================================================
  TEXT HELPERS
  UEFI OutputString takes a CHAR16 string, so every literal has to be
  widened. The buffer lives in this frame and is valid until the caller
  returns, which covers every use (the pointer is always consumed by the
  immediately following Print).
  ========================================================================== }
function U16(s: AnsiString): PWord;
var
  buffer: array[0..UEFI_STR_MAX] of Word;
  i: Integer;
begin
  i := 0;
  while (i < Length(s)) and (i < UEFI_STR_MAX) do
  begin
    buffer[i] := Byte(s[i + 1]);
    Inc(i);
  end;
  buffer[i] := 0;
  U16 := @buffer[0];
end;

{ ==========================================================================
  UEFI SERVICE WRAPPERS
  ========================================================================== }
function Uefi_AllocatePages(bs: PEfiBootServices; allocType, memType: Cardinal;
                           pages: QWord; memory: PQWord): QWord;
var
  f: TfnAllocatePages;
begin
  f := TfnAllocatePages(bs^.AllocatePages);
  Uefi_AllocatePages := f(bs, allocType, memType, pages, memory);
end;

function Uefi_GetMemoryMap(bs: PEfiBootServices; mapSize: PQWord;
                           map: PPointer; mapKey: PQWord;
                           descSize: PQWord; descVersion: PCardinal): QWord;
var
  f: TfnGetMemoryMap;
begin
  f := TfnGetMemoryMap(bs^.GetMemoryMap);
  Uefi_GetMemoryMap := f(bs, mapSize, map, mapKey, descSize, descVersion);
end;

function Uefi_AllocatePool(bs: PEfiBootServices; poolType: Cardinal;
                           size: QWord; buffer: PPointer): QWord;
var
  f: TfnAllocatePool;
begin
  f := TfnAllocatePool(bs^.AllocatePool);
  Uefi_AllocatePool := f(bs, poolType, size, buffer);
end;

function Uefi_FreePool(bs: PEfiBootServices; buffer: Pointer): QWord;
var
  f: TfnFreePool;
begin
  f := TfnFreePool(bs^.FreePool);
  Uefi_FreePool := f(bs, buffer);
end;

function Uefi_Stall(bs: PEfiBootServices; microseconds: QWord): QWord;
var
  f: TfnStall;
begin
  f := TfnStall(bs^.Stall);
  Uefi_Stall := f(bs, microseconds);
end;

function Uefi_ExitBootServices(bs: PEfiBootServices; imageHandle: Pointer;
                               mapKey: QWord): QWord;
var
  f: TfnExitBootServices;
begin
  f := TfnExitBootServices(bs^.ExitBootServices);
  Uefi_ExitBootServices := f(bs, imageHandle, mapKey);
end;

function Uefi_GetNextMonotonicCount(bs: PEfiBootServices; count: PCardinal): QWord;
var
  f: TfnGetNextMonotonicCount;
begin
  f := TfnGetNextMonotonicCount(bs^.GetNextMonotonicCount);
  Uefi_GetNextMonotonicCount := f(bs, count);
end;

function Uefi_LocateProtocol(bs: PEfiBootServices; protocol: PEfiGuid;
                             registration: Pointer;
                             OutInterface: PPointer): QWord;
var
  f: TfnLocateProtocol;
begin
  f := TfnLocateProtocol(bs^.LocateProtocol);
  Uefi_LocateProtocol := f(bs, protocol, registration, OutInterface);
end;

function Uefi_HandleProtocol(bs: PEfiBootServices; handle: Pointer;
                             protocol: PEfiGuid; OutInterface: PPointer): QWord;
var
  f: TfnHandleProtocol;
begin
  f := TfnHandleProtocol(bs^.HandleProtocol);
  Uefi_HandleProtocol := f(bs, handle, protocol, OutInterface);
end;

function Uefi_GetTime(rs: PEfiRuntimeServices; t: PEfiTime;
                      capabilities: PCardinal): QWord;
var
  f: TfnGetTime;
begin
  f := TfnGetTime(rs^.GetTime);
  Uefi_GetTime := f(rs, t, capabilities);
end;

procedure Uefi_ResetSystem(rs: PEfiRuntimeServices; resetType: Cardinal;
                           data: Pointer; dataSize: QWord; resetData: Pointer);
var
  f: TfnResetSystem;
begin
  f := TfnResetSystem(rs^.ResetSystem);
  f(rs, resetType, data, dataSize, resetData);
end;

function Uefi_OutputString(conOut: PEfiSimpleTextOutput; str: PWord): QWord;
var
  f: TfnOutputString;
begin
  f := TfnOutputString(conOut^.OutputString);
  Uefi_OutputString := f(conOut, str);
end;

function Uefi_SetAttribute(conOut: PEfiSimpleTextOutput; attr: QWord): QWord;
var
  f: TfnSetAttribute;
begin
  f := TfnSetAttribute(conOut^.SetAttribute);
  Uefi_SetAttribute := f(conOut, attr);
end;

function Uefi_ClearScreen(conOut: PEfiSimpleTextOutput): QWord;
var
  f: TfnClearScreen;
begin
  f := TfnClearScreen(conOut^.ClearScreen);
  Uefi_ClearScreen := f(conOut);
end;

function Uefi_EnableCursor(conOut: PEfiSimpleTextOutput; visible: Boolean): QWord;
var
  f: TfnEnableCursor;
begin
  f := TfnEnableCursor(conOut^.EnableCursor);
  Uefi_EnableCursor := f(conOut, visible);
end;

function Uefi_GetRNG(rng: PEfiRngProtocol; algorithm: PEfiGuid;
                     valueLength: QWord; value: PByte): QWord;
var
  f: TfnGetRNG;
begin
  f := TfnGetRNG(rng^.GetRNG);
  Uefi_GetRNG := f(rng, algorithm, valueLength, value);
end;

function Uefi_OpenVolume(fileSystem: PEfiSimpleFileSystem;
                         rootDir: PEfiFileProtocol): QWord;
var
  f: TfnFileOpen;
begin
  f := TfnFileOpen(fileSystem^.OpenVolume);
  Uefi_OpenVolume := f(fileSystem, rootDir, nil, 0, 0);
end;

function Uefi_FileOpen(rootDir: PEfiFileProtocol; fileHandle: PEfiFileProtocol;
                       fileName: PWord; openMode, attributes: QWord): QWord;
var
  f: TfnFileOpen;
begin
  f := TfnFileOpen(rootDir^.Open);
  Uefi_FileOpen := f(rootDir, fileHandle, fileName, openMode, attributes);
end;

function Uefi_FileClose(fileHandle: PEfiFileProtocol): QWord;
var
  f: TfnFileClose;
begin
  f := TfnFileClose(fileHandle^.Close);
  Uefi_FileClose := f(fileHandle);
end;

function Uefi_FileRead(fileHandle: PEfiFileProtocol; size: PQWord;
                       buffer: Pointer): QWord;
var
  f: TfnFileRead;
begin
  f := TfnFileRead(fileHandle^.Read);
  Uefi_FileRead := f(fileHandle, size, buffer);
end;

function Uefi_FileGetInfo(fileHandle: PEfiFileProtocol; informationType: PEfiGuid;
                          bufferSize: PQWord; buffer: Pointer): QWord;
var
  f: TfnFileGetInfo;
begin
  f := TfnFileGetInfo(fileHandle^.GetInfo);
  Uefi_FileGetInfo := f(fileHandle, informationType, bufferSize, buffer);
end;

{ ==========================================================================
  COM1 SERIAL
  UEFI/OVMF already forwards the console to COM1, so this is only used for
  the debugger handshake and the mini shell.
  ========================================================================== }
procedure SerialInit;
begin
  Out8(COM1 + 1, $00);
  Out8(COM1 + 3, $80);
  Out8(COM1 + 0, $03);
  Out8(COM1 + 1, $00);
  Out8(COM1 + 3, $03);
  Out8(COM1 + 2, $C7);
  Out8(COM1 + 4, $0B);
end;

function SerialReceived: Boolean;
begin
  SerialReceived := (In8(COM1 + 5) and $01) <> 0;
end;

procedure SerialWriteChar(c: Char);
begin
  if c = #10 then
  begin
    while (In8(COM1 + 5) and $20) = 0 do ;
    Out8(COM1, $0D);
  end;
  while (In8(COM1 + 5) and $20) = 0 do ;
  Out8(COM1, Byte(Ord(c)));
end;

function SerialReadChar: Char;
begin
  while not SerialReceived do ;
  SerialReadChar := Char(In8(COM1));
end;

{ Non-blocking read with a millisecond budget, spent in 1 ms Stall slices. }
function SerialReadCharWithTimeout(bs: PEfiBootServices;
                                   timeoutMs: QWord): Char;
var
  elapsed: QWord;
begin
  elapsed := 0;
  while elapsed < timeoutMs do
  begin
    if SerialReceived then
    begin
      SerialReadCharWithTimeout := Char(In8(COM1));
      Exit;
    end;
    if bs = nil then
    begin
      SerialReadCharWithTimeout := #0;
      Exit;
    end;
    Uefi_Stall(bs, 1000);
    Inc(elapsed);
  end;
  SerialReadCharWithTimeout := #0;
end;

{ Read a big-endian hex number from COM1, echoing valid digits. Non-hex
  bytes are silently dropped, exactly like the C# original. }
function SerialReadHex: QWord;
var
  c: Char;
begin
  SerialReadHex := 0;
  while true do
  begin
    c := SerialReadChar;
    if (c = #13) or (c = #10) then
    begin
      SerialWriteChar(#13);
      SerialWriteChar(#10);
      Break;
    end;

    if (c >= '0') and (c <= '9') then
    begin
      SerialReadHex := (SerialReadHex shl 4) or QWord(Ord(c) - Ord('0'));
      SerialWriteChar(c);
    end
    else if (c >= 'a') and (c <= 'f') then
    begin
      SerialReadHex := (SerialReadHex shl 4) or QWord(Ord(c) - Ord('a') + 10);
      SerialWriteChar(c);
    end
    else if (c >= 'A') and (c <= 'F') then
    begin
      SerialReadHex := (SerialReadHex shl 4) or QWord(Ord(c) - Ord('A') + 10);
      SerialWriteChar(c);
    end;
  end;
end;

{ ==========================================================================
  CONSOLE OUTPUT
  ========================================================================== }
procedure Print(conOut: PEfiSimpleTextOutput; str: PWord);
begin
  Uefi_OutputString(conOut, str);
end;

procedure PrintHex(conOut: PEfiSimpleTextOutput; number: QWord);
const
  HexChars: array[0..15] of Char =
    ('0', '1', '2', '3', '4', '5', '6', '7',
     '8', '9', 'A', 'B', 'C', 'D', 'E', 'F');
var
  buffer: array[0..18] of Word;
  i: Integer;
  nibble: Integer;
begin
  buffer[0] := Ord('0');
  buffer[1] := Ord('x');
  buffer[18] := 0;
  for i := 0 to 15 do
  begin
    nibble := Integer((number shr ((15 - i) * 4)) and $F);
    buffer[2 + i] := Ord(HexChars[nibble]);
  end;
  Print(conOut, @buffer[0]);
end;

procedure PrintNumber(conOut: PEfiSimpleTextOutput; number: QWord);
var
  buffer: array[0..19] of Word;
  index: Integer;
begin
  if number = 0 then
  begin
    Print(conOut, U16('0'));
    Exit;
  end;

  index := 19;
  buffer[index] := 0;
  Dec(index);
  while number > 0 do
  begin
    buffer[index] := Ord('0') + Word(number mod 10);
    number := number div 10;
    Dec(index);
  end;
  Print(conOut, @buffer[index + 1]);
end;

{ ==========================================================================
  RANDOM
  ========================================================================== }
function BootRandom(st: PEfiSystemTable; minValue, maxValue: QWord): QWord;
var
  bs: PEfiBootServices;
  rs: PEfiRuntimeServices;
  rngInterface: Pointer;
  status: QWord;
  hwRandom: QWord;
  t: TEfiTime;
  seed, stackRnd, monotonic, range: QWord;
begin
  bs := st^.BootServices;
  rs := st^.RuntimeServices;

  seed := 0;
  rngInterface := nil;
  status := Uefi_LocateProtocol(bs, @GUID_RNG, nil, @rngInterface);
  if status = 0 then
  begin
    hwRandom := 0;
    status := Uefi_GetRNG(PEfiRngProtocol(rngInterface), nil, 8, PByte(@hwRandom));
    if status = 0 then seed := hwRandom;
  end;

  Uefi_GetTime(rs, @t, nil);
  seed := seed xor (QWord(t.Nanosecond) shl 24);
  seed := seed xor ((QWord(t.Second) shl 32) or QWord(t.Minute));
  seed := seed xor (QWord(t.Day) shl 48);

  { Address of a stack local: cheap ASLR-ish entropy, same trick as C#. }
  stackRnd := QWord(@t);
  seed := seed xor ((stackRnd shl 13) or (stackRnd shr 7));
  seed := seed xor QWord(st);

  monotonic := 0;
  Uefi_GetNextMonotonicCount(bs, @monotonic);
  seed := seed xor ((monotonic shl 32) or (monotonic shr 32));

  seed := seed or (seed or RAND_MUL_A) or RAND_MUL_B or (seed * seed);
  seed := (seed xor (seed shr 30)) * RAND_SPLIT_A;
  seed := (seed xor (seed shr 27)) * RAND_SPLIT_B;

  range := maxValue - minValue + 1;
  BootRandom := minValue + (seed mod range);
end;

{ ==========================================================================
  [CRYPTO] Baremetal SHA-256
  Stack based, no heap: the UEFI boot environment has no allocator wired up
  for us beyond the boot pool, and the hash must run before the kernel image
  is trusted.
  ========================================================================== }
const
  SHA256_K: array[0..63] of Cardinal = (
    $428A2F98, $71374491, $B5C0FBCF, $E9B5DBA5, $3956C25B, $59F111F1, $923F82A4, $AB1C5ED5,
    $D807AA98, $12835B01, $243185BE, $550C7DC3, $72BE5D74, $80DEB1FE, $9BDC06A7, $C19BF174,
    $E49B69C1, $EFBE4786, $0FC19DC6, $240CA1CC, $2DE92C6F, $4A7484AA, $5CB0A9DC, $76F988DA,
    $983E5152, $A831C66D, $B00327C8, $BF597FC7, $C6E00BF3, $D5A79147, $06CA6351, $14292967,
    $27B70A85, $2E1B2138, $4D2C6DFC, $53380D13, $650A7354, $766A0ABB, $81C2C92E, $92722C85,
    $A2BFE8A1, $A81A664B, $C24B8B70, $C76C51A3, $D192E819, $D6990624, $F40E3585, $106AA070,
    $19A4C116, $1E376C08, $2748774C, $34B0BCB5, $391C0CB3, $4ED8AA4A, $5B9CCA4F, $682E6FF3,
    $748F82EE, $78A5636F, $84C87814, $8CC70208, $90BEFFFA, $A4506CEB, $BEF9A3F7, $C67178F2);

  SHA256_H0: array[0..7] of Cardinal = (
    $6A09E667, $BB67AE85, $3C6EF372, $A54FF53A,
    $510E527F, $9B05688C, $1F83D9AB, $5BE0CD19);

function Rotr(x: Cardinal; n: Integer): Cardinal; inline;
begin
  Rotr := (x shr n) or (x shl (32 - n));
end;

function Ch(x, y, z: Cardinal): Cardinal; inline;
begin
  Ch := (x and y) xor ((not x) and z);
end;

function Maj(x, y, z: Cardinal): Cardinal; inline;
begin
  Maj := (x and y) xor (x and z) xor (y and z);
end;

function BigSigma0(x: Cardinal): Cardinal; inline;
begin
  BigSigma0 := Rotr(x, 2) xor Rotr(x, 13) xor Rotr(x, 22);
end;

function BigSigma1(x: Cardinal): Cardinal; inline;
begin
  BigSigma1 := Rotr(x, 6) xor Rotr(x, 11) xor Rotr(x, 25);
end;

function SmallSigma0(x: Cardinal): Cardinal; inline;
begin
  SmallSigma0 := Rotr(x, 7) xor Rotr(x, 18) xor (x shr 3);
end;

function SmallSigma1(x: Cardinal): Cardinal; inline;
begin
  SmallSigma1 := Rotr(x, 17) xor Rotr(x, 19) xor (x shr 10);
end;

procedure Sha256Compute(data: PByte; length: QWord; outputHash: PByte);
var
  Hval: array[0..7] of Cardinal;
  W: array[0..63] of Cardinal;
  block: array[0..63] of Byte;
  totalBits, paddedLen, offset: QWord;
  a, b, c, d, e, f, g, h, T1, T2: Cardinal;
  i, t: Integer;
begin
  if (data = nil) or (outputHash = nil) or (length = 0) then Exit;

  { 256 MB ceiling, same as the C# original. }
  if length > $10000000 then Exit;

  for i := 0 to 7 do Hval[i] := SHA256_H0[i];

  totalBits := length * 8;
  paddedLen := length + 1;
  while (paddedLen mod 64) <> 56 do Inc(paddedLen);
  Inc(paddedLen, 8);

  offset := 0;
  while offset < paddedLen do
  begin
    for i := 0 to 63 do
    begin
      if offset + QWord(i) < length then
        block[i] := data[offset + QWord(i)]
      else if offset + QWord(i) = length then
        block[i] := $80
      else
        block[i] := 0;
    end;

    if offset + 64 >= paddedLen then
      for i := 0 to 7 do
        block[63 - i] := Byte((totalBits shr (i * 8)) and $FF);

    for t := 0 to 15 do
      W[t] := (Cardinal(block[t * 4]) shl 24) or
              (Cardinal(block[t * 4 + 1]) shl 16) or
              (Cardinal(block[t * 4 + 2]) shl 8) or
               Cardinal(block[t * 4 + 3]);

    for t := 16 to 63 do
      W[t] := SmallSigma1(W[t - 2]) + W[t - 7] + SmallSigma0(W[t - 15]) + W[t - 16];

    a := Hval[0]; b := Hval[1]; c := Hval[2]; d := Hval[3];
    e := Hval[4]; f := Hval[5]; g := Hval[6]; h := Hval[7];

    for t := 0 to 63 do
    begin
      T1 := h + BigSigma1(e) + Ch(e, f, g) + SHA256_K[t] + W[t];
      T2 := BigSigma0(a) + Maj(a, b, c);
      h := g; g := f; f := e; e := d + T1;
      d := c; c := b; b := a; a := T1 + T2;
    end;

    Hval[0] := Hval[0] + a; Hval[1] := Hval[1] + b; Hval[2] := Hval[2] + c; Hval[3] := Hval[3] + d;
    Hval[4] := Hval[4] + e; Hval[5] := Hval[5] + f; Hval[6] := Hval[6] + g; Hval[7] := Hval[7] + h;

    Inc(offset, 64);
  end;

  for i := 0 to 7 do
  begin
    outputHash[i * 4]     := Byte((Hval[i] shr 24) and $FF);
    outputHash[i * 4 + 1] := Byte((Hval[i] shr 16) and $FF);
    outputHash[i * 4 + 2] := Byte((Hval[i] shr 8) and $FF);
    outputHash[i * 4 + 3] := Byte(Hval[i] and $FF);
  end;
end;

{ ==========================================================================
  [CRYPTO] Baremetal RSA-2048 verifier
  Fixed-width little-endian uint32 limbs, no heap, so it fits next to the
  SHA-256 state on the boot stack.
  ========================================================================== }
function RsaCmp(a, b: PCardinal): Integer;
var
  i: Integer;
begin
  for i := RSA_LEN - 1 downto 0 do
  begin
    if a[i] > b[i] then
    begin
      RsaCmp := 1;
      Exit;
    end;
    if a[i] < b[i] then
    begin
      RsaCmp := -1;
      Exit;
    end;
  end;
  RsaCmp := 0;
end;

procedure RsaSub(a, b: PCardinal);
var
  borrow, res: QWord;
  i: Integer;
begin
  borrow := 0;
  for i := 0 to RSA_LEN - 1 do
  begin
    res := QWord(a[i]) - QWord(b[i]) - borrow;
    a[i] := Cardinal(res and $FFFFFFFF);
    borrow := (res shr 32) and 1;
  end;
end;

{ r := (128-limb a) mod (64-limb n), long division one bit at a time.
  The iteration cap mirrors the C# original exactly: the loop can never
  legitimately need more than 4096 iterations, so the cap is unreachable
  in practice and exists only as a hang guard. }
procedure RsaMod(a, n, r: PCardinal);
const
  MaxIterations = 16386;
var
  iterationCount, i, j: Integer;
  carry, nextCarry: Cardinal;
begin
  if (a = nil) or (n = nil) or (r = nil) then Exit;

  for i := 0 to RSA_LEN - 1 do r[i] := 0;

  iterationCount := 0;
  for i := 128 * 32 - 1 downto 0 do
  begin
    if iterationCount >= MaxIterations then Break;
    Inc(iterationCount);

    { r := r << 1, carrying out of the top limb into `carry`. }
    carry := 0;
    for j := RSA_LEN - 1 downto 0 do
    begin
      nextCarry := r[j] shr 31;
      r[j] := (r[j] shl 1) or carry;
      carry := nextCarry;
    end;

    r[0] := r[0] or ((a[i div 32] shr (i mod 32)) and 1);

    if (carry <> 0) or (RsaCmp(r, n) >= 0) then RsaSub(r, n);
  end;
end;

{ Schoolbook multiplication: 64x64 limbs into a 128-limb result. }
procedure RsaMul(a, b, r: PCardinal);
var
  i, j: Integer;
  carry, res: QWord;
begin
  for i := 0 to 127 do r[i] := 0;
  for i := 0 to RSA_LEN - 1 do
  begin
    carry := 0;
    for j := 0 to RSA_LEN - 1 do
    begin
      res := QWord(r[i + j]) + (QWord(a[i]) * QWord(b[j])) + carry;
      r[i + j] := Cardinal(res and $FFFFFFFF);
      carry := res shr 32;
    end;
    r[i + RSA_LEN] := Cardinal(carry and $FFFFFFFF);
  end;
end;

{ Big-endian (OpenSSL wire order) limbs -> little-endian limbs. }
procedure BytesToUInts(bytes: PByte; uints: PCardinal);
var
  i, b: Integer;
begin
  for i := 0 to RSA_LEN - 1 do
  begin
    b := 252 - (i * 4);
    uints[i] := (Cardinal(bytes[b]) shl 24) or
                (Cardinal(bytes[b + 1]) shl 16) or
                (Cardinal(bytes[b + 2]) shl 8) or
                 Cardinal(bytes[b + 3]);
  end;
end;

procedure UIntsToBytes(uints: PCardinal; bytes: PByte);
var
  i, b: Integer;
begin
  for i := 0 to RSA_LEN - 1 do
  begin
    b := 252 - (i * 4);
    bytes[b]     := Byte(uints[i] shr 24);
    bytes[b + 1] := Byte(uints[i] shr 16);
    bytes[b + 2] := Byte(uints[i] shr 8);
    bytes[b + 3] := Byte(uints[i]);
  end;
end;

{ S^65537 mod N, exponentiation by the standard four squarings + one multiply
  (e = 0x10001 = 2^16 + 1). }
procedure RsaVerifySignature(signature, publicKey, output: PByte;
                            S, N, Res, tempMul, baseS: PCardinal);
var
  i: Integer;
begin
  if (signature = nil) or (publicKey = nil) or (output = nil) or
     (S = nil) or (N = nil) or (Res = nil) or (tempMul = nil) or
     (baseS = nil) then Exit;

  BytesToUInts(signature, S);
  BytesToUInts(publicKey, N);

  for i := 0 to RSA_LEN - 1 do
  begin
    baseS[i] := S[i];
    Res[i] := S[i];
  end;

  for i := 0 to 15 do
  begin
    RsaMul(Res, Res, tempMul);
    RsaMod(tempMul, N, Res);
  end;
  RsaMul(Res, baseS, tempMul);
  RsaMod(tempMul, N, Res);

  UIntsToBytes(Res, output);
end;

{ ==========================================================================
  [GRAPHICS] ACPI BGRT -> BMP -> framebuffer
  ========================================================================== }
procedure DrawOEMLogo(rsdpAddress: QWord; fb: PCardinal; fbWidth,
                      fbHeight, scanLine: Cardinal);
var
  rsdp: PByte;
  isAcpi2: Boolean;
  xsdtAddr, entryAddr, offsetX, offsetY: QWord;
  xsdt: PAcpiHeader;
  header: PAcpiHeader;
  bgrt: PAcpiBgrt;
  entryCount, i: Integer;
  entryBytes: Cardinal;
  entryStride: Cardinal;
  entries: PByte;
  bmp: PBmpHeader;
  pixelData: PByte;
  width, height, bytesPerPixel, pitch: LongInt;
  isBottomUp: Boolean;
  x, y, drawX, drawY: LongInt;
  p: PByte;
  color: Cardinal;
  entryCountRaw: Cardinal;
begin
  if (rsdpAddress = 0) or (fb = nil) or (fbWidth = 0) or
     (fbHeight = 0) or (scanLine = 0) then Exit;

  rsdp := PByte(rsdpAddress);
  isAcpi2 := rsdp[15] >= 2;

  if isAcpi2 then
    xsdtAddr := PQWord(rsdp + 24)^
  else
    xsdtAddr := QWord(PCardinal(rsdp + 16)^);

  if xsdtAddr = 0 then Exit;

  xsdt := PAcpiHeader(xsdtAddr);

  { Guard before the subtraction: an XSDT shorter than its own header would
    underflow the byte count. The C# computed the (garbage) count first and
    then rejected it; rejecting up front is the same outcome without the
    underflow (AGENTS.md 6.6). }
  if xsdt^.Length < SizeOf(TAcpiHeader) then Exit;

  entryCountRaw := xsdt^.Length - Cardinal(SizeOf(TAcpiHeader));
  if isAcpi2 then entryStride := 8 else entryStride := 4;
  entryBytes := entryCountRaw;
  if entryStride <> 0 then entryCount := Integer(entryBytes div entryStride)
  else entryCount := 0;
  entries := PByte(xsdt) + SizeOf(TAcpiHeader);

  if entryCount < 0 then Exit;
  if entryCount > 100 then Exit;   { bound the table scan }

  bgrt := nil;
  for i := 0 to entryCount - 1 do
  begin
    if isAcpi2 then
      entryAddr := PQWord(entries + (i * IntPtr(entryStride)))^
    else
      entryAddr := QWord(PCardinal(entries + (i * IntPtr(entryStride)))^);

    if (entryAddr < $1000) or (entryAddr > QWord($000FFFFFFFFFFFFF)) then Continue;

    header := PAcpiHeader(entryAddr);

    { $54524742 is "BGRT" read little-endian. }
    if header^.Signature = $54524742 then
    begin
      if header^.Length >= SizeOf(TAcpiBgrt) then
      begin
        bgrt := PAcpiBgrt(entryAddr);
        if bgrt^.ImageAddress <> 0 then Break;
      end;
    end;
  end;

  if (bgrt = nil) or (bgrt^.ImageAddress = 0) then Exit;

  bmp := PBmpHeader(bgrt^.ImageAddress);
  { $4D42 is "BM". }
  if bmp^.Signature <> $4D42 then Exit;

  if (bmp^.Width <= 0) or (bmp^.Height = 0) then Exit;
  if bmp^.Width > LongInt(fbWidth) then Exit;

  pixelData := PByte(bmp) + bmp^.DataOffset;
  width := bmp^.Width;
  height := bmp^.Height;
  isBottomUp := True;
  if height < 0 then
  begin
    height := -height;
    isBottomUp := False;
  end;

  offsetX := bgrt^.ImageOffsetX;
  offsetY := bgrt^.ImageOffsetY;

  bytesPerPixel := bmp^.Bpp div 8;
  pitch := (width * bytesPerPixel + 3) and (not 3);   { BMP rows pad to 4 }

  if pixelData = nil then Exit;

  for y := 0 to height - 1 do
  begin
    { BMPs are usually stored bottom-up, so the Y axis is flipped here. }
    if isBottomUp then drawY := LongInt(offsetY) + (height - 1 - y)
    else drawY := LongInt(offsetY) + y;
    if (drawY < 0) or (drawY >= LongInt(fbHeight)) then Continue;

    for x := 0 to width - 1 do
    begin
      drawX := LongInt(offsetX) + x;
      if (drawX < 0) or (drawX >= LongInt(fbWidth)) then Continue;

      p := pixelData + (y * pitch) + (x * bytesPerPixel);

      color := 0;
      if bytesPerPixel = 3 then
        color := Cardinal(p[0] or (p[1] shl 8) or (p[2] shl 16) or ($FF shl 24))
      else if bytesPerPixel = 4 then
        color := Cardinal(p[0] or (p[1] shl 8) or (p[2] shl 16) or (p[3] shl 24));

      { Never draw pure black, so the logo blends into our own background. }
      if (color and $00FFFFFF) <> 0 then
        fb[QWord(drawY) * QWord(scanLine) + QWord(drawX)] := color;
    end;
  end;
end;

{ ==========================================================================
  PE EXPORT / RELOCATION
  ========================================================================== }
function RvaToOffset(rva: Cardinal; ntHeader: PByte): Cardinal;
var
  numSections, optHeaderSize: Word;
  sectionTable, sec: PByte;
  i: Integer;
  vSize, vAddr, rawPtr: Cardinal;
begin
  numSections := PWord(ntHeader + 6)^;
  optHeaderSize := PWord(ntHeader + 20)^;
  sectionTable := ntHeader + 24 + optHeaderSize;
  for i := 0 to numSections - 1 do
  begin
    sec := sectionTable + (i * 40);
    vSize := PCardinal(sec + 8)^;
    vAddr := PCardinal(sec + 12)^;
    rawPtr := PCardinal(sec + 20)^;
    if (rva >= vAddr) and (rva < vAddr + vSize) then
    begin
      RvaToOffset := rva - vAddr + rawPtr;
      Exit;
    end;
  end;
  RvaToOffset := rva;
end;

function IsKernelMain(name: PByte): Boolean;
begin
  IsKernelMain := (name <> nil) and
    (name[0] = Ord('K')) and (name[1] = Ord('e')) and (name[2] = Ord('r')) and
    (name[3] = Ord('n')) and (name[4] = Ord('n')) and (name[5] = Ord('e')) and
    (name[6] = Ord('l')) and (name[7] = Ord('M')) and (name[8] = Ord('a')) and
    (name[9] = Ord('i')) and (name[10] = Ord('n')) and (name[11] = 0);
end;

{ Walk the PE export directory for the real address of KernelMain, which the
  linker may have placed anywhere once relocations have been applied. }
function GetKernelRealEntryPoint(imageBase: Pointer): Pointer;
var
  basePtr, nt, exportDir: PByte;
  exportRVA, addressOfFunctionsRVA, addressOfNamesRVA: Cardinal;
  addressOfNameOrdinalsRVA, numberOfNames: Cardinal;
  addressOfFunctions: PCardinal;
  addressOfNames: PCardinal;
  addressOfNameOrdinals: PWord;
  e_lfanew: LongInt;
  i: Cardinal;
  ordinal: Word;
  funcRVA: Cardinal;
begin
  basePtr := PByte(imageBase);
  e_lfanew := PLongInt(basePtr + $3C)^;
  nt := basePtr + e_lfanew;
  exportRVA := PCardinal(nt + 136)^;
  if exportRVA = 0 then
  begin
    GetKernelRealEntryPoint := nil;
    Exit;
  end;

  exportDir := basePtr + exportRVA;
  numberOfNames := PCardinal(exportDir + 24)^;
  addressOfFunctionsRVA := PCardinal(exportDir + 28)^;
  addressOfNamesRVA := PCardinal(exportDir + 32)^;
  addressOfNameOrdinalsRVA := PCardinal(exportDir + 36)^;

  addressOfFunctions := PCardinal(basePtr + addressOfFunctionsRVA);
  addressOfNames := PCardinal(basePtr + addressOfNamesRVA);
  addressOfNameOrdinals := PWord(basePtr + addressOfNameOrdinalsRVA);

  for i := 0 to numberOfNames - 1 do
  begin
    if IsKernelMain(PByte(basePtr + addressOfNames[i])) then
    begin
      ordinal := addressOfNameOrdinals[i];
      funcRVA := addressOfFunctions[ordinal];
      GetKernelRealEntryPoint := Pointer(basePtr + funcRVA);
      Exit;
    end;
  end;
  GetKernelRealEntryPoint := nil;
end;

{ ==========================================================================
  ENTRY POINT
  ========================================================================== }
procedure NekkoBoot(imageHandle: Pointer; systemTable: Pointer); cdecl;
var
  st: PEfiSystemTable;
  bs: PEfiBootServices;
  rs: PEfiRuntimeServices;
  conOut: PEfiSimpleTextOutput;

  frameBuffer: PCardinal;
  frameBufferSize, width, height, scanLine: Cardinal;

  { SMP trampoline reservation at 0x8000 (AllocateAddress below 1 MiB). }
  smpHolyLand: QWord;
  reserveStatus: QWord;

  memoryMapSize, mapKey, descriptorSize: QWord;
  descriptorVersion: Cardinal;
  memoryMap, finalMemoryMap: PEfiMemoryDescriptor;
  mapPtr: PByte;
  buffer, finalBuffer: Pointer;
  totalPages, numEntries, totalMB, allocatedMapCapacity: QWord;
  i: QWord;

  rsdpAddress: QWord;
  guid: PEfiGuid;
  entry: PEfiConfigurationTable;

  gopInterface: Pointer;
  status: QWord;
  gop: PEfiGraphicsOutput;

  loadedImage: PEfiLoadedImage;
  fileSystem: PEfiSimpleFileSystem;
  rootDir, kernelFile: PEfiFileProtocol;
  openStatus: LongInt;

  infoSize, actualFileSize: QWord;
  infoBuffer, tempBuffer: Pointer;

  sigFile: PEfiFileProtocol;
  sigBuffer: array[0..255] of Byte;
  sigSize: QWord;
  computedHash: array[0..31] of Byte;
  decryptedSig: array[0..255] of Byte;
  rsaBuffer: Pointer;
  S_buf, N_buf, Res_buf, tempMul_buf, baseS_buf: PCardinal;

  isVerified: Boolean;

  raw, nt, kBase, sec, relocDir: PByte;
  e_lfanew: LongInt;
  sizeOfImage, sizeOfHeaders, numSections, optHeaderSize: Cardinal;
  pages, kernelBase, maxAddress, minAddress, originalImageBase: QWord;
  allocStatus: QWord;
  vAddr, rawSize, rawPtr: Cardinal;
  j: Cardinal;
  delta: Int64;
  relocRVA, relocSize, bytesParsed, pageRva, blockSize: Cardinal;
  relocEntriesCount: Cardinal;
  entries: PWord;
  entryWord, relocType, relocOffset: Word;
  targetAddr: QWord;

  realEntry: Pointer;
  bootInfo: PNekkoBootInfo;
  finalMemoryMapSize, finalMapKey, finalDescriptorSize: QWord;
  finalDescriptorVersion: Cardinal;
  exitStatus: QWord;
  kernelMain: TfnKernelMain;

  magicKey: Char;
  cmd: Char;
  debugging: Boolean;
  nl, one: PWord;
  dumpAddr: QWord;
  ptr64: PQWord;
  port: Word;
  val, hrs, mins, secs: Byte;
  cols, targetRow, pad1, pad2, pad3, pad4, cx, cy, r, x, y: LongInt;
  padLoop, lineLoop: LongInt;
  color, offset: Cardinal;
begin
  SerialInit;

  st := PEfiSystemTable(systemTable);
  bs := st^.BootServices;
  rs := st^.RuntimeServices;
  conOut := st^.ConOut;

  frameBuffer := nil;
  frameBufferSize := 0;
  width := 0;
  height := 0;
  scanLine := 0;

  Uefi_SetAttribute(conOut, $0A);

  { ---------------------------------------------------------- }
  { Reserve the SMP trampoline pages at exactly 0x8000 so UEFI  }
  { hands them to us and keeps its own allocations away.       }
  { ---------------------------------------------------------- }
  smpHolyLand := $8000;
  reserveStatus := Uefi_AllocatePages(bs, 2, 2, 2, @smpHolyLand);
  if reserveStatus = 0 then
    Print(conOut, U16('[+] SMP Memory Land (0x8000-0x9FFF) Reserved Successfully!'#13#10))
  else
    Print(conOut, U16('[-] WARNING: 0x8000 is currently occupied by UEFI!'#13#10));

  Uefi_SetAttribute(conOut, $0E);

  { ---------------------------------------------------------- }
  { Memory map, sized with headroom because the map itself      }
  { grows as the allocations above land.                        }
  { ---------------------------------------------------------- }
  memoryMapSize := 0;
  memoryMap := nil;
  mapKey := 0;
  descriptorSize := 0;
  descriptorVersion := 0;
  Uefi_GetMemoryMap(bs, @memoryMapSize, nil, @mapKey, @descriptorSize,
                    @descriptorVersion);
  memoryMapSize := memoryMapSize + (descriptorSize * 4);
  buffer := nil;
  Uefi_AllocatePool(bs, 2, memoryMapSize, @buffer);
  memoryMap := PEfiMemoryDescriptor(buffer);
  Uefi_GetMemoryMap(bs, @memoryMapSize, @buffer, @mapKey, @descriptorSize,
                    @descriptorVersion);

  totalPages := 0;
  numEntries := memoryMapSize div descriptorSize;
  mapPtr := PByte(memoryMap);
  for i := 0 to numEntries - 1 do
  begin
    totalPages := totalPages +
      PEfiMemoryDescriptor(mapPtr + (i * descriptorSize))^.NumberOfPages;
  end;

  totalMB := (totalPages * 4096) div (1024 * 1024);

  Print(conOut, U16('Total RAM: '));
  PrintNumber(conOut, totalMB);
  Print(conOut, U16(' MB'#13#10'RAM detect OK!'#13#10));

  Uefi_SetAttribute(conOut, $0F);

  { ---------------------------------------------------------- }
  { ACPI RSDP: prefer 2.0, fall back to the 1.0 table.         }
  { ---------------------------------------------------------- }
  rsdpAddress := 0;
  for i := 0 to st^.NumberOfTableEntries - 1 do
  begin
    entry := @st^.ConfigurationTable[i];
    guid := @entry^.VendorGuid;
    if (guid^.Data1 = GUID_ACPI20.Data1) and (guid^.Data2 = GUID_ACPI20.Data2) and
       (guid^.Data3 = GUID_ACPI20.Data3) and (guid^.D4_0 = GUID_ACPI20.D4_0) then
    begin
      rsdpAddress := QWord(entry^.VendorTable);
      Print(conOut, U16('[+] ACPI 2.0 RSDP Found at '));
      PrintHex(conOut, rsdpAddress);
      Print(conOut, U16(#13#10));
      Break;
    end
    else if (guid^.Data1 = GUID_ACPI10.Data1) and (guid^.Data2 = GUID_ACPI10.Data2) and
            (guid^.Data3 = GUID_ACPI10.Data3) and (guid^.D4_0 = GUID_ACPI10.D4_0) then
    begin
      rsdpAddress := QWord(entry^.VendorTable);
    end;
  end;

  if rsdpAddress = 0 then
    Print(conOut, U16('[-] WARNING: ACPI RSDP NOT FOUND IN UEFI TABLES!'#13#10));

  { ---------------------------------------------------------- }
  { Turn the GOP on, black the screen, and blit the OEM BGRT    }
  { logo over it so the kernel load is hidden behind the logo.  }
  { ---------------------------------------------------------- }
  gopInterface := nil;
  status := Uefi_LocateProtocol(bs, @GUID_GOP, nil, @gopInterface);

  if status = 0 then
  begin
    gop := PEfiGraphicsOutput(gopInterface);
    width := gop^.Mode^.Info^.HorizontalResolution;
    height := gop^.Mode^.Info^.VerticalResolution;
    scanLine := gop^.Mode^.Info^.PixelsPerScanLine;
    frameBuffer := PCardinal(Pointer(gop^.Mode^.FrameBufferBase));
    frameBufferSize := gop^.Mode^.FrameBufferSize;

    for i := 0 to (frameBufferSize div 4) - 1 do
      frameBuffer[i] := $FF000000;

    DrawOEMLogo(rsdpAddress, frameBuffer, width, height, scanLine);
  end;

  { ---------------------------------------------------------- }
  { Open the ESP and pull Kernel.exe into boot-pool memory.      }
  { ---------------------------------------------------------- }
  loadedImage := nil;
  Uefi_HandleProtocol(bs, imageHandle, @GUID_LOADED_IMAGE, PPointer(@loadedImage));

  fileSystem := nil;
  Uefi_HandleProtocol(bs, PEfiLoadedImage(loadedImage)^.DeviceHandle,
                      @GUID_SIMPLE_FS, PPointer(@fileSystem));

  rootDir := nil;
  Uefi_OpenVolume(fileSystem, @rootDir);

  kernelFile := nil;
  openStatus := LongInt(Uefi_FileOpen(rootDir, @kernelFile, U16('Kernel.exe'), 1, 0));
  if openStatus <> 0 then
  begin
    Print(conOut, U16('LOI: Khong tim thay Kernel.exe tren dia!'#13#10));
    while true do ;
  end;

  infoSize := 0;
  Uefi_FileGetInfo(kernelFile, @GUID_FILE_INFO, @infoSize, nil);
  infoBuffer := nil;
  Uefi_AllocatePool(bs, 2, infoSize, @infoBuffer);
  Uefi_FileGetInfo(kernelFile, @GUID_FILE_INFO, @infoSize, infoBuffer);

  actualFileSize := PEfiFileInfo(infoBuffer)^.FileSize;
  Uefi_FreePool(bs, infoBuffer);

  tempBuffer := nil;
  Uefi_AllocatePool(bs, 2, actualFileSize, @tempBuffer);
  if tempBuffer = nil then
  begin
    Print(conOut, U16('LOI: Khong du bo nho de doc Kernel.exe!'#13#10));
    while true do ;
  end;

  Uefi_FileRead(kernelFile, @actualFileSize, tempBuffer);
  Uefi_FileClose(kernelFile);

  { ==========================================================
    [VERIFIED BOOT TIER 2] RSA-2048 SIGNATURE VERIFICATION
    ========================================================== }
  isVerified := True;

  sigFile := nil;
  status := Uefi_FileOpen(rootDir, @sigFile, U16('\Kernel.exe.mui'), 1, 0);

  if (status <> 0) or (sigFile = nil) then
  begin
    isVerified := False;
  end
  else
  begin
    sigSize := 256;
    Uefi_FileRead(sigFile, @sigSize, @sigBuffer[0]);
    Uefi_FileClose(sigFile);

    Sha256Compute(PByte(tempBuffer), actualFileSize, @computedHash[0]);

    { Scratch space for the bignum limbs, carved out of one pool:
      S(256) + N(256) + Res(256) + tempMul(512) + baseS(256) = 1536 bytes,
      2048 allocated so the RSA work never touches the boot stack. }
    rsaBuffer := nil;
    Uefi_AllocatePool(bs, 2, 2048, @rsaBuffer);

    S_buf := PCardinal(rsaBuffer);
    N_buf := S_buf + 64;
    Res_buf := N_buf + 64;
    tempMul_buf := Res_buf + 64;
    baseS_buf := tempMul_buf + 128;

    RsaVerifySignature(@sigBuffer[0], @Boot_PublicKeyN[0], @decryptedSig[0],
                       S_buf, N_buf, Res_buf, tempMul_buf, baseS_buf);

    Uefi_FreePool(bs, rsaBuffer);

    { PKCS#1 v1.5 padding: 00 01 FF..FF 00 DigestInfo }
    if (decryptedSig[0] <> $00) or (decryptedSig[1] <> $01) then
      isVerified := False;
    for i := 2 to 203 do
      if decryptedSig[i] <> $FF then isVerified := False;
    if decryptedSig[204] <> $00 then isVerified := False;

    { ASN.1 prefix identifying SHA-256 (OID 2.16.840.1.101.3.4.2.1). }
    if (decryptedSig[205] <> $30) or (decryptedSig[206] <> $31) or
       (decryptedSig[207] <> $30) or (decryptedSig[208] <> $0D) or
       (decryptedSig[209] <> $06) or (decryptedSig[210] <> $09) or
       (decryptedSig[211] <> $60) or (decryptedSig[212] <> $86) or
       (decryptedSig[213] <> $48) or (decryptedSig[214] <> $01) or
       (decryptedSig[215] <> $65) or (decryptedSig[216] <> $03) or
       (decryptedSig[217] <> $04) or (decryptedSig[218] <> $02) or
       (decryptedSig[219] <> $01) or (decryptedSig[220] <> $05) or
       (decryptedSig[221] <> $00) or (decryptedSig[222] <> $04) or
       (decryptedSig[223] <> $20) then
      isVerified := False;

    { The decrypted digest has to equal the one we just computed. }
    for i := 0 to 31 do
      if decryptedSig[224 + i] <> computedHash[i] then
        isVerified := False;
  end;

  if not isVerified then
  begin
    { ==========================================================
      [TỬ HÌNH MỸ THUẬT] ANDROID VERIFIED BOOT FAILURE SCREEN
      ========================================================== }
    Uefi_EnableCursor(conOut, False);
    Uefi_SetAttribute(conOut, $0F);
    Uefi_ClearScreen(conOut);

    cx := LongInt(width div 2);
    cy := LongInt(height div 3);
    r := 40;

    if frameBuffer <> nil then
    begin
      for i := 0 to (frameBufferSize div 4) - 1 do
        frameBuffer[i] := $FF000000;

      for y := -r to r do
        for x := -r to r do
          if (x * x + y * y) <= (r * r) then
          begin
            color := $FFDD0000;
            if (x >= -5) and (x <= 5) and (y >= -20) and (y <= 5) then
              color := $FF000000;
            if (x >= -5) and (x <= 5) and (y >= 15) and (y <= 25) then
              color := $FF000000;
            offset := Cardinal((cy + y) * LongInt(scanLine) + (cx + x));
            frameBuffer[offset] := color;
          end;
    end;

    { Vertically centre the text under the icon: UEFI text lines are
      roughly 16 pixels tall, so the row count is pure arithmetic. }
    cols := LongInt(width div 8);
    targetRow := (cy + r + 1) div 16;

    one := U16(' ');
    nl := U16(#13#10);
    for lineLoop := 0 to targetRow - 1 do Print(conOut, nl);

    pad1 := (cols - 22) div 2;
    for padLoop := 0 to pad1 - 1 do Print(conOut, one);
    Uefi_SetAttribute(conOut, $0C);
    Print(conOut, U16('YOUR DEVICE IS CORRUPT'#13#10#13#10));

    pad2 := (cols - 39) div 2;
    for padLoop := 0 to pad2 - 1 do Print(conOut, one);
    Uefi_SetAttribute(conOut, $0F);
    Print(conOut, U16('It cannot be trusted and will not boot.'#13#10));

    pad3 := (cols - 38) div 2;
    for padLoop := 0 to pad3 - 1 do Print(conOut, one);
    Print(conOut, U16('Please re-flash genuine NekkoOS image.'#13#10));

    Print(conOut, U16(#13#10));
    pad4 := (cols - 8) div 2;
    for padLoop := 0 to pad4 - 1 do Print(conOut, one);
    Uefi_SetAttribute(conOut, $08);
    Print(conOut, U16('g.co/ABH'#13#10));

    while true do ;
  end;

  { ==========================================================
    KASLR + PE LOAD
    ========================================================== }
  raw := PByte(tempBuffer);
  e_lfanew := PLongInt(raw + $3C)^;
  nt := raw + e_lfanew;
  sizeOfImage := PCardinal(nt + 80)^;
  sizeOfHeaders := PCardinal(nt + 84)^;
  pages := (QWord(sizeOfImage) + 4095) div 4096;
  kernelBase := 0;

  maxAddress := 0;
  for i := 0 to numEntries - 1 do
  begin
    if PEfiMemoryDescriptor(mapPtr + (i * descriptorSize))^.MemType = 7 then
    begin
      if PEfiMemoryDescriptor(mapPtr + (i * descriptorSize))^.PhysicalStart +
         (PEfiMemoryDescriptor(mapPtr + (i * descriptorSize))^.NumberOfPages * 4096)
         > maxAddress then
        maxAddress := PEfiMemoryDescriptor(mapPtr + (i * descriptorSize))^.PhysicalStart +
                     (PEfiMemoryDescriptor(mapPtr + (i * descriptorSize))^.NumberOfPages * 4096);
    end;
  end;

  { Keep the kernel under 1 GiB so the 32-bit SMP trampoline can still
    address it. }
  if maxAddress > $40000000 then maxAddress := $40000000;
  if maxAddress < $02000000 then maxAddress := $40000000;

  minAddress := $02000000;
  maxAddress := maxAddress - (QWord(sizeOfImage) + $100000);

  for i := 1 to 999 do
  begin
    kernelBase := BootRandom(st, minAddress, maxAddress) and QWord($FFFFFFFFFFFFF000);
    allocStatus := Uefi_AllocatePages(bs, 2, 2, pages, @kernelBase);
    if allocStatus = 0 then Break;
  end;

  if allocStatus <> 0 then
  begin
    Print(conOut, U16('Failed to find RAM space!'#13#10));
    while true do ;
  end;

  kBase := PByte(kernelBase);
  for i := 0 to QWord(sizeOfImage) - 1 do kBase[i] := 0;
  for j := 0 to sizeOfHeaders - 1 do kBase[j] := raw[j];

  numSections := PCardinal(nt + 6)^ and $FFFF;
  optHeaderSize := PCardinal(nt + 20)^ and $FFFF;
  sec := nt + 24 + optHeaderSize;
  for i := 0 to QWord(numSections) - 1 do
  begin
    vAddr := PCardinal(sec + 12)^;
    rawSize := PCardinal(sec + 16)^;
    rawPtr := PCardinal(sec + 20)^;
    if rawSize > 0 then
      for j := 0 to rawSize - 1 do
        kBase[vAddr + j] := raw[rawPtr + j];
    Inc(sec, 40);
  end;

  originalImageBase := PQWord(nt + 24 + 24)^;
  delta := Int64(kernelBase) - Int64(originalImageBase);

  if delta <> 0 then
  begin
    relocRVA := PCardinal(nt + 176)^;
    relocSize := PCardinal(nt + 180)^;
    if relocRVA <> 0 then
    begin
      relocDir := kBase + relocRVA;
      bytesParsed := 0;
      while bytesParsed < relocSize do
      begin
        pageRva := PCardinal(relocDir + bytesParsed)^;
        blockSize := PCardinal(relocDir + bytesParsed + 4)^;
        if blockSize = 0 then Break;
        relocEntriesCount := (blockSize - 8) div 2;
        entries := PWord(relocDir + bytesParsed + 8);

        if relocEntriesCount > 10000 then Break;

        for i := 0 to QWord(relocEntriesCount) - 1 do
        begin
          entryWord := entries[i];
          relocType := entryWord shr 12;
          relocOffset := entryWord and $FFF;

          { Type 10 = IMAGE_REL_AMD64_ADDR64 (64-bit absolute)
            Type 3  = IMAGE_REL_AMD64_ADDR32 (32-bit absolute)
            Type 4  = IMAGE_REL_AMD64_REL32  - RIP-relative, needs no
                      adjustment because both ends move with the image. }
          if relocType = 10 then
          begin
            targetAddr := QWord(kBase) + QWord(pageRva) + QWord(relocOffset);
            if (targetAddr >= QWord(kBase)) and
               (targetAddr < QWord(kBase) + QWord(sizeOfImage)) then
              PQWord(targetAddr)^ := PQWord(targetAddr)^ + QWord(delta);
          end
          else if relocType = 3 then
          begin
            targetAddr := QWord(kBase) + QWord(pageRva) + QWord(relocOffset);
            if (targetAddr >= QWord(kBase)) and
               (targetAddr < QWord(kBase) + QWord(sizeOfImage)) then
              PCardinal(targetAddr)^ := PCardinal(targetAddr)^ + Cardinal(delta);
          end;
        end;
        bytesParsed := bytesParsed + blockSize;
      end;
    end;
  end;

  Uefi_FreePool(bs, tempBuffer);

  Print(conOut, U16('[BOOT] kernelBase = '));
  PrintHex(conOut, kernelBase);
  Print(conOut, U16(#13#10));

  realEntry := GetKernelRealEntryPoint(Pointer(kernelBase));
  Print(conOut, U16('[BOOT] realEntry = '));
  PrintHex(conOut, QWord(realEntry));
  Print(conOut, U16(#13#10));

  if realEntry = nil then
  begin
    Print(conOut, U16('ERROR: KernelMain not found!'#13#10));
    while true do ;
  end;

  { ---------------------------------------------------------- }
  { Boot contract: build the final memory map, then hand it and  }
  { the resolved video state to the kernel.                     }
  { ---------------------------------------------------------- }
  bootInfo := nil;
  Uefi_AllocatePool(bs, 6, QWord(SizeOf(TNekkoBootInfo)), PPointer(@bootInfo));

  finalMemoryMapSize := 0;
  finalMemoryMap := nil;
  finalMapKey := 0;
  finalDescriptorSize := 0;
  finalDescriptorVersion := 0;
  Uefi_GetMemoryMap(bs, @finalMemoryMapSize, nil, @finalMapKey,
                    @finalDescriptorSize, @finalDescriptorVersion);
  allocatedMapCapacity := finalMemoryMapSize + (finalDescriptorSize * 8);

  finalBuffer := nil;
  Uefi_AllocatePool(bs, 6, allocatedMapCapacity, @finalBuffer);
  finalMemoryMap := PEfiMemoryDescriptor(finalBuffer);

  finalMemoryMapSize := allocatedMapCapacity;
  Uefi_GetMemoryMap(bs, @finalMemoryMapSize, @finalBuffer, @finalMapKey,
                    @finalDescriptorSize, @finalDescriptorVersion);

  bootInfo^.FrameBufferBase := QWord(frameBuffer);
  bootInfo^.FrameBufferSize := QWord(frameBufferSize);
  bootInfo^.HorizontalResolution := width;
  bootInfo^.VerticalResolution := height;
  bootInfo^.PixelsPerScanLine := scanLine;
  bootInfo^.MemoryMap := finalMemoryMap;
  bootInfo^.MemoryMapSize := finalMemoryMapSize;
  bootInfo^.DescriptorSize := finalDescriptorSize;
  bootInfo^.AcpiRsdp := rsdpAddress;

  { ==========================================================
    [DEBUG] Debugger handshake: 2 second window on COM1 looking
    for 'D'. Anything else drops straight into production mode.
    ========================================================== }
  magicKey := SerialReadCharWithTimeout(bs, 2000);

  if (magicKey = 'D') or (magicKey = 'd') then
  begin
    Print(conOut, U16(#13#10'[DEBUG] DEBUGGER ATTACHED!'#13#10));
    Print(conOut, U16('Type ''H'' for Help.'#13#10));

    debugging := True;
    nl := U16(#13#10);
    one := U16(' ');
    while debugging do
    begin
      Print(conOut, U16('NekkoBoot> '));

      cmd := SerialReadChar;
      SerialWriteChar(cmd);
      Print(conOut, nl);

      case cmd of
        'C', 'c':
          begin
            Print(conOut, U16('[DEBUG] Resuming boot sequence...'#13#10));
            debugging := False;
          end;

        'R', 'r':
          begin
            Print(conOut, U16('[DEBUG] Cold Rebooting System...'#13#10));
            Uefi_ResetSystem(rs, 0, nil, 0, nil);
            while true do ;
          end;

        'M', 'm':
          begin
            Print(conOut, U16('[DEBUG] Kernel Base Address : '));
            PrintHex(conOut, kernelBase);
            Print(conOut, U16(#13#10'[DEBUG] ACPI RSDP Address   : '));
            PrintHex(conOut, rsdpAddress);
            Print(conOut, nl);
          end;

        { Dump 16 bytes of physical memory. }
        'D', 'd':
          begin
            Print(conOut, U16('Enter Physical Address (Hex): 0x'));
            dumpAddr := SerialReadHex;

            ptr64 := PQWord(dumpAddr);

            Print(conOut, U16('[DEBUG] Dump 16-bytes at '));
            PrintHex(conOut, dumpAddr);
            Print(conOut, U16(' => '));

            PrintHex(conOut, ptr64[0]);
            Print(conOut, U16('  '));
            PrintHex(conOut, ptr64[1]);
            Print(conOut, nl);
          end;

        { Read one I/O port. }
        'I', 'i':
          begin
            Print(conOut, U16('Enter I/O Port (Hex): 0x'));
            port := Word(SerialReadHex);
            val := In8(port);

            Print(conOut, U16('[DEBUG] Port 0x'));
            PrintHex(conOut, QWord(port));
            Print(conOut, U16(' = 0x'));
            PrintHex(conOut, QWord(val));
            Print(conOut, nl);
          end;

        { Raw CMOS RTC read, proves port I/O actually works. }
        'T', 't':
          begin
            Out8($70, $04);
            hrs := In8($71);
            Out8($70, $02);
            mins := In8($71);
            Out8($70, $00);
            secs := In8($71);

            Print(conOut, U16('[DEBUG] Raw RTC Time (BCD): '));
            PrintHex(conOut, QWord(hrs));
            Print(conOut, one);
            PrintHex(conOut, QWord(mins));
            Print(conOut, one);
            PrintHex(conOut, QWord(secs));
            Print(conOut, nl);
          end;

        { GOP framebuffer state. }
        'G', 'g':
          begin
            Print(conOut, U16('[DEBUG] FrameBuffer Base : '));
            PrintHex(conOut, bootInfo^.FrameBufferBase);
            Print(conOut, U16(#13#10'[DEBUG] Resolution       : '));
            PrintNumber(conOut, QWord(bootInfo^.HorizontalResolution));
            Print(conOut, U16(' x '));
            PrintNumber(conOut, QWord(bootInfo^.VerticalResolution));
            Print(conOut, nl);
          end;

        'H', 'h':
          Print(conOut, U16('Commands:'#13#10' [C]ontinue Boot'#13#10' [R]eboot'#13#10' [M]emory Base'#13#10' [D]ump RAM (Hex)'#13#10' [I]N Port (Hex)'#13#10' [T]ime RTC'#13#10' [G]OP Video Info'#13#10' [H]elp'#13#10));

        else
          Print(conOut, U16('Unknown command. Press ''H''.'#13#10));
      end;
    end;
  end
  else
  begin
    Print(conOut, U16('[BOOT] No Debugger detected. Booting Production Mode...'#13#10));
  end;

  { ---------------------------------------------------------- }
  { Leave boot services and jump to the kernel.                 }
  { ---------------------------------------------------------- }
  exitStatus := Uefi_ExitBootServices(bs, imageHandle, finalMapKey);
  if exitStatus <> 0 then
  begin
    { The map key went stale, so the spec allows exactly one retry with a
      freshly fetched map. }
    finalMemoryMapSize := allocatedMapCapacity;
    Uefi_GetMemoryMap(bs, @finalMemoryMapSize, @finalBuffer, @finalMapKey,
                      @finalDescriptorSize, @finalDescriptorVersion);
    bootInfo^.MemoryMapSize := finalMemoryMapSize;
    exitStatus := Uefi_ExitBootServices(bs, imageHandle, finalMapKey);
    if exitStatus <> 0 then while true do ;
  end;

  kernelMain := TfnKernelMain(realEntry);
  kernelMain(bootInfo);

  while true do ;
end;

end.
