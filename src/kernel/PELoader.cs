// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

public static unsafe class PELoader
{
    // [PASCAL PORT] PE parsing logic extracted to pe_loader.pas
    [DllImport("*", EntryPoint = "PELoader_ValidateHeaders_Pas")]
    private static extern byte ValidateHeaders_Pas(byte* rawFile, uint rawSize, out uint sizeOfImage, out uint sizeOfHeaders, out ushort numSections, out ushort optHeaderSize);

    [DllImport("*", EntryPoint = "PELoader_CopySections_Pas")]
    private static extern byte CopySections_Pas(byte* appBasePhys, byte* rawFile, uint sizeOfImage, ushort numSections, ushort optHeaderSize, byte* ntHeader);

    [DllImport("*", EntryPoint = "PELoader_ApplyRelocations_Pas")]
    private static extern byte ApplyRelocations_Pas(byte* appBasePhys, uint sizeOfImage, uint relocRVA, uint relocSize, long delta);

    [DllImport("*", EntryPoint = "PELoader_FindAppMainExport_Pas")]
    private static extern byte FindAppMainExport_Pas(byte* appBasePhys, uint sizeOfImage, uint exportRVA, uint exportSize, out uint addressOfEntryPoint);

    [DllImport("*", EntryPoint = "PELoader_FindKaslrMagic_Pas")]
    private static extern byte FindKaslrMagic_Pas(byte* appBasePhys, ulong sizeToScan, ulong vdsoVirt);

    public static void LoadAndRun(byte* rawFile, bool runInBackground = false, bool isJailed = false, bool forceRoot = false, char* processName = null, byte priority = 1)
    {
        int _unusedId;
        LoadAndRun(rawFile, out _unusedId, runInBackground, isJailed, forceRoot, processName, priority);
    }

    // [FIX CRITICAL #1] Overload trả về thread ID của tiến trình vừa tạo qua tham số out,
    // để Kernel.cs có thể ghi nhận danh tính THẬT (không thể giả mạo) của các Daemon hệ
    // thống ngay tại thời điểm spawn ở boot sequence, thay vì dựa vào Thread.Name.
    public static void LoadAndRun(byte* rawFile, out int newThreadId, bool runInBackground = false, bool isJailed = false, bool forceRoot = false, char* processName = null, byte priority = 1)
    {
        newThreadId = -1;
        if (rawFile == null) return;

        uint sizeOfImage, sizeOfHeaders;
        ushort numSections, optHeaderSize;
        byte peValid = ValidateHeaders_Pas(rawFile, 0xFFFFFFFF, out sizeOfImage, out sizeOfHeaders, out numSections, out optHeaderSize);
        if (peValid == 0) return;

        if (sizeOfHeaders == 0 || sizeOfHeaders > sizeOfImage) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PE headers size!\n\0") Terminal.Print(err);
            Heap.Free(rawFile);
            return;
        }

        int e_lfanew = *(int*)(rawFile + 0x3C);
        byte* ntHeader = rawFile + e_lfanew;

        ulong appVirtualBase = 0x0000400000000000; 
        ulong* originalPml4 = Mem.KernelRoot; 
        
        ulong* appPml4 = (ulong*)PMM.AllocatePage(); 
        if (appPml4 == null) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] PELoader OOM: Cannot allocate PML4 Table!\n\0") Terminal.Print(err);
            Heap.Free(rawFile);
            return;
        }

        LibC.MemCpy((byte*)appPml4, (byte*)originalPml4, 4096);
        // ==========================================================
        // [FIX CHÍ MẠNG] CHỈ XOÁ CÁC ENTRY KHÔNG THUỘC KERNEL!
        // Entry 0 giữ nguyên (Kernel identity map).
        // Entries 1-255: Chỉ xoá nếu nó không phải của Kernel (tránh unmap kernel code).
        // Entries 256-511: Giữ nguyên (Kernel higher-half).
        // ==========================================================
        for (int i = 1; i < 256; i++) { 
            if (appPml4[i] == originalPml4[i] && (originalPml4[i] & 0x04) == 0) {
                // Entry này là của Kernel (User bit = 0), giữ nguyên!
            } else if (appPml4[i] != originalPml4[i]) {
                // Entry này đã bị sửa, xoá đi!
                appPml4[i] = originalPml4[i]; // Copy lại từ Kernel PML4
            }
            // Nếu entry là của Kernel và chưa bị sửa, giữ nguyên!
        }
        
        // ==========================================================
        // [FIX CHÍ MẠNG] ĐÉO MAP NULL PAGE NỮA!
        // MapPage(0x0, 0x0, 0x00) tạo ra mapping PRESENT tại virtual 0x0,
        // cho phép supervisor code đọc/ghi vào phần cứng IVT!
        // Để trang 0 UNMAPPED làm trap page tự nhiên cho NULL pointer.
        // ==========================================================

        ulong pages = (sizeOfImage + 4095) / 4096;

        // [BẢO VỆ KÉP] Chặn PE file quá lớn (> 512MB) - defense in depth!
        // Ngăn chặn cả overflow attack và malicious oversized PE.
        const ulong MAX_PE_PAGES = 131072; // 512MB = 131072 pages
        if (pages > MAX_PE_PAGES) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] PELoader BLOCKED: PE SizeOfImage exceeds 512MB security limit!\n\0") Terminal.Print(err);
            PMM.FreePage(appPml4);
            Heap.Free(rawFile);
            return;
        }

        ulong physBase = (ulong)PMM.AllocateContiguousPages(pages);
        
        if (physBase == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] PELoader OOM: Cannot allocate Physical Memory for App!\n\0") Terminal.Print(err);
            PMM.FreePage(appPml4); 
            Heap.Free(rawFile);    
            return;
        }

        byte* appBasePhys = (byte*)physBase;
        // Kiểm tra xem appBasePhys có null không
        if (appBasePhys == null) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: appBasePhys is null after allocation!\n\0") Terminal.Print(err);
            PMM.FreePage(appPml4);
            Heap.Free(rawFile);
            return;
        }

        // [FIX CHÍ MẠNG] Tẩy rửa RAM an toàn tránh integer overflow!
        // PMM.AllocateContiguousPages đã zero rồi, nhưng vẫn cần đảm bảo.
        // Nếu pages * 4096 > uint.MaxValue thì cast sẽ tràn về 0!
        const uint UIntMax = 0xFFFFFFFF;
        if (pages <= UIntMax / 4096) {
            LibC.MemSet(appBasePhys, 0, (uint)(pages * 4096));
        } else {
            // Trường hợp pages quá lớn - chunk memset
            ulong remaining = pages;
            byte* current = appBasePhys;
            while (remaining > 0) {
                uint chunkPages = remaining > (UIntMax / 4096) ? (UIntMax / 4096) : (uint)remaining;
                LibC.MemSet(current, 0, chunkPages * 4096);
                current += chunkPages * 4096;
                remaining -= chunkPages;
            }
        }
        LibC.MemCpy(appBasePhys, rawFile, sizeOfHeaders);

        byte* sectionTable = ntHeader + 24 + optHeaderSize;

        if (CopySections_Pas(appBasePhys, rawFile, sizeOfImage, numSections, optHeaderSize, ntHeader) != 0) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: PE section exceeds image bounds!\n\0") Terminal.Print(err);
            for (ulong i = 0; i < pages; i++) {
                PMM.FreePage((void*)(physBase + (i * 4096)));
            }
            PMM.FreePage(appPml4); 
            Heap.Free(rawFile);
            return;
        }

        ulong originalImageBase = *(ulong*)(ntHeader + 48);
        long delta = (long)appVirtualBase - (long)originalImageBase;

        if (delta != 0)
        {
            uint relocRVA = *(uint*)(ntHeader + 176);
            uint relocSize = *(uint*)(ntHeader + 180);

            if (relocRVA > sizeOfImage || relocSize > sizeOfImage || relocRVA + relocSize > sizeOfImage) {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL: Invalid PE relocation data!\n\0") Terminal.Print(err);
                for (ulong i = 0; i < pages; i++) {
                    PMM.FreePage((void*)(physBase + (i * 4096)));
                }
                PMM.FreePage(appPml4); 
                Heap.Free(rawFile);
                return;
            }

            ApplyRelocations_Pas(appBasePhys, sizeOfImage, relocRVA, relocSize, delta);
        }
        
        // HERE WE GO!!! vDSO mapping here!
        ulong kaslrBase = (ulong)PRNG.Next(0x5000, 0x7FFF); 
        ulong vdsoVirt = (kaslrBase << 32); 

        ulong localVdsoPhys = (ulong)PMM.AllocatePage();
        LibC.MemCpy((byte*)localVdsoPhys, (byte*)vDSO.PhysPage, 4096);

        Mem.MapPage(localVdsoPhys, vdsoVirt, 0x07, appPml4);

        // ==========================================================
        // [FIX CHÍ MẠNG VŨ TRỤ] QUÉT BYTE-BY-BYTE BRUTEFORCE!
        // Chấp mọi thể loại Padding và Căn lề của Trình biên dịch C#!
        // ==========================================================
        
        ulong sizeToScan = pages * 4096;
        bool injected = FindKaslrMagic_Pas(appBasePhys, sizeToScan, vdsoVirt) != 0;
        if (!injected) {
            Terminal.SetColor(0x00FF00FF);
            fixed(char* warn = "   [?] Warning: Legacy App detected (No KASLR Magic Signature).\n\0") Terminal.Print(warn);
            Terminal.SetColor(0x00FFFFFF);
        }

        for (ulong i = 0; i < pages; i++)
        {
            Mem.MapPage(physBase + (i * 4096), appVirtualBase + (i * 4096), 0x07, appPml4);
        }

        uint addressOfEntryPoint = 0;
        uint exportRVA = *(uint*)(ntHeader + 136);

        if (exportRVA > sizeOfImage) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PE export directory RVA!\n\0") Terminal.Print(err);
            for (ulong i = 0; i < pages; i++) {
                PMM.FreePage((void*)(physBase + (i * 4096)));
            }
            PMM.FreePage(appPml4); 
            Heap.Free(rawFile);
            return;
        }

        if (exportRVA != 0)
        {
            uint exportSize = *(uint*)(ntHeader + 140);
            if (FindAppMainExport_Pas(appBasePhys, sizeOfImage, exportRVA, exportSize, out addressOfEntryPoint) == 0)
            {
                Terminal.SetColor(0x00FF0000);
                for (ulong i = 0; i < pages; i++) PMM.FreePage((void*)(physBase + (i * 4096)));
                PMM.FreePage(appPml4); Heap.Free(rawFile);
                return;
            }
        }

        if (addressOfEntryPoint == 0)
        {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] PELoader: Entry point not found!\n\0") Terminal.Print(err);
            Terminal.SetColor(0x00FFFFFF);
            
            for (ulong i = 0; i < pages; i++) {
                PMM.FreePage((void*)(physBase + (i * 4096)));
            }
            PMM.FreePage(appPml4); 
            Heap.Free(rawFile);
            return;
        }

        ulong virtualEntryPoint = appVirtualBase + addressOfEntryPoint;
        // Kiểm tra xem virtualEntryPoint có hợp lệ không
        if (virtualEntryPoint < appVirtualBase || virtualEntryPoint >= appVirtualBase + sizeOfImage) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PE entry point address!\n\0") Terminal.Print(err);
            // Cleanup resources
            for (ulong i = 0; i < pages; i++) {
                PMM.FreePage((void*)(physBase + (i * 4096)));
            }
            PMM.FreePage(appPml4); 
            Heap.Free(rawFile);
            return;
        }

        delegate*<void> appMain = (delegate*<void>)virtualEntryPoint;

        // Kiểm tra xem appMain có hợp lệ không
        if (appMain == null) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PE entry point function pointer!\n\0") Terminal.Print(err);
            // Cleanup resources
            for (ulong i = 0; i < pages; i++) {
                PMM.FreePage((void*)(physBase + (i * 4096)));
            }
            PMM.FreePage(appPml4); 
            Heap.Free(rawFile);
            return;
        }

        // Kiểm tra xem Scheduler có được khởi tạo chưa
        if (Scheduler.Threads == null) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Scheduler not initialized!\n\0") Terminal.Print(err);
            // Cleanup resources
            for (ulong i = 0; i < pages; i++) {
                PMM.FreePage((void*)(physBase + (i * 4096)));
            }
            PMM.FreePage(appPml4); 
            Heap.Free(rawFile);
            return;
        }
        
        Scheduler.CreateUserTask(appMain, (ulong)appPml4, out newThreadId, !runInBackground, isJailed, forceRoot, processName, (uint)pages, priority);

        fixed (char* msg = "[+] Process Started!\n\0") Terminal.Print(msg);

        Heap.Free(rawFile);
    }
}