// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// (No deferred mapping table; keep scheduler/thread layout unchanged.)

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct Thread
{
    public ulong Rsp;           
    public byte Active; // 0 = Dead (can't be choose) 
                        // 1 = Runnable (can be choose)
                        // 2 = Sleeping (can't be choose)
                        // 3 = Being Created (can't be choose) 
                        // 4 = Zombie (can't be choose)     
    public byte IsJailed;       
    public byte IsPhantomDead;  
    public byte Padding1;       
    public int ParentId;        
    
    public int ExecutingOnCore; // Where process running on? (Core 0, 1, 2, etc.)
    public uint PaddingNew;     
    
    public ulong PaddingAlign;  
    
    public ulong AppHeapBase;   
    public ulong KernelStackTop;
    public ulong Pml4;          
    public uint UID;            
    public uint GID;            
    public ulong SharedMemPhys; 
    public ulong SharedMemVirt; 
    public fixed byte Name[16];
    
    public ulong CpuTicks; // CPU Usage - for top.exe usage only
    public uint PhysPages;      
    public uint VirtPages;      
    public ulong WakeUpTick;    
    public ulong VRuntime; // Virtual Runtime
    public byte Priority;
    public uint TextColor; // [FIX MÀU CHỮ] Màu chữ hiện tại của RIÊNG tiến trình này -
                            // trước đây dùng 1 biến global chung (Terminal.fgColor), khiến
                            // các luồng/core chạy song song ghi đè màu của nhau vô tội vạ.
    public fixed byte Padding3[11];
    public fixed byte FpuState[512];
}

public static unsafe class Scheduler
{
    [DllImport("*", EntryPoint = "GetCS")] public static extern ushort GetCS();
    [DllImport("*", EntryPoint = "GetSS")] public static extern ushort GetSS();
    [DllImport("*", EntryPoint = "ForceYield")] public static extern void Yield();
    [DllImport("*", EntryPoint = "SaveFPU")] public static extern void SaveFPU(void* buffer);
    [DllImport("*", EntryPoint = "RestoreFPU")] public static extern void RestoreFPU(void* buffer);
    [DllImport("*", EntryPoint = "GetRflags")] public static extern ulong GetRflags();

    [DllImport("*", EntryPoint = "LockScheduler")] public static extern void LockScheduler();
    [DllImport("*", EntryPoint = "UnlockScheduler")] public static extern void UnlockScheduler();

    public static bool AcquireSchedLockSafe() {
        bool irq = (GetRflags() & 0x200) != 0; 
        IO.Cli(); LockScheduler(); return irq;
    }
    public static void ReleaseSchedLockSafe(bool irq) {
        UnlockScheduler(); if (irq) IO.EnableInterrupts();
    }

    public static Thread* Threads;
    public static int ThreadCount = 0;
    public static bool Ready = false;
    public static int ForegroundTask = -1;

    public static Spinlock SchedLock = new Spinlock();
    public static int* CurrentThreadIds;
    public static int* IdleThreadIds;
    
    // ==========================================================
    // [SCHEDULER] Zombie thread tracking array
    // ==========================================================
    public static int* DyingThreadPerCore;

    public static ulong SystemTicks = 0;

    public static int CurrentThreadId {
        get {
            if (CurrentThreadIds == null) return 0;
            if (!APIC.IsAwake) return CurrentThreadIds[0];
            uint coreId = APIC.Read(0x020) >> 24;
            // [FIX CRITICAL] Guard against out-of-bounds or uninitialized (-1)
            if (coreId >= 256) return 0;
            int tid = CurrentThreadIds[coreId];

            // [FIX CVE-2026-008] Extra safety: check Threads không null và tid trong range
            if (Threads == null || tid < 0 || tid >= ThreadCount) return 0;

            return tid;
        }
    }

    public static void Init()
    {
        Threads = (Thread*)PMM.AllocateContiguousPages(64);
        if (Threads == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate Threads memory!\n\0") Terminal.Print(err);
            return;
        }
        LibC.MemSet((byte*)Threads, 0, 64 * 4096);
        
        CurrentThreadIds = (int*)PMM.AllocatePage();
        if (CurrentThreadIds == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate CurrentThreadIds memory!\n\0") Terminal.Print(err);
            return;
        }
        IdleThreadIds = (int*)PMM.AllocatePage();
        if (IdleThreadIds == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate IdleThreadIds memory!\n\0") Terminal.Print(err);
            PMM.FreePage(CurrentThreadIds);
            return;
        }
        DyingThreadPerCore = (int*)PMM.AllocatePage();
        if (DyingThreadPerCore == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate DyingThreadPerCore memory!\n\0") Terminal.Print(err);
            PMM.FreePage(CurrentThreadIds);
            PMM.FreePage(IdleThreadIds);
            return;
        }

        // Tẩy não toàn bộ! Đéo cho thằng nào nhận vơ là Thread 0!
        for (int i = 0; i < 256; i++) {
            CurrentThreadIds[i] = -1;
            IdleThreadIds[i] = -1;
        }

        CurrentThreadIds[0] = 0;
        IdleThreadIds[0] = 0;

        for (int i = 0; i < 256; i++) DyingThreadPerCore[i] = -1;

        Threads[0].Active = 1;
        Threads[0].KernelStackTop = GDT.Tss->Rsp0;
        Threads[0].Pml4 = (ulong)VMM.PML4;
        Threads[0].UID = 0;
        Threads[0].GID = 0;
        Threads[0].TextColor = 0x00FFFFFF;
        Threads[0].ParentId = 0;
        Threads[0].ExecutingOnCore = 0; 
        // ==========================================================
        // [SCHEDULER RACE FIX] Thread 0 must be flagged as idle-pinned (Priority = 99)
        // Thread 0 (Kernel boot thread) serves as IdleThreadIds[0], the fallback task for Core 0.
        // Previously, it had normal priority (Priority = 1), causing other cores'
        // task stealers to select it, leading to concurrency issues.
        // Setting Priority = 99 pins it exclusively to Core 0.
        // ==========================================================
        // "Threads[current].ExecutingOnCore = -1;" ngay dưới), Thread 0 sẽ 
        // LỌT ĐIỀU KIỆN STEAL vì Priority=1 != 99! Core phụ (AP) hoàn toàn 
        // có thể "cướp" chạy Thread 0 CÙNG LÚC với core 0 - HAI LÕI DÙNG CHUNG 
        // MỘT KERNEL STACK ĐỒNG THỜI => tan nát toàn bộ ngữ cảnh (RAX/RSP/CS
        // rác), gây GPF ngẫu nhiên y hệt triệu chứng "thoắt ẩn thoắt hiện"!
        // Phải ép Priority=99 giống hệt mọi Idle Task khác để nó KHÔNG BAO GIỜ
        // bị core khác cướp - chỉ dành riêng cho Core 0 dùng làm Idle Loop.
        // ==========================================================
        Threads[0].Priority = 99; 
        
        Threads[0].Name[0] = (byte)'K'; Threads[0].Name[1] = (byte)'E'; Threads[0].Name[2] = (byte)'R'; Threads[0].Name[3] = (byte)'N'; 
        Threads[0].Name[4] = (byte)'E'; Threads[0].Name[5] = (byte)'L'; Threads[0].Name[6] = 0;

        SaveFPU(Threads[0].FpuState);

        ThreadCount = 1;
        Ready = true;
        // No deferred pending mappings to initialize.
        Terminal.SetColor(0x0000FF00);
        fixed (char* msg = "[+] Multiverse Scheduler Initialized! Threads Isolated.\n\0") Terminal.Print(msg);
    }

    // ==========================================================
    // CỖ MÁY CẤP GIƯỜNG NGỦ (IDLE THREAD) CHO TỪNG LÕI CPU!
    // ==========================================================
    public static void CreateIdleTaskForCore(uint coreId)
    {
        // Kiểm tra xem coreId có nằm trong phạm vi hợp lệ không
        if (coreId >= 256) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid core ID in CreateIdleTaskForCore!\n\0") Terminal.Print(err);
            return;
        }

        bool irq = AcquireSchedLockSafe(); 
        int id = GetFreeThreadSlot();

        // Kiểm tra xem id có hợp lệ không
        if (id < 0 || id >= ThreadCount) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid thread ID in CreateIdleTaskForCore!\n\0") Terminal.Print(err);
            ReleaseSchedLockSafe(irq);
            return;
        }
        
        Threads[id].Active = 1; 
        Threads[id].Priority = 99; // Cờ 99 = Tầng lớp đáy xã hội, chỉ chạy khi rảnh
        Threads[id].ExecutingOnCore = (int)coreId; // Trói chặt vào Lõi này!
        Threads[id].Name[0] = (byte)'I'; Threads[id].Name[1] = (byte)'D'; Threads[id].Name[2] = (byte)'L'; Threads[id].Name[3] = (byte)'E';
        
        ulong* kStackBase = (ulong*)PMM.AllocateContiguousPages(4); // Xin hẳn 4 Page (16KB)
        if (kStackBase == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate kernel stack for idle task!\n\0") Terminal.Print(err);
            ReleaseSchedLockSafe(irq);
            return;
        }

        ulong* kStackTop = kStackBase + 2048; // 2048 ulong = 16384 bytes
        Threads[id].KernelStackTop = (ulong)kStackTop;

        // Defensive checks: ensure stack top is a sensible kernel virtual address.
        if ((ulong)kStackTop < 0x10000 || (ulong)kStackTop >= PMM.TotalPages * 4096UL) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Allocated kernel stack invalid in CreateIdleTaskForCore!\n\0") Terminal.Print(err);
            PMM.FreePage(kStackBase);
            ReleaseSchedLockSafe(irq);
            return;
        }

        // ==========================================================
        // [ALIGNMENT] ABI stack alignment for C# runtime entry
        // Previously, rspValue was aligned strictly to 16-byte boundaries (rspValue &= ~0xFUL).
        // Since KernelIdleLoop is entered directly via IRETQ rather than a CALL instruction,
        // we must subtract 8 bytes to satisfy the C# compiler assumption of RSP ≡ 8 (mod 16)
        // at function entry. Missing this offset causes alignment faults on SSE instructions.
        // ==========================================================
        // (movaps) bên trong hàm sẽ #GP ngay khi vừa nhảy vào KernelIdleLoop!
        // Phải bắt chước đúng như CreateTask() đã làm: đẩy thêm 1 word rác
        // để RSP lệch đúng 8 so với bội số 16, y hệt hành vi của CALL.
        // ==========================================================
        *(--kStackTop) = 0; 
        ulong rspValue = (ulong)kStackTop;
        
        *(--kStackTop) = GetSS();
        *(--kStackTop) = rspValue;
        *(--kStackTop) = 0x202;
        *(--kStackTop) = GetCS();
        // Validate KernelIdleLoop pointer before writing it to stack
        ulong idleAddr = (ulong)(delegate*<void>)&Program.KernelIdleLoop;
        if (idleAddr < 4096 || !VMM.IsCanonical(idleAddr)) {
            Terminal.SetColor(0x00FF00);
            fixed(char* warn = "[WARN] KernelIdleLoop pointer invalid, using fallback\n\0") Terminal.Print(warn);
            *(--kStackTop) = idleAddr;
        } else {
            *(--kStackTop) = idleAddr; // Cho xài chung hàm KernelIdleLoop của Lõi 0 luôn!
        }
        
        for (int j = 0; j < 15; j++) *(--kStackTop) = 0;
        
        Threads[id].Rsp = (ulong)kStackTop;
        Threads[id].Pml4 = (ulong)VMM.PML4;
        
        IdleThreadIds[coreId] = id; // Giao sổ đỏ!
        ReleaseSchedLockSafe(irq);
    }

    [UnmanagedCallersOnly(EntryPoint = "YieldHandler")]
    public static ulong YieldHandler(ulong currentRsp) 
    { 
        return SwitchTask(currentRsp); 
    }

    public static ulong SwitchTask(ulong currentRsp)
    {
        LockScheduler();

        if (!Ready) { UnlockScheduler(); return currentRsp; } 
        
        uint coreId = APIC.IsAwake ? (APIC.Read(0x020) >> 24) : 0;

        // Kiểm tra xem coreId có nằm trong phạm vi hợp lệ không
        if (coreId >= 256) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid core ID in SwitchTask!\n\0") Terminal.Print(err);
            UnlockScheduler();
            return currentRsp;
        }
        
        if (DyingThreadPerCore[coreId] != -1) {
            int zombieId = DyingThreadPerCore[coreId];
            ulong zombiePml4 = Threads[zombieId].Pml4;
            Threads[zombieId].Active = 0;
            DyingThreadPerCore[coreId] = -1;

            if (zombiePml4 != 0 && zombiePml4 != (ulong)VMM.PML4) {
                UnlockScheduler();
                VMM.DestroyUserSpace(zombiePml4);
                LockScheduler();
            }
        }

        // [FIX TRIỆT ĐỂ] Quét và cleanup TẤT CẢ zombies còn lại (Active == 4)
        // Đảm bảo không leak resources ngay cả khi nhiều threads bị kill cùng lúc
        for (int i = 0; i < ThreadCount; i++) {
            if (Threads[i].Active == 4) {
                ulong zombiePml4 = Threads[i].Pml4;
                Threads[i].Active = 0;

                if (zombiePml4 != 0 && zombiePml4 != (ulong)VMM.PML4) {
                    UnlockScheduler();
                    VMM.DestroyUserSpace(zombiePml4);
                    LockScheduler();
                }
            }
        }

        int current = CurrentThreadIds[coreId];

        // ==========================================================
        // [SCHEDULER] Avoid out-of-bounds array access on boot
        // When AP cores first boot, current is initialized to -1.
        // Skip context saving if there is no active previous thread context.
        // ==========================================================
        if (current != -1 && Threads[current].Active != 0)
        {
            if (Threads[current].Active == 4) {
                DyingThreadPerCore[coreId] = current; 
            } 
            else {
                SaveFPU(Threads[current].FpuState); 
                
                if (Threads[current].Active == 1) 
                {
                    Threads[current].CpuTicks++;

                    // If Priority = 99, then that's threads it's a idle thread
                    if (Threads[current].Priority != 99) {
                        // Whole algorithms here! Damn
                        ulong weight = (ulong)Threads[current].Priority;
                        if (weight == 0) weight = 1; 
                        Threads[current].VRuntime += weight; 
                    }
                }
                Threads[current].Rsp = currentRsp;
            }
        }

        // Cũng phải chặn ở đây nữa!
        if (current != -1) Threads[current].ExecutingOnCore = -1;

        ulong currentTicks = SystemTicks; 
        ulong sysMinVRuntime = 0xFFFFFFFFFFFFFFFF;
        for (int i = 0; i < ThreadCount; i++) {
            if (Threads[i].Active == 1 && Threads[i].ExecutingOnCore == -1 && Threads[i].Priority != 99) {
                if (Threads[i].VRuntime < sysMinVRuntime) sysMinVRuntime = Threads[i].VRuntime;
            }
        }

        for (int i = 0; i < ThreadCount; i++) {
            if (Threads[i].Active == 2 && currentTicks >= Threads[i].WakeUpTick) {
                Threads[i].Active = 1; 
                if (sysMinVRuntime != 0xFFFFFFFFFFFFFFFF && Threads[i].VRuntime < sysMinVRuntime) {
                    Threads[i].VRuntime = sysMinVRuntime; 
                }
            }
        }

        int bestId = -1; 
        ulong minVRuntime = 0xFFFFFFFFFFFFFFFF;
        for (int i = 0; i < ThreadCount; i++) {
            if (Threads[i].Active == 1 && Threads[i].ExecutingOnCore == -1 && Threads[i].Priority != 99 && Threads[i].VRuntime < minVRuntime) {
                minVRuntime = Threads[i].VRuntime;
                bestId = i;
            }
        }

        if (bestId == -1) bestId = IdleThreadIds[coreId];

        CurrentThreadIds[coreId] = bestId;
        Threads[bestId].ExecutingOnCore = (int)coreId;

        ulong nextRsp = Threads[bestId].Rsp;
        ulong nextKStack = Threads[bestId].KernelStackTop;
        ulong nextPml4 = Threads[bestId].Pml4;

        if (nextKStack != 0) {
            if (coreId == 0) GDT.Tss->Rsp0 = nextKStack;
            else if (SMP.CoreTssList != null && SMP.CoreTssList[coreId] != null) SMP.CoreTssList[coreId]->Rsp0 = nextKStack;
        }

        if (nextPml4 == 0 || !VMM.IsCanonical(nextPml4) || nextPml4 >= PMM.TotalPages * 4096UL)
        {
            nextPml4 = (ulong)VMM.PML4;
            Threads[bestId].Pml4 = (ulong)VMM.PML4;
        }
        VMM.LoadPML4_ASM((void*)nextPml4);

        // No per-thread deferred mappings to process here.

        RestoreFPU(Threads[bestId].FpuState);

        UnlockScheduler();

        return nextRsp;
    }

    public static int GetFreeThreadSlot()
    {
        // Kiểm tra xem ThreadCount có nằm trong phạm vi hợp lệ không
        if (ThreadCount < 1 || ThreadCount > 256) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid thread count in GetFreeThreadSlot!\n\0") Terminal.Print(err);
            return -1;
        }
        
        for (int i = 1; i < ThreadCount; i++) { 
            if (Threads[i].Active == 0) return i; 
        }
        
        if (ThreadCount < 256) { 
            int newId = ThreadCount; 
            ThreadCount++; 
            return newId; 
        } 
        
        return -1; 
    }

    public static void CreateTask(delegate* <void> entryPoint)
    {
        bool irq = AcquireSchedLockSafe(); 
        int id = GetFreeThreadSlot();
        if (id == -1) { ReleaseSchedLockSafe(irq); return; }

        // Kiểm tra xem id có hợp lệ không
        if (id < 0 || id >= ThreadCount) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid thread ID in CreateTask!\n\0") Terminal.Print(err);
            ReleaseSchedLockSafe(irq);
            return;
        }

        Threads[id].Active = 3; 

        ulong* stackTop;
        if (Threads[id].KernelStackTop == 0) {
            ReleaseSchedLockSafe(irq);
            ulong* stackBase = (ulong*)PMM.AllocateContiguousPages(4);
            irq = AcquireSchedLockSafe(); 
            if (stackBase == null) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Failed to allocate kernel stack for task!\n\0") Terminal.Print(err);
                Threads[id].Active = 0;
                ReleaseSchedLockSafe(irq);
                return;
            }
            stackTop = stackBase + 2048;
            Threads[id].KernelStackTop = (ulong)stackTop;
        } else {
            stackTop = (ulong*)Threads[id].KernelStackTop;
            // ==========================================================
            // [STACK MANAGEMENT] Avoid MemSet on stack recycling
            // When recycling stacks, overwrite stack top values directly.
            // MemSet operations on active stacks can lead to data races and crash other cores.
            // ==========================================================
        }

        *(--stackTop) = 0; ulong originalTop = (ulong)stackTop;
        *(--stackTop) = GetSS(); *(--stackTop) = originalTop; *(--stackTop) = 0x202; *(--stackTop) = GetCS();
        // Validate entryPoint before placing on stack
        ulong epAddr = (ulong)entryPoint;
        if (entryPoint == null || epAddr < 4096 || !VMM.IsCanonical(epAddr)) {
            Terminal.SetColor(0x00FF00);
            fixed(char* warn = "[WARN] Invalid entryPoint in CreateTask, using KernelIdleLoop fallback\n\0") Terminal.Print(warn);
            *(--stackTop) = (ulong)(delegate*<void>)&Program.KernelIdleLoop;
        } else {
            *(--stackTop) = epAddr; 
        }
        for (int i = 0; i < 15; i++) *(--stackTop) = 0;
        
        Threads[id].Rsp = (ulong)stackTop; 
        Threads[id].Pml4 = (ulong)VMM.PML4;
        Threads[id].ExecutingOnCore = -1; 
        
        Threads[id].Active = 1;
        ReleaseSchedLockSafe(irq);
    }

    public static void CreateUserTask(delegate*<void> entryPoint, ulong appPml4, bool isForeground = true, bool isJailed = false, bool forceRoot = false, char* processName = null, uint imagePages = 0, byte priority = 1)
    {
        int _unusedId;
        CreateUserTask(entryPoint, appPml4, out _unusedId, isForeground, isJailed, forceRoot, processName, imagePages, priority);
    }

    // [FIX CRITICAL #1] Overload trả về thread ID vừa tạo qua tham số out - cho phép Kernel.cs
    // ghi nhận danh tính THẬT của các Daemon hệ thống (vd: FAT16 Daemon) ngay tại thời điểm
    // tạo tiến trình (do chính Kernel tự spawn lúc boot, không thể bị giả mạo), thay vì phải
    // tin vào Thread.Name (chuỗi do người dùng cung cấp qua lệnh "run"/"daemon", CÓ THỂ bị
    // giả mạo) hay đợi IPC handshake (có race lúc Daemon tự đọc boot sector trước khi handshake).
    public static void CreateUserTask(delegate*<void> entryPoint, ulong appPml4, out int newThreadId, bool isForeground = true, bool isJailed = false, bool forceRoot = false, char* processName = null, uint imagePages = 0, byte priority = 1)
    {
        newThreadId = -1;
        if (entryPoint == null || (ulong)entryPoint < 4096 || !VMM.IsCanonical((ulong)entryPoint)) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] Scheduler Blocked: Garbage PE EntryPoint! IPC/FAT16 Delivery Failed!\n\0") Terminal.Print(err);
            Terminal.SetColor(0x00FFFFFF);
            return;
        }

        // Kiểm tra xem appPml4 có null không
        if (appPml4 == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PML4 in CreateUserTask!\n\0") Terminal.Print(err);
            Terminal.SetColor(0x00FFFFFF);
            return;
        }

        bool irq = AcquireSchedLockSafe(); 
        int id = GetFreeThreadSlot();
        if (id == -1) { ReleaseSchedLockSafe(irq); return; }

        // Kiểm tra xem id có hợp lệ không
        if (id < 0 || id >= ThreadCount) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid thread ID in CreateUserTask!\n\0") Terminal.Print(err);
            ReleaseSchedLockSafe(irq);
            return;
        }

        Threads[id].Active = 3; 
        
        LibC.MemCpy(Threads[id].FpuState, Threads[0].FpuState, 512);

        // Kiểm tra xem Threads[0].FpuState có được khởi tạo chưa
        if (Threads[0].FpuState == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: FPU state not initialized in CreateUserTask!\n\0") Terminal.Print(err);
            ReleaseSchedLockSafe(irq);
            return;
        }
        
        uint coreId = APIC.IsAwake ? (APIC.Read(0x020) >> 24) : 0;
        int currentParent = CurrentThreadIds[coreId];

        ulong* kStackTop;
        if (Threads[id].KernelStackTop == 0) {
            ReleaseSchedLockSafe(irq);
            ulong* kStackBase = (ulong*)PMM.AllocateContiguousPages(4);
            irq = AcquireSchedLockSafe(); 
            if (kStackBase == null) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Failed to allocate kernel stack for user task!\n\0") Terminal.Print(err);
                ReleaseSchedLockSafe(irq);
                return;
            }
            kStackTop = kStackBase + 2048; 
            Threads[id].KernelStackTop = (ulong)kStackTop;
        } else {
            kStackTop = (ulong*)Threads[id].KernelStackTop;
            // ==========================================================
            // [STACK MANAGEMENT] Overwrite values directly to recycle stack
            // ==========================================================
        }

        ulong stackVirtualBase = PRNG.Next(0x0000600000000000, 0x0000700000000000) & ~0xFFFUL;
        ulong stackPages = 4; 
        
        ReleaseSchedLockSafe(irq);
        for (ulong i = 0; i < stackPages; i++) {
            ulong physPage = (ulong)PMM.AllocatePage(); 
            if (physPage == 0) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Failed to allocate stack page in CreateUserTask!\n\0") Terminal.Print(err);
                return;
            }
            VMM.MapPage(physPage, stackVirtualBase + (i * 4096), 0x07, (ulong*)appPml4); 
        }
        irq = AcquireSchedLockSafe(); 
        
        ulong appStackTop = stackVirtualBase + 0x3FF8;

        ulong rflags = 0x202;
        if (forceRoot || Threads[currentParent].UID == 0) {
            rflags = 0x3202; // IOPL=3 cho Root Daemon: Chạy IN/OUT qua vDSO không cần IOPB
        }

        *(--kStackTop) = 0;     
        *(--kStackTop) = 0x1B; 
        *(--kStackTop) = appStackTop; 
        *(--kStackTop) = rflags; 
        *(--kStackTop) = 0x23; 
        *(--kStackTop) = (ulong)entryPoint;

        for (int i = 0; i < 15; i++) *(--kStackTop) = 0;

        Threads[id].Rsp = (ulong)kStackTop; 
        Threads[id].Pml4 = appPml4;
        Threads[id].IsJailed = (byte)(isJailed ? 1 : 0);
        Threads[id].IsPhantomDead = 0; 
        Threads[id].CpuTicks = 0;
        Threads[id].PhysPages = 5 + imagePages; 
        Threads[id].VirtPages = 5 + imagePages;
        
        ulong minHeapVirtual = 0x0000700000000000; 
        ulong maxHeapVirtual = 0x0000780000000000; 
        Threads[id].AppHeapBase = PRNG.Next(minHeapVirtual, maxHeapVirtual) & ~0xFFFUL;
        
        if (forceRoot) { Threads[id].UID = 0; Threads[id].GID = 0; }
        else { Threads[id].GID = Threads[currentParent].GID; Threads[id].UID = Threads[currentParent].UID; }
        Threads[id].TextColor = 0x00FFFFFF; // [FIX MÀU CHỮ] Mặc định trắng, riêng cho từng tiến trình

        LibC.MemCpy(Threads[id].FpuState, Threads[0].FpuState, 512);

        if (processName != null) {
            for (int i = 0; i < 15; i++) {
                if (processName[i] == '\0') { Threads[id].Name[i] = 0; break; }
                Threads[id].Name[i] = (byte)processName[i];
            }
            Threads[id].Name[15] = 0; 
        } else {
            Threads[id].Name[0] = (byte)'U'; Threads[id].Name[1] = (byte)'N'; Threads[id].Name[2] = (byte)'K'; Threads[id].Name[3] = 0;
        }

        Threads[id].ParentId = currentParent;
        Threads[id].Priority = priority; 
        Threads[id].VRuntime = Threads[currentParent].VRuntime;
        Threads[id].ExecutingOnCore = -1; 

        if (isForeground) ForegroundTask = id;

        Threads[id].Active = 1;
        newThreadId = id;
        ReleaseSchedLockSafe(irq);
    }

    public static void TerminateTask(int id)
    {
        bool irq = AcquireSchedLockSafe(); 
        
        if (id <= 0 || id >= ThreadCount || Threads[id].Active == 0 || Threads[id].Priority == 99) {
            ReleaseSchedLockSafe(irq); return;
        }

        uint coreId = APIC.IsAwake ? (APIC.Read(0x020) >> 24) : 0;

        while (Threads[id].ExecutingOnCore != -1 && Threads[id].ExecutingOnCore != coreId)
        {
            ReleaseSchedLockSafe(irq);
            Yield(); 
            irq = AcquireSchedLockSafe();
        }

        if (ForegroundTask == id) {
            ForegroundTask = Threads[id].ParentId;
            Terminal.SetColor(0x00FFFFFF);
        }

        Threads[id].UID = 9999; Threads[id].GID = 9999; Threads[id].AppHeapBase = 0;
        IPC.ClearMailbox((uint)id);

        // [CVE-2026-012 ANALYSIS] SharedMemPhys is already freed by VMM.DestroyUserSpace()
        // when it walks the page tables. No explicit free needed here - it would be a double free!
        Threads[id].SharedMemPhys = 0; Threads[id].SharedMemVirt = 0;

        bool isSelf = (id == CurrentThreadIds[coreId]);
        ulong dyingPml4 = 0;

        if (Threads[id].Pml4 != 0 && Threads[id].Pml4 != (ulong)VMM.PML4) {
            dyingPml4 = Threads[id].Pml4;
            Threads[id].Pml4 = 0;
            if (isSelf) VMM.LoadPML4_ASM((void*)VMM.PML4);
        }

        if (isSelf) {
            Threads[id].Active = 4; // ZOMBIE! Cấm đứa khác đụng vào Stack!
        } else {
            Threads[id].Active = 0; // Đứa khác chết thì chôn ngay lập tức (Xóa MemSet rồi nên an toàn tuyệt đối).
        }

        ReleaseSchedLockSafe(irq);

        if (dyingPml4 != 0) {
            // Prevent preemption during physical memory free to avoid races
            // (matches pattern used in interrupt handlers).
            IO.DisableInterrupts();
            VMM.DestroyUserSpace(dyingPml4);
            IO.EnableInterrupts();
        }

        if (isSelf) Yield(); 
    }

    public static void TerminateCurrentTask() { TerminateTask(CurrentThreadId); }
}