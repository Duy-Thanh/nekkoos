// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// [PASCAL PORT] Logic lives in pic.pas.
public static unsafe class PIC
{
    [DllImport("*", EntryPoint = "Pic_Remap_Pas")] private static extern void Remap_Pas();
    [DllImport("*", EntryPoint = "Pic_Disable_Pas")] private static extern void Disable_Pas();
    [DllImport("*", EntryPoint = "Pic_MaskAllIrqs_Pas")] private static extern void MaskAllIrqs_Pas();
    [DllImport("*", EntryPoint = "Pic_SendEOI_Pas")] private static extern void SendEOI_Pas();

    public static void Remap() => Remap_Pas();
    public static void SendEOI() => SendEOI_Pas();
    public static void Disable() => Disable_Pas();
    public static void MaskAllIrqs() => MaskAllIrqs_Pas();
}
