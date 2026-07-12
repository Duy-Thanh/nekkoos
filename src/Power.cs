// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

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

    // [FIX AN TOÀN SHUTDOWN] Đợi tối đa `spinLimit` lần lặp để AtaHardwareLock được nhả ra
    // trước khi cho phép bắn INIT IPI cưỡng ép - tránh cắt ngang PIO transfer giữa chừng
    // và để lại sector rác trên đĩa.
    private static void WaitAtaIdleBeforeApocalypse(int spinLimit)
    {
        int spins = 0;
        while (Driver.ATA.AtaHardwareLock.IsLocked() && spins < spinLimit) {
            IO.Hlt();
            spins++;
        }
    }

    public static void Shutdown()
    {
        IO.EnableInterrupts();
        Terminal.Clear(0x00000000);
        Terminal.SetColor(0x00FF0000);
        fixed (char* msg1 = "\n\n   [*] INITIATING GRACEFUL SHUTDOWN...\n\0") Terminal.Print(msg1);

        int acpiPid = -1, ataPid = -1;
        bool irq = Scheduler.AcquireSchedLockSafe();
        for (int i = 1; i < Scheduler.ThreadCount; i++) {
            if (Scheduler.Threads[i].Active != 0 &&
                Scheduler.Threads[i].Name[0] == 'A' && Scheduler.Threads[i].Name[1] == 'C' &&
                Scheduler.Threads[i].Name[2] == 'P' && Scheduler.Threads[i].Name[3] == 'I') {
                acpiPid = i;
            }
            // [FIX AN TOÀN SHUTDOWN] Nhận diện ATA Daemon để kill SAU CÙNG, vì FAT16/các
            // thread khác phụ thuộc vào nó (FlushCacheIPC/WriteSectorIPC) - kill ATA trước
            // sẽ khiến các thread đó treo vĩnh viễn chờ phản hồi từ 1 daemon đã chết.
            if (Scheduler.Threads[i].Active != 0 &&
                Scheduler.Threads[i].Name[0] == 'A' && Scheduler.Threads[i].Name[1] == 'T' &&
                Scheduler.Threads[i].Name[2] == 'A') {
                ataPid = i;
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
            if (i == Scheduler.CurrentThreadId || i == acpiPid || i == ataPid) continue;
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
                if (i == Scheduler.CurrentThreadId || i == acpiPid || i == ataPid) continue;
                // [FIX CHÍ MẠNG 1] Bỏ qua bọn Idle Threads khi đếm xác!
                if (Scheduler.Threads[i].Active != 0 && Scheduler.Threads[i].Priority != 99) { allDead = false; break; }
            }
            Scheduler.ReleaseSchedLockSafe(irq);

            if (allDead) break;
            IO.Hlt(); // [FIX] Không dùng Scheduler.Yield() (int 0x81) trong Ring 0!
        }

        if (!allDead) {
            // [FIX TRIỆT ĐỂ] KHÔNG được gọi BroadcastApocalypse() ở đây! INIT IPI reset
            // TOÀN BỘ core phụ bất kể core đó đang chạy gì - nếu ACPI/ATA Daemon tình cờ
            // đang thực thi trên 1 AP đúng lúc này, chúng sẽ bị xóa sổ trước khi kịp
            // chạy 0xDEAD/0xBEEF ở phía dưới (dù đã được loại khỏi danh sách nhận 0xDEAD
            // ở tầng thread - loại trừ đó không bảo vệ được ở tầng core vật lý).
            // Chỉ cần đánh dấu Active=0 để Scheduler ngừng cấp CPU cho các thread cứng
            // đầu này là đủ - không cần đụng tới phần cứng core. BroadcastApocalypse()
            // chỉ được gọi ở CUỐI HÀM, sau khi ACPI Daemon đã có cơ hội chạy trọn vẹn
            // và tự nó thất bại - lúc đó không còn gì cần bảo vệ nữa.
            irq = Scheduler.AcquireSchedLockSafe();
            for (int i = 1; i < Scheduler.ThreadCount; i++) {
                if (i == Scheduler.CurrentThreadId || i == acpiPid || i == ataPid) continue;
                if (Scheduler.Threads[i].Priority != 99) {
                    Scheduler.Threads[i].Active = 0;
                    Scheduler.Threads[i].UID = 9999;
                }
            }
            Scheduler.ReleaseSchedLockSafe(irq);
        }

        // [FIX AN TOÀN SHUTDOWN] Chỉ giờ mới kill ATA Daemon - sau khi FAT16/thread khác
        // đã thoát hẳn (hoặc bị force-kill), đảm bảo không ai còn chờ IPC từ nó nữa.
        if (ataPid != -1) {
            IPC.Send(0xDEAD, 0, (uint)ataPid, 0);
            ulong ataTimeout = PIT.Ticks + 1000;
            while (PIT.Ticks < ataTimeout) {
                irq = Scheduler.AcquireSchedLockSafe();
                bool ataDead = Scheduler.Threads[ataPid].Active == 0;
                Scheduler.ReleaseSchedLockSafe(irq);
                if (ataDead) break;
                IO.Hlt();
            }
        }

        Driver.ATA.UseDaemon = false;
        Driver.ATA.FlushCache();

        if (acpiPid != -1)
        {
            fixed (char* msg4 = "   [*] Delegating Hardware Power-off to ACPI Daemon...\n\0") Terminal.Print(msg4);
            // Gửi lệnh tắt máy 0xDEAD cho ACPI Daemon qua IPC
            IPC.Send(0xDEAD, 0, (uint)acpiPid, 0);

            // [FIX NESTED INTERRUPT BUG] Scheduler.Yield() = ForceYield = "int 0x81" tạo ra
            // nested interrupt khi đang ở Ring 0 (syscall context) → stack frame bị lệch
            // → ACPI daemon không bao giờ được schedule! Dùng IO.Sti() + IO.Hlt() thay thế:
            // Timer interrupt vẫn fire bình thường → scheduler context-switch sang ACPI daemon.
            IO.EnableInterrupts();
            ulong acpiTimeout = PIT.Ticks + 3000;
            while (PIT.Ticks < acpiTimeout) IO.Hlt();
        }

        // [FIX TRIỆT ĐỂ] Đây là điểm DUY NHẤT gọi BroadcastApocalypse() - ACPI Daemon
        // đã được trao trọn thời gian (acpiTimeout) và tự nó thất bại, không còn thread
        // nào cần bảo vệ nữa. Vẫn đợi ATA rảnh tay trước khi bắn INIT IPI để không cắt
        // ngang 1 PIO transfer dở dang.
        Scheduler.Ready = false; IO.Cli();
        WaitAtaIdleBeforeApocalypse(2000);
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

        int acpiPid = -1, ataPid = -1;
        bool irq = Scheduler.AcquireSchedLockSafe();
        for (int i = 1; i < Scheduler.ThreadCount; i++) {
            if (Scheduler.Threads[i].Active != 0 &&
                Scheduler.Threads[i].Name[0] == 'A' && Scheduler.Threads[i].Name[1] == 'C' &&
                Scheduler.Threads[i].Name[2] == 'P' && Scheduler.Threads[i].Name[3] == 'I') {
                acpiPid = i;
            }
            // [FIX AN TOÀN SHUTDOWN] Kill ATA Daemon sau cùng - lý do như trong Shutdown().
            if (Scheduler.Threads[i].Active != 0 &&
                Scheduler.Threads[i].Name[0] == 'A' && Scheduler.Threads[i].Name[1] == 'T' &&
                Scheduler.Threads[i].Name[2] == 'A') {
                ataPid = i;
            }
        }
        Scheduler.ReleaseSchedLockSafe(irq);

        // [ĐÃ DỌN DẸP] Không đẻ Struct Message nữa!
        irq = Scheduler.AcquireSchedLockSafe();
        for (uint i = 1; i < (uint)Scheduler.ThreadCount; i++) {
            if (i == Scheduler.CurrentThreadId || i == acpiPid || i == ataPid) continue;
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
                if (i == Scheduler.CurrentThreadId || i == acpiPid || i == ataPid) continue;
                // [FIX CHÍ MẠNG 1] Bỏ qua bọn Idle Threads khi đếm xác!
                if (Scheduler.Threads[i].Active != 0 && Scheduler.Threads[i].Priority != 99) { allDead = false; break; }
            }
            Scheduler.ReleaseSchedLockSafe(irq);

            if (allDead) break;
            IO.Hlt(); // [FIX] Không dùng Scheduler.Yield() (int 0x81) trong Ring 0!
        }

        if (!allDead) {
            // [FIX TRIỆT ĐỂ] Xem giải thích trong Shutdown() - KHÔNG gọi BroadcastApocalypse()
            // ở đây. INIT IPI reset TOÀN BỘ core phụ vô điều kiện, có thể xóa sổ ACPI/ATA
            // Daemon nếu chúng đang chạy trên 1 AP - trước khi kịp xử lý 0xBEEF/0xDEAD phía
            // dưới. Chỉ đánh dấu Active=0 để Scheduler ngừng cấp CPU, không đụng phần cứng core.
            irq = Scheduler.AcquireSchedLockSafe();
            for (int i = 1; i < Scheduler.ThreadCount; i++) {
                if (i == Scheduler.CurrentThreadId || i == acpiPid || i == ataPid) continue;
                if (Scheduler.Threads[i].Priority != 99) {
                    Scheduler.Threads[i].Active = 0;
                    Scheduler.Threads[i].UID = 9999;
                }
            }
            Scheduler.ReleaseSchedLockSafe(irq);
        }

        // [FIX AN TOÀN SHUTDOWN] Chỉ giờ mới kill ATA Daemon - sau khi các thread khác đã
        // thoát hẳn, tránh chúng treo chờ phản hồi IPC từ 1 daemon đã chết.
        if (ataPid != -1) {
            IPC.Send(0xDEAD, 0, (uint)ataPid, 0);
            ulong ataTimeout = PIT.Ticks + 1000;
            while (PIT.Ticks < ataTimeout) {
                irq = Scheduler.AcquireSchedLockSafe();
                bool ataDead = Scheduler.Threads[ataPid].Active == 0;
                Scheduler.ReleaseSchedLockSafe(irq);
                if (ataDead) break;
                IO.Hlt();
            }
        }

        Driver.ATA.UseDaemon = false;
        Driver.ATA.FlushCache();

        if (acpiPid != -1)
        {
            fixed (char* msg4 = "   [*] Delegating Hardware Reboot to ACPI Daemon...\n\0") Terminal.Print(msg4);
            // Gửi lệnh reboot 0xBEEF cho ACPI Daemon qua IPC
            IPC.Send(0xBEEF, 0, (uint)acpiPid, 0);

            // [FIX NESTED INTERRUPT BUG] Tương tự Shutdown - dùng IO.Hlt() thay Scheduler.Yield()
            IO.EnableInterrupts();
            ulong acpiTimeout = PIT.Ticks + 3000;
            while (PIT.Ticks < acpiTimeout) IO.Hlt();
        }

        // [FIX TRIỆT ĐỂ] Điểm DUY NHẤT gọi BroadcastApocalypse() trong Reboot() - ACPI
        // Daemon đã có trọn thời gian (acpiTimeout) và tự nó thất bại, không còn thread
        // nào cần bảo vệ. Vẫn đợi ATA rảnh tay trước khi bắn INIT IPI.
        Scheduler.Ready = false; IO.Cli();
        WaitAtaIdleBeforeApocalypse(2000);
        BroadcastApocalypse(); // Bắn INIT IPI đóng băng trước khi chìm vào giấc ngủ vĩnh hằng!

        Terminal.SetColor(0x00FF0000);
        fixed (char* msg5 = "\n   [!!!] FATAL: ACPI DAEMON FAILED TO REBOOT HARDWARE! SYSTEM HALTED!\n\0") Terminal.Print(msg5);
        HardReboot();
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