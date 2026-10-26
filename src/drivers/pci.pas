{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: pci - legacy PCI configuration-space access (ports 0xCF8/0xCFC).
  PORTED FROM: src/drivers/x86-legacy/PCI.cs.

  x86 legacy mechanism #1: write an address to 0xCF8, read or write the
  dword at 0xCFC. The two accesses have to be atomic with respect to every
  other core, hence the lock.
  =========================================================================
}
unit pci;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Read one dword of configuration space. Returns 0 for an out-of-range
  bus/slot/function. }
function Pci_ConfigRead(bus, slot, func: Word; offset: Byte): Cardinal;

{ Print every device that answers on the bus (the `pci` shell builtin). }
procedure Pci_ScanBus;

{ Clear Bus Master Enable on every device that is not a bridge or a display
  adapter. Stops a device DMAing into memory the kernel is about to reuse
  while it boots. }
procedure Pci_DisableAllBusMastering;

implementation

uses arch_interface, console, kstring, spinlock;

const
  PCI_CONFIG_ADDRESS = $CF8;
  PCI_CONFIG_DATA    = $CFC;
  PCI_ENABLE_BIT     = $80000000;

  CLASS_BRIDGE  = $06;
  CLASS_DISPLAY = $03;

var
  PciLock: Cardinal = 0;

procedure Fatal(const msg: AnsiString);
begin
  Con_SetColor($00FF0000);
  Con_Print(W(msg));
end;

function Pci_ConfigRead(bus, slot, func: Word; offset: Byte): Cardinal;
var
  address: Cardinal;
  irq: Byte;
begin
  Pci_ConfigRead := 0;
  if bus > 255 then begin Fatal('[!] FATAL: Invalid PCI bus number!'#13#10); Exit; end;
  if slot > 31 then begin Fatal('[!] FATAL: Invalid PCI slot number!'#13#10); Exit; end;
  if func > 7 then begin Fatal('[!] FATAL: Invalid PCI function number!'#13#10); Exit; end;

  address := (Cardinal(bus) shl 16) or (Cardinal(slot) shl 11) or
             (Cardinal(func) shl 8) or (offset and $FC) or PCI_ENABLE_BIT;

  irq := Spinlock_AcquireSafe_Pas(@PciLock);
  Arch_WritePort32(PCI_CONFIG_ADDRESS, address);
  Pci_ConfigRead := Arch_ReadPort32(PCI_CONFIG_DATA);
  Spinlock_ReleaseSafe_Pas(@PciLock, irq);
end;

procedure Pci_ScanBus;
var
  bus, slot: Word;
  reg0, reg8: Cardinal;
  vendor, device: Word;
  classCode: Byte;
  count: Integer;
begin
  Con_SetColor($00FF00FF);
  Con_Print(W('[*] Scanning PCI Bus for attached hardware...'#13#10));
  Con_SetColor($00FFFFFF);

  count := 0;

  for bus := 0 to 255 do
    for slot := 0 to 31 do
    begin
      reg0 := Pci_ConfigRead(bus, slot, 0, 0);
      vendor := Word(reg0 and $FFFF);

      if vendor = $FFFF then Continue;          { empty slot }

      if vendor = $0000 then
      begin
        Fatal('[!] FATAL: Invalid PCI vendor ID!'#13#10);
        Continue;
      end;

      device := Word(reg0 shr 16);
      if (device = $0000) or (device = $FFFF) then
      begin
        Fatal('[!] FATAL: Invalid PCI device ID!'#13#10);
        Continue;
      end;

      reg8 := Pci_ConfigRead(bus, slot, 0, $08);
      classCode := Byte(reg8 shr 24);
      if classCode = $00 then
      begin
        Fatal('[!] FATAL: Invalid PCI class code!'#13#10);
        Continue;
      end;

      Con_Print(W('B:'));
      Con_PrintHex(bus);
      Con_Print(W(' S:'));
      Con_PrintHex(slot);

      Con_SetColor($00FFFF00);
      Con_Print(W(' | Ven: '));
      Con_PrintHex(vendor);
      Con_Print(W(' Dev: '));
      Con_PrintHex(device);

      Con_SetColor($0000FFFF);
      Con_Print(W(' | Class: '));
      Con_PrintHex(classCode);

      Con_Print(W(#13#10));
      Con_SetColor($00FFFFFF);

      Inc(count);
    end;

  Con_SetColor($0000FF00);
  Con_Print(W('[+] Total PCI devices found: '));
  Con_PrintHex(QWord(count));
  Con_Print(W(#13#10));
end;

procedure Pci_DisableAllBusMastering;
var
  bus, slot, func: Word;
  address, classInfo, cmd: Cardinal;
  baseClass: Cardinal;
begin
  for bus := 0 to 255 do
    for slot := 0 to 31 do
    begin
      { Function 0 decides whether the slot is populated at all. }
      Arch_WritePort32(PCI_CONFIG_ADDRESS,
        (Cardinal(bus) shl 16) or (Cardinal(slot) shl 11) or PCI_ENABLE_BIT);
      Arch_FullFence;
      if (Arch_ReadPort32(PCI_CONFIG_DATA) and $FFFF) = $FFFF then Continue;

      for func := 0 to 7 do
      begin
        address := (Cardinal(bus) shl 16) or (Cardinal(slot) shl 11) or
                   (Cardinal(func) shl 8) or PCI_ENABLE_BIT;
        Arch_WritePort32(PCI_CONFIG_ADDRESS, address);
        Arch_FullFence;

        if (Arch_ReadPort32(PCI_CONFIG_DATA) and $FFFF) = $FFFF then Continue;

        Arch_WritePort32(PCI_CONFIG_ADDRESS, address or $08);
        Arch_FullFence;
        classInfo := Arch_ReadPort32(PCI_CONFIG_DATA);
        baseClass := (classInfo shr 24) and $FF;

        if (baseClass <> CLASS_BRIDGE) and (baseClass <> CLASS_DISPLAY) then
        begin
          Arch_WritePort32(PCI_CONFIG_ADDRESS, address or $04);
          Arch_FullFence;
          cmd := Arch_ReadPort32(PCI_CONFIG_DATA);

          if (cmd and $00000004) <> 0 then
          begin
            cmd := cmd and (not Cardinal($00000004));
            Arch_WritePort32(PCI_CONFIG_ADDRESS, address or $04);
            Arch_FullFence;
            Arch_WritePort32(PCI_CONFIG_DATA, cmd);
          end;
        end;
      end;
    end;
end;

procedure Pci_ScanBus_Pas; cdecl; public name 'Pci_ScanBus_Pas';
begin
  Pci_ScanBus;
end;

procedure Pci_DisableAllBusMastering_Pas; cdecl; public name 'Pci_DisableAllBusMastering_Pas';
begin
  Pci_DisableAllBusMastering;
end;

end.
