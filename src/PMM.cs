// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// ==========================================================
// INTEROP: Thuật toán bitmap allocator (thuần logic, không phụ thuộc
// kiến trúc CPU) đã port sang src/pmm.pas. Phần duy nhất còn lại ở đây
// là Init() - đọc UEFI Memory Map (EFI_MEMORY_DESCRIPTOR), thuộc lớp
// "boot-glue" của firmware chứ không phải kiến trúc CPU, nên được giữ ở
// C# cho tới khi có lớp trừu tượng bootloader riêng cho các kiến trúc khác.
// ==========================================================
public static unsafe class PMM
{
    // Định nghĩa hằng số để thay thế ulong.MaxValue
    private const ulong ULongMax = 0xFFFFFFFFFFFFFFFF;
    private const uint UIntMax = 0xFFFFFFFF;
    private const ulong PmmInvalidIndex = ULongMax;

    public static byte* Bitmap;
    public static ulong BitmapSize;

    public static Spinlock PmmLock = new Spinlock();

    // ==========================================================
    // INTEROP: Gọi sang implementation bằng Pascal (src/pmm.pas)
    // ==========================================================
    [DllImport("*", EntryPoint = "PMM_SetState_Pas")]
    private static extern void PMM_SetState_Pas(byte* bitmap, ulong totalPages, ulong bitmapSize, ulong freePages);

    [DllImport("*", EntryPoint = "PMM_SetFreePages_Pas")]
    private static extern void PMM_SetFreePages_Pas(ulong freePages);

    [DllImport("*", EntryPoint = "PMM_SetBit_Pas")]
    private static extern void PMM_SetBit_Pas(ulong index);

    [DllImport("*", EntryPoint = "PMM_ClearBit_Pas")]
    private static extern void PMM_ClearBit_Pas(ulong index);

    [DllImport("*", EntryPoint = "PMM_TestBit_Pas")]
    private static extern byte PMM_TestBit_Pas(ulong index);

    [DllImport("*", EntryPoint = "PMM_GetTotalPages_Pas")]
    private static extern ulong PMM_GetTotalPages_Pas();

    [DllImport("*", EntryPoint = "PMM_GetFreePages_Pas")]
    private static extern ulong PMM_GetFreePages_Pas();

    [DllImport("*", EntryPoint = "PMM_AllocatePageIndex_Pas")]
    private static extern ulong PMM_AllocatePageIndex_Pas();

    [DllImport("*", EntryPoint = "PMM_AllocatePageBelow4GBIndex_Pas")]
    private static extern ulong PMM_AllocatePageBelow4GBIndex_Pas();

    [DllImport("*", EntryPoint = "PMM_AllocateContiguousIndex_Pas")]
    private static extern ulong PMM_AllocateContiguousIndex_Pas(ulong count);

    [DllImport("*", EntryPoint = "PMM_FreePageByIndex_Pas")]
    private static extern byte PMM_FreePageByIndex_Pas(ulong index);

    // TotalPages không đổi sau Init(); FreePages đổi liên tục - cả hai đều
    // đọc trực tiếp từ trạng thái nội bộ trong Pascal để luôn nhất quán.
    public static ulong TotalPages => PMM_GetTotalPages_Pas();
    public static ulong FreePages => PMM_GetFreePages_Pas();

    public static void Init(NekkoBootInfo* bootInfo, ulong largestFreeStart)
    {
        ulong mapSize = bootInfo->MemoryMapSize;
        ulong descSize = bootInfo->DescriptorSize;
        byte* mapPtr = (byte*)bootInfo->MemoryMap;
        ulong numEntries = mapSize / descSize;

        // Kiểm tra tràn khi tính toán numEntries
        if (mapSize < descSize) {
            // Xử lý lỗi: không có memory descriptor hợp lệ
            return;
        }

        ulong maxPhysicalAddress = 0;
        for (ulong i = 0; i < numEntries; i++)
        {
            EFI_MEMORY_DESCRIPTOR* desc = (EFI_MEMORY_DESCRIPTOR*)(mapPtr + (i * descSize));

            // [FIX CVE-2026-005] Kiểm tra tràn TRƯỚC KHI tính toán topAddress!
            if (desc->NumberOfPages > (ULongMax - desc->PhysicalStart) / 4096) {
                // Bỏ qua descriptor này vì nó quá lớn, có thể là attack vector
                continue;
            }

            ulong topAddress = desc->PhysicalStart + (desc->NumberOfPages * 4096);
            if (topAddress > maxPhysicalAddress) maxPhysicalAddress = topAddress;
        }

        // Kiểm tra giới hạn bộ nhớ
        if (maxPhysicalAddress > 0x100000000000) { // 256TB
            maxPhysicalAddress = 0x100000000000;
        }

        ulong totalPages = maxPhysicalAddress / 4096;
        // Tính toán BitmapSize chính xác
        ulong bitmapSize = (totalPages + 7) / 8; // Sửa lại để đảm bảo đủ bit
        // Đảm bảo BitmapSize không vượt quá giới hạn
        if (bitmapSize > ULongMax / 4096) {
            bitmapSize = ULongMax / 4096;
        }
        if (bitmapSize == 0) bitmapSize = 1; // Đảm bảo ít nhất 1 byte

        Bitmap = (byte*)largestFreeStart;
        BitmapSize = bitmapSize;

        // Kiểm tra xem có đủ bộ nhớ cho bitmap không
        if (largestFreeStart + bitmapSize > maxPhysicalAddress) {
            // Xử lý lỗi: không đủ bộ nhớ cho bitmap
            return;
        }

        for (ulong i = 0; i < bitmapSize; i++) Bitmap[i] = 0xFF;

        // Đăng ký trạng thái ban đầu vào Pascal (FreePages tạm = 0, sẽ cập
        // nhật sau khi quét xong các descriptor free bên dưới).
        PMM_SetState_Pas(Bitmap, totalPages, bitmapSize, 0);

        ulong freePages = 0;
        for (ulong i = 0; i < numEntries; i++)
        {
            EFI_MEMORY_DESCRIPTOR* desc = (EFI_MEMORY_DESCRIPTOR*)(mapPtr + (i * descSize));
            if (desc->Type == 7)
            {
                // Kiểm tra tràn khi tính toán startPage
                if (desc->PhysicalStart > ULongMax - 1) continue;
                ulong startPage = desc->PhysicalStart / 4096;
                // Kiểm tra tràn khi tính toán số trang
                if (desc->NumberOfPages > (ULongMax - startPage)) {
                    desc->NumberOfPages = ULongMax - startPage;
                }
                for (ulong j = 0; j < desc->NumberOfPages; j++) {
                    if (startPage + j < totalPages) {
                        PMM_ClearBit_Pas(startPage + j);
                    }
                }
                freePages += desc->NumberOfPages;
            }
        }

        ulong bitmapPages = (bitmapSize + 4095) / 4096;
        ulong bitmapStartPage = largestFreeStart / 4096;
        for (ulong i = 0; i < bitmapPages; i++) {
            if (bitmapStartPage + i < totalPages) {
                PMM_SetBit_Pas(bitmapStartPage + i);
                freePages--;
            }
        }

        // ==========================================================
        // [CRITICAL PROTECTION] Reserve critical system memory pages
        // Page 0 (0x0000): BIOS Interrupt Vector Table
        // Page 8 (0x8000): SMP Trampoline code for AP startup
        // Page 9 (0x9000): SMP Trampoline extension (if code exceeds 4KB)
        // These pages must never be allocated to userspace to prevent GPF
        // ==========================================================
        if (PMM_TestBit_Pas(0) == 0) { PMM_SetBit_Pas(0); freePages--; }
        if (PMM_TestBit_Pas(8) == 0) { PMM_SetBit_Pas(8); freePages--; }
        if (PMM_TestBit_Pas(9) == 0) { PMM_SetBit_Pas(9); freePages--; }

        // Chốt lại FreePages cuối cùng vào trạng thái Pascal.
        PMM_SetFreePages_Pas(freePages);
    }

    public static void* AllocatePage()
    {
        bool irq = PmmLock.AcquireSafe();
        ulong index = PMM_AllocatePageIndex_Pas();
        PmmLock.ReleaseSafe(irq);

        if (index == PmmInvalidIndex) return null;

        void* result = (void*)(index * 4096);
        // Tẩy rửa RAM (MemSet) ở BÊN NGOÀI KHÓA!
        LibC.MemSet((byte*)result, 0, 4096);
        return result;
    }

    // ==========================================================
    // [MEMORY CONSTRAINT] Allocate pages below 4GB for SMP Trampoline
    // Protected Mode only supports 32-bit addressing in CR3.
    // If PML4 is above 4GB, the trampoline will truncate the CR3 value,
    // resulting in incorrect page table pointer and kernel panic.
    // This function ensures SMP bootstrap code has accessible memory.
    // ==========================================================
    public static void* AllocatePageBelow4GB()
    {
        bool irq = PmmLock.AcquireSafe();
        ulong index = PMM_AllocatePageBelow4GBIndex_Pas();
        PmmLock.ReleaseSafe(irq);

        if (index == PmmInvalidIndex) return null;

        void* result = (void*)(index * 4096);
        LibC.MemSet((byte*)result, 0, 4096);
        return result;
    }

    // ==========================================================
    // [BƠM VIAGRA] HÀM CẤP PHÁT RAM LIỀN KỀ BỌC THÉP TỪ 16MB!
    // Tuyệt đối không Fallback về 0 để tránh mìn Kernel.
    // Dùng cho cấp phát siêu to khổng lồ (Ví dụ: Framebuffer 3MB)
    // ==========================================================
    public static void* AllocateContiguousPages(ulong count)
    {
        bool irq = PmmLock.AcquireSafe();
        ulong index = PMM_AllocateContiguousIndex_Pas(count);
        PmmLock.ReleaseSafe(irq);

        if (index == PmmInvalidIndex) return null;

        void* result = (void*)(index * 4096);

        // Tẩy rửa RAM bằng (uint)count để tránh tràn!
        if (count <= UIntMax / 4096) {
            LibC.MemSet((byte*)result, 0, (uint)(count * 4096));
        } else {
            // Xử lý trường hợp count > UIntMax bằng memset nhiều lần
            ulong remaining = count;
            byte* current = (byte*)result;

            while (remaining > 0) {
                uint chunkSize = remaining > UIntMax ? UIntMax : (uint)remaining;
                LibC.MemSet(current, 0, chunkSize);
                current += chunkSize;
                remaining -= chunkSize;
            }
        }

        return result; // Hết RAM liền kề rồi con trai!
    }

    // ==========================================================
    // [THIẾT QUÂN LUẬT] VŨ KHÍ THU HỒI RAM VẬT LÝ (FREE PAGE)
    // Trả lại tài nguyên cho Quốc gia khi App bị tử hình!
    // ==========================================================
    public static void FreePage(void* ptr)
    {
        if (ptr == null) return; // Kiểm tra null pointer

        ulong addr = (ulong)ptr;

        // Kiểm tra xem địa chỉ có hợp lệ không
        if (addr % 4096 != 0) {
            // Địa chỉ không phải là boundary của trang
            return;
        }

        ulong index = addr / 4096;

        bool irq = PmmLock.AcquireSafe();
        byte status = PMM_FreePageByIndex_Pas(index);
        PmmLock.ReleaseSafe(irq);

        if (status == 2) {
            // Double free or freeing unallocated page
            Terminal.SetColor(0x00FF0000);
            fixed (char* msg = "[!] PMM WARNING: Attempt to free unallocated page!\n\0") Terminal.Print(msg);
        }
    }
}
