using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

public static unsafe class Power
{
    // ==========================================================
    // [VŨ KHÍ TỐI THƯỢNG] CÚ HACK INIT IPI XUYÊN PHẦN CỨNG!
    // ==========================================================
    private static void BroadcastApocalypse()
    {
        // Kiểm tra xem APIC có được khởi tạo chưa
        if (!APIC.IsAwake) {
            return;
        }
        
        // Kiểm tra xem APIC.Write có thành công không
        try {
            // Thay vì NMI (0x000C4400) dễ gây GPF vì thiếu IDT Vector 2.
            // Dùng INIT IPI (0x000C4500) ép CPU Reset thẳng về trạng thái 
            // Wait-for-SIPI. Bọn Lõi Phụ sẽ biến thành Xác Sống ngay tức khắc!
            APIC.Write(0x300, 0x000C4500); 
        } catch {
            // Xử lý lỗi nếu APIC.Write thất bại
            return;
        }
    }

    public static void Shutdown()
    {
        IO.EnableInterrupts();
        Terminal.Clear(0x00000000); 
        Terminal.SetColor(0x00FF0000); 
        fixed (char* msg1 = "\n\n   [*] INITIATING GRACEFUL SHUTDOWN...\n\0") Terminal.Print(msg1);

        int acpiPid = -1;
        bool irq = Scheduler.AcquireSchedLockSafe();
        for (int i = 1; i < Scheduler.ThreadCount; i++) {
            if (Scheduler.Threads[i].Active != 0 && 
                Scheduler.Threads[i].Name[0] == 'A' && Scheduler.Threads[i].Name[1] == 'C' && 
                Scheduler.Threads[i].Name[2] == 'P' && Scheduler.Threads[i].Name[3] == 'I') {
                acpiPid = i; break;
            }
        }
        Scheduler.ReleaseSchedLockSafe(irq);

        // [ĐÃ DỌN DẸP] Không đẻ Struct Message nữa!
        irq = Scheduler.AcquireSchedLockSafe();
        
        // Kiểm tra xem lock có được thành công không
        if (!irq) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to acquire scheduler lock in Shutdown!\n\0") Terminal.Print(err);
            return;
        }

        for (uint i = 1; i < (uint)Scheduler.ThreadCount; i++) {
            if (i == Scheduler.CurrentThreadId || i == acpiPid) continue;
            // [FIX CHÍ MẠNG 1] CẤM ĐỤNG VÀO BỌN IDLE THREADS (Priority = 99)!
            if (Scheduler.Threads[i].Active != 0 && Scheduler.Threads[i].Priority != 99) { 
                Scheduler.ReleaseSchedLockSafe(irq); 
                // Type = 0xDEAD, Sender = 0, Receiver = i, Payload = 0
                IPC.Send(0xDEAD, 0, i, 0); 
                irq = Scheduler.AcquireSchedLockSafe(); 
            }
        }
        Scheduler.ReleaseSchedLockSafe(irq);

        ulong timeout = PIT.Ticks + 5000; bool allDead = false;
        while (PIT.Ticks < timeout) {
            allDead = true;
            irq = Scheduler.AcquireSchedLockSafe();
            for (int i = 1; i < Scheduler.ThreadCount; i++) {
                if (i == Scheduler.CurrentThreadId || i == acpiPid) continue;
                // [FIX CHÍ MẠNG 1] Bỏ qua bọn Idle Threads khi đếm xác!
                if (Scheduler.Threads[i].Active != 0 && Scheduler.Threads[i].Priority != 99) { allDead = false; break; }
            }
            Scheduler.ReleaseSchedLockSafe(irq);
            
            if (allDead) break; 
            Scheduler.Yield(); 
        }

        if (!allDead) {
            irq = Scheduler.AcquireSchedLockSafe();
            for (int i = 1; i < Scheduler.ThreadCount; i++) {
                if (i == Scheduler.CurrentThreadId || i == acpiPid) continue; 
                if (Scheduler.Threads[i].Priority != 99) {
                    Scheduler.Threads[i].Active = 0; 
                    Scheduler.Threads[i].UID = 9999; 
                }
            }
            Scheduler.ReleaseSchedLockSafe(irq);
            BroadcastApocalypse(); 
        }

        Driver.ATA.UseDaemon = false; 
        Driver.ATA.FlushCache();

        if (acpiPid != -1)
        {
            fixed (char* msg4 = "   [*] Delegating Hardware Power-off to ACPI Daemon...\n\0") Terminal.Print(msg4);
            // [ĐÃ DỌN DẸP] Gửi lệnh tắt máy cho ACPI
            IPC.Send(0xDEAD, 0, (uint)acpiPid, 0); 

            ulong acpiTimeout = PIT.Ticks + 3000;
            while (PIT.Ticks < acpiTimeout) Scheduler.Yield();
        }

        Scheduler.Ready = false; IO.Cli(); 
        BroadcastApocalypse(); 
        
        Terminal.SetColor(0x00FF0000);
        fixed (char* msg5 = "\n   [!!!] FATAL: ACPI DAEMON FAILED TO SHUTDOWN HARDWARE! SYSTEM HALTED!\n\0") Terminal.Print(msg5);
        // 0x0604 là cổng PM1a_CNT_BLK mặc định của chipset ICH9 (Q35) trên QEMU
        // 0x2000 bao gồm:
        // Bit 13 (SLP_EN): Sleep Enable - Kích hoạt trạng thái ngủ/tắt
        // Bits 10-12 (SLP_TYP): Sleep Type - Trên QEMU, giá trị 0 thường đại diện cho S5 (Soft Off)
        
        IO.Out16(0x0604, 0x2000);

        // Nếu lệnh trên chưa đủ đô (tùy cấu hình QEMU), thử giá trị 0x3400 
        // (SLP_TYP là 5 thay vì 0)
        // IO.Out16(0x0604, 0x3400);
    }

    public static void Reboot()
    {
        IO.EnableInterrupts();
        Terminal.Clear(0x00000000); 
        Terminal.SetColor(0x00FFFF00); 
        fixed (char* msg1 = "\n\n   [*] INITIATING GRACEFUL REBOOT SEQUENCE...\n\0") Terminal.Print(msg1);

        int acpiPid = -1;
        bool irq = Scheduler.AcquireSchedLockSafe();
        for (int i = 1; i < Scheduler.ThreadCount; i++) {
            if (Scheduler.Threads[i].Active != 0 && 
                Scheduler.Threads[i].Name[0] == 'A' && Scheduler.Threads[i].Name[1] == 'C' && 
                Scheduler.Threads[i].Name[2] == 'P' && Scheduler.Threads[i].Name[3] == 'I') {
                acpiPid = i; break;
            }
        }
        Scheduler.ReleaseSchedLockSafe(irq);

        // [ĐÃ DỌN DẸP] Không đẻ Struct Message nữa!
        irq = Scheduler.AcquireSchedLockSafe();
        for (uint i = 1; i < (uint)Scheduler.ThreadCount; i++) {
            if (i == Scheduler.CurrentThreadId || i == acpiPid) continue;
            // [FIX CHÍ MẠNG 1] CẤM ĐỤNG VÀO BỌN IDLE THREADS (Priority = 99)!
            if (Scheduler.Threads[i].Active != 0 && Scheduler.Threads[i].Priority != 99) { 
                Scheduler.ReleaseSchedLockSafe(irq);
                // Type = 0xDEAD, Sender = 0, Receiver = i, Payload = 0
                IPC.Send(0xDEAD, 0, i, 0); 
                irq = Scheduler.AcquireSchedLockSafe();
            }
        }
        Scheduler.ReleaseSchedLockSafe(irq);

        ulong timeout = PIT.Ticks + 5000; bool allDead = false;
        while (PIT.Ticks < timeout) {
            allDead = true;
            irq = Scheduler.AcquireSchedLockSafe();
            for (int i = 1; i < Scheduler.ThreadCount; i++) {
                if (i == Scheduler.CurrentThreadId || i == acpiPid) continue;
                // [FIX CHÍ MẠNG 1] Bỏ qua bọn Idle Threads khi đếm xác!
                if (Scheduler.Threads[i].Active != 0 && Scheduler.Threads[i].Priority != 99) { allDead = false; break; }
            }
            Scheduler.ReleaseSchedLockSafe(irq);
            
            if (allDead) break; 
            Scheduler.Yield(); 
        }

        if (!allDead) {
            irq = Scheduler.AcquireSchedLockSafe();
            for (int i = 1; i < Scheduler.ThreadCount; i++) {
                if (i == Scheduler.CurrentThreadId || i == acpiPid) continue; 
                if (Scheduler.Threads[i].Priority != 99) {
                    Scheduler.Threads[i].Active = 0; 
                    Scheduler.Threads[i].UID = 9999;
                }
            }
            Scheduler.ReleaseSchedLockSafe(irq);
            
            BroadcastApocalypse(); // BẮN INIT IPI, NGƯNG ĐỌNG LÕI PHỤ AN TOÀN TUYỆT ĐỐI!
        }

        Driver.ATA.UseDaemon = false; 
        Driver.ATA.FlushCache();

        if (acpiPid != -1)
        {
            fixed (char* msg4 = "   [*] Delegating Hardware Reboot to ACPI Daemon...\n\0") Terminal.Print(msg4);
            // [ĐÃ DỌN DẸP] Gửi lệnh 0xBEEF (Reboot) cho ACPI
            IPC.Send(0xBEEF, 0, (uint)acpiPid, 0); 

            ulong acpiTimeout = PIT.Ticks + 3000;
            while (PIT.Ticks < acpiTimeout) Scheduler.Yield();
        }

        Scheduler.Ready = false; IO.Cli(); 
        BroadcastApocalypse(); // Bắn INIT IPI đóng băng trước khi chìm vào giấc ngủ vĩnh hằng!
        
        Terminal.SetColor(0x00FF0000);
        fixed (char* msg5 = "\n   [!!!] FATAL: ACPI DAEMON FAILED TO REBOOT HARDWARE! SYSTEM HALTED!\n\0") Terminal.Print(msg5);
        while (true) IO.Hlt(); 
    }

    public static void HardReboot()
    {
        // 0x06 vào cổng 0xCF9: Lệnh "System Reset" của chuẩn PCI/ACPI
        // Nó sẽ kích hoạt chân RESET của CPU ngay lập tức!
        IO.Out8(0xCF9, 0x06);
    }

    public static void LegacyReboot()
    {
        // Gửi lệnh 0xFE vào cổng 0x64 (Keyboard Controller Command Port)
        // 0xFE có nghĩa là "Pulse Reset Line"
        IO.Out8(0x64, 0xFE);
    }
}