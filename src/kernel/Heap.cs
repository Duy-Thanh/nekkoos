// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct HeapBlock
{
    public ulong Size;      // 8 bytes - CHỊU ĐƯỢC HEAP > 4GB!
    public byte IsFree;     // 1 byte
    public byte Pad1, Pad2, Pad3; // 3 bytes căn chẵn
    public uint Magic;      // 4 bytes
    public ulong ExactSize; // 8 bytes - CHỊU ĐƯỢC ALLOC > 4GB!
    public HeapBlock* Next; // 8 bytes. Tổng Struct: 32 Bytes! Căn 8 hoàn hảo!
}

// [PASCAL PORT] The allocator lives in heap.pas; this class only forwards.
public static unsafe class Heap
{
    [DllImport("*", EntryPoint = "Heap_Init_Pas")] private static extern void Init_Pas();
    [DllImport("*", EntryPoint = "Heap_Alloc_Pas")] private static extern void* Alloc_Pas(uint size);
    [DllImport("*", EntryPoint = "Heap_Free_Pas")] private static extern void Free_Pas(void* ptr);

    public static void Init() => Init_Pas();
    public static void* Alloc(uint size) => Alloc_Pas(size);
    public static void Free(void* ptr) => Free_Pas(ptr);
}
