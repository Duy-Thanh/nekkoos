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

public static unsafe class Heap
{
    // ==========================================================
    // KHAI BÁO RÀO CHẮN PHẦN CỨNG & COMPILER
    // ==========================================================
    [DllImport("*", EntryPoint = "CompilerFence")] public static extern void CompilerFence();
    [DllImport("*", EntryPoint = "LoadFence")] public static extern void LoadFence();
    [DllImport("*", EntryPoint = "StoreFence")] public static extern void StoreFence();
    [DllImport("*", EntryPoint = "FullFence")] public static extern void FullFence();

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

        // requiredSize = payload + canary, aligned to 8
        ulong requiredSize = (ulong)size + 4; // 4 bytes cho canary
        ulong remainder = requiredSize % 8;
        if (remainder != 0) requiredSize += (8 - remainder);

        HeapBlock* current = Head;
        while (current != null)
        {
            // ==========================================================
            // [COMPILER FENCE]
            // Prevent LLVM from caching the 'current' pointer in registers
            // Forces sequential retrieval from RAM during linked list traversal
            // ==========================================================
            CompilerFence();

            if (current->Magic != 0xDEADBEEF) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* msg = "[!] MPU FATAL: HEAP CORRUPTION DETECTED DURING ALLOC!\n\0") Terminal.Print(msg);
                HeapLock.ReleaseSafe(irq);
                Scheduler.TerminateCurrentTask();
                while(true) IO.Hlt();
            }

            if (current->IsFree == 1 && current->Size >= requiredSize)
            {
                // Kiểm tra xem block mới có nằm trong giới hạn heap không
                ulong newBlockAddr = (ulong)current + (ulong)sizeof(HeapBlock) + requiredSize;
                if (newBlockAddr + (ulong)sizeof(HeapBlock) > (ulong)HeapStart + HeapTotalSize) {
                    // Không đủ chỗ để tạo block mới, tiếp tục tìm
                    current = current->Next;
                    continue;
                }

                if (current->Size > requiredSize + (ulong)sizeof(HeapBlock) + 8)
                {
                    HeapBlock* newBlock = (HeapBlock*)((byte*)current + sizeof(HeapBlock) + (int)requiredSize);
                    newBlock->Size = current->Size - requiredSize - (ulong)sizeof(HeapBlock);
                    newBlock->IsFree = 1;
                    newBlock->Magic = 0xDEADBEEF;
                    newBlock->Next = current->Next;

                    // TRÌNH TỰ BẤT KHẢ XÂM PHẠM: Phải ghi xong data của newBlock rồi mới được móc dây xích Next!
                    CompilerFence();

                    current->Size = requiredSize;
                    current->Next = newBlock;
                    
                    // ==========================================================
                    // [BỌC THÉP PHẦN CỨNG] 
                    // Vừa cắt đôi Block xong! Ép xả Store Buffer ngay lập tức 
                    // để cứu Linked List khỏi sự phân mảnh nếu Context Switch xảy ra!
                    // ==========================================================
                    StoreFence();
                }

                current->IsFree = 0;
                current->ExactSize = size; 

                byte* userRam = (byte*)current + sizeof(HeapBlock);
                LibC.MemSet(userRam, 0, (uint)size);
                *(uint*)(userRam + size) = 0xDEADBEEF;
                
                // ==========================================================
                // [BỌC THÉP SINH TỬ] ÉP XẢ RAM SAU KHI MEMSET!
                // Cấm CPU ngâm những số 0 vừa MemSet trong L1 Cache. 
                // Trả về cho Ring 3 là phải sạch sẽ 100% trên mặt vật lý!
                // ==========================================================
                StoreFence();
                
                HeapLock.ReleaseSafe(irq); 
                return userRam;
            }
            current = current->Next;
        }

        HeapLock.ReleaseSafe(irq);
        return null;
    }

    public static void Free(void* ptr)
    {
        bool irq = HeapLock.AcquireSafe();

        if (ptr == null) {
            HeapLock.ReleaseSafe(irq); 
            return;
        }

        // Kiểm tra căn chỉnh của con trỏ
        if (((ulong)ptr & 0x7) != 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* msg = "[!] MPU BLOCKED: UNALIGNED POINTER FREE DETECTED!\n\0") Terminal.Print(msg);
            HeapLock.ReleaseSafe(irq); 
            Scheduler.TerminateCurrentTask();
            return;
        }

        // Kiểm tra xem con trỏ có nằm trong heap không
        if ((byte*)ptr < HeapStart + sizeof(HeapBlock) || 
            (byte*)ptr >= HeapStart + HeapTotalSize - sizeof(HeapBlock) - 4)
        {
            Terminal.SetColor(0x00FF0000);
            fixed (char* msg = "[!] MPU BLOCKED: WILD POINTER FREE DETECTED!\n\0") Terminal.Print(msg);
            HeapLock.ReleaseSafe(irq); 
            Scheduler.TerminateCurrentTask();
            return;
        }

        HeapBlock* block = (HeapBlock*)((byte*)ptr - sizeof(HeapBlock));

        if (block->Magic != 0xDEADBEEF)
        {
            Terminal.SetColor(0x00FF0000);
            fixed (char* msg = "[!] MPU FATAL: HEAP CORRUPTION! INVALID HEADER MAGIC!\n\0") Terminal.Print(msg);
            
            HeapLock.ReleaseSafe(irq); 
            Scheduler.TerminateCurrentTask();
            while(true) IO.Hlt(); 
        }

        // Kiểm tra xem block có đang được sử dụng không
        if (block->IsFree == 1)
        {
            Terminal.SetColor(0x00FF0000);
            fixed (char* msg = "[!] MPU WARNING: DOUBLE FREE DETECTED!\n\0") Terminal.Print(msg);
            HeapLock.ReleaseSafe(irq); 
            return;
        }

        uint tailDog = *(uint*)((byte*)ptr + block->ExactSize);
        if (tailDog != 0xDEADBEEF)
        {
            Terminal.SetColor(0x00FF0000);
            fixed (char* msg = "\n[!] MPU FATAL: HEAP BUFFER OVERFLOW DETECTED!\n\0") Terminal.Print(msg);
            
            HeapLock.ReleaseSafe(irq); 
            Scheduler.TerminateCurrentTask();
            while(true) IO.Hlt(); 
        }

        block->IsFree = 1;
        
        // Chốt trạng thái Free trước khi bước vào dọn rác!
        StoreFence();

        HeapBlock* current = Head;
        while (current != null)
        {
            // ==========================================================
            // [BỌC THÉP COMPILER] Ép LLVM không gộp lệnh khi duyệt Merge!
            // ==========================================================
            CompilerFence();

            if (current->Magic != 0xDEADBEEF) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* msg = "[!] MPU FATAL: HEAP CHAIN BROKEN DURING MERGE!\n\0") Terminal.Print(msg);
                HeapLock.ReleaseSafe(irq); 
                Scheduler.TerminateCurrentTask();
                while(true) IO.Hlt(); 
            }

            if (current->IsFree == 1 && current->Next != null && current->Next->IsFree == 1)
            {
                if (current->Next->Magic != 0xDEADBEEF) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* msg = "[!] MPU FATAL: NEXT BLOCK CORRUPTED!\n\0") Terminal.Print(msg);
                    HeapLock.ReleaseSafe(irq); 
                    Scheduler.TerminateCurrentTask();
                    while(true) IO.Hlt(); 
                }

                // Kiểm tra xem việc hợp nhất có nằm trong giới hạn heap không
                ulong newBlockSize = current->Size + current->Next->Size + (ulong)sizeof(HeapBlock);
                if (newBlockSize > HeapTotalSize) {
                    // Vượt quá giới hạn heap, không hợp nhất
                    current = current->Next;
                    continue;
                }
                
                current->Size += current->Next->Size + (ulong)sizeof(HeapBlock);
                current->Next = current->Next->Next;
                
                // ==========================================================
                // [BỌC THÉP PHẦN CỨNG] 
                // Vừa hợp nhất 2 Block xong! Ép xả Store Buffer để nối lại sợi 
                // xích Linked List trên RAM thực tế, chống đứt xích!
                // ==========================================================
                StoreFence();
            }
            else current = current->Next; 
        }

        HeapLock.ReleaseSafe(irq);
    }
}