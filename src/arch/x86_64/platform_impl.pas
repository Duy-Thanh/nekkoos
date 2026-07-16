unit platform_impl;

{ x86_64 Implementation of HAL Platform Interface

  Implements platform control for x86_64:
  - CPU information (CPUID vendor/model)
  - Power management (reboot/shutdown via ports)
  - Early serial output (COM1 port 0x3F8)
  - Hardware random number generator (RDRAND)
  - Performance counters (RDTSC)

  This provides the implementation for the HAL platform interface
  documented in src/arch/hal/platform.pas }

{$MODE FPC}
{$ASMMODE Intel}
{$M-}

interface

type
  TPlatformType = (ptX86_64, ptARM64, ptRISCV64);

function  HAL_GetPlatformType: TPlatformType; cdecl; public name 'HAL_GetPlatformType';
function  HAL_GetPlatformName: PChar; cdecl; public name 'HAL_GetPlatformName';
function  HAL_GetCPUVendor: PChar; cdecl; public name 'HAL_GetCPUVendor';
function  HAL_GetCPUModel: PChar; cdecl; public name 'HAL_GetCPUModel';
procedure HAL_EarlyInit; cdecl; public name 'HAL_EarlyInit';
procedure HAL_InitFirmware; cdecl; public name 'HAL_InitFirmware';
function  HAL_GetCoreCount: Cardinal; cdecl; public name 'HAL_GetCoreCount';
procedure HAL_Reboot; cdecl; public name 'HAL_Reboot';
procedure HAL_Shutdown; cdecl; public name 'HAL_Shutdown';
procedure HAL_InitEarlySerial; cdecl; public name 'HAL_InitEarlySerial';
procedure HAL_DebugWrite(str: PChar); cdecl; public name 'HAL_DebugWrite';
procedure HAL_DebugWriteChar(c: Char); cdecl; public name 'HAL_DebugWriteChar';
function  HAL_GetHardwareRandom(buffer: Pointer; length: Cardinal): Cardinal; cdecl; public name 'HAL_GetHardwareRandom';
function  HAL_ReadCycleCounter: QWord; cdecl; public name 'HAL_ReadCycleCounter';

implementation

{ AAL Layer 1 primitives }
procedure Arch_WritePort8(port: Word; value: Byte); cdecl; external name 'Arch_WritePort8';
function  Arch_ReadPort8(port: Word): Byte; cdecl; external name 'Arch_ReadPort8';
procedure Arch_WritePort16(port: Word; value: Word); cdecl; external name 'Arch_WritePort16';
function  Arch_ReadTimestamp: QWord; cdecl; external name 'Arch_ReadTimestamp';

const
  COM1 = $3F8;

function HAL_GetPlatformType: TPlatformType; cdecl;
begin
  HAL_GetPlatformType := ptX86_64;
end;

function HAL_GetPlatformName: PChar; cdecl;
begin
  HAL_GetPlatformName := 'x86_64 PC (UEFI)';
end;

function HAL_GetCPUVendor: PChar; cdecl;
var
  ebx, ecx, edx: Cardinal;
  vendor: array[0..12] of Char;
begin
  vendor[12] := #0;
  asm
    mov eax, 0
    cpuid
    mov ebx, ebx
    mov ecx, ecx
    mov edx, edx
  end;
  { Pack characters into string }
  PCardinal(@vendor[0])^ := ebx;
  PCardinal(@vendor[4])^ := edx;
  PCardinal(@vendor[8])^ := ecx;
  HAL_GetCPUVendor := @vendor[0];
end;

function HAL_GetCPUModel: PChar; cdecl;
begin
  HAL_GetCPUModel := 'Intel/AMD x86_64 Processor';
end;

procedure HAL_EarlyInit; cdecl;
begin
  { Minimal GDT/IDT is handled in C# early boot for now }
end;

procedure HAL_InitFirmware; cdecl;
begin
  { ACPI Parsing is handled in C# for now }
end;

function HAL_GetCoreCount: Cardinal; cdecl;
begin
  { Count retrieved from ACPI MADT in C# }
  HAL_GetCoreCount := 2; { Placeholder, actual managed in SMP.cs }
end;

procedure HAL_Reboot; cdecl;
var
  temp: Byte;
begin
  { 1. Try 8042 Keyboard Controller Reset }
  temp := Arch_ReadPort8($64);
  while (temp and 2) <> 0 do
    temp := Arch_ReadPort8($64);
  Arch_WritePort8($64, $FE);

  { 2. Fallback to ACPI reset register port (0xCF9) }
  Arch_WritePort8($CF9, $06);
end;

procedure HAL_Shutdown; cdecl;
begin
  { ACPI Shutdown: PM1a_CNT writes are executed via ACPI Daemon in C# }
  { Fallback to QEMU shutdown ports if running under QEMU }
  Arch_WritePort16($604, $2000);  { Bochs/QEMU ACPI Shutdown }
  Arch_WritePort16($B004, $2000); { Older QEMU ACPI Shutdown }
  Arch_WritePort16($4004, $3400); { VirtualBox Shutdown }
end;

procedure HAL_InitEarlySerial; cdecl;
begin
  Arch_WritePort8(COM1 + 1, $00);    { Disable all interrupts }
  Arch_WritePort8(COM1 + 3, $80);    { Enable DLAB (set baud rate divisor) }
  Arch_WritePort8(COM1 + 0, $03);    { Set divisor to 3 (lo byte) 38400 baud }
  Arch_WritePort8(COM1 + 1, $00);    {                  (hi byte) }
  Arch_WritePort8(COM1 + 3, $03);    { 8 bits, no parity, one stop bit }
  Arch_WritePort8(COM1 + 2, $C7);    { Enable FIFO, clear them }
  Arch_WritePort8(COM1 + 4, $0B);    { IRQs enabled, RTS/DSR set }
end;

procedure HAL_DebugWriteChar(c: Char); cdecl;
begin
  while (Arch_ReadPort8(COM1 + 5) and $20) = 0 do ;
  Arch_WritePort8(COM1, Byte(c));
end;

procedure HAL_DebugWrite(str: PChar); cdecl;
var
  i: Integer;
begin
  i := 0;
  while str[i] <> #0 do
  begin
    if str[i] = #10 then
      HAL_DebugWriteChar(#13);
    HAL_DebugWriteChar(str[i]);
    Inc(i);
  end;
end;

function HAL_GetHardwareRandom(buffer: Pointer; length: Cardinal): Cardinal; cdecl;
var
  i: Cardinal;
  val: QWord;
  success: Byte;
  buf: PByte;
  supported: Cardinal;
begin
  { Check CPUID EAX=1 ECX Bit 30 (RDRAND support) }
  asm
    mov eax, 1
    cpuid
    mov supported, ecx
  end;
  if (supported and (1 shl 30)) = 0 then
  begin
    HAL_GetHardwareRandom := 0;
    Exit;
  end;

  buf := PByte(buffer);
  i := 0;
  while i < length do
  begin
    asm
      db $48, $0F, $C7, $F0  { RDRAND RAX }
      setc success
      mov val, rax
    end;
    if success = 1 then
    begin
      { Copy random bytes }
      if length - i >= 8 then
      begin
        PQWord(buf + i)^ := val;
        Inc(i, 8);
      end
      else
      begin
        buf[i] := Byte(val);
        Inc(i);
      end;
    end
    else
    begin
      { RDRAND failed to generate entropy in time }
      Break;
    end;
  end;
  HAL_GetHardwareRandom := i;
end;

function HAL_ReadCycleCounter: QWord; cdecl;
begin
  HAL_ReadCycleCounter := Arch_ReadTimestamp();
end;

end.
