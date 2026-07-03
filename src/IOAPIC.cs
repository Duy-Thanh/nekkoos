using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

public static unsafe class IOAPIC
{
    // ==========================================================
    // KHAI BÁO RÀO CHẮN PHẦN CỨNG & COMPILER
    // ==========================================================
    [DllImport("*", EntryPoint = "CompilerFence")] public static extern void CompilerFence();
    [DllImport("*", EntryPoint = "LoadFence")] public static extern void LoadFence();
    [DllImport("*", EntryPoint = "StoreFence")] public static extern void StoreFence();
    [DllImport("*", EntryPoint = "FullFence")] public static extern void FullFence();

    [DllImport("*", EntryPoint = "WriteMmio32")]
    public static extern void WriteMmio32(ulong address, uint value);

    [DllImport("*", EntryPoint = "ReadMmio32")]
    public static extern uint ReadMmio32(ulong address);

    public static ulong BaseAddress = 0;

    public static Spinlock IoApicLock = new Spinlock();

    // ==========================================================
    // [VŨ KHÍ MỚI] HÀM GHI NỘI BỘ (KHÔNG KHÓA - BỌC THÉP TRÌNH TỰ)
    // Đảm bảo lệnh chọn Index phải XONG XUÔI rồi mới được bơm Data!
    // ==========================================================
    private static void WriteUnsafe(uint reg, uint value)
    {
        // Kiểm tra xem BaseAddress có hợp lệ không
        if (BaseAddress == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC base address is zero!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem reg có nằm trong phạm vi hợp lệ không
        if (reg > 0xFF) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC register number out of range!\n\0") Terminal.Print(err);
            return;
        }

        CompilerFence();
        WriteMmio32(BaseAddress, reg); 
        
        // [BỌC THÉP PHẦN CỨNG] Ép IC nhận Index trước! Cấm đảo lệnh!
        FullFence(); 
        
        WriteMmio32(BaseAddress + 0x10, value); 
        
        // [BỌC THÉP PHẦN CỨNG] Ép IC nhận Data!
        FullFence(); 
    }

    public static void Write(uint reg, uint value)
    {
        bool irq = IoApicLock.AcquireSafe(); 
        WriteUnsafe(reg, value);
        IoApicLock.ReleaseSafe(irq);         
    }

    public static uint Read(uint reg)
    {
        bool irq = IoApicLock.AcquireSafe(); 

        // Kiểm tra xem BaseAddress có hợp lệ không
        if (BaseAddress == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC base address is zero!\n\0") Terminal.Print(err);
            IoApicLock.ReleaseSafe(irq);
            return 0;
        }
        
        // Kiểm tra xem reg có nằm trong phạm vi hợp lệ không
        if (reg > 0xFF) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC register number out of range!\n\0") Terminal.Print(err);
            IoApicLock.ReleaseSafe(irq);
            return 0;
        }
        
        CompilerFence();
        WriteMmio32(BaseAddress, reg);
        
        // [BỌC THÉP PHẦN CỨNG] Đợi IC nuốt xong cái Index mới dám xin Data!
        FullFence(); 

        uint val = ReadMmio32(BaseAddress + 0x10);
        
        IoApicLock.ReleaseSafe(irq);         
        return val;
    }

    public static void SetEntry(byte irq, byte vector, uint destApicId)
    {
        // Kiểm tra xem irq có nằm trong phạm vi hợp lệ không
        if (irq > 255) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC IRQ number too large!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem vector có nằm trong phạm vi hợp lệ không
        if (vector < 32 || vector > 255) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC vector number out of range!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem destApicId có nằm trong phạm vi hợp lệ không
        if (destApicId > 255) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC destination APIC ID too large!\n\0") Terminal.Print(err);
            return;
        }

        uint low = vector; 
        uint high = destApicId << 24;

        uint reg = (uint)(0x10 + (irq * 2));

        // Kiểm tra xem reg có nằm trong phạm vi hợp lệ không
        if (reg > 0xFF) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC register number out of range!\n\0") Terminal.Print(err);
            return;
        }
        
        bool irqFlag = IoApicLock.AcquireSafe(); 
        WriteUnsafe(reg, low | 0x10000); // BƯỚC 1: MASK
        WriteUnsafe(reg + 1, high);      // BƯỚC 2: TARGET CORE
        WriteUnsafe(reg, low);           // BƯỚC 3: UNMASK
        IoApicLock.ReleaseSafe(irqFlag);
    }

    public static void Init()
    {
        if (APIC.IOApicBase == 0) return;

        BaseAddress = APIC.IOApicBase;
        VMM.MapPage(BaseAddress, BaseAddress, 0x13);

        // Kiểm tra xem BaseAddress có được căn chỉnh đúng không
        if (((ulong)BaseAddress & 0xF) != 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC base address is not 16-byte aligned!\n\0") Terminal.Print(err);
            return;
        }

        PIC.Disable();

        uint maxIntr = (Read(0x01) >> 16) & 0xFF;
        
        // Kiểm tra xem maxIntr có nằm trong phạm vi hợp lệ không
        if (maxIntr > 255) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC maximum interrupt too large!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem maxIntr có hợp lệ không
        if (maxIntr == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC maximum interrupt is zero!\n\0") Terminal.Print(err);
            return;
        }

        for (uint i = 0; i <= maxIntr; i++)
        {
            Write((uint)(0x10 + (i * 2)), 0x10000); 
            Write((uint)(0x10 + (i * 2) + 1), 0);
        }

        uint bspApicId = 0;
        if (APIC.LocalApicBaseVirt != 0) {
            bspApicId = APIC.Read(0x020) >> 24;

            // Kiểm tra xem bspApicId có hợp lệ không
            if (bspApicId > 255) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: BSP APIC ID too large!\n\0") Terminal.Print(err);
                return;
            }
        }

        SetEntry(1, 33, bspApicId);
        SetEntry(12, 44, bspApicId); // [VŨ KHÍ MỚI] Chuột PS/2 -> Vector 44
        
        SetEntry(14, 46, bspApicId);
        SetEntry(15, 47, bspApicId);

        Terminal.SetColor(0x0000FFFF);
        fixed (char* m = "[+] I/O APIC Armed! PCIe/Hardware Interrupts routed natively.\n\0") Terminal.Print(m);
    }

    public static void MaskAll()
    {
        if (APIC.IOApicBase == 0) return;
        BaseAddress = APIC.IOApicBase;
        
        VMM.MapPage(BaseAddress, BaseAddress, 0x13);

        // Kiểm tra xem BaseAddress có được căn chỉnh đúng không
        if (((ulong)BaseAddress & 0xF) != 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC base address is not 16-byte aligned!\n\0") Terminal.Print(err);
            return;
        }

        uint maxIntr = (Read(0x01) >> 16) & 0xFF;

        // Kiểm tra xem maxIntr có nằm trong phạm vi hợp lệ không
        if (maxIntr > 255) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC maximum interrupt too large!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem maxIntr có hợp lệ không
        if (maxIntr == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOAPIC maximum interrupt is zero!\n\0") Terminal.Print(err);
            return;
        }

        for (uint i = 0; i <= maxIntr; i++)
        {
            WriteUnsafe((uint)(0x10 + (i * 2)), 0x10000); 
            WriteUnsafe((uint)(0x10 + (i * 2) + 1), 0);
        }
    }
}