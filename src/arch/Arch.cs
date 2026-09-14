// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
// MODULE: Arch - BE MAT IMPORT CHUAN DUY NHAT cua AAL phia C# (twin cua
// src/arch/arch_interface.pas ben Pascal).
//
// QUY TAC (build.sh lint kiem tra): KHONG file nao ngoai src/arch/ duoc
// khai bao [DllImport EntryPoint="Arch_..."]. Kernel/apps chi goi qua class
// Arch nay. Port sang arch moi = cung cap asm export dung bo symbol nay
// + thay the cac implementation trong src/arch/<arch>/. Kernel generic
// va apps KHONG PHAI SUA GI.
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

public static unsafe class Arch
{
        [DllImport("*", EntryPoint = "Arch_AtomicExchange")] public static extern uint AtomicExchange(ref uint location, uint newValue);
        [DllImport("*", EntryPoint = "Arch_CompilerFence")] public static extern void CompilerFence();
        [DllImport("*", EntryPoint = "Arch_DisableInterrupts")] public static extern void DisableInterrupts();
        [DllImport("*", EntryPoint = "Arch_EnableInterrupts")] public static extern void EnableInterrupts();
        // Nguồn: platform_impl.pas (HAL_Reboot/HAL_Shutdown) - hợp đồng reboot/shutdown
        [DllImport("*", EntryPoint = "HAL_Reboot")] public static extern void Reboot();
        [DllImport("*", EntryPoint = "HAL_Shutdown")] public static extern void Shutdown();
        [DllImport("*", EntryPoint = "Arch_FullFence")] public static extern void FullFence();
        [DllImport("*", EntryPoint = "Arch_GetFlags")] public static extern ulong GetFlags();
        [DllImport("*", EntryPoint = "Arch_GetIsrDiv0")] public static extern void* GetIsrDiv0();
        [DllImport("*", EntryPoint = "Arch_GetIsrGPF")] public static extern void* GetIsrGPF();
        [DllImport("*", EntryPoint = "Arch_GetIsrKeyboard")] public static extern void* GetIsrKeyboard();
        [DllImport("*", EntryPoint = "Arch_GetIsrMouse")] public static extern void* GetIsrMouse();
        [DllImport("*", EntryPoint = "Arch_GetIsrPageFault")] public static extern void* GetIsrPageFault();
        [DllImport("*", EntryPoint = "Arch_GetIsrSyscall")] public static extern void* GetIsrSyscall();
        [DllImport("*", EntryPoint = "Arch_GetIsrTimer")] public static extern void* GetIsrTimer();
        [DllImport("*", EntryPoint = "Arch_GetIsrYield")] public static extern void* GetIsrYield();
        [DllImport("*", EntryPoint = "Arch_Halt")] public static extern void Halt();
        [DllImport("*", EntryPoint = "Arch_LoadFence")] public static extern void LoadFence();
        [DllImport("*", EntryPoint = "Arch_LoadGDT")] public static extern void LoadGDT(GDTDescriptor* gdtPtr);
        [DllImport("*", EntryPoint = "Arch_LoadIDT")] public static extern void LoadIdt(IDTPointer* p);
        [DllImport("*", EntryPoint = "Arch_LoadTSS")] public static extern void LoadTSS(ushort tssSegment);
        [DllImport("*", EntryPoint = "Arch_ReadMmio32")] public static extern uint ReadMmio32(ulong address);
        [DllImport("*", EntryPoint = "Arch_ReadPort16")] public static extern ushort ReadPort16(ushort port);
        [DllImport("*", EntryPoint = "Arch_ReadPort32")] public static extern uint ReadPort32(ushort port);
        [DllImport("*", EntryPoint = "Arch_ReadPort8")] public static extern byte ReadPort8(ushort port);
        [DllImport("*", EntryPoint = "Arch_ReadTimestamp")] public static extern ulong ReadTimestamp();
        [DllImport("*", EntryPoint = "Arch_StoreFence")] public static extern void StoreFence();
        [DllImport("*", EntryPoint = "Arch_UnlockScheduler")] public static extern void UnlockScheduler();
        [DllImport("*", EntryPoint = "Arch_LockScheduler")] public static extern void LockScheduler();
        [DllImport("*", EntryPoint = "Arch_ForceYield")] public static extern void ForceYield();
        [DllImport("*", EntryPoint = "Arch_GetCS")] public static extern ushort GetCs();
        [DllImport("*", EntryPoint = "Arch_GetSS")] public static extern ushort GetSs();
        [DllImport("*", EntryPoint = "Arch_WriteMmio32")] public static extern void WriteMmio32(ulong address, uint value);
        [DllImport("*", EntryPoint = "Arch_WritePort16")] public static extern void WritePort16(ushort port, ushort value);
        [DllImport("*", EntryPoint = "Arch_WritePort32")] public static extern void WritePort32(ushort port, uint value);
        [DllImport("*", EntryPoint = "Arch_WritePort8")] public static extern void WritePort8(ushort port, byte value);

    // ---- I/O Wait ----
        [DllImport("*", EntryPoint = "Arch_IoWait")] public static extern void IoWait();

    // ---- FPU State ----
        [DllImport("*", EntryPoint = "Arch_SaveFPU")] public static extern void SaveFpu(void* buffer);
        [DllImport("*", EntryPoint = "Arch_RestoreFPU")] public static extern void RestoreFpu(void* buffer);

    // ---- Spinlock ----
        [DllImport("*", EntryPoint = "Arch_SpinlockAcquire")] public static extern uint SpinlockAcquire(uint* lockVar);
        [DllImport("*", EntryPoint = "Arch_SpinlockRelease")] public static extern void SpinlockRelease(uint* lockVar);

    // ---- Paging / TLB / NX ----
        [DllImport("*", EntryPoint = "Arch_LoadPageTable")] public static extern void LoadPageTable(ulong physAddr);
        [DllImport("*", EntryPoint = "Arch_ReadPageTable")] public static extern ulong ReadPageTable();
        [DllImport("*", EntryPoint = "Arch_FlushTLB")] public static extern void FlushTlbAll();
        [DllImport("*", EntryPoint = "Arch_EnableNX")] public static extern void EnableNx();
}
