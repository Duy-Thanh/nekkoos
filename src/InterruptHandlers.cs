using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

public static unsafe class InterruptHandlers
{
    // ==========================================================
    // KHAI BÁO RÀO CHẮN PHẦN CỨNG & COMPILER
    // ==========================================================
    [DllImport("*", EntryPoint = "CompilerFence")] public static extern void CompilerFence();
    [DllImport("*", EntryPoint = "LoadFence")] public static extern void LoadFence();
    [DllImport("*", EntryPoint = "StoreFence")] public static extern void StoreFence();
    [DllImport("*", EntryPoint = "FullFence")] public static extern void FullFence();

    public static Spinlock PanicLock = new Spinlock();

    [DllImport("*", EntryPoint = "HltCPU")]
    public static extern void HltCPU();

    [DllImport("*", EntryPoint = "DisableInterrupts")]
    public static extern void DisableInterrupts();

    [DllImport("*", EntryPoint = "AtomicAdd64")] public static extern ulong AtomicAdd64(ulong* ptr, ulong val);

    private static void HaltSystemForever()
    {
        DisableInterrupts();
        while (true)
        {
            HltCPU(); 
        }
    }

    private static void BroadcastApocalypse()
    {
        if (APIC.IsAwake) {
            // [BỌC THÉP] Ép mọi dữ liệu Panic/Lỗi phải nằm gọn trên RAM 
            // trước khi ra lệnh đóng băng các Lõi khác!
            StoreFence(); 
            APIC.Write(0x300, 0x000C4500); // Bắn INIT IPI đóng băng Lõi Phụ!
        }
    }

    // ==========================================================
    // [VŨ KHÍ TỐI THƯỢNG] MÁY KHẠC LOG NGUYÊN THỦY (ĐÃ FIX SCOPE)
    // ==========================================================
    private static void PanicToSerial(char* title, RegisterContext* ctx, ulong extraAddr = 0)
    {
        fixed (char* nl = "\r\n\0")
        {
            fixed (char* sep = "\r\n==================================================\r\n\0") Serial.WriteString(sep);
            fixed (char* hdr = " [SERIAL KERNEL PANIC DUMP] \r\n\0") Serial.WriteString(hdr);
            Serial.WriteString(title);
            fixed (char* sep2 = "\r\n--------------------------------------------------\r\n\0") Serial.WriteString(sep2);
            
            fixed (char* s1 = "   RIP: \0") Serial.WriteString(s1); Serial.WriteHex(ctx->Rip);
            Serial.WriteString(nl);
            fixed (char* s2 = "   RSP: \0") Serial.WriteString(s2); Serial.WriteHex(ctx->Rsp);
            Serial.WriteString(nl);
            
            fixed (char* s3 = "   RAX: \0") Serial.WriteString(s3); Serial.WriteHex(ctx->Rax);
            fixed (char* s4 = "   RBX: \0") Serial.WriteString(s4); Serial.WriteHex(ctx->Rbx);
            Serial.WriteString(nl);
            
            fixed (char* s5 = "   RCX: \0") Serial.WriteString(s5); Serial.WriteHex(ctx->Rcx);
            fixed (char* s6 = "   RDX: \0") Serial.WriteString(s6); Serial.WriteHex(ctx->Rdx);
            Serial.WriteString(nl);

            fixed (char* s7 = "   CS : \0") Serial.WriteString(s7); Serial.WriteHex(ctx->Cs);
            fixed (char* s8 = "   FLG: \0") Serial.WriteString(s8); Serial.WriteHex(ctx->Rflags);
            Serial.WriteString(nl);

            if (extraAddr != 0) {
                fixed (char* s9 = "   CR2: \0") Serial.WriteString(s9); Serial.WriteHex(extraAddr);
                Serial.WriteString(nl);
            }
            fixed (char* end = "==================================================\r\n\r\n\0") Serial.WriteString(end);
        }
    }

    // Đập hàm cũ, thay bằng hàm này: Gửi Hex thẳng ra Serial Port!
    private static void PanicHexToSerial(ulong val) {
        char* hexChars = stackalloc char[] { '0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F' };
        char* buffer = stackalloc char[19]; buffer[0] = '0'; buffer[1] = 'x'; buffer[18] = '\0';
        for (int i = 0; i < 16; i++) { buffer[17 - i] = hexChars[(val >> (i * 4)) & 0xF]; }
        Serial.WriteString(buffer); 
    }

    private static void PrintRegisterDumpToSerial(RegisterContext* ctx)
    {
        fixed (char* nl = "\r\n\0") {
            fixed (char* s1 = "   RIP: \0") Serial.WriteString(s1); PanicHexToSerial(ctx->Rip);
            fixed (char* s2 = "   RSP: \0") Serial.WriteString(s2); PanicHexToSerial(ctx->Rsp);
            Serial.WriteString(nl);
            
            fixed (char* s3 = "   RAX: \0") Serial.WriteString(s3); PanicHexToSerial(ctx->Rax);
            fixed (char* s4 = "   RBX: \0") Serial.WriteString(s4); PanicHexToSerial(ctx->Rbx);
            Serial.WriteString(nl);
            
            fixed (char* s5 = "   RCX: \0") Serial.WriteString(s5); PanicHexToSerial(ctx->Rcx);
            fixed (char* s6 = "   RDX: \0") Serial.WriteString(s6); PanicHexToSerial(ctx->Rdx);
            Serial.WriteString(nl);

            fixed (char* s7 = "   CS : \0") Serial.WriteString(s7); PanicHexToSerial(ctx->Cs);
            fixed (char* s8 = "   FLG: \0") Serial.WriteString(s8); PanicHexToSerial(ctx->Rflags);
            Serial.WriteString(nl);
        }
    }

    [UnmanagedCallersOnly(EntryPoint = "DivideByZeroHandler")]
    public static ulong DivideByZeroHandler(ulong currentRsp)
    {
        // Kiểm tra xem currentRsp có hợp lệ không
        if (currentRsp == 0 || currentRsp < 0x1000 || currentRsp > 0x7FFFFFFFFFFFF000) {
            // Xử lý lỗi stack pointer không hợp lệ
            BroadcastApocalypse();
            fixed (char* title = " [FATAL EXCEPTION 0x00] INVALID STACK POINTER!\0") PanicToSerial(title, null);
            HaltSystemForever();
            return currentRsp;
        }
        
        RegisterContext* ctx = (RegisterContext*)currentRsp;

        // Kiểm tra xem ctx->Cs có hợp lệ không
        if (ctx->Cs == 0 || ctx->Cs > 0xFFFFFFFF) {
            BroadcastApocalypse();
            fixed (char* title = " [FATAL EXCEPTION 0x00] INVALID CODE SEGMENT!\0") PanicToSerial(title, ctx);
            HaltSystemForever();
            return currentRsp;
        }

        if (Scheduler.Threads == null || Scheduler.CurrentThreadId < 0) {
            BroadcastApocalypse();
            fixed (char* title = " [FATAL EXCEPTION 0x00] SCHEDULER NOT INITIALIZED!\0") PanicToSerial(title, ctx);
            HaltSystemForever();
            return currentRsp;
        }

        // ==========================================================
        // [BỌC THÉP RING 3] KIỂM TRA NGUỒN GỐC LỖI!
        // Nếu App Ring 3 chia cho 0 → Giết App, KHÔNG ĐƯỢC sập Kernel!
        // ==========================================================
        if ((ctx->Cs & 0x03) == 3)
        {
            bool scrIrq = Terminal.ScreenLock.AcquireSafe();
            Terminal.SetColor(0x00FF0000);
            fixed(char* m1 = "\n[!] MPU: DIVIDE BY ZERO IN RING 3 APP! Terminated!\n\0") Terminal.Print(m1);
            Terminal.SetColor(0x00FFFFFF);
            Terminal.ScreenLock.ReleaseSafe(scrIrq);

            fixed (char* title = " [EXCEPTION 0x00] Ring 3 DIVIDE BY ZERO - App Killed\0") PanicToSerial(title, ctx);

            int id = Scheduler.CurrentThreadId;
            uint coreId = APIC.IsAwake ? (APIC.Read(0x020) >> 24) : 0;
            
            bool irq = Scheduler.AcquireSchedLockSafe();
            
            if (Scheduler.ForegroundTask == id) {
                Scheduler.ForegroundTask = Scheduler.Threads[id].ParentId;
            }
            
            Scheduler.Threads[id].UID = 9999; 
            IPC.ClearMailbox((uint)id);
            
            Scheduler.Threads[id].Pml4 = 0;
            VMM.LoadPML4_ASM((void*)VMM.PML4);

            // ==========================================================
            // [FIX CHÍ MẠNG] DÙNG CƠ CHẾ ZOMBIE (Active=4)!
            // Active=0 cho phép Lõi khác tái chế Thread Slot + Stack NGAY LẬP TỨC,
            // trong khi ISR của mình vẫn đang chạy trên cái Stack đó!
            // Active=4 = Zombie: Slot bị khóa cho đến khi SwitchTask lần tiếp xử lý.
            // ==========================================================
            Scheduler.Threads[id].Active = 4; // ZOMBIE!

            // [FIX] Đăng ký zombie để SwitchTask cleanup ngoài interrupt context.
            if (Scheduler.DyingThreadPerCore[coreId] == -1)
                Scheduler.DyingThreadPerCore[coreId] = id;

            StoreFence();

            Scheduler.ReleaseSchedLockSafe(irq);

            return Scheduler.SwitchTask(currentRsp);
        }

        // Ring 0 chia cho 0 = Bug Kernel thực sự → Halt!
        BroadcastApocalypse(); 

        fixed (char* title = " [FATAL EXCEPTION 0x00] DIVIDE BY ZERO ERROR!\0") PanicToSerial(title, ctx);

        fixed (char* msg = "\n\n   *** KERNEL PANIC ***\n\n\0") Serial.WriteString(msg);
        fixed (char* msg2 = "   [FATAL EXCEPTION 0x00] DIVIDE BY ZERO ERROR!\n\n\0") Serial.WriteString(msg2);
        PrintRegisterDumpToSerial(ctx);
        fixed (char* msg3 = "\n   NekkoOS Microkernel halted to prevent system damage.\n\0") Serial.WriteString(msg3);

        Power.HardReboot();

        HaltSystemForever(); 
        return currentRsp; // Unreachable, nhưng compiler cần return value
    }

    [UnmanagedCallersOnly(EntryPoint = "KeyboardHandler")]
    public static unsafe void KeyboardHandler()
    {
        byte scanCode = IO.In8(0x60);

        // [FIX CHÍ MẠNG] Nã phím vào Receiver = 0 (Broadcast)!
        // Thằng DWM dùng Syscall 8 (ReceiveForRaw) sẽ TỪ CHỐI ĐỌC vì nó đéo phải PID 0.
        // NHƯNG Syscall 4 của CMD.EXE thì quét toàn mảng, nên nó luợm sạch 100% phím!
        IPC.SendFromInterrupt(1, 33, 0, scanCode);

        if (APIC.IsAwake) APIC.SendEOI(); 
        else PIC.SendEOI();
    }

    [UnmanagedCallersOnly(EntryPoint = "GPFHandler")]
    public static ulong GPFHandler(ulong currentRsp)
    {
        // 1. Kiểm tra an toàn con trỏ Stack thô trước
        if (currentRsp == 0 || currentRsp < 0x1000 || currentRsp > 0x7FFFFFFFFFFFF000)
        {
            BroadcastApocalypse();
            HaltSystemForever();
            return currentRsp;
        }

        // 2. BỐC THẲNG DATA TỪ STACK KHÔNG QUA TRUNG GIAN STRUCT ĐỂ TRÁNH LỆCH ERROR CODE
        ulong* stackPtr = (ulong*)currentRsp;
        ulong errorCode = stackPtr[15];
        ulong realRip    = stackPtr[16];
        ulong realCs     = stackPtr[17];
        ulong realRflags = stackPtr[18];
        ulong realRsp    = stackPtr[19];
        ulong realSs     = stackPtr[20];

        // 3. DÙNG BIẾN REAL_CS XỊN ĐỂ CHECK PHÂN QUYỀN
        // Nếu sập ở Ring 3 App -> Đá chết cụ nó đi, cứu mạng Kernel!
        if ((realCs & 0x03) == 3)
        {
            int id = Scheduler.CurrentThreadId;
            uint coreId = APIC.IsAwake ? (APIC.Read(0x020) >> 24) : 0;

            bool irq = Scheduler.AcquireSchedLockSafe();
            
            if (Scheduler.ForegroundTask == id) {
                Scheduler.ForegroundTask = Scheduler.Threads[id].ParentId;
            }
            
            Scheduler.Threads[id].UID = 9999; 
            IPC.ClearMailbox((uint)id);
            
            Scheduler.Threads[id].Pml4 = 0;
            VMM.LoadPML4_ASM((void*)VMM.PML4);
            
            Scheduler.Threads[id].Active = 4; // Biến thành ZOMBIE an toàn

            // [FIX] Đăng ký zombie để SwitchTask gọi DestroyUserSpace đúng chỗ
            // (ngoài interrupt context). Guard tránh overwrite nếu slot đã có zombie.
            if (Scheduler.DyingThreadPerCore[coreId] == -1)
                Scheduler.DyingThreadPerCore[coreId] = id;

            StoreFence();
            Scheduler.ReleaseSchedLockSafe(irq);

            // Không gọi DestroyUserSpace ở đây để tránh nghẽn mạch Stack ngắt
            return Scheduler.SwitchTask(currentRsp);
        }

        // 4. Nếu thực sự sập ở Ring 0 Kernel, ép dữ liệu vào ctx thô rồi dump an toàn
        RegisterContext* ctx = (RegisterContext*)currentRsp;
        ctx->Rip = realRip;
        ctx->Cs = realCs;
        ctx->Rflags = realRflags;
        ctx->Rsp = realRsp;
        ctx->Ss = realSs;

        BroadcastApocalypse();
        PrintRegisterDumpToSerial(ctx);
        
        // In thêm mã lỗi nguyên thủy của CPU ra cổng Serial
        PanicHexToSerial(errorCode);

        Power.HardReboot();

        HaltSystemForever();
        return currentRsp; 
    }

    [DllImport("*", EntryPoint = "ReadCR2")] public static extern ulong ReadCR2();

    [UnmanagedCallersOnly(EntryPoint = "PageFaultHandler")]
    public static ulong PageFaultHandler(ulong currentRsp)
    {
        // Validate stack pointer before dereferencing it to avoid recursive faults
        if (currentRsp == 0 || currentRsp < 0x1000 || currentRsp > 0x7FFFFFFFFFFFF000)
        {
            BroadcastApocalypse();
            fixed (char* msg = " [FATAL EXCEPTION 0x0E] INVALID STACK POINTER IN PAGE FAULT!\0") Serial.WriteString(msg);
            HaltSystemForever();
            return currentRsp;
        }

        RegisterContext* ctx = (RegisterContext*)currentRsp;
        ulong faultAddr = ReadCR2(); 
        
        // ==========================================================
        // [BỌC THÉP ĐỌC CR2] Chặn đứng Speculative Execution 
        // nạp sai biến faultAddr trước khi CPU kịp báo lỗi thực sự!
        // ==========================================================
        LoadFence(); 

        // Validate code segment
        if (ctx->Cs == 0 || ctx->Cs > 0xFFFFFFFF)
        {
            BroadcastApocalypse();
            fixed (char* msg = " [FATAL EXCEPTION 0x0E] INVALID CODE SEGMENT IN PAGE FAULT!\0") Serial.WriteString(msg);
            HaltSystemForever();
            return currentRsp;
        }

        if ((ctx->Cs & 0x03) == 3)
        {
            bool scrIrq = Terminal.ScreenLock.AcquireSafe();
            Terminal.SetColor(0x00FF0000);
            fixed(char* m1 = "\n[!] MPU: SEGMENTATION FAULT IN RING 3 APP!\n    -> Blocked Address: \0") Terminal.Print(m1);
            Terminal.PrintHex(faultAddr);
            fixed(char* nl = "\n\n\0") Terminal.Print(nl);
            PrintRegisterDumpToSerial(ctx);
            Terminal.SetColor(0x00FFFFFF);
            Terminal.ScreenLock.ReleaseSafe(scrIrq);

            // [FIX TRIỆT ĐỂ] Tìm thread bằng kernel stack thay vì tin CurrentThreadId!
            // currentRsp nằm trên kernel stack của thread bị lỗi. Quét tất cả threads
            // để tìm thread nào có kernel stack chứa currentRsp.
            const ulong KERNEL_STACK_SIZE = 4 * 4096; // 4 pages = 16KB
            int id = -1;

            for (int i = 0; i < Scheduler.ThreadCount; i++) {
                if (Scheduler.Threads[i].Active == 0) continue;
                ulong kTop = Scheduler.Threads[i].KernelStackTop;
                if (kTop == 0) continue;
                ulong kBottom = kTop - KERNEL_STACK_SIZE;
                if (currentRsp >= kBottom && currentRsp <= kTop) {
                    id = i;
                    break;
                }
            }

            // Nếu vẫn không tìm thấy, fallback về CurrentThreadId (có validate)
            if (id == -1) {
                id = Scheduler.CurrentThreadId;
                if (id < 0 || id >= Scheduler.ThreadCount) {
                    // Không thể xác định thread - kill tất cả Ring 3 threads trên core này
                    uint coreId = APIC.IsAwake ? (APIC.Read(0x020) >> 24) : 0;
                    if (coreId >= 256) coreId = 0;

                    int firstZombie = -1;
                    bool irqFallback = Scheduler.AcquireSchedLockSafe();
                    for (int i = 0; i < Scheduler.ThreadCount; i++) {
                        if (Scheduler.Threads[i].ExecutingOnCore == (int)coreId &&
                            (Scheduler.Threads[i].Active == 1 || Scheduler.Threads[i].Active == 2)) {
                            Scheduler.Threads[i].Active = 4; // Zombie
                            if (firstZombie == -1) firstZombie = i;
                        }
                    }

                    // Đăng ký zombie đầu tiên để SwitchTask cleanup (các zombie còn lại sẽ leak)
                    if (firstZombie != -1 && Scheduler.DyingThreadPerCore[coreId] == -1) {
                        Scheduler.DyingThreadPerCore[coreId] = firstZombie;
                    }

                    StoreFence();
                    Scheduler.ReleaseSchedLockSafe(irqFallback);
                    return Scheduler.SwitchTask(currentRsp);
                }
            }

            uint coreId2 = APIC.IsAwake ? (APIC.Read(0x020) >> 24) : 0;
            if (coreId2 >= 256) coreId2 = 0;

            bool irq = Scheduler.AcquireSchedLockSafe();

            if (Scheduler.ForegroundTask == id) {
                Scheduler.Threads[id].UID = 9999;
                Scheduler.ForegroundTask = Scheduler.Threads[id].ParentId;
            }

            Scheduler.Threads[id].UID = 9999; 
            IPC.ClearMailbox((uint)id);
            
            ulong dyingPml4 = Scheduler.Threads[id].Pml4;
            Scheduler.Threads[id].Pml4 = 0;
            VMM.LoadPML4_ASM((void*)VMM.PML4);
            
            // [FIX CHÍ MẠNG] DÙNG CƠ CHẾ ZOMBIE! (Active=4)
            Scheduler.Threads[id].Active = 4; // ZOMBIE!

            // [FIX] Đăng ký zombie để SwitchTask gọi DestroyUserSpace đúng chỗ
            // (ngoài interrupt context). Guard tránh overwrite nếu slot đã có zombie.
            if (Scheduler.DyingThreadPerCore[coreId2] == -1)
                Scheduler.DyingThreadPerCore[coreId2] = id;

            StoreFence();

            Scheduler.ReleaseSchedLockSafe(irq);

            // [FIX CHÍ MẠNG] CẤM GỌI DestroyUserSpace() TRONG INTERRUPT CONTEXT!
            // dyingPml4 là physical address, không thể dereferencing trực tiếp
            // để tránh free garbage addresses. Zombie mechanism sẽ xử lý cleanup ở SwitchTask.

            return Scheduler.SwitchTask(currentRsp); 
        }

        BroadcastApocalypse();

        fixed (char* title = " [FATAL EXCEPTION 0x0E] PAGE FAULT IN RING 0!\0") PanicToSerial(title, ctx, faultAddr);

        fixed (char* msg = "\n\n   *** KERNEL PANIC ***\n\n   [FATAL EXCEPTION 0x0E] PAGE FAULT IN RING 0!\n   Fault Address: \0") Serial.WriteString(msg);
        PanicHexToSerial(faultAddr);
        fixed(char* nl = "\n\n\0") Serial.WriteString(nl);
        PrintRegisterDumpToSerial(ctx);
        fixed (char* m2 = "\n   System Halted.\n\0") Serial.WriteString(m2);
        
        Power.HardReboot();
        Power.LegacyReboot();

        HaltSystemForever();
        
        return currentRsp; 
    }

    [UnmanagedCallersOnly(EntryPoint = "TimerHandler")]
    public static ulong TimerHandler(ulong currentRsp)
    {
        if (!APIC.IsAwake)
        {    
            fixed (ulong* p = &PIT.Ticks) AtomicAdd64(p, 1);
            fixed (ulong* q = &Scheduler.SystemTicks) AtomicAdd64(q, 1);
            PIC.SendEOI(); 
            if (!Scheduler.Ready) return currentRsp;
            return Scheduler.SwitchTask(currentRsp);
        }

        uint coreId = APIC.Read(0x020) >> 24;
        if (coreId == 0) {
            fixed (ulong* p = &PIT.Ticks) AtomicAdd64(p, 1);
            fixed (ulong* q = &Scheduler.SystemTicks) AtomicAdd64(q, 1);

            // ==========================================================
            // [BỌC THÉP TRÁI TIM OS] ĐỒNG BỘ THỜI GIAN TUYỆT ĐỐI!
            // Lõi 0 vừa tăng nhịp đập, PHẢI ÉP NÓ XẢ RAM NGAY LẬP TỨC 
            // để Lõi 1, 2, 3 đọc được giờ chuẩn chỉ, đéo bị kẹt ở quá khứ!
            // ==========================================================
            StoreFence(); 
        }

        APIC.SendEOI(); 

        if (!Scheduler.Ready) return currentRsp;
        return Scheduler.SwitchTask(currentRsp);
    }

    private static int mouseCycle = 0;
    private static byte mouseByte0 = 0;
    private static byte mouseByte1 = 0;
    private static byte mouseByte2 = 0;

    [UnmanagedCallersOnly(EntryPoint = "MouseHandler")]
    public static ulong MouseHandler(ulong currentRsp)
    {
        while (true) 
        {
            byte status = IO.In8(0x64);
            if ((status & 0x01) == 0) break; 
            if ((status & 0x20) == 0) break; 

            byte data = IO.In8(0x60); 

            if (Driver.Mouse.UseDaemon && Driver.Mouse.DaemonId != 0)
            {
                if (mouseCycle == 0) {
                    if ((data & 0x08) != 0) { mouseByte0 = data; mouseCycle++; }
                }
                else if (mouseCycle == 1) { mouseByte1 = data; mouseCycle++; }
                else if (mouseCycle == 2) {
                    mouseByte2 = data; mouseCycle = 0;
                    
                    ulong payload = ((ulong)mouseByte2 << 16) | ((ulong)mouseByte1 << 8) | (ulong)mouseByte0;
                    
                    // Quăng thẳng vào Mailbox an toàn, hàm này không gây chết Stack
                    IPC.SendFromInterrupt(2, 44, Driver.Mouse.DaemonId, payload);
                }
            }
        }

        if (APIC.IsAwake) APIC.SendEOI(); 
        else PIC.SendEOI();

        // ==========================================================
        // [VÁ TỬ HUYỆT GIẾT NGƯỜI LẠC CONTEXT]
        // Bẻ gãy hoàn toàn lệnh SwitchTask ở đây! Ngắt chuột xử lý xong 
        // PHẢI trả về currentRsp cũ để luồng tiếp tục chạy Syscall dở dang!
        // Tuyệt đối không đứng núi này trông núi nọ làm lệch lề RSP!
        // ==========================================================
        return currentRsp; 
    }
}