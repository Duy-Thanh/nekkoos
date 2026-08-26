// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// [BOOT CONTRACT] NekkoBootInfo đã tách sang src/BootContract.cs (ABI dùng
// chung với bootloader src/Boot.cs) - không định nghĩa lại ở đây.

[StructLayout(LayoutKind.Sequential)]
public struct EFI_MEMORY_DESCRIPTOR
{
    public uint Type;
    public ulong PhysicalStart;
    public ulong VirtualStart;
    public ulong NumberOfPages;
    public ulong Attribute;
}

public static unsafe class Program
{
    // ==========================================================
    // KHAI BÁO RÀO CHẮN PHẦN CỨNG & COMPILER
    // ==========================================================
    public static void CompilerFence() => Arch.CompilerFence();
    public static void LoadFence() => Arch.LoadFence();
    public static void StoreFence() => Arch.StoreFence();
    public static void FullFence() => Arch.FullFence();

    static void Out32(ushort port, uint value) => Arch.WritePort32(port, value);
    static uint In32(ushort port) => Arch.ReadPort32(port);
    static void UnlockScheduler_ASM() => Arch.UnlockScheduler();

    public static int spinner_frame = 0;
    public static ulong last_spinner_tick = 0;
    public static NekkoBootInfo* GlobalBootInfo;

    // =========================================================================
    // [STRAND TASK] SPINNER HIỆU ỨNG LOADING GÓC MÀN HÌNH
    // =========================================================================
    public static void StrandTask2()
    {
        // if (Scheduler.SystemTicks >= last_spinner_tick + 100) 
        // {
        //     last_spinner_tick = Scheduler.SystemTicks; 

        //     LibC.CheckHardwareError();
        // }
        return;
    }
    
    public static unsafe void SetGateWithRing3(int interruptNumber, void* handlerAddress)
    {
        ulong addr = (ulong)handlerAddress;
        byte* entryPtr = (byte*)IDTManager.idt;
        for (int i = 0; i < interruptNumber; i++) { entryPtr += 16; }
        
        IDTEntry* entry = (IDTEntry*)entryPtr;

        // ==========================================================
        // [TRÌNH TỰ BẤT KHẢ XÂM PHẠM]
        // Khóa cửa địa chỉ trước khi bật cờ Present (0xEE - Ring 3)!
        // ==========================================================
        entry->BaseLow = (ushort)(addr & 0xFFFF);
        entry->Selector = 0x08; 
        entry->Ist = 0;
        entry->BaseMid = (ushort)((addr >> 16) & 0xFFFF);
        entry->BaseHigh = (uint)((addr >> 32) & 0xFFFFFFFF);
        entry->Reserved = 0;

        CompilerFence();
        StoreFence();

        entry->Flags = 0xEE; // DPL 3 (Ring 3 accessible)
        
        StoreFence();
    }

    // =========================================================================
    // [KERNEL IDLE] VÒNG LẶP NGHỈ NGƠI CỦA BSP (LÕI VUA)
    // =========================================================================
    public static void KernelIdleLoop()
    {
        while (true)
        {
            // [BỌC THÉP VÒNG LẶP VÔ TẬN] Trị cờ -Ot!
            CompilerFence();

            StrandScheduler.RunCycle();

            if (!Driver.ATA.UseDaemon || !Driver.FAT16.UseDaemon)
            {
                // [ĐÃ DỌN DẸP] Thay Message Struct bằng Raw Variables
                uint rType = 0, rSender = 0; ulong rPayload = 0;
                while (IPC.ReceiveForRaw(0, &rType, &rSender, &rPayload)) 
                {
                    if (rType == 9) { Driver.ATA.DaemonId = rSender; Driver.ATA.UseDaemon = true; }
                    else if (rType == 39) { Driver.FAT16.DaemonId = rSender; Driver.FAT16.UseDaemon = true; }
                }
            }

            IO.Hlt();
            Scheduler.Yield();
        }
    }

    [UnmanagedCallersOnly(EntryPoint = "KernelMain")]
    public static void KernelMain(NekkoBootInfo* bootInfo)
    {
        // =====================================================================
        // PHASE 1: KHỞI TẠO NỀN TẢNG BAREMETAL & BẢO MẬT
        // =====================================================================
        UnlockScheduler_ASM(); 

        if (NekkoInt.isDebug) {
            fixed (char* dbg1 = "[DBG] KM: after UnlockScheduler\n\0") Serial.WriteString(dbg1);
        }

        Terminal.backbuffer = null; 

        Scheduler.Ready = false;
        Scheduler.ForegroundTask = -1;
        Scheduler.SystemTicks = 0;
        
        APIC.IsAwake = false;
        APIC.IOApicBase = 0;
        APIC.LocalApicBaseVirt = 0;
        
        Driver.ATA.UseDaemon = false;
        Driver.FAT16.UseDaemon = false;
        Driver.ATA.DaemonId = 0;      
        Driver.FAT16.DaemonId = 0;    
        
        last_spinner_tick = 0;
        spinner_frame = 0;
        LibC.RtcInterruptHandler_Ptr = 0; 

        VMM.VmmLock = new Spinlock();
        Heap.HeapLock = new Spinlock();
        IOAPIC.IoApicLock = new Spinlock();
        SMP.SmpLock = new Spinlock();
        InterruptHandlers.PanicLock = new Spinlock();
        Scheduler.SchedLock = new Spinlock(); 
        // Initialize Syscall shared-memory lock here to avoid static init ordering issues
        Syscall.SharedMemLock = new Spinlock();

        if (NekkoInt.isDebug) {
            fixed (char* dbg2 = "[DBG] KM: after SharedMemLock init\n\0") Serial.WriteString(dbg2);
        }

        PlatformBootstrap.EarlySerial();
        
        if (NekkoInt.isDebug) {
            fixed (char* dbg3 = "[DBG] KM: after Serial.Init\n\0") Serial.WriteString(dbg3);
        }

        GlobalBootInfo = bootInfo;
        Terminal.Init(bootInfo);
        
        if (NekkoInt.isDebug) {
            fixed (char* dbg4 = "[DBG] KM: after Terminal.Init\n\0") Terminal.Print(dbg4);
        }

        Terminal.SetColor(0x0000FF00); 
        fixed (char* msg = "=================================================\n\0") Terminal.Print(msg);
        fixed (char* msg2 = "                    NEKKO OS\n\0") Terminal.Print(msg2);
        fixed (char* msg3 = "=================================================\n\n\0") Terminal.Print(msg3);

        // =====================================================================
        // PHASE 2: QUY HOẠCH BỘ NHỚ VẬT LÝ & ẢO (PMM/VMM)
        // =====================================================================
        Terminal.SetColor(0x0000FFFF); 
        fixed (char* mScan = "[*] Reading memory map...\n\0") Terminal.Print(mScan);

        ulong totalPages = 0; ulong freePages = 0; ulong largestFreeStart = 0; ulong largestFreePages = 0;
        ulong maxPhysicalAddr = 0; 
        ulong numEntries = bootInfo->MemoryMapSize / bootInfo->DescriptorSize;
        byte* mapPtr = (byte *)bootInfo->MemoryMap;

        for (ulong i = 0; i < numEntries; i++)
        {
            EFI_MEMORY_DESCRIPTOR* desc = (EFI_MEMORY_DESCRIPTOR*)(mapPtr + (i * bootInfo->DescriptorSize));
            totalPages += desc->NumberOfPages;

            ulong endAddr = desc->PhysicalStart + (desc->NumberOfPages * 4096);
            if (endAddr > maxPhysicalAddr) maxPhysicalAddr = endAddr;

            if (desc->Type == 7) {
                freePages += desc->NumberOfPages;
                if (desc->NumberOfPages > largestFreePages) {
                    largestFreePages = desc->NumberOfPages;
                    largestFreeStart = desc->PhysicalStart;
                }
            }
        }

        ulong fbEnd = bootInfo->FrameBufferBase + bootInfo->FrameBufferSize;
        if (fbEnd > maxPhysicalAddr) maxPhysicalAddr = fbEnd;

        maxPhysicalAddr += 0x100000000UL; 
        maxPhysicalAddr = (maxPhysicalAddr + 2097151UL) & ~2097151UL;

        PMM.Init(bootInfo, largestFreeStart);

        if (NekkoInt.isDebug) {
            fixed (char* dbg5 = "[DBG] KM: after PMM.Init\n\0") Serial.WriteString(dbg5);
        }

        VMM.Init();

        if (NekkoInt.isDebug) {
            fixed (char* dbg6 = "[DBG] KM: after VMM.Init\n\0") Serial.WriteString(dbg6);
        }

        for (ulong addr = 2097152UL; addr < maxPhysicalAddr; addr += 2097152UL) { 
            VMM.MapHugePage(addr, addr);
        }

        Terminal.SetColor(0x00FF00FF);
        fixed (char* nukeMsg = "[*] Enforcing 8GB Strict Identity Paging against UEFI fragmentation...\n\0") Terminal.Print(nukeMsg);

        Heap.Init();
        Terminal.EnableShadowBuffer(); 
        Driver.FAT16.Init();
        
        // =====================================================================
        // PHASE 3: THIẾT LẬP NGẮT (IDT) & LÁ CHẮN PHẦN CỨNG
        // =====================================================================
        static void* GetIsrDiv0() => Arch.GetIsrDiv0();
        static void* GetIsrGPF() => Arch.GetIsrGPF();
        static void* GetIsrPageFault() => Arch.GetIsrPageFault();
        static void* GetIsrTimer() => Arch.GetIsrTimer();
        // GetIsrKeyboard/GetIsrMouse đã chuyển vào PlatformBootstrap (arch/x86_64)
        static void* GetIsrSyscall() => Arch.GetIsrSyscall();
        static void* GetIsrYield() => Arch.GetIsrYield();

        GDT.Init();

        if (NekkoInt.isDebug) {
            ulong tAddr = (ulong)GDT.Tss;
            ulong iopbAddr = (ulong)&(GDT.Tss->Iopb[0]);
            ulong offset = iopbAddr - tAddr;
            fixed (char* dMsg = "DEBUG: TSSEntry.Iopb Offset: \0") Terminal.Print(dMsg);
            Terminal.PrintHex(offset);
            fixed (char* nl = "\n\0") Terminal.Print(nl);
        }

        IDTManager.Init();

        void* dummyIsr = GetIsrYield();
        for (int i = 32; i < 256; i++) { IDTManager.SetGate(i, dummyIsr); }

        SetGateWithRing3(128, GetIsrSyscall()); 

        IDTManager.SetGate(0, GetIsrDiv0());
        IDTManager.SetGate(13, GetIsrGPF());
        IDTManager.SetGate(14, GetIsrPageFault());
        IDTManager.SetGate(32, GetIsrTimer());
        PlatformBootstrap.HookPs2IsrGates();
        IDTManager.SetGate(129, dummyIsr);

        PIC.Remap();
        PCI.DisableAllBusMastering();

        PlatformBootstrap.DrainPs2Buffers();
        PIC.MaskAllIrqs();


        Terminal.SetColor(0x0000FF00);
        fixed (char* okMsg = "[+] IDT Shield & Nuclear DMA Purge Active! Boot Sequence Proceeding...\n\0") Terminal.Print(okMsg);

        // =====================================================================
        // PHASE 4: KHỞI ĐỘNG ĐỘNG CƠ CỐT LÕI (SCHEDULER, IPC)
        // =====================================================================
        PlatformBootstrap.InitLegacyTimer(250);
        
        IPC.Init(); 
        PRNG.Init();
        vDSO.Init();

        // Deferred mapping is handled per-thread now; no global init required.

        StrandScheduler.Init();
        StrandScheduler.CreateStrand(&StrandTask2);
        
        Scheduler.Init();

        IO.EnableInterrupts(); 

        HardwareChecks.CheckHardwareError();

        // Print runtime Kernel text address and an inferred Map Base for crash mapping (KASLR)
        if (NekkoInt.isDebug)
        {
            ulong addr = (ulong)(delegate*<void>)&Program.KernelIdleLoop;
            Terminal.SetColor(0x00FFFFFF);
            fixed (char* pre = "[INFO] Kernel Text Address : \0") { Serial.WriteString(pre); }
            Serial.WriteHex(addr);
            fixed (char* nl = "\n\0") { Terminal.Print(nl); }

            // Inferred map base = address of KernelIdleLoop - known offset of that method in maps/Kernel.map
            // NOTE: update this constant if maps are regenerated with different ordering.
            const ulong KERNEL_IDLE_MAP_OFFSET = 177UL;
            ulong inferredMapBase = addr - KERNEL_IDLE_MAP_OFFSET;
            fixed (char* pre2 = "[INFO] Kernel Map Base   : \0") { Serial.WriteString(pre2); }
            Serial.WriteHex(inferredMapBase);
            fixed (char* nl2 = "\n\0") { Serial.WriteString(nl2); }
        }

        // =====================================================================
        // PHASE 5: BOOTSTRAP ĐẠI MÃNG XÀ MICROKERNEL DAEMONS (RING 3)
        // =====================================================================
        uint dummySize = 0;

        fixed (char* p_acpi = "ACPI.EXE\0") {
            byte* rawAcpi = Driver.FAT16.ReadFile(p_acpi, &dummySize);
            if (rawAcpi != null) PELoader.LoadAndRun(rawAcpi, true, false, true, p_acpi, 3); 
            else {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL KERNEL ERROR: ACPI.EXE is missing or corrupted!\n\0") Terminal.Print(err);
                while(true) IO.Cli(); 
            }
        }

        Terminal.SetColor(0x00FFFF00);
        fixed (char* waitAcpi = "[*] Kernel: Waiting for ACPI Daemon to discover IOAPIC...\n\0") Terminal.Print(waitAcpi);

        while (APIC.IOApicBase == 0 || APIC.LocalApicBaseVirt == 0) { 
            CompilerFence(); 
            Scheduler.Yield(); 
        }

        Terminal.SetColor(0x0000FF00);
        fixed (char* acpiOk = "[+] ACPI Discovery Complete! Initializing SMP and IOAPIC...\n\0") Terminal.Print(acpiOk);

        IOAPIC.Init(); 
        SMP.InitAndWakeCores();

        // [ĐÃ DỌN DẸP] Xả sạch thư rác trước khi boot ATA
        uint fType = 0, fSender = 0; ulong fPayload = 0;
        while (IPC.ReceiveForRaw(0, &fType, &fSender, &fPayload)) { CompilerFence(); }

        fixed (char* p1 = "ATA.EXE\0") {
            byte* rawAta = Driver.FAT16.ReadFile(p1, &dummySize);
            if (rawAta != null) PELoader.LoadAndRun(rawAta, true, false, true, p1, 3); 
            else {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL KERNEL ERROR: ATA.EXE is missing or corrupted!\n\0") Terminal.Print(err);
                while(true) IO.Cli(); 
            }
        }

        fixed (char* p2 = "FAT16.EXE\0") {
            byte* rawFat = Driver.FAT16.ReadFile(p2, &dummySize);
            if (rawFat != null) {
                // [FIX CRITICAL #1] Ghi nhận thread ID thật của FAT16 Daemon NGAY LÚC spawn -
                // trước cả khi daemon kịp tự gọi ATA để đọc boot sector, nên không có race.
                int fatDaemonId;
                PELoader.LoadAndRun(rawFat, out fatDaemonId, true, false, true, p2, 3);
                Driver.FAT16.TrustedThreadId = fatDaemonId;
            }
            else {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL KERNEL ERROR: FAT16.EXE is missing or corrupted!\n\0") Terminal.Print(err);
                while(true) IO.Cli(); 
            }
        }

        fixed (char* p3 = "MOUSE.EXE\0") {
            byte* rawFat = Driver.FAT16.ReadFile(p3, &dummySize);
            if (rawFat != null) PELoader.LoadAndRun(rawFat, true, false, true, p3, 3); 
            else {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL KERNEL ERROR: MOUSE.EXE is missing or corrupted!\n\0") Terminal.Print(err);
                while(true) IO.Cli(); 
            }
        }

        // ==========================================================
        // [FIX KVM RACE] Dùng IO.Hlt() thay vì chỉ Scheduler.Yield() thuần túy.
        // Với KVM, Scheduler.Yield() có thể không đủ để daemons chạy và gửi IPC.
        // IO.Hlt() đảm bảo CPU thực sự nghỉ đến khi timer interrupt kích hoạt,
        // cho daemons đủ thời gian gửi handshake. Timeout 30s để không treo mãi.
        // ==========================================================
        ulong daemonWaitStart = PIT.Ticks;
        while (!Driver.ATA.UseDaemon || !Driver.FAT16.UseDaemon || !Driver.Mouse.UseDaemon)
        {
            CompilerFence();
            //FullFence();

            uint rType = 0, rSender = 0; ulong rPayload = 0;
            while (IPC.ReceiveForRaw(0, &rType, &rSender, &rPayload)) 
            {
                if (rType == 9)  { Driver.ATA.DaemonId   = rSender; Driver.ATA.UseDaemon   = true; }
                else if (rType == 39) { Driver.FAT16.DaemonId = rSender; Driver.FAT16.UseDaemon = true; }
                else if (rType == 44) { Driver.Mouse.DaemonId = rSender; Driver.Mouse.UseDaemon = true; }
            }

            if (Driver.ATA.UseDaemon && Driver.FAT16.UseDaemon && Driver.Mouse.UseDaemon) break;

            // Timeout 30 giây: nếu daemon nào đó không gửi handshake được thì bỏ qua nó
            if (PIT.Ticks - daemonWaitStart > 30000) {
                Terminal.SetColor(0x00FF0000);
                if (!Driver.ATA.UseDaemon)   { fixed(char* w = "[!] Timeout waiting for ATA handshake! Proceeding anyway.\n\0")   Terminal.Print(w); Driver.ATA.UseDaemon   = true; }
                if (!Driver.FAT16.UseDaemon) { fixed(char* w = "[!] Timeout waiting for FAT16 handshake! Proceeding anyway.\n\0") Terminal.Print(w); Driver.FAT16.UseDaemon = true; }
                if (!Driver.Mouse.UseDaemon) { fixed(char* w = "[!] Timeout waiting for Mouse handshake! Proceeding anyway.\n\0") Terminal.Print(w); Driver.Mouse.UseDaemon = true; }
                Terminal.SetColor(0x00FFFFFF);
                break;
            }

            IO.Hlt(); // Thực sự nghỉ đến timer interrupt → scheduler chạy dæmons
        }

        fixed (char* p3 = "SYSLOGON.EXE\0") {
            byte* rawLogin = Driver.FAT16.ReadFile(p3, &dummySize); 
            if (rawLogin != null) PELoader.LoadAndRun(rawLogin, false, false, true, p3, 2);
            else while(true) IO.Cli(); 
        }


        // fixed (char* p_dwm = "DSRV.EXE\0") {
        //     byte* rawDwm = Driver.FAT16.ReadFile(p_dwm, &dummySize);
        //     if (rawDwm != null) {
        //         PELoader.LoadAndRun(rawDwm, true, false, true, p_dwm, 2); 
        //     }
        //     else {
        //         Terminal.SetColor(0x00FF0000);
        //         fixed(char* err = "[!] KERNEL FATAL: DSRV.EXE missing! GUI offline.\n\0") Terminal.Print(err);
        //     }
        // }

        // fixed (char* p_exp = "EXPLORER.EXE\0") {
        //     byte* rawExp = Driver.FAT16.ReadFile(p_exp, &dummySize);
        //     if (rawExp != null) {
        //         PELoader.LoadAndRun(rawExp, false, false, true, p_exp, 2); 
        //     }
        //     else {
        //         Terminal.SetColor(0x00FF0000);
        //         fixed(char* err = "[!] KERNEL FATAL: EXPLORER.EXE missing! Fallback to Console...\n\0") Terminal.Print(err);
        //     }
        // }

        Scheduler.Threads[0].Priority = 99;
        KernelIdleLoop();
    }
}