// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// [PASCAL PORT] AP bring-up lives in src/arch/x86_64/smp.pas.
public static unsafe class SMP
{
    [DllImport("*", EntryPoint = "Smp_InitAndWakeCores_Pas")] private static extern void InitAndWakeCores_Pas();

    public static void InitAndWakeCores() => InitAndWakeCores_Pas();
}
