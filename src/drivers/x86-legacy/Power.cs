// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// [PASCAL PORT] The shutdown/reboot sequencing lives in src/drivers/power.pas.
public static unsafe class Power
{
    [DllImport("*", EntryPoint = "Power_Shutdown_Pas")] private static extern void Shutdown_Pas();
    [DllImport("*", EntryPoint = "Power_Reboot_Pas")] private static extern void Reboot_Pas();
    [DllImport("*", EntryPoint = "Power_HardReboot_Pas")] private static extern void HardReboot_Pas();
    [DllImport("*", EntryPoint = "Power_LegacyReboot_Pas")] private static extern void LegacyReboot_Pas();

    public static void Shutdown() => Shutdown_Pas();
    public static void Reboot() => Reboot_Pas();
    public static void HardReboot() => HardReboot_Pas();
    public static void LegacyReboot() => LegacyReboot_Pas();
}
