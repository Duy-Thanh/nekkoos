// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// [PASCAL PORT] The PE loader lives in pe_loader.pas; this class only forwards.
public static unsafe class PELoader
{
    [DllImport("*", EntryPoint = "PELoader_LoadAndRun_Pas")]
    private static extern int LoadAndRun_Pas(byte* rawFile, byte runInBackground, byte isJailed, byte forceRoot, char* processName, byte priority);

    public static void LoadAndRun(byte* rawFile, bool runInBackground = false, bool isJailed = false, bool forceRoot = false, char* processName = null, byte priority = 1)
        => LoadAndRun_Pas(rawFile, (byte)(runInBackground ? 1 : 0), (byte)(isJailed ? 1 : 0), (byte)(forceRoot ? 1 : 0), processName, priority);

    // Returns the new process's thread id so Kernel.cs can record the real identity of daemons it spawns.
    public static void LoadAndRun(byte* rawFile, out int newThreadId, bool runInBackground = false, bool isJailed = false, bool forceRoot = false, char* processName = null, byte priority = 1)
        => newThreadId = LoadAndRun_Pas(rawFile, (byte)(runInBackground ? 1 : 0), (byte)(isJailed ? 1 : 0), (byte)(forceRoot ? 1 : 0), processName, priority);
}
