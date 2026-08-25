// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

public unsafe struct Spinlock
{
    [DllImport("*", EntryPoint = "AsmSpinlockAcquire")]
    private static extern void AsmSpinlockAcquire(uint* lockVar);

    [DllImport("*", EntryPoint = "AsmSpinlockRelease")]
    private static extern void AsmSpinlockRelease(uint* lockVar);

    [DllImport("*", EntryPoint = "GetRflags")]
    public static extern ulong GetRflags();

    // ==========================================================
    // [BARRIERS] Import memory barrier functions from assembly
    // ==========================================================
    [DllImport("*", EntryPoint = "CompilerFence")] public static extern void CompilerFence();
    [DllImport("*", EntryPoint = "StoreFence")] public static extern void StoreFence();

    private uint _lockStatus;

    // Thêm constructor để đảm bảo initialization
    public Spinlock()
    {
        _lockStatus = 0; // Đảm bảo lock được khởi tạo ở trạng thái unlocked
    }

    // ==========================================================
    // [SYNCHRONIZATION] Interrupt-safe lock acquisition
    // Disables interrupts to prevent deadlocks from interrupt handlers (e.g. Timer, Keyboard)
    // ==========================================================
    public bool AcquireSafe()
    {
        bool intsEnabled = (GetRflags() & 0x200) != 0;
        IO.Cli(); // Khóa tịt ngắt
        // Kiểm tra xem con trỏ có null không
        fixed (uint* ptr = &_lockStatus) {
            if (ptr == null) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Null pointer in Spinlock AcquireSafe!\n\0") Terminal.Print(err);
                if (intsEnabled) IO.EnableInterrupts();
                return false;
            }
            AsmSpinlockAcquire(ptr);
        }
        // [CỬA VÀO VÙNG CẤM] 
        // Báo cho LLVM: "Từ dòng này trở đi là Critical Section! Đéo được đảo lệnh!"
        CompilerFence();
        return intsEnabled;
    }

    public void ReleaseSafe(bool intsEnabled)
    {
        // [CỬA RA VÙNG CẤM] 
        // 1. Ép LLVM không được mang lệnh từ trong vùng cấm lọt ra ngoài.
        CompilerFence();
        
        // 2. Ép CPU xả toàn bộ Store Buffer xuống RAM thực tế.
        // Cứu mạng OS khỏi trường hợp Lõi 2 thấy cửa mở nhưng data chưa kịp ghi xong!
        StoreFence();
        
        fixed (uint* ptr = &_lockStatus) {
            if (ptr == null) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Null pointer in Spinlock ReleaseSafe!\n\0") Terminal.Print(err);
                if (intsEnabled) IO.EnableInterrupts();
                return;
            }
            AsmSpinlockRelease(ptr);
        }
        if (intsEnabled) IO.EnableInterrupts(); // Trả lại y nguyên lúc đầu!
    }

    // [FIX AN TOÀN SHUTDOWN] Peek trạng thái khóa, không chiếm khóa - dùng để
    // kiểm tra "có lõi nào đang giữ khóa PIO không" trước khi bắn INIT IPI cưỡng ép,
    // tránh cắt ngang giữa chừng 1 sector ATA đang ghi dở dang.
    public bool IsLocked()
    {
        fixed (uint* ptr = &_lockStatus) { return *ptr != 0; }
    }

    // Giữ lại 2 hàm gốc cho các trường hợp đặc biệt
    // ==========================================================
    // BỌC THÉP LUÔN CHO 2 HÀM GỐC!
    // ==========================================================
    public void Acquire() 
    { 
        fixed (uint* ptr = &_lockStatus) { AsmSpinlockAcquire(ptr); } 
        CompilerFence(); // Chốt cửa vào!
    }
    
    public void Release() 
    { 
        CompilerFence(); // Chốt cửa ra!
        StoreFence();    // Xả Cache RAM!
        fixed (uint* ptr = &_lockStatus) { AsmSpinlockRelease(ptr); } 
    }
}