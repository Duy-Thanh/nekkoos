// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

public unsafe struct Spinlock
{
    private uint _lockStatus;

    public Spinlock()
    {
        _lockStatus = 0;
    }

    [DllImport("*", EntryPoint = "Spinlock_AcquireSafe_Pas")]
    private static extern byte Spinlock_AcquireSafe_Pas(uint* lockVar);

    [DllImport("*", EntryPoint = "Spinlock_ReleaseSafe_Pas")]
    private static extern void Spinlock_ReleaseSafe_Pas(uint* lockVar, byte intsWereEnabled);

    [DllImport("*", EntryPoint = "Spinlock_IsLocked_Pas")]
    private static extern byte Spinlock_IsLocked_Pas(uint* lockVar);

    [DllImport("*", EntryPoint = "Spinlock_Acquire_Pas")]
    private static extern void Spinlock_Acquire_Pas(uint* lockVar);

    [DllImport("*", EntryPoint = "Spinlock_Release_Pas")]
    private static extern void Spinlock_Release_Pas(uint* lockVar);

    public static ulong GetRflags() => Arch.GetFlags();
    public static void CompilerFence() => Arch.CompilerFence();
    public static void StoreFence() => Arch.StoreFence();

    public bool AcquireSafe()
    {
        fixed (uint* ptr = &_lockStatus)
        {
            return Spinlock_AcquireSafe_Pas(ptr) != 0;
        }
    }

    public void ReleaseSafe(bool intsEnabled)
    {
        fixed (uint* ptr = &_lockStatus)
        {
            Spinlock_ReleaseSafe_Pas(ptr, (byte)(intsEnabled ? 1 : 0));
        }
    }

    public bool IsLocked()
    {
        fixed (uint* ptr = &_lockStatus)
        {
            return Spinlock_IsLocked_Pas(ptr) != 0;
        }
    }

    public void Acquire()
    {
        fixed (uint* ptr = &_lockStatus)
        {
            Spinlock_Acquire_Pas(ptr);
        }
    }

    public void Release()
    {
        fixed (uint* ptr = &_lockStatus)
        {
            Spinlock_Release_Pas(ptr);
        }
    }
}