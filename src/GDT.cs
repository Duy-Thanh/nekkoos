// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// ==========================================================
// MODULE: NHÀ TÙ QUYỀN LỰC (GDT & TSS MANAGER - MILITARY GRADE)
// ==========================================================

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct GDTDescriptor
{
    public ushort Size;
    public ulong Offset;
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct GDTEntry
{
    public ushort LimitLow;
    public ushort BaseLow;
    public byte BaseMiddle;
    public byte Access;
    public byte Flags;
    public byte BaseHigh;
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct TSSEntry
{
    public uint Reserved0;
    public ulong Rsp0; 
    public ulong Rsp1;
    public ulong Rsp2;
    public ulong Reserved1;
    public ulong Ist1;
    public ulong Ist2;
    public ulong Ist3;
    public ulong Ist4;
    public ulong Ist5;
    public ulong Ist6;
    public ulong Ist7;
    public ulong Reserved2;
    public ushort Reserved3;
    public ushort IopbOffset; 
    public fixed byte Iopb[8192]; 
    public byte EndMarker; 
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct TSSDescriptor
{
    public ushort LimitLow;
    public ushort BaseLow;
    public byte BaseMiddle;
    public byte Access;
    public byte Flags;
    public byte BaseHigh;
    public uint BaseUpper32;
    public uint Reserved;
}

public static unsafe class GDT
{
    [DllImport("*", EntryPoint = "Arch_LoadGDT")] 
    public static extern void LoadGDT(GDTDescriptor* gdtPtr);
    
    [DllImport("*", EntryPoint = "Arch_LoadTSS")] 
    public static extern void LoadTSS(ushort tssSegment);

    // ==========================================================
    // KHAI BÁO RÀO CHẮN PHẦN CỨNG & COMPILER
    // ==========================================================
    [DllImport("*", EntryPoint = "Arch_CompilerFence")] public static extern void CompilerFence();
    [DllImport("*", EntryPoint = "Arch_LoadFence")] public static extern void LoadFence();
    [DllImport("*", EntryPoint = "Arch_StoreFence")] public static extern void StoreFence();
    [DllImport("*", EntryPoint = "Arch_FullFence")] public static extern void FullFence();

    public static TSSEntry* Tss;
    public static GDTDescriptor gdt_struct;

    public static unsafe void GrantPortAccess(ushort port)
    {
        // Kiểm tra xem port có nằm trong phạm vi hợp lệ không
        if (port > 0xFFFF) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid port number!\n\0") Terminal.Print(err);
            return;
        }

        int byteIndex = port / 8;
        int bitIndex = port % 8;
        
        // Kiểm tra xem byteIndex có nằm trong phạm vi IOPB không
        if (byteIndex >= 8192) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Port access out of IOPB range!\n\0") Terminal.Print(err);
            return;
        }
        
        byte mask = (byte)~(1 << bitIndex);
        
        // ==========================================================
        // [BỌC THÉP COMPILER] Ép LLVM không được gộp lệnh hay đảo lệnh
        // ==========================================================
        CompilerFence(); 
        
        // 1. Mở khóa cho Lõi Vua (Core 0)
        Tss->Iopb[byteIndex] &= mask;

        // 2. Đồng bộ quyền lực I/O cho toàn bộ Lõi Phụ!
        for (uint i = 1; i < APIC.CoreCount; i++) {
            if (SMP.CoreTssList != null && SMP.CoreTssList[i] != null) {
                TSSEntry* apTss = (TSSEntry*)SMP.CoreTssList[i];
                CompilerFence(); // Báo LLVM vòng lặp này có sửa RAM!
                apTss->Iopb[byteIndex] &= mask;
            }
        }

        // ==========================================================
        // [BỌC THÉP PHẦN CỨNG] FULL FENCE (MFENCE)
        // Mày vừa cập nhật bản đồ I/O (IOPB) cho tất cả các CPU. 
        // Phải dùng mfence chốt cứng ngay lập tức! Ép mọi Lõi xả Store Buffer, 
        // đảm bảo dữ liệu "chín" trước khi App kịp gọi lệnh IN/OUT!
        // ==========================================================
        FullFence();
    }

    private static void SetEntry(GDTEntry* entry, uint baseAddr, uint limit, byte access, byte flags)
    {
        entry->BaseLow = (ushort)(baseAddr & 0xFFFF);
        entry->BaseMiddle = (byte)((baseAddr >> 16) & 0xFF);
        entry->BaseHigh = (byte)((baseAddr >> 24) & 0xFF);
        entry->LimitLow = (ushort)(limit & 0xFFFF);
        entry->Flags = (byte)((limit >> 16) & 0x0F);
        entry->Flags |= (byte)(flags & 0xF0);
        entry->Access = access;
    }

    public static void Init()
    {
        byte* gdtMem = (byte*)PMM.AllocatePage();
        if (gdtMem == null)
        {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Cannot allocate memory for GDT!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        // Kiểm tra xem GDT có được căn chỉnh đúng không
        if (((ulong)gdtMem & 0x7) != 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: GDT is not 8-byte aligned!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        Tss = (TSSEntry*)PMM.AllocateContiguousPages(3);

        if (Tss == null)
        {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Cannot allocate contiguous memory for TSS!\n\0") Terminal.Print(err);
            IO.Hlt();
        }
        
        // Kiểm tra xem TSS có được căn chỉnh đúng không
        if (((ulong)Tss & 0xF) != 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: TSS is not 16-byte aligned!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        LibC.MemSet((byte*)Tss, 0, (uint)sizeof(TSSEntry));

        // Kiểm tra xem kích thước TSS có đủ lớn cho IOPB không
        if (sizeof(TSSEntry) < 104 + 8192) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: TSS size is too small for IOPB!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        // Kiểm tra xem TSS có được căn chỉnh đúng không
        if (((ulong)Tss & 0xF) != 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: TSS is not 16-byte aligned!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        for (int i = 0; i < 8192; i++) Tss->Iopb[i] = 0xFF;
        Tss->EndMarker = 0xFF; 

        GDTEntry* entries = (GDTEntry*)gdtMem;

        SetEntry(&entries[0], 0, 0, 0, 0);                       // Null
        SetEntry(&entries[1], 0, 0xFFFFF, 0x9A, 0xA0);           // Ring 0 Code
        SetEntry(&entries[2], 0, 0xFFFFF, 0x92, 0xA0);           // Ring 0 Data
        SetEntry(&entries[3], 0, 0xFFFFF, 0xF2, 0xA0);           // Ring 3 Data 
        SetEntry(&entries[4], 0, 0xFFFFF, 0xFA, 0xA0);           // Ring 3 Code

        TSSDescriptor* tssDesc = (TSSDescriptor*)&entries[5];
        ulong tssBase = (ulong)Tss;
        uint tssLimit = (uint)sizeof(TSSEntry) - 1;

        // Kiểm tra xem kích thước TSS có hợp lệ không
        if (tssLimit > 0x0FFFFF) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: TSS size exceeds limit!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        tssDesc->LimitLow = (ushort)(tssLimit & 0xFFFF);
        tssDesc->BaseLow = (ushort)(tssBase & 0xFFFF);
        tssDesc->BaseMiddle = (byte)((tssBase >> 16) & 0xFF);
        tssDesc->Access = 0x89;
        tssDesc->Flags = (byte)((tssLimit >> 16) & 0x0F);
        tssDesc->BaseHigh = (byte)((tssBase >> 24) & 0xFF);
        tssDesc->BaseUpper32 = (uint)(tssBase >> 32);
        tssDesc->Reserved = 0;

        Tss->IopbOffset = 104; 

        // Kiểm tra xem IOPBOffset có hợp lệ không
        if (Tss->IopbOffset >= 8192) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: IOPB offset out of range!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        gdt_struct.Size = 55; 
        gdt_struct.Offset = (ulong)gdtMem;

        byte* rsp0Page = (byte*)PMM.AllocatePage();
        if (rsp0Page == null)
        {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Cannot allocate memory for Rsp0!\n\0") Terminal.Print(err);
            IO.Hlt();
        }
        
        Tss->Rsp0 = (ulong)rsp0Page + 4096;
        
        // Kiểm tra xem Rsp0 có nằm trong phạm vi hợp lệ không
        if (Tss->Rsp0 < (ulong)rsp0Page || Tss->Rsp0 > (ulong)rsp0Page + 4096) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid Rsp0 address!\n\0") Terminal.Print(err);
            IO.Hlt();
        }

        // ==========================================================
        // [BỌC THÉP TỬ HUYỆT BOOT] TRƯỚC KHI GỌI LGDT & LTR
        // Cấm CPU nạp GDT/TSS khi dữ liệu RAM vẫn đang kẹt trong Cache!
        // ==========================================================
        StoreFence(); 

        fixed (GDTDescriptor* ptr = &gdt_struct) 
        { 
            LoadGDT(ptr); 
        }
        
        LoadTSS(0x28); 

        Terminal.SetColor(0x0000FF00);
        fixed (char* msg = "[+] Core GDT and Ring 3 TSS Jail Forged in Steel!\n\0") Terminal.Print(msg);
    }
}