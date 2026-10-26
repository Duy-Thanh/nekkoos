// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// [PASCAL PORT] Logic lives in vmm.pas.
public static unsafe class VMM
{
    [DllImport("*", EntryPoint = "HAL_LoadPageTable")]
    public static extern void HAL_LoadPageTable(void* pageTable);

    [DllImport("*", EntryPoint = "HAL_GetCurrentPageTable")]
    public static extern void* HAL_GetCurrentPageTable();

    [DllImport("*", EntryPoint = "HAL_FlushTLBAddress")]
    public static extern void HAL_FlushTLBAddress(ulong virtualAddress);

    [DllImport("*", EntryPoint = "Vmm_Init_Pas")] private static extern void Init_Pas();
    [DllImport("*", EntryPoint = "Vmm_MapPage_Pas")] private static extern void MapPage_Pas(ulong phys, ulong virt, ulong flags);
    [DllImport("*", EntryPoint = "Vmm_MapPageIn_Pas")] private static extern void MapPageIn_Pas(ulong phys, ulong virt, ulong flags, ulong* pml4);
    [DllImport("*", EntryPoint = "Vmm_MapHugePage_Pas")] private static extern void MapHugePage_Pas(ulong phys, ulong virt);
    [DllImport("*", EntryPoint = "Vmm_DestroyUserSpace_Pas")] private static extern void DestroyUserSpace_Pas(ulong pml4);
    [DllImport("*", EntryPoint = "Vmm_GetPml4_Pas")] private static extern ulong* GetPml4_Pas();

    public static void LoadPML4_ASM(void* pml4Address) => HAL_LoadPageTable(pml4Address);
    public static ulong ReadCR3() => (ulong)HAL_GetCurrentPageTable();
    public static void FlushTLB(void* virtualAddress) => HAL_FlushTLBAddress((ulong)virtualAddress);

    public static ulong* PML4 => GetPml4_Pas();

    public static bool IsCanonical(ulong addr)
    {
        ulong top16 = addr >> 48;
        return top16 == 0x0000 || top16 == 0xFFFF;
    }

    public static void Init() => Init_Pas();
    public static void MapHugePage(ulong physAddr, ulong virtAddr) => MapHugePage_Pas(physAddr, virtAddr);
    public static void MapPage(ulong physAddr, ulong virtAddr, ulong flags) => MapPage_Pas(physAddr, virtAddr, flags);
    public static void MapPage(ulong physAddr, ulong virtAddr, ulong flags, ulong* pml4Dir) => MapPageIn_Pas(physAddr, virtAddr, flags, pml4Dir);
    public static void DestroyUserSpace(ulong pml4_phys) => DestroyUserSpace_Pas(pml4_phys);
}
