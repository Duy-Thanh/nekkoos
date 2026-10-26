// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// [PASCAL PORT] Logic lives in apic.pas.
public static unsafe class APIC
{
    [DllImport("*", EntryPoint = "HAL_InitInterruptController")] public static extern void InitInterruptController();
    [DllImport("*", EntryPoint = "HAL_GetCoreId")] public static extern uint GetCoreIdHal();

    [DllImport("*", EntryPoint = "Apic_Init_Pas")] private static extern void Init_Pas(ulong phys);
    [DllImport("*", EntryPoint = "Apic_Read_Pas")] private static extern uint Read_Pas(uint offset);
    [DllImport("*", EntryPoint = "Apic_Write_Pas")] private static extern void Write_Pas(uint offset, uint value);
    [DllImport("*", EntryPoint = "Apic_SendEOI_Pas")] private static extern void SendEOI_Pas();
    [DllImport("*", EntryPoint = "Apic_GetBaseVirt_Pas")] private static extern ulong GetBaseVirt_Pas();
    [DllImport("*", EntryPoint = "Apic_SetBaseVirt_Pas")] private static extern void SetBaseVirt_Pas(ulong v);
    [DllImport("*", EntryPoint = "Apic_IsAwake_Pas")] private static extern byte IsAwake_Pas();
    [DllImport("*", EntryPoint = "Apic_SetIsAwake_Pas")] private static extern void SetIsAwake_Pas(byte v);
    [DllImport("*", EntryPoint = "Apic_GetCoreCount_Pas")] private static extern uint GetCoreCount_Pas();
    [DllImport("*", EntryPoint = "Apic_SetCoreCount_Pas")] private static extern void SetCoreCount_Pas(uint c);
    [DllImport("*", EntryPoint = "Apic_GetIoApicBase_Pas")] private static extern ulong GetIoApicBase_Pas();
    [DllImport("*", EntryPoint = "Apic_SetIoApicBase_Pas")] private static extern void SetIoApicBase_Pas(ulong b);
    [DllImport("*", EntryPoint = "Apic_GetTicksPerQuantum_Pas")] private static extern uint GetTicksPerQuantum_Pas();

    public static ulong LocalApicBaseVirt { get => GetBaseVirt_Pas(); set => SetBaseVirt_Pas(value); }
    public static bool IsAwake { get => IsAwake_Pas() != 0; set => SetIsAwake_Pas((byte)(value ? 1 : 0)); }
    public static uint CalibratedTicksPerQuantum => GetTicksPerQuantum_Pas();
    public static uint CoreCount { get => GetCoreCount_Pas(); set => SetCoreCount_Pas(value); }
    public static ulong IOApicBase { get => GetIoApicBase_Pas(); set => SetIoApicBase_Pas(value); }

    public static void Write(uint offset, uint value) => Write_Pas(offset, value);
    public static uint Read(uint offset) => Read_Pas(offset);
    public static void SendEOI() => SendEOI_Pas();

    public static void Init(ulong physAddress)
    {
        Init_Pas(physAddress);
    }
}
