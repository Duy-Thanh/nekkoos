// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// [PASCAL PORT] Parsing and execution both live in internal_shell.pas.
public static unsafe class InternalShell
{
    [DllImport("*", EntryPoint = "InternalShell_Dispatch_Pas")]
    private static extern ulong Dispatch_Pas(int id, ulong currentTicks, byte isKing, ulong* ctx);

    public static ulong Dispatch(int id, ulong currentTicks, bool isKing, RegisterContext* ctx)
        => Dispatch_Pas(id, currentTicks, (byte)(isKing ? 1 : 0), (ulong*)ctx);
}
