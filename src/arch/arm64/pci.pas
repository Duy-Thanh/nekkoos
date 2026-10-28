{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: pci (ARM64) - same interface as src/drivers/pci.pas.

  x86 reaches PCI configuration space through ports 0xCF8/0xCFC, which do
  not exist here. QEMU virt's PCIe is ECAM above 4 GiB and nothing on this
  port uses it yet (the disk is virtio-mmio), so the scan reports that
  instead of touching x86 ports.
  =========================================================================
}
unit pci;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

function Pci_ConfigRead(bus, slot, func: Word; offset: Byte): Cardinal;
procedure Pci_ScanBus;
procedure Pci_DisableAllBusMastering;

implementation

uses terminal, kstring;

function Pci_ConfigRead(bus, slot, func: Word; offset: Byte): Cardinal;
begin
  Pci_ConfigRead := $FFFFFFFF;          { "no device", as on an empty x86 slot }
end;

procedure Pci_ScanBus;
begin
  Terminal_Print_Pas(W('[*] PCI: no port-I/O configuration space on this architecture (ECAM not used yet)'#13#10));
  Terminal_Print_Pas(W('Total PCI devices found: 0'#13#10));
end;

procedure Pci_DisableAllBusMastering;
begin
end;

end.
