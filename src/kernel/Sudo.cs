// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// [PASCAL PORT] The sudo logic lives in sudo_dispatch.pas.
public static unsafe class Sudo
{
    [DllImport("*", EntryPoint = "Sudo_Dispatch_Pas")]
    private static extern int Dispatch_Pas(int id, ulong* ctx);

    public static int Dispatch(int id, RegisterContext* ctx) => Dispatch_Pas(id, (ulong*)ctx);
}
