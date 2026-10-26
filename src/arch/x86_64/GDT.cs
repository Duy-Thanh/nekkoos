// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// ==========================================================
// MODULE: NHÀ TÙ QUYỀN LỰC (GDT & TSS MANAGER - MILITARY GRADE)
// ==========================================================

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct GDTDescriptor
{
    public ushort Size;
    public ulong Offset;
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct GDTEntry
{
    public ushort LimitLow;
    public ushort BaseLow;
    public byte BaseMiddle;
    public byte Access;
    public byte Flags;
    public byte BaseHigh;
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct TSSEntry
{
    public uint Reserved0;
    public ulong Rsp0; 
    public ulong Rsp1;
    public ulong Rsp2;
    public ulong Reserved1;
    public ulong Ist1;
    public ulong Ist2;
    public ulong Ist3;
    public ulong Ist4;
    public ulong Ist5;
    public ulong Ist6;
    public ulong Ist7;
    public ulong Reserved2;
    public ushort Reserved3;
    public ushort IopbOffset; 
    public fixed byte Iopb[8192]; 
    public byte EndMarker; 
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct TSSDescriptor
{
    public ushort LimitLow;
    public ushort BaseLow;
    public byte BaseMiddle;
    public byte Access;
    public byte Flags;
    public byte BaseHigh;
    public uint BaseUpper32;
    public uint Reserved;
}

public static unsafe class GDT
{
    // [PASCAL PORT] All logic lives in gdt.pas.
    [DllImport("*", EntryPoint = "Gdt_Init_Pas")] private static extern void Init_Pas();
    [DllImport("*", EntryPoint = "Gdt_GrantPortAccess_Pas")] private static extern void GrantPortAccess_Pas(ushort port, uint coreCount);
    [DllImport("*", EntryPoint = "Gdt_GetTss_Pas")] private static extern TSSEntry* GetTss_Pas();
    [DllImport("*", EntryPoint = "Gdt_SetCoreTss_Pas")] private static extern void SetCoreTss_Pas(uint coreIndex, void* tss);
    [DllImport("*", EntryPoint = "Gdt_GetCoreTss_Pas")] private static extern TSSEntry* GetCoreTss_Pas(uint coreIndex);

    public static TSSEntry* Tss => GetTss_Pas();

    public static void RegisterCoreTss(uint coreIndex, TSSEntry* tss) => SetCoreTss_Pas(coreIndex, tss);
    public static TSSEntry* GetCoreTss(uint coreIndex) => GetCoreTss_Pas(coreIndex);

    public static void GrantPortAccess(ushort port) => GrantPortAccess_Pas(port, APIC.CoreCount);
    public static void Init() => Init_Pas();
}
