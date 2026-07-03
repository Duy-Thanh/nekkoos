using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct Strand {
    public delegate*<void> Action; 
    // Trạng thái: 0 = Dead, 1 = Ready, 2 = Running
    public byte Active;            
    public fixed byte Padding[7];  
}

public static unsafe class StrandScheduler
{
    public static Strand* Strands;
    public static int MAX_STRANDS = 256; 
    public static int StrandCount = 0;
    public static int CurrentStrand = 0;

    // [VŨ KHÍ MỚI] Ổ KHÓA BẢO VỆ STRAND KHỎI BỌN LÕI PHỤ!
    public static Spinlock StrandLock = new Spinlock();

    public static void Init() {
        StrandCount = 0;
        Strands = (Strand*)PMM.AllocatePage();
        LibC.MemSet((byte*)Strands, 0, 4096);
        Terminal.SetColor(0x00FF00FF);
        fixed (char* msg = "[+] Zero-Context Strands Engine Forged in Steel!\n\0") Terminal.Print(msg);
    }

    public static void CreateStrand(delegate*<void> action) {
        if (action == null) return; 
        
        bool irq = StrandLock.AcquireSafe(); // [FIX CHÍ MẠNG] DÙNG KHÓA AN TOÀN!
        for (int i = 0; i < StrandCount; i++) {
            if (Strands[i].Active == 0) {
                Strands[i].Action = action; 
                Strands[i].Active = 1; // Mark Ready
                StrandLock.ReleaseSafe(irq); 
                return; 
            }
        }
        if (StrandCount < MAX_STRANDS) {
            Strands[StrandCount].Action = action; 
            Strands[StrandCount].Active = 1; 
            StrandCount++;
        }
        StrandLock.ReleaseSafe(irq); 
    }

    public static void RunCycle() {
        bool irq = StrandLock.AcquireSafe(); // [FIX CHÍ MẠNG] KHÓA AN TOÀN!
        
        if (StrandCount == 0) {
            StrandLock.ReleaseSafe(irq); 
            return;
        }

        int selected = -1;
        int checkedCount = 0;

        // ==========================================================
        // [VŨ KHÍ TỐI THƯỢNG] THUẬT TOÁN TÌM KIẾM AN TOÀN ĐA LÕI
        // Chỉ bốc những thằng có Active == 1 (Ready). Bỏ qua bọn = 2 (Running).
        // ==========================================================
        while (checkedCount < StrandCount) {
            if (Strands[CurrentStrand].Active == 1) {
                selected = CurrentStrand;
                Strands[selected].Active = 2; // ĐÓNG DẤU CHỦ QUYỀN: TAO ĐANG CHẠY NÓ!
                CurrentStrand = (CurrentStrand + 1) % StrandCount;
                break;
            }
            CurrentStrand = (CurrentStrand + 1) % StrandCount;
            checkedCount++;
        }

        StrandLock.ReleaseSafe(irq);

        // CHẠY HÀM Ở NGOÀI Ổ KHÓA ĐỂ TRÁNH DEADLOCK!
        if (selected != -1) {
            var action = Strands[selected].Action;
            if (action != null) action();

            // ==========================================================
            // [CHU KỲ SỐNG CỦA STRAND] SAU KHI CHẠY XONG, TRẢ VỀ READY!
            // ==========================================================
            irq = StrandLock.AcquireSafe();
            // Chỉ trả về 1 nếu nó chưa bị hàm khác bóp chết (tức là vẫn bằng 2)
            if (Strands[selected].Active == 2) {
                Strands[selected].Active = 1; 
            }
            StrandLock.ReleaseSafe(irq);
        }
    }
}