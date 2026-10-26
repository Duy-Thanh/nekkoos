// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel.Driver;

// [PASCAL PORT] The driver lives in ata_kernel.pas; this class only forwards.
public static unsafe class ATA
{
    [DllImport("*", EntryPoint = "Ata_GetUseDaemon_Pas")] private static extern byte GetUseDaemon_Pas();
    [DllImport("*", EntryPoint = "Ata_SetUseDaemon_Pas")] private static extern void SetUseDaemon_Pas(byte v);
    [DllImport("*", EntryPoint = "Ata_GetDaemonId_Pas")] private static extern uint GetDaemonId_Pas();
    [DllImport("*", EntryPoint = "Ata_SetDaemonId_Pas")] private static extern void SetDaemonId_Pas(uint v);
    [DllImport("*", EntryPoint = "Ata_ReadSector_Pas")] private static extern void ReadSector_Pas(uint lba, byte* buffer);
    [DllImport("*", EntryPoint = "Ata_WriteSector_Pas")] private static extern void WriteSector_Pas(uint lba, byte* buffer);
    [DllImport("*", EntryPoint = "Ata_FlushCache_Pas")] private static extern void FlushCache_Pas();
    [DllImport("*", EntryPoint = "Ata_HwLockAcquire_Pas")] private static extern void HwLockAcquire_Pas();
    [DllImport("*", EntryPoint = "Ata_HwLockRelease_Pas")] private static extern void HwLockRelease_Pas();
    [DllImport("*", EntryPoint = "Ata_HwLockIsLocked_Pas")] private static extern byte HwLockIsLocked_Pas();

    public static bool UseDaemon { get => GetUseDaemon_Pas() != 0; set => SetUseDaemon_Pas((byte)(value ? 1 : 0)); }
    public static uint DaemonId { get => GetDaemonId_Pas(); set => SetDaemonId_Pas(value); }

    public static void ReadSector(uint lba, byte* buffer) => ReadSector_Pas(lba, buffer);
    public static void WriteSector(uint lba, byte* buffer) => WriteSector_Pas(lba, buffer);
    public static void FlushCache() => FlushCache_Pas();

    // Shared with ATA.EXE through syscalls 60/61.
    public static class AtaHardwareLock
    {
        public static void Acquire() => HwLockAcquire_Pas();
        public static void Release() => HwLockRelease_Pas();
        public static bool IsLocked() => HwLockIsLocked_Pas() != 0;
    }
}
