{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: boot_arm64 - first Pascal code on ARM64 (called from start.S).

  Bring-up milestone 1: prove the toolchain, the link and the HAL by
  printing on the PL011 UART and reading the counter. This grows into
  KernelMain one HAL phase at a time.
  =========================================================================
}
unit boot_arm64;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

procedure Arm64Main; cdecl;

implementation

uses arch_interface, arch_hal, pmm, fdt;

var
  Arm64_DtbPhys: QWord; external name 'Arm64_DtbPhys';
  KernelEndMarker: Byte; external name '__stack_top';

var
  { One EFI_MEMORY_DESCRIPTOR (48 bytes) describing the free RAM; this is the
    format the generic Pmm_Init consumes. }
  MemMap: array[0..5] of QWord;

procedure Puts(s: PChar);
begin
  while s^ <> #0 do
  begin
    if s^ = #10 then Arch_WriteMmio32(QWord($09000000), 13);
    Arch_WriteMmio32(QWord($09000000), Ord(s^));
    Inc(s);
  end;
end;

procedure PutDec(v: QWord);
var
  buf: array[0..19] of Byte;
  n: Integer;
begin
  n := 0;
  repeat
    buf[n] := Ord('0') + (v mod 10);
    v := v div 10;
    Inc(n);
  until v = 0;
  while n > 0 do
  begin
    Dec(n);
    Arch_WriteMmio32(QWord($09000000), buf[n]);
  end;
end;

procedure Arm64Main; cdecl; public name 'Arm64Main';
var
  t0, ramBase, ramSize, freeStart, ramEnd: QWord;
begin
  Hal_EarlyInit;
  if not Fdt_FindMemory(PByte(Arm64_DtbPhys), ramBase, ramSize) then
  begin
    Puts('arm64: no /memory node in the device tree, dtb at '); PutDec(Arm64_DtbPhys); Puts(' magic '); PutDec(PCardinal(Arm64_DtbPhys)^); Puts(#10);
    while True do Arch_Halt;
  end;
  ramEnd := ramBase + ramSize;
  { Free RAM starts after the kernel image and its boot stack. }
  freeStart := (QWord(@KernelEndMarker) + 4095) and not QWord(4095);
  MemMap[0] := 7;                                   { EfiConventionalMemory }
  MemMap[1] := freeStart;                           { PhysicalStart }
  MemMap[2] := 0;
  MemMap[3] := (ramEnd - freeStart) div 4096;       { NumberOfPages }
  MemMap[4] := 0;
  MemMap[5] := 0;
  Pmm_Init(PByte(@MemMap), 48, 48, freeStart);
  Puts('arm64: RAM ');
  PutDec(ramSize div (1024 * 1024));
  Puts(' MiB, ');
  PutDec(Pmm_GetFreePages);
  Puts(' free pages'#10);
  Hal_InitMemory(ramEnd);
  Puts('arm64: MMU on, kernel address space at ');
  PutDec(Hal_KernelAddressSpace);
  Puts(#10);
  t0 := Hal_Ticks;
  while Hal_Ticks < t0 + Hal_MsToTicks(100) do ;
  Hal_InitInterrupts;
  Hal_StartTimer(Hal_TickFrequency);
  Hal_EnableInterrupts;
  t0 := Hal_Ticks;
  while Hal_Ticks < t0 + Hal_MsToTicks(1000) do Arch_Halt;
  Puts('arm64: timer interrupts in 1 s: ');
  PutDec(Arm64_TimerInterrupts);
  Puts(#10);
  Puts('arm64: 100 ms elapsed on the generic counter, core id ');
  Arch_WriteMmio32(QWord($09000000), Ord('0') + Hal_CurrentCoreId);
  Puts(#10'arm64: bring-up milestone 1 reached'#10);
  while True do Arch_Halt;
end;

end.
