// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
// MODULE: AddressSpaces - giao diện scheduler/loader thao tác không gian
// địa chỉ theo HANDLE mờ (một ulong do arch định nghĩa). ARCH: x86_64 ONLY
// - bên dưới là PML4 vật lý; port arch khác thay đúng file này, kernel
// generic (Thread/Syscall/PELoader/Kernel) không được nhắc tên VMM/PML4.
// =========================================================================

namespace NekkoOS.Kernel;

public static unsafe class Mem
{
    public static Spinlock VmmLock => VMM.VmmLock;
    public static void ResetLock() => VMM.VmmLock = new Spinlock();
    public static void Init() => VMM.Init();

    /// Root của address-space kernel (handle mờ cho generic code).
    public static ulong* KernelRoot => VMM.PML4;

    public static bool IsCanonical(ulong addr) => VMM.IsCanonical(addr);
    public static void MapPage(ulong physAddr, ulong virtAddr, ulong flags) => VMM.MapPage(physAddr, virtAddr, flags);
    public static void MapPage(ulong physAddr, ulong virtAddr, ulong flags, ulong* spaceRoot) => VMM.MapPage(physAddr, virtAddr, flags, spaceRoot);
    public static void MapHugePage(ulong physAddr, ulong virtAddr) => VMM.MapHugePage(physAddr, virtAddr);
    public static void DestroyUserSpace(ulong spaceRoot) => VMM.DestroyUserSpace(spaceRoot);
}
