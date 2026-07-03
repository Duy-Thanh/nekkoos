using System.Runtime.InteropServices;

namespace NekkoOS.Kernel.Utilities;

public static unsafe class PRNG
{
    [DllImport("*", EntryPoint = "ReadTSC")] 
    public static extern ulong ReadTSC();

    private static ulong state = 0;

    // ==========================================================
    // [VŨ KHÍ MỚI] Ổ KHÓA LƯỢNG TỬ (SPINLOCK)
    // Đảm bảo 8 Lõi CPU đéo bao giờ xâu xé cái hạt giống này!
    // ==========================================================
    private static Spinlock PrngLock = new Spinlock();

    public static void Init()
    {
        state = ReadTSC();

        // Kiểm tra xem ReadTSC có trả về giá trị hợp lệ không
        if (state == 0) {
            state = 0x1337CAFE8BADBEEFUL; // Sử dụng giá trị mặc định nếu TSC = 0
        }
        
        state ^= PIT.Ticks << 16;
        
        state = (state ^ (state >> 30)) * 0xbf58476d1ce4e5b9UL;
        state = (state ^ (state >> 27)) * 0x94d049bb133111ebUL;

        // ==========================================================
        // [FIX CHÍ MẠNG 1] LUẬT TỬ TẾ CỦA XORSHIFT!
        // State đéo bao giờ được phép bằng 0! Nếu bằng 0, ép nó thành số khác!
        // ==========================================================
        if (state == 0) state = 0x1337CAFE8BADBEEFUL; 
    }

    public static ulong Next()
    {
        // ==========================================================
        // [FIX CHÍ MẠNG 2] KHÓA MÕM TẤT CẢ CÁC LÕI KHÁC KHI LẤY SỐ!
        // ==========================================================
        bool irq = PrngLock.AcquireSafe();

        // Đề phòng trường hợp có thằng ngáo đá nào gọi Next() trước khi KernelMain gọi Init()
        if (state == 0) {
            ulong tsc = ReadTSC();
            // Kiểm tra xem ReadTSC có trả về giá trị hợp lệ không
            if (tsc == 0) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: TSC returned zero in PRNG!\n\0") Terminal.Print(err);
                PrngLock.ReleaseSafe(irq);
                return 0; // Trả về giá trị mặc định
            }
            state = tsc | 1; 
        }

        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        
        ulong result = state * 0x2545F4914F6CDD1DUL;

        PrngLock.ReleaseSafe(irq); // TRẢ KHÓA!
        
        return result;
    }

    public static ulong Next(ulong min, ulong max)
    {
        if (min >= max) return min; // Cản tụi ngáo truyền max nhỏ hơn min

        // ==========================================================
        // [FIX CHÍ MẠNG 3] CHỐNG TRÀN SỐ (OVERFLOW) GÂY KERNEL PANIC DIVIDE BY ZERO!
        // ==========================================================
        ulong range = max - min;
        
        // ==========================================================
        // [SỬA LỖI CS0117 CHÍ MẠNG] DÙNG RAW HEX THAY VÌ ULONG.MAXVALUE!
        // Baremetal đéo có System.UInt64.MaxValue! Phải tự đúc bằng thép!
        // ==========================================================
        if (range == 0xFFFFFFFFFFFFFFFFUL) return Next(); 
        
        range += 1; 
        
        return min + (Next() % range);
    }
}