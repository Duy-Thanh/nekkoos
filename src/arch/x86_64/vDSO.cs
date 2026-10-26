// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// [PASCAL PORT] Logic lives in vdso.pas.
public static unsafe class vDSO
{
    [DllImport("*", EntryPoint = "Vdso_Init_Pas")] private static extern void Init_Pas();
    [DllImport("*", EntryPoint = "Vdso_GetPhysPage_Pas")] private static extern ulong GetPhysPage_Pas();

    public static ulong PhysPage => GetPhysPage_Pas();
    public static void Init() => Init_Pas();
}
