// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;
namespace NekkoOS.Kernel.Driver;

// [PASCAL PORT] The PCI driver lives in src/drivers/pci.pas.
public static unsafe class PCI
{
    [DllImport("*", EntryPoint = "Pci_ScanBus_Pas")] private static extern void ScanBus_Pas();
    [DllImport("*", EntryPoint = "Pci_DisableAllBusMastering_Pas")] private static extern void DisableAllBusMastering_Pas();

    public static void ScanBus() => ScanBus_Pas();
    public static void DisableAllBusMastering() => DisableAllBusMastering_Pas();
}
