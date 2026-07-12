// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// ==========================================================
// MODULE: BẢNG PHÂN PHỐI NGẮT (IDT - QNX STYLE)
// DATE: TƯƠNG LAI CỦA NEKKO OS - KỶ LUẬT THÉP BẤT HOẠI
// ==========================================================
[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct IDTEntry
{
    public ushort BaseLow;       // 16 bit đầu của địa chỉ hàm ISR
    public ushort Selector;      // Code Segment Selector
    public byte Ist;             // Interrupt Stack Table
    public byte Flags;           // Cờ Type & Attributes (0x8E)
    public ushort BaseMid;       // 16 bit giữa
    public uint BaseHigh;        // 32 bit cuối
    public uint Reserved;        // Bỏ trống
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct IDTPointer
{
    public ushort Limit;         // Kích thước bảng IDT - 1
    public ulong Base;           // Địa chỉ gốc của bảng IDT
}

public static unsafe class IDTManager
{
    // ==========================================================
    // KHAI BÁO RÀO CHẮN PHẦN CỨNG & COMPILER
    // ==========================================================
    [DllImport("*", EntryPoint = "CompilerFence")] public static extern void CompilerFence();
    [DllImport("*", EntryPoint = "LoadFence")] public static extern void LoadFence();
    [DllImport("*", EntryPoint = "StoreFence")] public static extern void StoreFence();
    [DllImport("*", EntryPoint = "FullFence")] public static extern void FullFence();

    public static IDTEntry* idt;
    
    public static IDTPointer* idtr_struct;

    [DllImport("*", EntryPoint = "LoadIdt")]
    public static extern void LoadIdt(IDTPointer* p);

    public static void Init()
    {
        idt = (IDTEntry*)PMM.AllocatePage();
        if (idt == null)
        {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Cannot allocate memory for IDT!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        // Kiểm tra xem IDT có được căn chỉnh đúng không
        if (((ulong)idt & 0x7) != 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IDT is not 8-byte aligned!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        byte* ptr = (byte*)idt;
        for(int i = 0; i < 4096; i++) ptr[i] = 0;

        idtr_struct = (IDTPointer*)PMM.AllocatePage();
        if (idtr_struct == null)
        {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Cannot allocate memory for IDTR!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        // Kiểm tra xem IDTR có được căn chỉnh đúng không
        if (((ulong)idtr_struct & 0x7) != 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IDTR is not 8-byte aligned!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        idtr_struct->Limit = 0x0FFF;
        idtr_struct->Base = (ulong)idt;

        // ==========================================================
        // [BỌC THÉP TỬ HUYỆT 1] ÉP XẢ STORE BUFFER TRƯỚC KHI LIDT!
        // Lệnh LIDT dưới ASM đọc thẳng từ RAM. Phải đảm bảo Limit và Base 
        // đã được chôn xuống RAM thật, cấm CPU ngâm trong Cache!
        // ==========================================================
        StoreFence();

        // Nạp bằng RAM Vật lý! Xuyên thấu mọi rào cản!
        LoadIdt(idtr_struct);
        
        Terminal.SetColor(0x0000FF00);
        fixed (char* msg = "[+] Multicore IDT (Interrupt Descriptor Table) Forged in PMM!\n\0") Terminal.Print(msg);
    }

    public static void SetGate(int interruptNumber, void* handlerAddress)
    {
        // Kiểm tra xem số ngắt có hợp lệ không
        if (interruptNumber < 0 || interruptNumber > 255) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid interrupt number!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem handlerAddress có hợp lệ không
        if (handlerAddress == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null handler address!\n\0") Terminal.Print(err);
            return;
        }
        
        ulong addr = (ulong)handlerAddress;
        byte* entryPtr = (byte*)idt;
        for (int i = 0; i < interruptNumber; i++) { entryPtr += 16; }
        IDTEntry* entry = (IDTEntry*)entryPtr;

        // ==========================================================
        // [TRÌNH TỰ BẤT KHẢ XÂM PHẠM]
        // 1. Ghi toàn bộ dữ liệu địa chỉ và Selector trước!
        // Tuyệt đối CHƯA bật cờ Flags (Present) ở bước này!
        // ==========================================================
        entry->BaseLow = (ushort)(addr & 0xFFFF);
        entry->Selector = 0x08; 
        entry->Ist = 0;
        entry->BaseMid = (ushort)((addr >> 16) & 0xFFFF);
        entry->BaseHigh = (uint)((addr >> 32) & 0xFFFFFFFF);
        entry->Reserved = 0;

        // Kiểm tra xem selector có hợp lệ không
        if (entry->Selector != 0x08) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid selector!\n\0") Terminal.Print(err);
            return;
        }

        // ==========================================================
        // [BỌC THÉP TỬ HUYỆT 2] KHÓA MÕM COMPILER VÀ CPU!
        // Phải đảm bảo địa chỉ hàm ISR đã "chín" 100% trên RAM
        // ==========================================================
        CompilerFence();
        StoreFence();

        // 2. KÍCH HOẠT NGẮT (BẬT CỜ PRESENT = 1 -> 0x8E)
        entry->Flags = 0x8E;

        // ==========================================================
        // 3. CHỐT SỔ ĐỂ CÁC LÕI KHÁC NHÌN THẤY GATE ĐÃ MỞ!
        // ==========================================================
        StoreFence();
    }
}