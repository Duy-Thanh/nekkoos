// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel.Utilities;

public static unsafe class PRNG
{
    // ==========================================================
    // INTEROP: Gọi sang implementation bằng Pascal
    // ==========================================================
    [DllImport("*", EntryPoint = "PRNG_Init_Pas")]
    private static extern void PRNG_Init_Pas(ulong pitTicks);

    [DllImport("*", EntryPoint = "PRNG_Next_Pas")]
    private static extern ulong PRNG_Next_Pas();

    [DllImport("*", EntryPoint = "PRNG_Next_Range_Pas")]
    private static extern ulong PRNG_Next_Range_Pas(ulong min, ulong max);

    public static void Init()
    {
        PRNG_Init_Pas(PIT.Ticks);
    }

    public static ulong Next()
    {
        return PRNG_Next_Pas();
    }

    public static ulong Next(ulong min, ulong max)
    {
        return PRNG_Next_Range_Pas(min, max);
    }
}