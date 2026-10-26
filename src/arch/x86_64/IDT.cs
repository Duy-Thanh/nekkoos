// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct IDTEntry
{
    public ushort BaseLow;
    public ushort Selector;
    public byte Ist;
    public byte Flags;
    public ushort BaseMid;
    public uint BaseHigh;
    public uint Reserved;
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct IDTPointer
{
    public ushort Limit;
    public ulong Base;
}

// [PASCAL PORT] Logic lives in idt.pas.
public static unsafe class IDTManager
{
    [DllImport("*", EntryPoint = "Idt_Init_Pas")] private static extern void Init_Pas();
    [DllImport("*", EntryPoint = "Idt_SetGate_Pas")] private static extern void SetGate_Pas(int n, void* handler);
    [DllImport("*", EntryPoint = "Idt_GetTable_Pas")] private static extern void* GetTable_Pas();

    public static void* idt => GetTable_Pas();
    public static void Init() => Init_Pas();
    public static void SetGate(int interruptNumber, void* handlerAddress) => SetGate_Pas(interruptNumber, handlerAddress);
}
