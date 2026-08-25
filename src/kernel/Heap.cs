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

// ==========================================================
// INTEROP: Thuật toán first-fit linked-list heap allocator (thuần logic,
// không phụ thuộc kiến trúc CPU) đã port sang src/heap.pas. Phần duy nhất
// còn lại ở đây là Init() (gọi PMM để cấp 4MB, setup Head block) và error
// handling (Terminal.Print/IO.Hlt/Scheduler.TerminateCurrentTask) vì đây là
// OS plumbing, không phải thuật toán allocator.
// ==========================================================
public static unsafe class Heap
{
    // ==========================================================
    // [MEMORY BARRIERS] Imported from Hardware.asm
    // ==========================================================
    [DllImport("*", EntryPoint = "Arch_CompilerFence")] public static extern void CompilerFence();
    [DllImport("*", EntryPoint = "Arch_LoadFence")] public static extern void LoadFence();
    [DllImport("*", EntryPoint = "Arch_StoreFence")] public static extern void StoreFence();
    [DllImport("*", EntryPoint = "Arch_FullFence")] public static extern void FullFence();

    // ==========================================================
    // INTEROP: Gọi sang implementation bằng Pascal (src/heap.pas)
    // ==========================================================
    [DllImport("*", EntryPoint = "Heap_SetState_Pas")]
    private static extern void Heap_SetState_Pas(HeapBlock* head, byte* heapStart, ulong heapTotalSize);

    [DllImport("*", EntryPoint = "Heap_AllocBlock_Pas")]
    private static extern byte Heap_AllocBlock_Pas(uint size, out void* userRam);

    [DllImport("*", EntryPoint = "Heap_FreeBlock_Pas")]
    private static extern byte Heap_FreeBlock_Pas(void* ptr);

    // Error codes from heap.pas
    private const byte HEAP_OK = 0;
    private const byte HEAP_OOM = 1;
    private const byte HEAP_CORRUPTION = 2;
    private const byte HEAP_INVALID_PTR = 3;
    private const byte HEAP_DOUBLE_FREE = 4;
    private const byte HEAP_OVERFLOW = 5;

    public static Spinlock HeapLock = new Spinlock();

    public static HeapBlock* Head;

    public static byte* HeapStart;
    public static ulong HeapTotalSize = 4096 * 1000; // 4MB KHỐI BÊ TÔNG ĐẶC

    public static void Init()
    {
        HeapStart = (byte*)PMM.AllocateContiguousPages(1000);
        if (HeapStart == null)
        {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Cannot allocate 4MB contiguous memory for Heap!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        // Kiểm tra căn chỉnh của HeapStart
        if (((ulong)HeapStart & 0xFFF) != 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Heap is not page aligned!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        Head = (HeapBlock*)HeapStart;

        // Kiểm tra xem HeapTotalSize có đủ lớn cho cấu trúc HeapBlock không
        if (HeapTotalSize < (ulong)sizeof(HeapBlock) + 8) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Heap size is too small!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        Head->Size = HeapTotalSize - (ulong)sizeof(HeapBlock);
        Head->IsFree = 1;
        Head->Magic = 0xDEADBEEF;
        Head->ExactSize = 0;
        Head->Next = null;

        // ==========================================================
        // [BỌC THÉP PHẦN CỨNG]
        // Đảm bảo cấu trúc Heap đầu tiên (Head) đã được chôn chặt
        // xuống RAM vật lý trước khi Lõi Phụ thức dậy có cơ hội đụng vào!
        // ==========================================================
        StoreFence();

        // Đăng ký trạng thái vào Pascal module
        Heap_SetState_Pas(Head, HeapStart, HeapTotalSize);

        Terminal.SetColor(0x0000FF00);
        fixed (char* msg = "[+] Fortress MPU Heap Initialized! (4MB Solid Block)\n\0") Terminal.Print(msg);
    }

    public static void* Alloc(uint size)
    {
        if (size > 0x100000) return null;

        bool irq = HeapLock.AcquireSafe();

        if (size == 0 || size >= HeapTotalSize) {
            HeapLock.ReleaseSafe(irq);
            return null;
        }

        void* userRam;
        byte errorCode = Heap_AllocBlock_Pas(size, out userRam);

        HeapLock.ReleaseSafe(irq);

        if (errorCode != HEAP_OK)
        {
            if (errorCode == HEAP_OOM)
            {
                return null;
            }
            else if (errorCode == HEAP_CORRUPTION)
            {
                Terminal.SetColor(0x00FF0000);
                fixed (char* msg = "[!] MPU FATAL: HEAP CORRUPTION DETECTED DURING ALLOC!\n\0") Terminal.Print(msg);
                Scheduler.TerminateCurrentTask();
                while(true) IO.Hlt();
            }
        }

        return userRam;
    }

    public static void Free(void* ptr)
    {
        bool irq = HeapLock.AcquireSafe();

        byte errorCode = Heap_FreeBlock_Pas(ptr);

        HeapLock.ReleaseSafe(irq);

        if (errorCode != HEAP_OK)
        {
            if (errorCode == HEAP_CORRUPTION)
            {
                Terminal.SetColor(0x00FF0000);
                fixed (char* msg = "[!] MPU FATAL: HEAP CORRUPTION! INVALID HEADER MAGIC!\n\0") Terminal.Print(msg);
                Scheduler.TerminateCurrentTask();
                while(true) IO.Hlt();
            }
            else if (errorCode == HEAP_INVALID_PTR)
            {
                Terminal.SetColor(0x00FF0000);
                fixed (char* msg = "[!] MPU BLOCKED: INVALID POINTER FREE DETECTED!\n\0") Terminal.Print(msg);
                Scheduler.TerminateCurrentTask();
            }
            else if (errorCode == HEAP_DOUBLE_FREE)
            {
                Terminal.SetColor(0x00FF0000);
                fixed (char* msg = "[!] MPU WARNING: DOUBLE FREE DETECTED!\n\0") Terminal.Print(msg);
            }
            else if (errorCode == HEAP_OVERFLOW)
            {
                Terminal.SetColor(0x00FF0000);
                fixed (char* msg = "\n[!] MPU FATAL: HEAP BUFFER OVERFLOW DETECTED!\n\0") Terminal.Print(msg);
                Scheduler.TerminateCurrentTask();
                while(true) IO.Hlt();
            }
        }
    }
}
