// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel.Driver;

// [PASCAL PORT] The mouse daemon's identity lives in src/drivers/input_drv.pas.
public static class Mouse
{
    [DllImport("*", EntryPoint = "Mouse_GetUseDaemon_Pas")] private static extern byte GetUseDaemon_Pas();
    [DllImport("*", EntryPoint = "Mouse_SetUseDaemon_Pas")] private static extern void SetUseDaemon_Pas(byte v);
    [DllImport("*", EntryPoint = "Mouse_GetDaemonId_Pas")] private static extern uint GetDaemonId_Pas();
    [DllImport("*", EntryPoint = "Mouse_SetDaemonId_Pas")] private static extern void SetDaemonId_Pas(uint v);

    public static bool UseDaemon { get => GetUseDaemon_Pas() != 0; set => SetUseDaemon_Pas((byte)(value ? 1 : 0)); }
    public static uint DaemonId { get => GetDaemonId_Pas(); set => SetDaemonId_Pas(value); }
}
