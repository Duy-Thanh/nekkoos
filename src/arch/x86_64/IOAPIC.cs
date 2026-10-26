// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// [PASCAL PORT] Logic lives in ioapic.pas.
public static unsafe class IOAPIC
{
    [DllImport("*", EntryPoint = "Ioapic_Init_Pas")] private static extern void Init_Pas();
    [DllImport("*", EntryPoint = "Ioapic_MaskAll_Pas")] private static extern void MaskAll_Pas();

    public static void Init() => Init_Pas();
    public static void MaskAll() => MaskAll_Pas();
}
