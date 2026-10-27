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

uses arch_interface, arch_hal;

procedure Puts(s: PChar);
begin
  while s^ <> #0 do
  begin
    if s^ = #10 then Arch_WriteMmio32(QWord($09000000), 13);
    Arch_WriteMmio32(QWord($09000000), Ord(s^));
    Inc(s);
  end;
end;

procedure Arm64Main; cdecl; public name 'Arm64Main';
var
  t0: QWord;
begin
  Hal_EarlyInit;
  t0 := Hal_Ticks;
  while Hal_Ticks < t0 + Hal_MsToTicks(100) do ;
  Puts('arm64: 100 ms elapsed on the generic counter, core id ');
  Arch_WriteMmio32(QWord($09000000), Ord('0') + Hal_CurrentCoreId);
  Puts(#10'arm64: bring-up milestone 1 reached'#10);
  while True do Arch_Halt;
end;

end.
