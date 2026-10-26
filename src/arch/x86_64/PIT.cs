// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// [PASCAL PORT] Logic lives in pit.pas.
public static unsafe class PIT
{
    [DllImport("*", EntryPoint = "HAL_GetTickCount")]
    public static extern ulong GetTickCountHal();

    [DllImport("*", EntryPoint = "HAL_IncrementTicks")]
    public static extern void IncrementTicksHal();

    [DllImport("*", EntryPoint = "Pit_Init_Pas")] private static extern void Init_Pas(uint frequency);
    [DllImport("*", EntryPoint = "Pit_MsToTicks_Pas")] private static extern ulong MsToTicks_Pas(ulong ms);
    [DllImport("*", EntryPoint = "Pit_GetFrequency_Pas")] private static extern uint GetFrequency_Pas();
    [DllImport("*", EntryPoint = "Pit_Sleep_Pas")] private static extern void Sleep_Pas(ulong ms);

    public static ulong Ticks => GetTickCountHal();
    public static uint CurrentFreq => GetFrequency_Pas();

    public static ulong GetTicksRealtime() => Ticks;
    public static void Init(uint frequency) => Init_Pas(frequency);
    public static ulong MsToTicks(ulong ms) => MsToTicks_Pas(ms);
    public static void Sleep(ulong ms) => Sleep_Pas(ms);
}
