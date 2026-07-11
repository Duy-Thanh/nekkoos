using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// ==========================================================
// MODULE: QUẢN LÝ BỘ NHỚ ẢO (VMM - PAGING X86_64 STRICT)
// DATE: TƯƠNG LAI CỦA NEKKO OS - KỶ LUẬT THÉP BẤT HOẠI
// ==========================================================
public static unsafe class VMM
{
    // ==========================================================
    // [INTEROP] Assembly bridge function declarations
    // ==========================================================
    [DllImport("*", EntryPoint = "LoadPML4")]
    public static extern void LoadPML4_ASM(void* pml4Address);

    [DllImport("*", EntryPoint = "FlushTLB")]
    public static extern void FlushTLB(void* virtualAddress);

    [DllImport("*", EntryPoint = "ReadCR3")] 
    public static extern ulong ReadCR3();

    [DllImport("*", EntryPoint = "EnableNXHardware")]
    public static extern void EnableNXHardware();

    // ==========================================================
    // MẶT NẠ LỌC ĐỊA CHỈ VẬT LÝ CHUẨN X86_64!
    // Lọc sạch Bit 63 (NX) và các bit cờ láo toét, chỉ chừa lại Bit 12 -> 51!
    // ==========================================================
    private const ulong PHYS_ADDR_MASK = 0x000FFFFFFFFFF000UL;

    public static ulong* PML4;

    // [THIẾT QUÂN LUẬT 1] BỔ SUNG Ổ KHÓA VMM!
    public static Spinlock VmmLock = new Spinlock();

    public static bool IsCanonical(ulong addr)
    {
        // Kiểm tra 16 bit cao nhất
        ulong top16 = addr >> 48;
        if (top16 != 0x0000 && top16 != 0xFFFF) {
            return false;
        }

        return true;
    }

    private static ulong* AllocateTable()
    {
        ulong* table = (ulong*)PMM.AllocatePage();
        if (table == null)
        {
            // Thay vì in lỗi và treo, hãy trả về null để caller xử lý
            return null;
        }
        
        // Tẩy sạch bảng trang
        for (int i = 0; i < 512; i++) {
            table[i] = 0;
        }
        
        return table;
    }

    public static void MapHugePage(ulong physAddr, ulong virtAddr)
    {
        bool irq = VmmLock.AcquireSafe(); 

        // Kiểm tra địa chỉ ảo có hợp lệ không
        if (!IsCanonical(virtAddr)) { 
            VmmLock.ReleaseSafe(irq); 
            return; 
        }
        
        // Kiểm tra địa chỉ vật lý có hợp lệ không
        if (physAddr > PMM.TotalPages * 4096UL) {
            VmmLock.ReleaseSafe(irq); 
            return; 
        }
        
        // Lọc sạch địa chỉ vật lý
        physAddr &= PHYS_ADDR_MASK;
        physAddr &= ~0x1FFFFFUL; // Đảm bảo là 2MB page boundary

        ulong pml4Index = (virtAddr >> 39) & 0x1FF;
        ulong pdptIndex = (virtAddr >> 30) & 0x1FF;
        ulong pdIndex   = (virtAddr >> 21) & 0x1FF;

        if ((PML4[pml4Index] & 0x01) == 0)
        {
            ulong* newPDPT = AllocateTable();
            if (newPDPT == null) {
                VmmLock.ReleaseSafe(irq);
                return;
            }
            PML4[pml4Index] = (ulong)newPDPT | 0x07;
        }
        ulong* pdpt = (ulong*)(PML4[pml4Index] & PHYS_ADDR_MASK);
        if (pdpt == null || (ulong)pdpt >= PMM.TotalPages * 4096UL) {
            VmmLock.ReleaseSafe(irq); 
            return; 
        }

        if ((pdpt[pdptIndex] & 0x01) == 0)
        {
            ulong* newPD = AllocateTable();
            if (newPD == null) {
                VmmLock.ReleaseSafe(irq); 
                return; 
            }
            pdpt[pdptIndex] = (ulong)newPD | 0x07;
        }
        ulong* pd = (ulong*)(pdpt[pdptIndex] & PHYS_ADDR_MASK);
        if (pd == null || (ulong)pd >= PMM.TotalPages * 4096UL) {
            VmmLock.ReleaseSafe(irq); 
            return; 
        }

        pd[pdIndex] = physAddr | 0x87;

        // [FIX CVE-2026-006] FLUSH TLB sau khi modify PTE!
        // TLB cache có thể giữ old permissions, phải flush ngay
        FlushTLB((void*)virtAddr);

        VmmLock.ReleaseSafe(irq); 
    }

    public static void MapPage(ulong physAddr, ulong virtAddr, ulong flags)
    {
        ulong* currentPml4 = (ulong*)(ReadCR3() & PHYS_ADDR_MASK);
        MapPage(physAddr, virtAddr, flags, currentPml4); 
    }

    public static void MapPage(ulong physAddr, ulong virtAddr, ulong flags, ulong* pml4Dir)
    {
        bool irq = VmmLock.AcquireSafe(); 
        
        // Kiểm tra địa chỉ ảo có hợp lệ không
        if (!IsCanonical(virtAddr)) { 
            VmmLock.ReleaseSafe(irq); 
            return; 
        }
        
        // Kiểm tra địa chỉ vật lý có hợp lệ không
        if (physAddr > PMM.TotalPages * 4096UL) {
            VmmLock.ReleaseSafe(irq); 
            return; 
        }
        
        // Lọc sạch địa chỉ vật lý
        physAddr &= PHYS_ADDR_MASK;
        // Validate pml4Dir pointer
        if (pml4Dir == null || (ulong)pml4Dir >= PMM.TotalPages * 4096UL) { VmmLock.ReleaseSafe(irq); return; }

        ulong pml4Index = (virtAddr >> 39) & 0x1FF;
        ulong pdpIndex  = (virtAddr >> 30) & 0x1FF;
        ulong pdIndex   = (virtAddr >> 21) & 0x1FF;
        ulong ptIndex   = (virtAddr >> 12) & 0x1FF;

        if ((pml4Dir[pml4Index] & 1) == 0) 
        {
            ulong newPdpt = (ulong)PMM.AllocatePage();
            if (newPdpt == 0) {
                VmmLock.ReleaseSafe(irq); 
                return; 
            }
            ulong* pdptPtr = (ulong*)newPdpt;
            for (int i = 0; i < 512; i++) pdptPtr[i] = 0;
            pml4Dir[pml4Index] = newPdpt | flags | 0x07; 
        }
        ulong* pdpt = (ulong*)(pml4Dir[pml4Index] & PHYS_ADDR_MASK);
        if (pdpt == null || (ulong)pdpt >= PMM.TotalPages * 4096UL) {
            VmmLock.ReleaseSafe(irq); 
            return; 
        }

        if ((pdpt[pdpIndex] & 1) == 0)
        {
            ulong newPd = (ulong)PMM.AllocatePage();
            if (newPd == 0) {
                VmmLock.ReleaseSafe(irq); 
                return; 
            }
            ulong* pdPtr = (ulong*)newPd;
            for (int i = 0; i < 512; i++) pdPtr[i] = 0;
            pdpt[pdpIndex] = newPd | flags | 0x07;
        }
        ulong* pd = (ulong*)(pdpt[pdpIndex] & PHYS_ADDR_MASK);
        if (pd == null || (ulong)pd >= PMM.TotalPages * 4096UL) {
            VmmLock.ReleaseSafe(irq); 
            return; 
        }

        if ((pd[pdIndex] & 1) == 0)
        {
            ulong newPt = (ulong)PMM.AllocatePage();
            if (newPt == 0) {
                VmmLock.ReleaseSafe(irq); 
                return; 
            }
            ulong* ptPtr = (ulong*)newPt;
            for (int i = 0; i < 512; i++) ptPtr[i] = 0;
            pd[pdIndex] = newPt | flags | 0x07;
        }
        ulong* pt = (ulong*)(pd[pdIndex] & PHYS_ADDR_MASK);
        if (pt == null || (ulong)pt >= PMM.TotalPages * 4096UL) {
            VmmLock.ReleaseSafe(irq); 
            return; 
        }

        pt[ptIndex] = physAddr | flags | 1;

        if (pml4Dir == (ulong*)(ReadCR3() & PHYS_ADDR_MASK)) {
            FlushTLB((void *)virtAddr); 
        }

        VmmLock.ReleaseSafe(irq); 
    }

    public static void Init()
    {
        fixed (char* msg = "[*] Building Paging 4-Level (Strict Military Grade)...\n\0") Terminal.Print(msg);

        EnableNXHardware();
        fixed (char* nxMsg = "[+] Hardware NX-Bit (No-Execute) Engaged!\n\0") Terminal.Print(nxMsg);

        // ==========================================================
        // [MEMORY CONFIGURATION] PML4 directory must reside below 4GB
        // SMP AP startup trampoline runs in 32-bit Protected Mode and can only load a 32-bit CR3.
        // If PML4 is placed above 4GB, the high 32 bits of CR3 are lost, leading to AP boot failures.
        // ==========================================================
        PML4 = (ulong*)PMM.AllocatePageBelow4GB();
        if (PML4 == null) {
            fixed (char* err = "[!] VMM FATAL: Cannot allocate PML4 below 4GB!\n\0") Terminal.Print(err);
            while(true) IO.Hlt(); 
        }

        // Kiểm tra căn chỉnh của PML4
        if (((ulong)PML4 & 0xFFF) != 0) {
            fixed (char* err = "[!] VMM FATAL: PML4 is not page aligned!\n\0") Terminal.Print(err);
            while(true) IO.Hlt(); 
        }
        
        // Tẩy sạch PML4
        for (int i = 0; i < 512; i++) {
            PML4[i] = 0;
        }

        ulong maxPhysicalRAM = PMM.TotalPages * 4096UL;

        // Kiểm tra xem maxPhysicalRAM có hợp lệ không
        if (maxPhysicalRAM == 0) {
            fixed (char* err = "[!] VMM FATAL: Invalid maxPhysicalRAM!\n\0") Terminal.Print(err);
            while(true) IO.Hlt(); 
        }
        
        // Ánh xánh bộ nhớ kernel
        for (ulong addr = 4096; addr < 2097152UL; addr += 4096)
        {
            MapPage(addr, addr, 0x03, PML4); 
        }

        // Ánh xạ huge pages cho phần còn lại
        for (ulong addr = 2097152UL; addr < maxPhysicalRAM; addr += 2097152UL)
        {
            MapHugePage(addr, addr); 
        }

        // ĐỔI THÀNH GỌI LOADPML4_ASM!
        LoadPML4_ASM(PML4);
        fixed (char* msgDone = "[+] VMM done! Exact memory space mapped & sealed bulletproof!\n\0") Terminal.Print(msgDone);
    }

    public static void DestroyUserSpace(ulong pml4_phys)
    {
        // Kiểm tra các tham số đầu vào
        if (pml4_phys == 0 || pml4_phys == (ulong)PML4) return;

        ulong* pml4 = (ulong*)pml4_phys;
        if (pml4 == null) return;

        // Thêm spinlock để tránh race condition
        bool irq = VmmLock.AcquireSafe();

        for (int i4 = 0; i4 < 256; i4++)
        {
            ulong entry4 = pml4[i4];
            
            if (entry4 == PML4[i4]) continue;

            if ((entry4 & 1) != 0 && (entry4 & 4) != 0) 
            {
                ulong* pdpt = (ulong*)(entry4 & PHYS_ADDR_MASK);
                if (pdpt == null || (ulong)pdpt >= PMM.TotalPages * 4096UL) continue;
                
                for (int i3 = 0; i3 < 512; i3++)
                {
                    ulong entry3 = pdpt[i3];
                    if ((entry3 & 1) != 0 && (entry3 & 4) != 0)
                    {
                        ulong* pd = (ulong*)(entry3 & PHYS_ADDR_MASK);
                        if (pd == null || (ulong)pd >= PMM.TotalPages * 4096UL) continue;
                        
                        for (int i2 = 0; i2 < 512; i2++)
                        {
                            ulong entry2 = pd[i2];
                                if ((entry2 & 1) != 0 && (entry2 & 4) != 0 && (entry2 & 0x80) == 0)
                                {
                                ulong* pt = (ulong*)(entry2 & PHYS_ADDR_MASK);
                                if (pt == null || (ulong)pt >= PMM.TotalPages * 4096UL) continue;
                                
                                for (int i1 = 0; i1 < 512; i1++)
                                {
                                    ulong entry1 = pt[i1];
                                    if ((entry1 & 1) != 0 && (entry1 & 4) != 0)
                                    {
                                        ulong physPage = entry1 & ~0xFFFUL; 
                                        
                                        // Kiểm tra tính hợp lệ của physPage
                                        if (physPage == 0 || physPage >= PMM.TotalPages * 4096UL) continue;
                                        
                                        bool isShared = false;
                                        if (Syscall.GlobalSharedRAM_Phys != 0 && Syscall.GlobalSharedRAM_Phys < PMM.TotalPages * 4096UL) {
                                            // Giới hạn vòng lặp để tránh tràn
                                            for(ulong p = 0; p < 5 && p < PMM.TotalPages; p++) {
                                                ulong candidate = Syscall.GlobalSharedRAM_Phys + (p * 4096);
                                                if (candidate >= PMM.TotalPages * 4096UL) break;
                                                if (physPage == candidate) { isShared = true; break; }
                                            }
                                        }

                                        bool isTrapPage = false;
                                        if (Syscall.MpuTrapPage_Phys != 0 && physPage == Syscall.MpuTrapPage_Phys) {
                                            isTrapPage = true; 
                                        }

                                        if (!isShared && !isTrapPage) {
                                            PMM.FreePage((void*)physPage);
                                        }
                                    }
                                }
                                PMM.FreePage((void*)pt); 
                            }
                        }
                        PMM.FreePage((void*)pd); 
                    }
                }
                PMM.FreePage((void*)pdpt); 
            }
        }
        PMM.FreePage((void*)pml4); 
        
        VmmLock.ReleaseSafe(irq);
    }
}