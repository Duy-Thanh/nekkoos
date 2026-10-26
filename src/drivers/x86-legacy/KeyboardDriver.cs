// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel.Driver;

// [PASCAL PORT] Scancode translation lives in src/drivers/input_drv.pas.
public static class KeyboardDriver
{
    [DllImport("*", EntryPoint = "Kbd_ProcessScanCode_Pas")] private static extern ushort ProcessScanCode_Pas(byte sc);
    [DllImport("*", EntryPoint = "Kbd_PollChar_Pas")] private static extern ushort PollChar_Pas();

    public static char ProcessScanCode(byte sc) => (char)ProcessScanCode_Pas(sc);
    public static char PollChar() => (char)PollChar_Pas();
}
