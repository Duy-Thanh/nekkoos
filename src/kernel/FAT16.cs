// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel.Driver;

// [PASCAL PORT] The kernel-side FAT16 client lives in fat16_kernel.pas.
public static unsafe class FAT16
{
    [DllImport("*", EntryPoint = "Fat16K_Init_Pas")] private static extern void Init_Pas();
    [DllImport("*", EntryPoint = "Fat16K_ReadFile_Pas")] private static extern byte* ReadFile_Pas(char* filename, uint* outSize, int callerOverride);
    [DllImport("*", EntryPoint = "Fat16K_Cd_Pas")] private static extern void Cd_Pas(char* dirname, int callerOverride);
    [DllImport("*", EntryPoint = "Fat16K_ListDir_Pas")] private static extern byte ListDir_Pas(char* outBuf, int outCap, int caller);
    [DllImport("*", EntryPoint = "Fat16K_WriteFileRelay_Pas")] private static extern int WriteFileRelay_Pas(char* filename, byte* data, uint size, int caller);
    [DllImport("*", EntryPoint = "Fat16K_MakeDir_Pas")] private static extern int MakeDir_Pas(char* name, int caller);
    [DllImport("*", EntryPoint = "Fat16K_RemoveFile_Pas")] private static extern int RemoveFile_Pas(char* name, int caller);
    [DllImport("*", EntryPoint = "Fat16K_RemoveDir_Pas")] private static extern int RemoveDir_Pas(char* name, int caller);
    [DllImport("*", EntryPoint = "Fat16K_Chmod_Pas")] private static extern int Chmod_Pas(char* path, uint mode, int caller);
    [DllImport("*", EntryPoint = "Fat16K_Chown_Pas")] private static extern int Chown_Pas(char* path, char* owner, int caller);
    [DllImport("*", EntryPoint = "Fat16K_GetUseDaemon_Pas")] private static extern byte GetUseDaemon_Pas();
    [DllImport("*", EntryPoint = "Fat16K_SetUseDaemon_Pas")] private static extern void SetUseDaemon_Pas(byte v);
    [DllImport("*", EntryPoint = "Fat16K_GetDaemonId_Pas")] private static extern uint GetDaemonId_Pas();
    [DllImport("*", EntryPoint = "Fat16K_SetDaemonId_Pas")] private static extern void SetDaemonId_Pas(uint v);
    [DllImport("*", EntryPoint = "Fat16K_GetTrustedThreadId_Pas")] private static extern int GetTrustedThreadId_Pas();
    [DllImport("*", EntryPoint = "Fat16K_SetTrustedThreadId_Pas")] private static extern void SetTrustedThreadId_Pas(int v);

    public static bool UseDaemon { get => GetUseDaemon_Pas() != 0; set => SetUseDaemon_Pas((byte)(value ? 1 : 0)); }
    public static uint DaemonId { get => GetDaemonId_Pas(); set => SetDaemonId_Pas(value); }
    public static int TrustedThreadId { get => GetTrustedThreadId_Pas(); set => SetTrustedThreadId_Pas(value); }

    public static void Init() => Init_Pas();
    public static byte* ReadFile(char* filename, uint* outSize, int callerThreadOverride = -1) => ReadFile_Pas(filename, outSize, callerThreadOverride);
    public static void Cd(char* dirname, int callerThreadOverride = -1) => Cd_Pas(dirname, callerThreadOverride);
    public static bool ListDir(char* outBuf, int outCap, int callerThreadOverride) => ListDir_Pas(outBuf, outCap, callerThreadOverride) != 0;
    public static int WriteFileRelay(char* filename, byte* data, uint size, int callerThreadOverride) => WriteFileRelay_Pas(filename, data, size, callerThreadOverride);
    public static int MakeDir(char* dirname, int callerThreadOverride) => MakeDir_Pas(dirname, callerThreadOverride);
    public static int RemoveFile(char* filename, int callerThreadOverride) => RemoveFile_Pas(filename, callerThreadOverride);
    public static int RemoveDir(char* dirname, int callerThreadOverride) => RemoveDir_Pas(dirname, callerThreadOverride);
    public static int Chmod(char* path, uint mode, int callerThreadOverride) => Chmod_Pas(path, mode, callerThreadOverride);
    public static int Chown(char* path, char* ownerStr, int callerThreadOverride) => Chown_Pas(path, ownerStr, callerThreadOverride);
}
