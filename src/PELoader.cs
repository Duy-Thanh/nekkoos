using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

public static unsafe class PELoader
{
    public static void LoadAndRun(byte* rawFile, bool runInBackground = false, bool isJailed = false, bool forceRoot = false, char* processName = null, byte priority = 1)
    {
        if (rawFile == null || rawFile[0] != 'M' || rawFile[1] != 'Z') return;
        int e_lfanew = *(int*)(rawFile + 0x3C);
        byte* ntHeader = rawFile + e_lfanew;
        if (ntHeader[0] != 'P' || ntHeader[1] != 'E') return;

        uint sizeOfImage = *(uint*)(ntHeader + 80);
        uint sizeOfHeaders = *(uint*)(ntHeader + 84);

        // Kiểm tra xem sizeOfImage có hợp lệ không
        if (sizeOfImage == 0 || sizeOfImage > 0x100000000) { // Giới hạn 4GB
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PE image size!\n\0") Terminal.Print(err);
            Heap.Free(rawFile);
            return;
        }
        
        // Kiểm tra xem sizeOfHeaders có hợp lệ không
        if (sizeOfHeaders == 0 || sizeOfHeaders > sizeOfImage) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PE headers size!\n\0") Terminal.Print(err);
            Heap.Free(rawFile);
            return;
        }

        ulong appVirtualBase = 0x0000400000000000; 
        ulong* originalPml4 = VMM.PML4; 
        
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
        LibC.MemSet(appBasePhys, 0, (uint)(pages * 4096));
        LibC.MemCpy(appBasePhys, rawFile, sizeOfHeaders);

        ushort numSections = *(ushort*)(ntHeader + 6);
        ushort optHeaderSize = *(ushort*)(ntHeader + 20);
        byte* sectionTable = ntHeader + 24 + optHeaderSize;

        // Kiểm tra xem numSections có hợp lệ không
        if (numSections > 96) { // Giới hạn số section (PE tối đa 96 section)
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Too many PE sections!\n\0") Terminal.Print(err);
            // Cleanup resources
            for (ulong i = 0; i < pages; i++) {
                PMM.FreePage((void*)(physBase + (i * 4096)));
            }
            PMM.FreePage(appPml4); 
            Heap.Free(rawFile);
            return;
        }
        
        // Kiểm tra xem optHeaderSize có hợp lệ không
        if (optHeaderSize == 0 || optHeaderSize > 1024) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PE optional header size!\n\0") Terminal.Print(err);
            // Cleanup resources
            for (ulong i = 0; i < pages; i++) {
                PMM.FreePage((void*)(physBase + (i * 4096)));
            }
            PMM.FreePage(appPml4); 
            Heap.Free(rawFile);
            return;
        }
        
        // Kiểm tra xem sectionTable có hợp lệ không
        if (sectionTable == null || (ulong)sectionTable > (ulong)rawFile + sizeOfHeaders) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PE section table!\n\0") Terminal.Print(err);
            // Cleanup resources
            for (ulong i = 0; i < pages; i++) {
                PMM.FreePage((void*)(physBase + (i * 4096)));
            }
            PMM.FreePage(appPml4); 
            Heap.Free(rawFile);
            return;
        }

        for (int i = 0; i < numSections; i++)
        {
            byte* sec = sectionTable + (i * 40);
            uint vSize = *(uint*)(sec + 8);   
            uint vAddr = *(uint*)(sec + 12);  
            uint rawSize = *(uint*)(sec + 16); 
            uint rawPtr = *(uint*)(sec + 20); 

            uint copySize = rawSize > vSize ? vSize : rawSize;
            if (copySize > 0) {
                // Kiểm tra xem bộ nhớ đích có đủ không
                if (vAddr + copySize > sizeOfImage) {
                    Terminal.SetColor(0x00FF0000);
                    fixed(char* err = "[!] FATAL: PE section exceeds image bounds!\n\0") Terminal.Print(err);
                    // Cleanup resources
                    for (ulong k = 0; k < pages; k++) {
                        PMM.FreePage((void*)(physBase + (k * 4096)));
                    }
                    PMM.FreePage(appPml4); 
                    Heap.Free(rawFile);
                    return;
                }
                
                LibC.MemCpy(appBasePhys + vAddr, rawFile + rawPtr, copySize);
            }
        }
        
        ulong originalImageBase = *(ulong*)(ntHeader + 48);
        long delta = (long)appVirtualBase - (long)originalImageBase;

        if (delta != 0)
        {
            uint relocRVA = *(uint*)(ntHeader + 176);
            uint relocSize = *(uint*)(ntHeader + 180);

            // Kiểm tra xem relocRVA và relocSize có hợp lệ không
            if (relocRVA > sizeOfImage || relocSize > sizeOfImage || relocRVA + relocSize > sizeOfImage) {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL: Invalid PE relocation data!\n\0") Terminal.Print(err);
                // Cleanup resources
                for (ulong i = 0; i < pages; i++) {
                    PMM.FreePage((void*)(physBase + (i * 4096)));
                }
                PMM.FreePage(appPml4); 
                Heap.Free(rawFile);
                return;
            }

            if (relocRVA != 0)
            {
                byte* relocDir = appBasePhys + relocRVA;

                // Kiểm tra xem relocDir có hợp lệ không
                if (relocDir == null || (ulong)relocDir > (ulong)appBasePhys + sizeOfImage) {
                    Terminal.SetColor(0x00FF0000);
                    fixed(char* err = "[!] FATAL: Invalid PE relocation directory!\n\0") Terminal.Print(err);
                    // Cleanup resources
                    for (ulong i = 0; i < pages; i++) {
                        PMM.FreePage((void*)(physBase + (i * 4096)));
                    }
                    PMM.FreePage(appPml4); 
                    Heap.Free(rawFile);
                    return;
                }

                uint bytesParsed = 0;

                while (bytesParsed < relocSize)
                {
                    uint pageRva = *(uint*)(relocDir + bytesParsed);
                    uint blockSize = *(uint*)(relocDir + bytesParsed + 4);

                    // Kiểm tra xem blockSize có hợp lệ không
                    if (blockSize == 0 || blockSize > relocSize - bytesParsed) {
                        Terminal.SetColor(0x00FF0000);
                        fixed(char* err = "[!] FATAL: Invalid PE relocation block size!\n\0") Terminal.Print(err);
                        // Cleanup resources
                        for (ulong i = 0; i < pages; i++) {
                            PMM.FreePage((void*)(physBase + (i * 4096)));
                        }
                        PMM.FreePage(appPml4); 
                        Heap.Free(rawFile);
                        return;
                    }

                    if (blockSize == 0) break;

                    uint relocCount = (blockSize - 8) / 2;
                    ushort* entries = (ushort*)(relocDir + bytesParsed + 8);

                    // Kiểm tra xem entries có hợp lệ không và không tràn bộ nhớ
                    if (entries == null || (ulong)entries > (ulong)appBasePhys + sizeOfImage) {
                        Terminal.SetColor(0x00FF0000);
                        fixed(char* err = "[!] FATAL: Invalid PE relocation entries!\n\0") Terminal.Print(err);
                        for (ulong i = 0; i < pages; i++) PMM.FreePage((void*)(physBase + (i * 4096)));
                        PMM.FreePage(appPml4); Heap.Free(rawFile); return;
                    }

                    // Ensure entries array is large enough for relocCount entries
                    if ((ulong)entries + (ulong)relocCount * 2 > (ulong)appBasePhys + sizeOfImage) {
                        Terminal.SetColor(0x00FF0000);
                        fixed(char* err = "[!] FATAL: PE relocation entries overflow!\n\0") Terminal.Print(err);
                        for (ulong i = 0; i < pages; i++) PMM.FreePage((void*)(physBase + (i * 4096)));
                        PMM.FreePage(appPml4); Heap.Free(rawFile); return;
                    }

                    for (uint i = 0; i < relocCount; i++)
                    {
                        ushort entry = entries[i];
                        int type = entry >> 12;
                        int offset = entry & 0xFFF;

                        if (type == 10)
                        {
                            // Kiểm tra bounds cho pageRva + offset trước khi truy cập target
                            if ((ulong)pageRva + (ulong)offset + sizeof(ulong) > sizeOfImage) {
                                Terminal.SetColor(0x00FF0000);
                                fixed(char* err = "[!] FATAL: PE relocation target out of bounds!\n\0") Terminal.Print(err);
                                for (ulong l = 0; l < pages; l++) PMM.FreePage((void*)(physBase + (l * 4096)));
                                PMM.FreePage(appPml4); Heap.Free(rawFile); return;
                            }

                            ulong* targetPtr = (ulong*)(appBasePhys + pageRva + offset);
                            *targetPtr = (ulong)((long)*targetPtr + delta);
                        }
                    }
                    bytesParsed += blockSize;
                }
            }
        }
        
        // HERE WE GO!!! vDSO mapping here!
        ulong kaslrBase = (ulong)PRNG.Next(0x5000, 0x7FFF); 
        ulong vdsoVirt = (kaslrBase << 32); 

        ulong localVdsoPhys = (ulong)PMM.AllocatePage();
        LibC.MemCpy((byte*)localVdsoPhys, (byte*)vDSO.PhysPage, 4096);

        VMM.MapPage(localVdsoPhys, vdsoVirt, 0x07, appPml4);

        // ==========================================================
        // [FIX CHÍ MẠNG VŨ TRỤ] QUÉT BYTE-BY-BYTE BRUTEFORCE!
        // Chấp mọi thể loại Padding và Căn lề của Trình biên dịch C#!
        // ==========================================================
        ulong sizeToScan = pages * 4096; 
        bool injected = false;
        
        for(ulong i = 0; i <= sizeToScan - 8; i++) 
        {
            // Trích xuất con số 64-bit từ offset i (Bất chấp lệch lề)
            ulong maybeMagic = *(ulong*)(appBasePhys + i); 
            
            if (maybeMagic == 0x1337BEEFCAFE8BAD) {
                // Đóng đinh con trỏ KASLR vào đúng vị trí đó!
                *(ulong*)(appBasePhys + i) = vdsoVirt; 
                injected = true;
                break;
            }
        }

        if (!injected) {
            Terminal.SetColor(0x00FF00FF);
            fixed(char* warn = "   [?] Warning: Legacy App detected (No KASLR Magic Signature).\n\0") Terminal.Print(warn);
            Terminal.SetColor(0x00FFFFFF);
        }

        for (ulong i = 0; i < pages; i++)
        {
            VMM.MapPage(physBase + (i * 4096), appVirtualBase + (i * 4096), 0x07, appPml4);
        }

        uint addressOfEntryPoint = 0;
        uint exportRVA = *(uint*)(ntHeader + 136); 

        // Kiểm tra xem exportRVA có hợp lệ không
        if (exportRVA > sizeOfImage) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PE export directory RVA!\n\0") Terminal.Print(err);
            // Cleanup resources
            for (ulong i = 0; i < pages; i++) {
                PMM.FreePage((void*)(physBase + (i * 4096)));
            }
            PMM.FreePage(appPml4); 
            Heap.Free(rawFile);
            return;
        }
        
        if (exportRVA != 0)
        {
            byte* exportDir = appBasePhys + exportRVA;
            // Kiểm tra xem exportDir có hợp lệ không
            if (exportDir == null || (ulong)exportDir > (ulong)appBasePhys + sizeOfImage) {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL: Invalid PE export directory!\n\0") Terminal.Print(err);
                // Cleanup resources
                for (ulong i = 0; i < pages; i++) {
                    PMM.FreePage((void*)(physBase + (i * 4096)));
                }
                PMM.FreePage(appPml4); 
                Heap.Free(rawFile);
                return;
            }
            uint numberOfNames = *(uint*)(exportDir + 24);

            uint addrOfFuncsRva = *(uint*)(exportDir + 28);
            uint addrOfNamesRva = *(uint*)(exportDir + 32);
            uint addrOfNameOrdinalsRva = *(uint*)(exportDir + 36);

            // Validate RVAs and sizes before turning them into pointers
            if (addrOfFuncsRva > sizeOfImage || addrOfNamesRva > sizeOfImage || addrOfNameOrdinalsRva > sizeOfImage) {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL: Invalid PE export directory RVA offsets!\n\0") Terminal.Print(err);
                for (ulong i = 0; i < pages; i++) PMM.FreePage((void*)(physBase + (i * 4096)));
                PMM.FreePage(appPml4); Heap.Free(rawFile);
                return;
            }

            // Limit numberOfNames to avoid pathological cases and overflows
            if (numberOfNames == 0 || numberOfNames > 10000) {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL: Invalid or too many PE export names!\n\0") Terminal.Print(err);
                for (ulong i = 0; i < pages; i++) PMM.FreePage((void*)(physBase + (i * 4096)));
                PMM.FreePage(appPml4); Heap.Free(rawFile);
                return;
            }

            // Ensure the arrays for functions/names/ordinals fit within the image
            if ((ulong)addrOfFuncsRva + (ulong)numberOfNames * 4 > sizeOfImage || (ulong)addrOfNamesRva + (ulong)numberOfNames * 4 > sizeOfImage || (ulong)addrOfNameOrdinalsRva + (ulong)numberOfNames * 2 > sizeOfImage) {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL: PE export directory arrays out of bounds!\n\0") Terminal.Print(err);
                for (ulong i = 0; i < pages; i++) PMM.FreePage((void*)(physBase + (i * 4096)));
                PMM.FreePage(appPml4); Heap.Free(rawFile);
                return;
            }

            uint* addressOfFunctions = (uint*)(appBasePhys + addrOfFuncsRva);
            uint* addressOfNames = (uint*)(appBasePhys + addrOfNamesRva);
            ushort* addressOfNameOrdinals = (ushort*)(appBasePhys + addrOfNameOrdinalsRva);

            for (uint i = 0; i < numberOfNames; i++)
            {
                uint nameRva = addressOfNames[i];

                // Kiểm tra xem nameRva có hợp lệ và đủ dài để truy xuất 8 byte
                if (nameRva >= sizeOfImage || (ulong)nameRva + 8 > sizeOfImage) {
                    Terminal.SetColor(0x00FF0000);
                    fixed(char* err = "[!] FATAL: Invalid PE export name pointer!\n\0") Terminal.Print(err);
                    for (ulong j = 0; j < pages; j++) PMM.FreePage((void*)(physBase + (j * 4096)));
                    PMM.FreePage(appPml4); Heap.Free(rawFile); return;
                }

                byte* name = appBasePhys + nameRva;

                if (name[0] == 'A' && name[1] == 'p' && name[2] == 'p' && name[3] == 'M' &&
                    name[4] == 'a' && name[5] == 'i' && name[6] == 'n' && name[7] == '\0')
                {
                    addressOfEntryPoint = addressOfFunctions[addressOfNameOrdinals[i]];
                    break;
                }
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
        
        Scheduler.CreateUserTask(appMain, (ulong)appPml4, !runInBackground, isJailed, forceRoot, processName, (uint)pages, priority);

        fixed (char* msg = "[+] Process Started!\n\0") Terminal.Print(msg);

        Heap.Free(rawFile);
    }
}