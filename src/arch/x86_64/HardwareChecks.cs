// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// [PASCAL PORT] The platform authenticity gate lives in hardware_checks.pas.
public static unsafe class HardwareChecks
{
    [DllImport("*", EntryPoint = "HwChecks_CheckHardwareError_Pas")] private static extern void CheckHardwareError_Pas();

    public static void CheckHardwareError() => CheckHardwareError_Pas();
}
