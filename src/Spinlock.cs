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
    // NẠP KHO VŨ KHÍ RÀO CHẮN
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
    // [VŨ KHÍ TỐI THƯỢNG] KHÓA AN TOÀN (TỰ ĐỘNG BỊT LỖ TAI)
    // Đảm bảo đéo có thằng Timer hay Keyboard nào dám ngắt lúc đang ôm khóa!
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