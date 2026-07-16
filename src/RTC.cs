// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// ==========================================================
// MODULE: BỘ ĐỌC THỜI GIAN THỰC (RTC / CMOS) - SHIM
// Trỏ thẳng sang rtc.pas của Pascal!
// ==========================================================
public static unsafe class RTC
{
    [DllImport("*", EntryPoint = "RTC_PrintCurrentTime_Pas")]
    private static extern void RTC_PrintCurrentTime_Pas();

    [DllImport("*", EntryPoint = "RTC_GetSeconds_Pas")]
    private static extern ulong RTC_GetSeconds_Pas();

    public static void PrintCurrentTime()
    {
        RTC_PrintCurrentTime_Pas();
    }

    public static ulong GetSeconds()
    {
        return RTC_GetSeconds_Pas();
    }
}
