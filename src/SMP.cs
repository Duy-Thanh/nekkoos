using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct TSS64 {
    public uint Reserved0; public ulong Rsp0; public ulong Rsp1; public ulong Rsp2;
    public ulong Reserved1; public ulong Ist1, Ist2, Ist3, Ist4, Ist5, Ist6, Ist7;
    public ulong Reserved2; public ushort Reserved3; public ushort IoMapBase;
}

public static unsafe class SMP
{
    private const uint ICR_LOW = 0x300;
    private const uint ICR_HIGH = 0x310;
    public static uint CoreCountAwake = 1; 
    public static uint* CoreReadyAcks; 
    public static Spinlock SmpLock = new Spinlock();

    [DllImport("*", EntryPoint = "GetIdtr")] public static extern void GetIdtr(void* ptr);
    [DllImport("*", EntryPoint = "LoadIdt")] public static extern void LoadIdt(void* ptr);
    [DllImport("*", EntryPoint = "LoadGDT")] public static extern void LoadGDT(void* ptr);
    [DllImport("*", EntryPoint = "LoadTSS")] public static extern void LoadTSS(ushort sel);
    
    [DllImport("*", EntryPoint = "WriteMmio32")] public static extern void WriteMmio32(ulong address, uint value);
    [DllImport("*", EntryPoint = "ReadMmio32")] public static extern uint ReadMmio32(ulong address);

    [DllImport("*", EntryPoint = "CompilerFence")] public static extern void CompilerFence();
    [DllImport("*", EntryPoint = "LoadFence")] public static extern void LoadFence();
    [DllImport("*", EntryPoint = "StoreFence")] public static extern void StoreFence();
    [DllImport("*", EntryPoint = "FullFence")] public static extern void FullFence();

    public static byte* SharedIdtr = null;
    public static TSSEntry** CoreTssList;

    [UnmanagedCallersOnly(EntryPoint = "ApEntryPoint")]
    public static void ApEntryPoint()
    {
        VMM.LoadPML4_ASM(VMM.PML4);

        uint myId = APIC.Read(0x020) >> 24;

        // Kiểm tra xem myId có nằm trong phạm vi hợp lệ không
        if (myId >= 256) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid CPU core ID in ApEntryPoint!\n\0") Terminal.Print(err);
            return;
        }

        while (myId == 0) { 
            CompilerFence(); // [BỌC THÉP] Chống LLVM cache myId!
            myId = APIC.Read(0x020) >> 24; 
        }

        // Kiểm tra xem CoreReadyAcks có được khởi tạo chưa
        if (CoreReadyAcks == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: CoreReadyAcks not initialized in ApEntryPoint!\n\0") Terminal.Print(err);
            return;
        }

        WriteMmio32((ulong)&CoreReadyAcks[myId], 1);
        StoreFence(); // [BỌC THÉP] Ép RAM cập nhật cờ Ack ngay lập tức!

        APIC.Write(0x0F0, 0x1FF); 
        LoadIdt(SharedIdtr);

        ulong* gdt = (ulong*)PMM.AllocatePage();
        if (gdt == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate GDT page in APEntryPoint!\n\0") Terminal.Print(err);
            return;
        }

        gdt[0] = 0; gdt[1] = 0x00209A0000000000; gdt[2] = 0x0000920000000000; 
        gdt[3] = 0x0000F20000000000; gdt[4] = 0x0020FA0000000000; gdt[5] = 0;                  

        TSSEntry* tss = (TSSEntry*)PMM.AllocateContiguousPages(3);
        if (tss == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate TSS pages in APEntryPoint!\n\0") Terminal.Print(err);
            return;
        }
        LibC.MemSet((byte*)tss, 0, (uint)sizeof(TSSEntry));
        for (int i = 0; i < 8192; i++) tss->Iopb[i] = 0xFF;
        tss->EndMarker = 0xFF;

        ulong tssAddr = (ulong)tss;
        ulong iopbAddr = (ulong)&(tss->Iopb[0]);
        tss->IopbOffset = (ushort)(iopbAddr - tssAddr);

        CoreTssList[myId] = tss; 

        uint tssLimit = (uint)sizeof(TSSEntry) - 1;
        ulong limitLow = tssLimit & 0xFFFF;
        ulong baseLow = tssAddr & 0xFFFF;
        ulong baseMid = (tssAddr >> 16) & 0xFF;
        ulong access = 0x89;
        ulong flags = (tssLimit >> 16) & 0x0F;
        ulong baseHighVal = (tssAddr >> 24) & 0xFF;

        gdt[6] = limitLow | (baseLow << 16) | (baseMid << 32) | (access << 40) | (flags << 48) | (baseHighVal << 56);
        gdt[7] = tssAddr >> 32;

        ushort* gdtDesc = (ushort*)((byte*)gdt + 2048);
        gdtDesc[0] = (ushort)(8 * 8 - 1);
        *((ulong*)(gdtDesc + 1)) = (ulong)gdt;
        
        LoadGDT(gdtDesc);

        FullFence();
        CompilerFence();

        LoadTSS(0x30);

        FullFence();
        CompilerFence();

        // ==========================================================
        // [FIX CHÍ MẠNG RACE #4] TẠO IDLE THREAD TRƯỚC KHI BẬT NGẮT!
        // CreateIdleTaskForCore() trước đây KHÔNG BAO GIỜ được gọi cho
        // các Lõi phụ (AP)! IdleThreadIds[coreId] luôn = -1 vĩnh viễn.
        // Hệ quả: Nếu Timer IRQ nổ trên lõi này (đã Arm timer + Enable
        // Interrupts ngay bên dưới) TRƯỚC KHI có Thread nào khác sẵn
        // sàng chạy trên đúng lõi này, SwitchTask() sẽ chọn
        // bestId = IdleThreadIds[coreId] = -1, rồi truy cập
        // Threads[-1] => ĐỌC/GHI NGOÀI MẢNG => rác toàn bộ Rsp/Pml4/
        // ExecutingOnCore => sập máy random (GPF/Page Fault/treo/lỗi
        // lạ FAT16) đúng như mô tả "thoắt ẩn thoắt hiện". Phải tạo
        // Idle Task NGAY TẠI ĐÂY, trước khi Arm Timer & Enable Interrupts!
        // ==========================================================
        Scheduler.CreateIdleTaskForCore(myId);

        APIC.Write(0x3E0, 0x03);  
        APIC.Write(0x320, 0x20000 | 32);

        if (APIC.CalibratedTicksPerQuantum != 0) { APIC.Write(0x380, APIC.CalibratedTicksPerQuantum); } 
        else { APIC.Write(0x380, 200000); } 

        bool irq = SmpLock.AcquireSafe();
        CoreCountAwake++;
        Terminal.SetColor(0x00FF00FF);
        fixed (char* m = "[+] CPU Core Online! GDT & TSS Forged! Unleashed into Scheduler!\n\0") Terminal.Print(m);
        SmpLock.ReleaseSafe(irq);

        WriteMmio32((ulong)&CoreReadyAcks[myId], 2);
        StoreFence(); // [BỌC THÉP] Báo hiệu đã Forged xong TSS/GDT!

        IO.EnableInterrupts();
        
        while (ReadMmio32((ulong)&CoreReadyAcks[0]) == 0) { 
            CompilerFence(); // [BỌC THÉP] Đợi Lõi 0 phát lệnh Release!
            IO.Hlt(); 
        }

        LoadFence(); // [BỌC THÉP] Đảm bảo mọi luồng dữ liệu đã được nạp xong trước khi nhảy vào Scheduler!

        while (true) {
            IO.Hlt();
            Scheduler.Yield(); 
        }
    }

    public static void InitAndWakeCores()
    {
        // Kiểm tra xem APIC có được khởi tạo chưa
        if (APIC.LocalApicBaseVirt == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: APIC not initialized in InitAndWakeCores!\n\0") Terminal.Print(err);
            return;
        }
        
        Terminal.SetColor(0x00FFFF00);
        fixed (char* m1 = "[*] SMP Controller: Reading Trampoline Payload...\n\0") Terminal.Print(m1);

        uint smpBinSize = 0;
        fixed (char* fileName = "SMP.BIN\0")
        {
            byte* smpPayload = FAT16.ReadFile(fileName, &smpBinSize);
            if (smpPayload == null || smpBinSize == 0) return;

            VMM.MapPage(0x8000, 0x8000, 0x07); 
            byte* trampoline = (byte*)0x8000;
            for (uint i = 0; i < smpBinSize; i++) trampoline[i] = smpPayload[i];

            ulong* pml4Mailbox = (ulong*)0x8F00;
            ulong* entryMailbox = (ulong*)0x8F08;
            ulong* stackMailbox = (ulong*)0x8F10;

            *pml4Mailbox = (ulong)VMM.PML4;
            *entryMailbox = (ulong)(delegate* unmanaged<void>)&ApEntryPoint;
            // Debug: print mailboxes to help trace AP boot issues
            fixed (char* dbgPml = "[DBG] SMP: pml4Mailbox= \0") Terminal.Print(dbgPml);
            Serial.WriteHex((ulong)*pml4Mailbox);
            fixed (char* dbgNl1 = "\n\0") Terminal.Print(dbgNl1);
            fixed (char* dbgEntry = "[DBG] SMP: entryMailbox= \0") Terminal.Print(dbgEntry);
            Serial.WriteHex((ulong)*entryMailbox);
            fixed (char* dbgNl2 = "\n\0") Terminal.Print(dbgNl2);
            Heap.Free(smpPayload);

            SharedIdtr = (byte*)PMM.AllocatePage();
            if (SharedIdtr == null) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Failed to allocate SharedIdtr page!\n\0") Terminal.Print(err);
                return;
            }

            GetIdtr(SharedIdtr);
            CoreTssList = (TSSEntry**)PMM.AllocatePage();
            if (CoreTssList == null) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Failed to allocate CoreTssList page!\n\0") Terminal.Print(err);
                PMM.FreePage(SharedIdtr);
                return;
            }
            LibC.MemSet((byte*)CoreTssList, 0, 4096); // [FIX] ZERO-FILL CHỐNG RÁC REBOOT!
            
            CoreReadyAcks = (uint*)PMM.AllocatePage();
            if (CoreReadyAcks == null) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Failed to allocate CoreReadyAcks page!\n\0") Terminal.Print(err);
                PMM.FreePage(SharedIdtr);
                PMM.FreePage(CoreTssList);
                return;
            }
            for (int i = 0; i < 256; i++) CoreReadyAcks[i] = 0;

            // Kiểm tra xem APIC.CoreCount có hợp lệ không
            if (APIC.CoreCount == 0 || APIC.CoreCount > 256) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Invalid APIC core count!\n\0") Terminal.Print(err);
                return;
            }

            // ==========================================================
            // [FIX RACE CONDITION SMP/SCHEDULER] DÙNG ĐÚNG KHÓA SCHEDULER!
            // SmpLock là khóa RIÊNG của module SMP, KHÔNG bảo vệ được mảng
            // Threads[] khỏi SwitchTask() (chạy trong Timer/Yield ISR trên
            // Core 0), vì SwitchTask() chỉ chờ Scheduler.LockScheduler().
            // Nếu Timer Interrupt nổ giữa lúc đang ghi dở Threads[id] ở đây
            // (Active=1 đã set nhưng Rsp=0 chưa kịp ghi), SwitchTask() có thể
            // chọn ngay thread nửa vời này làm bestId -> nhảy vào Rsp=0
            // -> Page Fault RIP=0 ngẫu nhiên lúc boot!
            // Phải dùng CHUNG khóa Scheduler thật (tự động Cli() luôn).
            // ==========================================================
            bool irq = Scheduler.AcquireSchedLockSafe(); 
            for (uint i = 1; i < APIC.CoreCount; i++) {
                // Kiểm tra xem i có nằm trong phạm vi hợp lệ không
                if (i >= 256) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Invalid core index in InitAndWakeCores!\n\0") Terminal.Print(err);
                    Scheduler.ReleaseSchedLockSafe(irq);
                    return;
                }
                
                int id = Scheduler.GetFreeThreadSlot();
                if (id < 0 || id >= Scheduler.ThreadCount) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Failed to allocate thread slot for core!\n\0") Terminal.Print(err);
                    Scheduler.ReleaseSchedLockSafe(irq);
                    return;
                }
                Scheduler.IdleThreadIds[i] = id; Scheduler.CurrentThreadIds[i] = id;
                Scheduler.Threads[id].Priority = 99; 
                Scheduler.Threads[id].ExecutingOnCore = (int)i; 
                Scheduler.Threads[id].Pml4 = (ulong)VMM.PML4;
                
                // ==========================================================
                // [FIX CHÍ MẠNG] TĂNG KERNEL STACK TỪ 1 PAGE (4KB) LÊN 4 PAGES (16KB)!
                // ISR push 15 thanh ghi (120 bytes), SaveFPU cần 528 bytes trên Stack,
                // cộng thêm overhead của C# = TRÀN STACK 4KB như chơi!
                // 16KB = An toàn tuyệt đối, khớp với CreateTask/CreateIdleTaskForCore!
                // ==========================================================
                ulong* kStackTop = (ulong*)((byte*)PMM.AllocateContiguousPages(4) + (4 * 4096));

                // Kiểm tra xem kStackTop có null không
                if (kStackTop == null) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Failed to allocate kernel stack for core!\n\0") Terminal.Print(err);
                    Scheduler.ReleaseSchedLockSafe(irq);
                    return;
                }

                Scheduler.Threads[id].KernelStackTop = (ulong)kStackTop; 
                
                // ==========================================================
                // [FIX CHÍ MẠNG TOÀN VŨ TRỤ] DÓNG LỀ ABI CHO IRETQ FRAME!
                // Trừ đi 8 byte giả làm lệnh CALL để cứu sống lệnh MOVAPS!
                // ==========================================================
                *(--kStackTop) = 0;
                *(--kStackTop) = 0; 
                ulong originalTop = (ulong)kStackTop; // <--- CỨU TINH Ở ĐÂY NÀY!
                
                *(--kStackTop) = Scheduler.GetSS(); 
                *(--kStackTop) = originalTop; // <--- NẠP ORIGINAL TOP CHỨ ĐÉO PHẢI KERNELSTACKTOP!
                *(--kStackTop) = 0x202; 
                *(--kStackTop) = Scheduler.GetCS(); 
                
                *(--kStackTop) = (ulong)(delegate*<void>)&Program.KernelIdleLoop;
                
                for (int j = 0; j < 15; j++) *(--kStackTop) = 0;
                
                Scheduler.Threads[id].Rsp = (ulong)kStackTop; 
                Scheduler.Threads[id].Name[0] = (byte)'I'; Scheduler.Threads[id].Name[1] = (byte)'D'; Scheduler.Threads[id].Name[2] = (byte)('0' + i); Scheduler.Threads[id].Name[3] = 0;
                LibC.MemCpy(Scheduler.Threads[id].FpuState, Scheduler.Threads[0].FpuState, 512);

                // [FIX RACE CONDITION SMP/SCHEDULER] CHỈ BẬT Active=1 SAU CÙNG,
                // khi Rsp/Pml4/KernelStackTop đã ghi xong hoàn chỉnh! (Phòng thủ kép,
                // dù đã có khóa đúng ở trên, để tránh SwitchTask() đọc trúng
                // struct nửa vời nếu về sau có code nào đọc Threads[] mà quên khóa.)
                Scheduler.Threads[id].Active = 1; 
            }
            Scheduler.ReleaseSchedLockSafe(irq);

            fixed (char* m2 = "[*] SMP Controller: Trampoline Armed at 0x8000. Sending SIPI Sequence...\n\0") Terminal.Print(m2);

            for (uint i = 1; i < APIC.CoreCount; i++)
            {
                ulong apStackPhys = (ulong)PMM.AllocateContiguousPages(4);
                for (ulong p = 0; p < 4; p++) VMM.MapPage(apStackPhys + (p * 4096), apStackPhys + (p * 4096), 0x03); 
                ulong apStack = apStackPhys + (4 * 4096) - 4096;
                
                WriteMmio32((ulong)&CoreReadyAcks[i], 0); 
                *stackMailbox = apStack;
                fixed (char* dbgStack = "[DBG] SMP: stackMailbox set= \0") Terminal.Print(dbgStack);
                Serial.WriteHex((ulong)*stackMailbox);
                fixed (char* dbgNl3 = "\n\0") Terminal.Print(dbgNl3);

                // ==========================================================
                // [BỌC THÉP BẰNG MFENCE TRƯỚC KHI BẮN IPI]
                // Ép CPU xả toàn bộ lệnh GHI (stackMailbox, CoreReadyAcks) 
                // xuống RAM thực tế trước khi gửi tín hiệu đánh thức Lõi Phụ!
                // ==========================================================
                FullFence();

                APIC.Write(ICR_HIGH, i << 24);
                APIC.Write(ICR_LOW, 0x00004500);
                
                for(int d = 0; d < 10000; d++) IO.In8(0x80); 

                APIC.Write(ICR_HIGH, i << 24);
                APIC.Write(ICR_LOW, 0x00004608);
                
                // ==========================================================
                // [FIX CHÍ MẠNG VŨ TRỤ] KHÓA CHÂN LÕI 0!
                // Phải đợi đến khi thằng ASM của Lõi Phụ bốc xong Stack
                // (nó sẽ set Hòm thư về 0) thì mới được phép đi vòng tiếp theo!
                // Cấm tuyệt đối Data Race Ghi Đè Hòm Thư!
                // ==========================================================
                int stackTimeout = 10000000;
                while (*stackMailbox != 0 && stackTimeout > 0) {
                    // ==========================================================
                    // [BỨC TƯỜNG THÉP] COMPILER FENCE!
                    // Ép LLVM phải reload *stackMailbox từ RAM cho vòng lặp tiếp theo!
                    // ==========================================================
                    CompilerFence();

                    IO.In8(0x80);
                    stackTimeout--;
                }
                
                if (*stackMailbox != 0) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* errS = "[!] SMP Error: Core failed to grab its Stack!\n\0") Terminal.Print(errS);
                    Terminal.SetColor(0x00FFFFFF);
                    continue; // Bỏ qua thằng chết yểu này!
                }

                // Kiểm tra xem stackTimeout có hết không
                if (stackTimeout <= 0) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Stack mailbox timeout for core!\n\0") Terminal.Print(err);
                    Terminal.SetColor(0x00FFFFFF);
                    continue;
                }

                LoadFence(); // [BỌC THÉP] Chặn đứng Speculative Execution lấn lướt qua vòng lặp!

                // Chờ nó Forged GDT/TSS (Phần C# ApEntryPoint của Lõi phụ)
                int timeout = 10000000; 
                while (ReadMmio32((ulong)&CoreReadyAcks[i]) < 2 && timeout > 0) { 
                    CompilerFence(); // RÀO CHẮN Ở ĐÂY NỮA!
                    IO.In8(0x80); 
                    timeout--; 
                }

                // Kiểm tra xem timeout có hết không
                if (timeout <= 0) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: GDT/TSS forge timeout for core!\n\0") Terminal.Print(err);
                    Terminal.SetColor(0x00FFFFFF);
                    continue;
                }

                LoadFence(); // [BỌC THÉP] Chặn đứng Speculative Execution lấn lướt qua vòng lặp!

                if (ReadMmio32((ulong)&CoreReadyAcks[i]) < 2) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] SMP Error: Core failed to forge GDT/TSS in time!\n\0") Terminal.Print(err);
                    Terminal.SetColor(0x00FFFFFF);
                }

                LoadFence(); // [BỌC THÉP] Chặn đứng Speculative Execution lấn lướt qua vòng lặp!
            }

            Terminal.ScreenLock.Acquire();
            Terminal.SetColor(0x0000FF00);
            fixed (char* m3 = "[+] SMP Initialization Complete! CPU Cores online: \0") Terminal.Print(m3);
            Terminal.PrintDec(CoreCountAwake);
            fixed (char* m4 = "\n\0") Terminal.Print(m4);
            Terminal.ScreenLock.Release();
            
            WriteMmio32((ulong)&CoreReadyAcks[0], 1);
            StoreFence();
        }
    }
}