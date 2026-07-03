namespace NekkoOS.Kernel;

public static unsafe class PMM
{
    // Định nghĩa hằng số để thay thế ulong.MaxValue
    private const ulong ULongMax = 0xFFFFFFFFFFFFFFFF;
    private const uint UIntMax = 0xFFFFFFFF;

    public static byte* Bitmap;
    public static ulong TotalPages;
    public static ulong FreePages;
    public static ulong BitmapSize;

    public static Spinlock PmmLock = new Spinlock();

    // ==========================================================
    // [VŨ KHÍ MỚI] CON TRỎ NEXT-FIT BẤT TỬ!
    // Ghi nhớ vị trí Page rảnh cuối cùng để đéo phải quét lại từ 0!
    // ==========================================================
    private static ulong LastUsedIndex = 0;

    public static void SetBit(ulong index) 
    {
        // Kiểm tra xem index có hợp lệ không
        if (index >= TotalPages) return;
        if (Bitmap == null) return;
        ulong byteIndex = index / 8;
        if (byteIndex >= BitmapSize) return;
        Bitmap[byteIndex] |= (byte)(1 << (int)(index % 8));
    }
    
    public static void ClearBit(ulong index) 
    {
        // Kiểm tra xem index có hợp lệ không
        if (index >= TotalPages) return;
        if (Bitmap == null) return;
        ulong byteIndex = index / 8;
        if (byteIndex >= BitmapSize) return;
        Bitmap[byteIndex] &= (byte)~(1 << (int)(index % 8));
    }
    
    public static bool TestBit(ulong index) 
    {
        // Kiểm tra xem index có hợp lệ không
        if (index >= TotalPages) return false;
        if (Bitmap == null) return false;
        ulong byteIndex = index / 8;
        if (byteIndex >= BitmapSize) return false;
        return (Bitmap[byteIndex] & (byte)(1 << (int)(index % 8))) != 0;
    }

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
            ulong topAddress = desc->PhysicalStart + (desc->NumberOfPages * 4096);
            // Kiểm tra tràn khi tính toán topAddress
            if (desc->NumberOfPages > (ULongMax - desc->PhysicalStart) / 4096) {
                // Bỏ qua descriptor này vì nó quá lớn
                continue;
            }
            if (topAddress > maxPhysicalAddress) maxPhysicalAddress = topAddress;
        }

        // Kiểm tra giới hạn bộ nhớ
        if (maxPhysicalAddress > 0x100000000000) { // 256TB
            maxPhysicalAddress = 0x100000000000;
        }

        TotalPages = maxPhysicalAddress / 4096;
        // Tính toán BitmapSize chính xác
        BitmapSize = (TotalPages + 7) / 8; // Sửa lại để đảm bảo đủ bit
        // Đảm bảo BitmapSize không vượt quá giới hạn
        if (BitmapSize > ULongMax / 4096) {
            BitmapSize = ULongMax / 4096;
        }
        if (BitmapSize == 0) BitmapSize = 1; // Đảm bảo ít nhất 1 byte

        Bitmap = (byte*)largestFreeStart;

        // Kiểm tra xem có đủ bộ nhớ cho bitmap không
        if (largestFreeStart + BitmapSize > maxPhysicalAddress) {
            // Xử lý lỗi: không đủ bộ nhớ cho bitmap
            return;
        }

        for (ulong i = 0; i < BitmapSize; i++) Bitmap[i] = 0xFF;

        FreePages = 0;
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
                    if (startPage + j < TotalPages) {
                        ClearBit(startPage + j);
                    }
                }
                FreePages += desc->NumberOfPages;
            }
        }

        ulong bitmapPages = (BitmapSize + 4095) / 4096;
        ulong bitmapStartPage = largestFreeStart / 4096;
        for (ulong i = 0; i < bitmapPages; i++) { 
            if (bitmapStartPage + i < TotalPages) {
                SetBit(bitmapStartPage + i); 
                FreePages--; 
            }
        }

        // ==========================================================
        // [FIX CHÍ MẠNG VŨ TRỤ] THIẾT LẬP VÙNG CẤM BAY BAREMETAL!
        // Cấm PMM đụng vào Page 0 (BIOS IVT) và Page 8 (0x8000 - SMP Trampoline)
        // Nếu không PMM sẽ lấy Trampoline ra cấp cho App và gây GPF!
        // ==========================================================
        if (!TestBit(0)) { SetBit(0); FreePages--; }
        if (!TestBit(8)) { SetBit(8); FreePages--; } 
        
        // Cẩn thận khóa luôn Page 9 (0x9000) nếu Trampoline của mày dài hơn 4KB
        if (!TestBit(9)) { SetBit(9); FreePages--; }

        LastUsedIndex = 0;
    }

    public static void* AllocatePage()
    {
        bool irq = PmmLock.AcquireSafe();

        // Giới hạn số lần thử để tránh vòng lặp vô hạn
        const int maxAttempts = 2;
        int attempt = 0;
        void* result = null;

        while (attempt < maxAttempts && result == null)
        {
            // Thử lần 1: từ LastUsedIndex đến cuối
            for (ulong i = LastUsedIndex; i < TotalPages; i++)
            {
                if (!TestBit(i)) 
                {
                    SetBit(i);   
                    FreePages--;
                    LastUsedIndex = i; // Cập nhật Next-Fit
                    result = (void*)(i * 4096);
                    break;
                }
            }

            // Nếu không tìm thấy, thử lần 2: từ đầu đến LastUsedIndex
            if (result == null)
            {
                for (ulong i = 0; i < LastUsedIndex; i++)
                {
                    if (!TestBit(i)) 
                    {
                        SetBit(i);   
                        FreePages--;
                        LastUsedIndex = i; 
                        result = (void*)(i * 4096);
                        break;
                    }
                }
            }

            attempt++;
        }

        if (result != null) {
            // Tẩy rửa RAM (MemSet) ở BÊN NGOÀI KHÓA!
            LibC.MemSet((byte*)result, 0, 4096);
        }

        PmmLock.ReleaseSafe(irq);
        
        return result; 
    }

    // ==========================================================
    // [FIX CHÍ MẠNG] CẤP PHÁT TRANG RAM DƯỚI 4GB CHO SMP TRAMPOLINE!
    // Protected Mode chỉ chứa được 32 bit trong CR3.
    // Nếu PML4 nằm trên 4GB, Trampoline sẽ load CR3 bị cắt cụt
    // → Bảng phâng trang SAI → RIP=0x100000000 → KERNEL PANIC!
    // ==========================================================
    public static void* AllocatePageBelow4GB()
    {
        bool irq = PmmLock.AcquireSafe();
        
        // Tính toán maxPage chính xác
        ulong maxPage = TotalPages;
        if (maxPage > 1048576) { // 4GB / 4096 = 1048576 pages
            maxPage = 1048576;
        }

        for (ulong i = 10; i < maxPage; i++) // Skip pages 0-9 (protected)
        {
            if (!TestBit(i)) 
            {
                SetBit(i);   
                FreePages--;
                void* ptr = (void*)(i * 4096);
                PmmLock.ReleaseSafe(irq); 
                LibC.MemSet((byte*)ptr, 0, 4096);
                return ptr; 
            }
        }

        PmmLock.ReleaseSafe(irq);
        return null; 
    }

    // ==========================================================
    // [BƠM VIAGRA] HÀM CẤP PHÁT RAM LIỀN KỀ BỌC THÉP TỪ 16MB!
    // Tuyệt đối không Fallback về 0 để tránh mìn Kernel.
    // Dùng cho cấp phát siêu to khổng lồ (Ví dụ: Framebuffer 3MB)
    // ==========================================================
    public static void* AllocateContiguousPages(ulong count)
    {
        if (count == 0) return null;
        
        // Giới hạn số trang liên tiếp tối đa
        if (count > 1024 * 1024) { // 4GB
            return null;
        }

        bool irq = PmmLock.AcquireSafe();
        void* result = null;

        // [VÒNG QUÉT CHÍNH] Tìm kiếm tiến lên đỉnh RAM
        ulong consecutiveFree = 0;
        ulong startPage = 0;
        ulong searchStart = (LastUsedIndex > 4096) ? LastUsedIndex : 4096;

        for (ulong i = searchStart; i < TotalPages; i++)
        {
            if (!TestBit(i)) // Page này rảnh!
            {
                if (consecutiveFree == 0) startPage = i;
                
                // Kiểm tra tràn khi cộng
                if (consecutiveFree < ULongMax - count) {
                    consecutiveFree++;
                } else {
                    consecutiveFree = 0; // Reset bộ đếm để tránh tràn
                    continue;
                }

                if (consecutiveFree == count)
                {
                    // TÌM THẤY RỒI! Đủ dung lượng liền kề!
                    for (ulong j = 0; j < count; j++) { 
                        if (startPage + j < TotalPages) {
                            SetBit(startPage + j); 
                            FreePages--; 
                        }
                    }
                    LastUsedIndex = startPage + count; 
                    result = (void*)(startPage * 4096);
                    break;
                }
            }
            else consecutiveFree = 0; // Đứt đoạn! Reset bộ đếm!
        }

        // ==========================================================
        // [VÒNG QUÉT XE LU LẦN 2] QUÉT TỪ MỐC 16MB ĐẾN LAST_USED_INDEX!
        // Đéo bao giờ quét ngược về mốc 0! 16MB đầu tiên là Vùng Đất Cấm!
        // ==========================================================
        if (result == null)
        {
            consecutiveFree = 0;
            for (ulong i = 4096; i < searchStart; i++) 
            {
                if (!TestBit(i))
                {
                    if (consecutiveFree == 0) startPage = i;
                    
                    // Kiểm tra tràn khi cộng
                    if (consecutiveFree < ULongMax - count) {
                        consecutiveFree++;
                    } else {
                        consecutiveFree = 0; // Reset bộ đếm để tránh tràn
                        continue;
                    }

                    if (consecutiveFree == count)
                    {
                        for (ulong j = 0; j < count; j++) { 
                            if (startPage + j < TotalPages) {
                                SetBit(startPage + j); 
                                FreePages--; 
                            }
                        }
                        LastUsedIndex = startPage + count; 
                        result = (void*)(startPage * 4096);
                        break;
                    }
                }
                else consecutiveFree = 0;
            }
        }

        PmmLock.ReleaseSafe(irq);

        if (result != null) {
            // Tẩy rửa RAM bằng (uint)count để tránh tràn!
            if (count <= UIntMax) {
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

        bool irq = PmmLock.AcquireSafe();

        ulong addr = (ulong)ptr;
        
        // Kiểm tra xem địa chỉ có hợp lệ không
        if (addr % 4096 != 0) {
            // Địa chỉ không phải là boundary của trang
            PmmLock.ReleaseSafe(irq);
            return;
        }
        
        ulong index = addr / 4096; 

        // ==========================================================
        // [LÁ CHẮN BẤT TỬ] CẤM TUYỆT ĐỐI FREE PAGE 0 ĐẾN 9!
        // Nếu thằng lồn nào truyền NULL vào, index sẽ là 0. Bỏ qua cmnl!
        // Đéo bao giờ được cấp phát lại vùng BIOS và Trampoline!
        // ==========================================================
        // Mở rộng danh sách các trang bị cấm
        const ulong minProtectedPage = 0;
        const ulong maxProtectedPage = 9;
        
        if (index >= minProtectedPage && index <= maxProtectedPage)
        {
            PmmLock.ReleaseSafe(irq);
            return;
        }

        if (index < TotalPages)
        {
            if (!TestBit(index))
            {
                // Double free or freeing unallocated page
                Terminal.SetColor(0x00FF0000);
                fixed (char* msg = "[!] PMM WARNING: Attempt to free unallocated page!\n\0") Terminal.Print(msg);
                PmmLock.ReleaseSafe(irq);
                return;
            }

            // Mark page free
            ClearBit(index);
            FreePages++;

            // Sanity clamp
            if (FreePages > TotalPages) FreePages = TotalPages;

            // Cập nhật LastUsedIndex nếu cần thiết
            // Chỉ cập nhật nếu trang được free nằm trước LastUsedIndex
            if (index < LastUsedIndex) {
                LastUsedIndex = index;
            }
        }

        PmmLock.ReleaseSafe(irq);
    }
}