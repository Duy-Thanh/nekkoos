using System.Runtime.InteropServices;

namespace NekkoOS.Kernel.Driver;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct MBR_Partition { public byte Status; public fixed byte ChsFirst[3]; public byte Type; public fixed byte ChsLast[3]; public uint LbaStart; public uint SectorCount; }

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct FAT_BPB { public fixed byte JumpBoot[3]; public fixed byte OEMName[8]; public ushort BytesPerSector; public byte SectorsPerCluster; public ushort ReservedSectorCount; public byte NumFATs; public ushort RootEntryCount; public ushort TotalSectors16; public byte Media; public ushort FATSize16; public ushort SectorsPerTrack; public ushort NumberOfHeads; public uint HiddenSectors; public uint TotalSectors32; }

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct FAT_DirectoryEntry { public fixed byte Name[11]; public byte Attributes; public byte Reserved; public byte CreationTimeTenths; public ushort CreationTime; public ushort CreationDate; public ushort LastAccessDate; public ushort FirstClusterHigh; public ushort WriteTime; public ushort WriteDate; public ushort FirstClusterLow; public uint FileSize; }

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct KernelSharedMemBlock {
    public fixed byte ShellCommandBuffer[4096];    
    public fixed byte FatRequestName[4096];        
    public fixed byte FatResponseData[8192];      
    public fixed byte AtaRawBuffer[4096];        
}

public static unsafe class FAT16
{
    public static bool UseDaemon = false;
    public static uint DaemonId = 0;

    public static FAT_BPB CachedBPB;
    public static uint FatStartLba;
    public static uint RootDirLba;
    public static uint FirstDataSector;
    public static uint RootDirSectors;
    public static ushort CurrentDirCluster = 0; 
    public static bool IsInitialized = false;

    private static Spinlock VfsStateLock = new Spinlock();
    private static bool VfsIsBusy = false;

    private static KernelSharedMemBlock* GetSharedMem() {
        if (Syscall.GlobalSharedRAM_Phys == 0) {
            // Prevent concurrent allocations from multiple kernel threads
            bool irqAlloc = Scheduler.AcquireSchedLockSafe();
            if (Syscall.GlobalSharedRAM_Phys == 0) {
                Syscall.GlobalSharedRAM_Phys = (ulong)PMM.AllocateContiguousPages(5);
                if (Syscall.GlobalSharedRAM_Phys != 0) {
                    LibC.MemSet((byte*)Syscall.GlobalSharedRAM_Phys, 0, 5 * 4096);
                }
            }
            Scheduler.ReleaseSchedLockSafe(irqAlloc);
        }
        // Validate the physical address is within known physical memory bounds
        if (Syscall.GlobalSharedRAM_Phys == 0 || Syscall.GlobalSharedRAM_Phys >= PMM.TotalPages * 4096UL) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid GlobalSharedRAM_Phys in GetSharedMem!\n\0") Terminal.Print(err);
            return null;
        }

        return (KernelSharedMemBlock*)Syscall.GlobalSharedRAM_Phys;
    }

    private static void WakeDaemon() {
        if (DaemonId == 0) {
            bool irq2 = Scheduler.AcquireSchedLockSafe();
            for (int i = 1; i < Scheduler.ThreadCount; i++) {
                if (Scheduler.Threads[i].Name[0] == 'F' && Scheduler.Threads[i].Name[1] == 'A' && Scheduler.Threads[i].Name[2] == 'T') {
                    DaemonId = (uint)i; break;
                }
            }
            Scheduler.ReleaseSchedLockSafe(irq2);
        }

        if (DaemonId != 0 && DaemonId < Scheduler.ThreadCount) {
            bool irq = Scheduler.AcquireSchedLockSafe();
            Scheduler.Threads[DaemonId].Active = 1; 
            Scheduler.ReleaseSchedLockSafe(irq);
        }
    }

    public static void AcquireVfs()
    {
        while (true)
        {
            bool irq = VfsStateLock.AcquireSafe();
            if (!VfsIsBusy)
            {
                VfsIsBusy = true; 
                VfsStateLock.ReleaseSafe(irq);
                return;
            }
            VfsStateLock.ReleaseSafe(irq);
            Scheduler.Yield(); 
        }
    }

    public static void ReleaseVfs()
    {
        bool irq = VfsStateLock.AcquireSafe();
        VfsIsBusy = false; 
        VfsStateLock.ReleaseSafe(irq);
    }

    public static void Init()
    {
        byte* bpbBuf = (byte*)Heap.Alloc(512);
        if (bpbBuf == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate BPB buffer in FAT16 Init!\n\0") Terminal.Print(err);
            return;
        }

        ATA.ReadSector(0, bpbBuf);
        
        MBR_Partition* part1 = (MBR_Partition*)(bpbBuf + 446);
        if (part1->Type > 0 && part1->Type <= 0xFF && part1->LbaStart > 0)
        {
            FatStartLba = part1->LbaStart;
            ATA.ReadSector(FatStartLba, bpbBuf);
        }
        else FatStartLba = 0;

        FAT_BPB* bpbPtr = (FAT_BPB*)bpbBuf;
        CachedBPB = *bpbPtr;

        if (CachedBPB.BytesPerSector == 0) CachedBPB.BytesPerSector = 512;
        if (CachedBPB.SectorsPerCluster == 0) CachedBPB.SectorsPerCluster = 1;

        RootDirSectors = ((uint)CachedBPB.RootEntryCount * 32 + (uint)CachedBPB.BytesPerSector - 1) / CachedBPB.BytesPerSector;
        RootDirLba = FatStartLba + CachedBPB.ReservedSectorCount + (uint)(CachedBPB.NumFATs * CachedBPB.FATSize16);
        FirstDataSector = RootDirLba + RootDirSectors;

        IsInitialized = true;
        CurrentDirCluster = 0; 
        
        Heap.Free(bpbBuf);
        Terminal.SetColor(0x0000FF00);
        fixed (char* msg = "[+] VFS FAT16 Initialized Successfully!\n\0") Terminal.Print(msg);
    }

    private static int CheckSectorInline(byte* buf, byte* formattedName, ushort* outCluster, uint* outSize, byte* outAttr)
    {
        // Kiểm tra xem các con trỏ có null không
        if (buf == null || formattedName == null || outCluster == null || outSize == null || outAttr == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in CheckSectorInline!\n\0") Terminal.Print(err);
            return -1;
        }
        
        FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)buf;
        for (int i = 0; i < 16; i++)
        {
            if (entries[i].Name[0] == 0x00) return 2; 
            if (entries[i].Name[0] == 0xE5 || entries[i].Attributes == 0x0F || (entries[i].Attributes & 0x08) != 0) continue;

            bool match = true;
            for (int j = 0; j < 11; j++) {
                if (entries[i].Name[j] != formattedName[j]) { 
                    match = false; 
                    break; 
                }
            }
                
            if (match)
            {
                *outCluster = entries[i].FirstClusterLow;
                *outSize = entries[i].FileSize;
                *outAttr = entries[i].Attributes;
                return 1; 
            }
        }
        return 0; 
    }

    private static bool FindEntry(char* name, ushort* outCluster, uint* outSize, byte* outAttr)
    {
        // Kiểm tra xem các con trỏ có null không
        if (name == null || outCluster == null || outSize == null || outAttr == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in FindEntry!\n\0") Terminal.Print(err);
            return false;
        }

        byte* sectorBuf = (byte*)Heap.Alloc(512);
        byte* formattedName = (byte*)Heap.Alloc(11);

        if (sectorBuf == null || formattedName == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate memory in FindEntry!\n\0") Terminal.Print(err);
            if (sectorBuf != null) Heap.Free(sectorBuf);
            if (formattedName != null) Heap.Free(formattedName);
            return false;
        }
        
        if (name[0] == '.' && name[1] == '.' && name[2] == '\0')
        {
            formattedName[0] = (byte)'.'; formattedName[1] = (byte)'.';
            for(int k=2; k<11; k++) formattedName[k] = (byte)' ';
        }
        else LibC.FormatFATName(name, formattedName);

        bool found = false;

        if (CurrentDirCluster == 0) 
        {
            // Kiểm tra xem RootDirSectors có hợp lệ không
            if (RootDirSectors > 0x10000) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Invalid root directory sectors in FindEntry!\n\0") Terminal.Print(err);
                Heap.Free(sectorBuf);
                Heap.Free(formattedName);
                return false;
            }

            for (uint s = 0; s < RootDirSectors; s++)
            {
                ATA.ReadSector(RootDirLba + s, sectorBuf);
                int st = CheckSectorInline(sectorBuf, formattedName, outCluster, outSize, outAttr);
                if (st == 1) { found = true; break; }
                if (st == 2) break;
            }
        }
        else 
        {
            ushort cluster = CurrentDirCluster;
            byte* fatBuf = (byte*)Heap.Alloc(512);

            if (fatBuf == null) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Failed to allocate FAT buffer in FindEntry!\n\0") Terminal.Print(err);
                Heap.Free(sectorBuf);
                Heap.Free(formattedName);
                return false;
            }
            
            while (cluster >= 0x0002 && cluster <= 0xFFEF)
            {
                // Kiểm tra xem cluster có hợp lệ không
                if (cluster < 2 || cluster > 0xFFEF) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Invalid cluster number in FindEntry!\n\0") Terminal.Print(err);
                    Heap.Free(fatBuf);
                    Heap.Free(sectorBuf);
                    Heap.Free(formattedName);
                    return false;
                }
                
                uint clusterLba = FirstDataSector + ((uint)(cluster - 2) * (uint)CachedBPB.SectorsPerCluster);
                bool abort = false;
                
                // Kiểm tra xem clusterLba có hợp lệ không
                if (clusterLba > 0xFFFFFF) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Invalid cluster LBA in FindEntry!\n\0") Terminal.Print(err);
                    Heap.Free(fatBuf);
                    Heap.Free(sectorBuf);
                    Heap.Free(formattedName);
                    return false;
                }

                for (int s = 0; s < CachedBPB.SectorsPerCluster; s++)
                {
                    ATA.ReadSector(clusterLba + (uint)s, sectorBuf);
                    int st = CheckSectorInline(sectorBuf, formattedName, outCluster, outSize, outAttr);
                    if (st == 1) { found = true; break; }
                    if (st == 2) { abort = true; break; }
                }
                if (found || abort) break;

                uint fatOffset = (uint)cluster * 2;
                uint fatSector = FatStartLba + CachedBPB.ReservedSectorCount + (fatOffset / 512);

                // Kiểm tra xem clusterLba có hợp lệ không
                if (clusterLba > 0xFFFFFF) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Invalid cluster LBA in FindEntry!\n\0") Terminal.Print(err);
                    Heap.Free(fatBuf);
                    Heap.Free(sectorBuf);
                    Heap.Free(formattedName);
                    return false;
                }
                
                ATA.ReadSector(fatSector, fatBuf);
                cluster = *(ushort*)(fatBuf + (fatOffset % 512));
            }
            Heap.Free(fatBuf);
        }

        Heap.Free(sectorBuf);
        Heap.Free(formattedName);
        
        return found; 
    }

    public static byte* ReadFile(char* filename, uint* outSize)
    {
        // Kiểm tra xem filename có null không
        if (filename == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null filename in ReadFile!\n\0") Terminal.Print(err);
            return null;
        }

        AcquireVfs(); 
        int callerThread = Scheduler.CurrentThreadId;
        
        if (UseDaemon && callerThread != 0) {
            KernelSharedMemBlock* shared = GetSharedMem();
            if (shared == null) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Failed to get shared memory in ReadFile!\n\0") Terminal.Print(err);
                ReleaseVfs();
                return null;
            }

            char* sharedNameBuf = (char*)shared->FatRequestName;
            // Protect shared memory write with kernel-side lock
            bool sm_irq = Syscall.SharedMemLock.AcquireSafe();
            int nameIdx = 0;
            while (filename[nameIdx] != '\0' && nameIdx < 255) {
                sharedNameBuf[nameIdx] = filename[nameIdx];
                nameIdx++;
            }
            sharedNameBuf[nameIdx] = '\0';
            Syscall.SharedMemLock.ReleaseSafe(sm_irq);

            IPC.Send(30, (uint)callerThread, DaemonId, 0);
            WakeDaemon(); 

            // [ĐÃ DỌN DẸP] Thay Message Struct bằng Raw Variables
            uint rType = 0, rSender = 0; ulong rPayload = 0;
            uint daemonFileSize = 0; byte* daemonFileBuffer = null;
            byte* dataChunk = (byte*)shared->FatResponseData;
            // Validate FatResponseData lies within physical memory bounds
            ulong sharedBaseChk = (ulong)shared;
            ulong fatRespOffset = 4096 + 4096; // ShellCommand + FatRequest
            if (sharedBaseChk == 0 || sharedBaseChk + fatRespOffset + 8192 > PMM.TotalPages * 4096UL) {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL: Shared memory FatResponseData out of bounds in ReadFile!\n\0") Terminal.Print(err);
                ReleaseVfs(); return null;
            }

            while (true) {
                if (IPC.ReceiveForRaw((uint)callerThread, &rType, &rSender, &rPayload)) {
                    if (rType == 31) {
                        daemonFileSize = (uint)rPayload;
                        if (daemonFileSize == 0) { ReleaseVfs(); return null; } 
                        
                        if (outSize != null) *outSize = daemonFileSize;
                        daemonFileBuffer = (byte*)Heap.Alloc(daemonFileSize); 
                        
                        if (daemonFileBuffer == null) {
                            Terminal.SetColor(0x00FF0000);
                            fixed(char* err = "[!] FAT16 Kernel: OOM! Cannot allocate IPC Read buffer!\n\0") Terminal.Print(err);
                            Terminal.SetColor(0x00FFFFFF);
                            ReleaseVfs(); return null;
                        }
                        
                        IPC.Send(311, (uint)callerThread, DaemonId, 0);
                        WakeDaemon(); 
                    }
                    else if (rType == 38) {
                        uint offset = (uint)rPayload;
                        // Kiểm tra xem offset có hợp lệ không
                        if (offset >= daemonFileSize) {
                            Terminal.SetColor(0x00FF0000);
                            fixed(char* err = "[!] FATAL: Invalid offset in ReadFile!\n\0") Terminal.Print(err);
                            ReleaseVfs();
                            if (daemonFileBuffer != null) Heap.Free(daemonFileBuffer);
                            return null;
                        }
                        // Copy chunk from shared memory under lock to avoid races with userland writer
                        bool sm_irq2 = Syscall.SharedMemLock.AcquireSafe();
                        for (int i = 0; i < 512; i++) { if (offset + i < daemonFileSize) {
                                // extra safety: ensure dataChunk access is within shared region
                                if ((ulong)(dataChunk + i) >= sharedBaseChk + fatRespOffset + 8192) {
                                    Terminal.SetColor(0x00FF0000);
                                    fixed(char* err = "[!] FATAL: FatResponseData index out of bounds!\n\0") Terminal.Print(err);
                                    if (daemonFileBuffer != null) Heap.Free(daemonFileBuffer);
                                    Syscall.SharedMemLock.ReleaseSafe(sm_irq2);
                                    ReleaseVfs(); return null;
                                }
                                daemonFileBuffer[offset + i] = dataChunk[i]; }
                        Syscall.SharedMemLock.ReleaseSafe(sm_irq2);
                        }
                        
                        IPC.Send(39, (uint)callerThread, DaemonId, 0);
                        WakeDaemon(); 
                    }
                    else if (rType == 42) { ReleaseVfs(); return daemonFileBuffer; } 
                }
                Scheduler.Yield(); 
            }
        }
        
        if (!IsInitialized) { ReleaseVfs(); return null; }

        ushort cluster = 0; uint fileSize = 0; byte attr = 0;
        FindEntry(filename, &cluster, &fileSize, &attr);

        if (cluster == 0 && fileSize == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] App not found on disk!\n\0") Terminal.Print(err);
            ReleaseVfs(); return null;
        }

        byte* fileBuffer = (byte*)Heap.Alloc(fileSize);
        if (fileBuffer == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FAT16: Out of Heap Memory!\n\0") Terminal.Print(err);
            ReleaseVfs(); return null;
        }
        byte* sectorBuf = (byte*)Heap.Alloc(512);
        if (sectorBuf == null) { Heap.Free(fileBuffer); ReleaseVfs(); return null; } 
        
        byte* fatBuf = (byte*)Heap.Alloc(512);
        if (fatBuf == null) { Heap.Free(fileBuffer); Heap.Free(sectorBuf); ReleaseVfs(); return null; }

        uint bytesRead = 0; byte* ptr = fileBuffer;

        while (cluster >= 0x0002 && cluster <= 0xFFEF && bytesRead < fileSize) {
            // Kiểm tra xem cluster có hợp lệ không
            if (cluster < 2 || cluster > 0xFFEF) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Invalid cluster number in ReadFile!\n\0") Terminal.Print(err);
                Heap.Free(sectorBuf); 
                Heap.Free(fatBuf);
                Heap.Free(fileBuffer);
                ReleaseVfs();
                return null;
            }

            uint clusterLba = FirstDataSector + ((uint)(cluster - 2) * (uint)CachedBPB.SectorsPerCluster);
            // Kiểm tra xem clusterLba có hợp lệ không
            if (clusterLba > 0xFFFFFF) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Invalid cluster LBA in ReadFile!\n\0") Terminal.Print(err);
                Heap.Free(sectorBuf); 
                Heap.Free(fatBuf);
                Heap.Free(fileBuffer);
                ReleaseVfs();
                return null;
            }
            for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) {
                ATA.ReadSector(clusterLba + (uint)s, sectorBuf);
                for (int b = 0; b < 512; b++) {
                    if (bytesRead >= fileSize) break; 
                    *ptr = sectorBuf[b];
                    ptr++; bytesRead++;
                }
                if (bytesRead >= fileSize) break;
            }
            uint fatOffset = (uint)cluster * 2;
            uint fatSector = FatStartLba + CachedBPB.ReservedSectorCount + (fatOffset / 512);

             // Kiểm tra xem fatSector có hợp lệ không
            if (fatSector > 0xFFFFFF) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Invalid FAT sector in ReadFile!\n\0") Terminal.Print(err);
                Heap.Free(sectorBuf); 
                Heap.Free(fatBuf);
                Heap.Free(fileBuffer);
                ReleaseVfs();
                return null;
            }

            ATA.ReadSector(fatSector, fatBuf); 
            cluster = *(ushort*)(fatBuf + (fatOffset % 512)); 
        }
        
        Heap.Free(sectorBuf); 
        Heap.Free(fatBuf);
        if (outSize != null) *outSize = fileSize;

        ReleaseVfs(); 
        return fileBuffer;
    }

    private static ushort FindFreeCluster()
    {
        // Kiểm tra xem FAT16 có được khởi tạo chưa
        if (!IsInitialized) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: FAT16 not initialized in FindFreeCluster!\n\0") Terminal.Print(err);
            return 0;
        }
        
        // Kiểm tra xem FATSize16 có hợp lệ không
        if (CachedBPB.FATSize16 == 0 || CachedBPB.FATSize16 > 0x10000) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid FAT size in FindFreeCluster!\n\0") Terminal.Print(err);
            return 0;
        }

        byte* fatBuf = (byte *)Heap.Alloc(512);

        if (fatBuf == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate FAT buffer in FindFreeCluster!\n\0") Terminal.Print(err);
            return 0;
        }

        for (uint s = 0; s < CachedBPB.FATSize16; s++)
        {
            // Kiểm tra xem s có hợp lệ không
            if (s >= CachedBPB.FATSize16) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Invalid FAT sector in FindFreeCluster!\n\0") Terminal.Print(err);
                Heap.Free(fatBuf);
                return 0;
            }
            ATA.ReadSector(FatStartLba + CachedBPB.ReservedSectorCount + s, fatBuf);
            ushort* fat = (ushort *)fatBuf;

            for (int i = 0; i < 256; i++)
            {
                ushort clusterNum = (ushort)(s * 256 + i);
                // Kiểm tra xem clusterNum có hợp lệ không
                if (clusterNum < 2 || clusterNum > 0xFFEF) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Invalid cluster number in FindFreeCluster!\n\0") Terminal.Print(err);
                    Heap.Free(fatBuf);
                    return 0;
                }
                if (clusterNum >= 2 && fat[i] == 0x0000)
                {
                    fat[i] = 0xFFFF;
                    ATA.WriteSector(FatStartLba + CachedBPB.ReservedSectorCount + s, fatBuf);
                    ATA.WriteSector(FatStartLba + CachedBPB.ReservedSectorCount + CachedBPB.FATSize16 + s, fatBuf);
                    Heap.Free(fatBuf);
                    return clusterNum;
                }
            }
        }
        Heap.Free(fatBuf);
        return 0; 
    }

    public static ushort GetFatEntry(ushort cluster)
    {
        // Kiểm tra xem FAT16 có được khởi tạo chưa
        if (!IsInitialized) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: FAT16 not initialized in GetFatEntry!\n\0") Terminal.Print(err);
            return 0;
        }
        
        // Kiểm tra xem cluster có hợp lệ không
        if (cluster < 2 || cluster > 0xFFEF) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid cluster number in GetFatEntry!\n\0") Terminal.Print(err);
            return 0;
        }
        uint fatOffset = (uint)cluster * 2;
        uint fatSector = FatStartLba + CachedBPB.ReservedSectorCount + (fatOffset / 512);
        // Kiểm tra xem fatSector có hợp lệ không
        if (fatSector > 0xFFFFFF) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid FAT sector in GetFatEntry!\n\0") Terminal.Print(err);
            return 0;
        }
        byte *buf = (byte *)Heap.Alloc(512);
        if (buf == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate buffer in GetFatEntry!\n\0") Terminal.Print(err);
            return 0;
        }
        ATA.ReadSector(fatSector, buf);
        ushort val = *(ushort*)(buf + (fatOffset % 512));
        Heap.Free(buf);
        return val;
    }

    public static void SetFatEntry(ushort cluster, ushort value)
    {
        // Kiểm tra xem FAT16 có được khởi tạo chưa
        if (!IsInitialized) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: FAT16 not initialized in SetFatEntry!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem cluster có hợp lệ không
        if (cluster < 2 || cluster > 0xFFEF) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid cluster number in SetFatEntry!\n\0") Terminal.Print(err);
            return;
        }

        uint fatOffset = (uint)cluster * 2;
        uint fatSector = FatStartLba + CachedBPB.ReservedSectorCount + (fatOffset / 512);
        
        // Kiểm tra xem fatSector có hợp lệ không
        if (fatSector > 0xFFFFFF) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid FAT sector in SetFatEntry!\n\0") Terminal.Print(err);
            return;
        }

        byte* buf = (byte *)Heap.Alloc(512);
        if (buf == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate buffer in SetFatEntry!\n\0") Terminal.Print(err);
            return;
        }
        ATA.ReadSector(fatSector, buf);
        ushort* ptr = (ushort*)(buf + (fatOffset % 512));
        *ptr = value;
        ATA.WriteSector(fatSector, buf);
        ATA.WriteSector(fatSector + CachedBPB.FATSize16, buf);
        Heap.Free(buf);
    }

    public static void WriteFile(char* filename, byte* data, uint size)
    {
        // Kiểm tra xem filename và data có null không
        if (filename == null || data == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null filename or data in WriteFile!\n\0") Terminal.Print(err);
            return;
        }

        AcquireVfs(); 

        int callerThread = Scheduler.CurrentThreadId;
        
        if (UseDaemon && callerThread != 0) {
            KernelSharedMemBlock* shared = GetSharedMem();
            if (shared == null) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Failed to get shared memory in WriteFile!\n\0") Terminal.Print(err);
                ReleaseVfs();
                return;
            }
            char* sharedNameBuf = (char*)shared->FatRequestName;
            
            // Protect shared memory write with kernel-side lock
            bool sm_irq = Syscall.SharedMemLock.AcquireSafe();
            int nameIdx = 0;
            while (filename[nameIdx] != '\0' && nameIdx < 255) {
                sharedNameBuf[nameIdx] = filename[nameIdx];
                nameIdx++;
            }
            sharedNameBuf[nameIdx] = '\0';
            Syscall.SharedMemLock.ReleaseSafe(sm_irq);

            IPC.Send(32, (uint)callerThread, DaemonId, size);
            WakeDaemon(); 

            // [ĐÃ DỌN DẸP] Thay Message Struct bằng Raw Variables
            uint rType = 0, rSender = 0; ulong rPayload = 0;
            byte* dataChunk = (byte*)shared->FatResponseData;

            while (true) {
                if (IPC.ReceiveForRaw((uint)callerThread, &rType, &rSender, &rPayload)) {
                    if (rType == 33) {
                        uint offset = (uint)rPayload;
                        // Kiểm tra xem offset có hợp lệ không
                        if (offset >= size) {
                            Terminal.SetColor(0x00FF0000);
                            fixed (char* err = "[!] FATAL: Invalid offset in WriteFile!\n\0") Terminal.Print(err);
                            ReleaseVfs();
                            return;
                        }
                        // Protect writes into FatResponseData with kernel-side lock
                        bool sm_irq2 = Syscall.SharedMemLock.AcquireSafe();
                        for(int i = 0; i < 512; i++) {
                            if (offset + i < size) dataChunk[i] = data[offset + i]; else dataChunk[i] = 0;
                        }
                        Syscall.SharedMemLock.ReleaseSafe(sm_irq2);
                        IPC.Send(34, (uint)callerThread, DaemonId, 0);
                        WakeDaemon(); 
                    }
                    else if (rType == 35) { 
                        if (rPayload == 1) {
                            Terminal.SetColor(0x0000FF00);
                            fixed(char* m = "[+] IPC Write complete! File committed to Platter!\n\0") Terminal.Print(m);
                        }
                        ReleaseVfs(); return; 
                    }
                }
                Scheduler.Yield(); 
            }
        }
        
        if (!IsInitialized) { ReleaseVfs(); return; }

        if (CachedBPB.SectorsPerCluster == 0) CachedBPB.SectorsPerCluster = 1; 
        uint clusterSize = (uint)CachedBPB.SectorsPerCluster * 512;
        uint numClusters = (size + clusterSize - 1) / clusterSize;
        if (numClusters == 0) numClusters = 1; 

        ushort firstCluster = 0;
        ushort prevCluster = 0;
        uint allocated = 0;

        for (ushort c = 2; c < 0xFFEF; c++) 
        {
            if (GetFatEntry(c) == 0x0000) {
                if (allocated == 0) firstCluster = c;
                else SetFatEntry(prevCluster, c); 

                SetFatEntry(c, 0xFFFF); 
                prevCluster = c;
                allocated++;

                if (allocated == numClusters) break;
            }
        }

        if (allocated < numClusters) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] Disk Full!\n\0") Terminal.Print(err);
            ReleaseVfs(); return; 
        }

        byte* sectorBuf = (byte*)Heap.Alloc(512);
        uint bytesWritten = 0;
        ushort currentCluster = firstCluster;

        while (currentCluster >= 2 && currentCluster <= 0xFFEF && bytesWritten < size) {
            uint clusterLba = FirstDataSector + ((uint)(currentCluster - 2) * (uint)CachedBPB.SectorsPerCluster);
            // Kiểm tra xem clusterLba có hợp lệ không
            if (clusterLba > 0xFFFFFF) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Invalid cluster LBA in WriteFile!\n\0") Terminal.Print(err);
                Heap.Free(sectorBuf);
                ReleaseVfs();
                return;
            }

            for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) {
                if (bytesWritten >= size) break;
                LibC.MemSet(sectorBuf, 0, 512); 
                for (int b = 0; b < 512 && bytesWritten < size; b++) {
                    sectorBuf[b] = data[bytesWritten++];
                }
                ATA.WriteSector(clusterLba + (uint)s, sectorBuf); 
            }
            currentCluster = GetFatEntry(currentCluster); 
        }

        byte* formattedName = (byte*)Heap.Alloc(11);
        
        if (formattedName == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Failed to allocate formatted name buffer in WriteFile!\n\0") Terminal.Print(err);
            Heap.Free(sectorBuf);
            ReleaseVfs();
            return;
        }

        LibC.FormatFATName(filename, formattedName);

        bool saved = false;
        for (uint s = 0; s < RootDirSectors; s++) {
            // Kiểm tra xem s có hợp lệ không
            if (s >= RootDirSectors) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Invalid root directory sector in WriteFile!\n\0") Terminal.Print(err);
                Heap.Free(sectorBuf);
                Heap.Free(formattedName);
                ReleaseVfs();
                return;
            }

            ATA.ReadSector(RootDirLba + s, sectorBuf);
            FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)sectorBuf;
            for (int i = 0; i < 16; i++) {
                if (entries[i].Name[0] == 0x00 || entries[i].Name[0] == 0xE5) {
                    for (int j = 0; j < 11; j++) entries[i].Name[j] = formattedName[j];
                    entries[i].Attributes = 0x20; 
                    entries[i].Reserved = 0; entries[i].CreationTimeTenths = 0;
                    entries[i].CreationTime = 0; entries[i].CreationDate = 0;
                    entries[i].LastAccessDate = 0; entries[i].WriteTime = 0;
                    entries[i].WriteDate = 0; entries[i].FirstClusterHigh = 0;
                    entries[i].FirstClusterLow = firstCluster; 
                    entries[i].FileSize = size;

                    ATA.WriteSector(RootDirLba + s, sectorBuf);
                    saved = true;
                    break;
                }
            }
            if (saved) break;
        }

        Heap.Free(sectorBuf); 
        Heap.Free(formattedName);
        ATA.FlushCache();

        ReleaseVfs(); 
    }

    public static void Cd(char* dirname)
    {
        // Kiểm tra xem dirname có null không
        if (dirname == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null dirname in Cd!\n\0") Terminal.Print(err);
            return;
        }

        AcquireVfs(); 

        int callerThread = Scheduler.CurrentThreadId;

        if (UseDaemon && callerThread != 0) {
            KernelSharedMemBlock* shared = GetSharedMem();
            if (shared == null) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Failed to get shared memory in Cd!\n\0") Terminal.Print(err);
                ReleaseVfs();
                return;
            }

            char* sharedNameBuf = (char*)shared->FatRequestName;

            // Protect shared memory write with kernel-side lock
            bool sm_irq3 = Syscall.SharedMemLock.AcquireSafe();
            int i = 0;
            while (dirname[i] != '\0' && i < 255) { sharedNameBuf[i] = dirname[i]; i++; }
            sharedNameBuf[i] = '\0';
            Syscall.SharedMemLock.ReleaseSafe(sm_irq3);

            IPC.Send(36, (uint)callerThread, DaemonId, 0);
            WakeDaemon(); 

            // [ĐÃ DỌN DẸP] Thay Message Struct bằng Raw Variables
            uint rType = 0, rSender = 0; ulong rPayload = 0;
            while(true) {
                if (IPC.ReceiveForRaw((uint)callerThread, &rType, &rSender, &rPayload) && rType == 37) {
                    if (rPayload == 0) {
                        Terminal.SetColor(0x00FF0000);
                        fixed (char* err = "[!] Thu muc khong ton tai hoac day la File!\n\0") Terminal.Print(err);
                    }
                    ReleaseVfs(); return; 
                }
                Scheduler.Yield(); 
            }
        }

        if (!IsInitialized) { ReleaseVfs(); return; }
        if (dirname[0] == '\\' && dirname[1] == '\0') { CurrentDirCluster = 0; ReleaseVfs(); return; }

        ushort cluster = 0; uint size = 0; byte attr = 0;
        FindEntry(dirname, &cluster, &size, &attr);
        
        if ((attr & 0x10) != 0) CurrentDirCluster = cluster;
        else {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] Thu muc khong ton tai hoac day la File!\n\0") Terminal.Print(err);
        }
        ReleaseVfs(); 
    }

    private static void PrintEntriesInline(byte* buf)
    {
        FAT_DirectoryEntry* entries = (FAT_DirectoryEntry*)buf;
        for (int i = 0; i < 16; i++) {
            if (entries[i].Name[0] == 0x00) return;
            if (entries[i].Name[0] == 0xE5 || entries[i].Attributes == 0x0F || (entries[i].Attributes & 0x08) != 0) continue;

            Terminal.SetColor(0x00FFFFFF);
            for (int j = 0; j < 11; j++) {
                char c = (char)entries[i].Name[j];
                Terminal.DrawChar((c >= 32 && c <= 126) ? c : ' ');
            }
            
            fixed (char* sep1 = " | \0") Terminal.Print(sep1);
            Terminal.SetColor(0x0000FF00);
            Terminal.PrintDec(entries[i].FileSize);
            
            int digits = 1; ulong temp = entries[i].FileSize;
            while (temp >= 10) { digits++; temp /= 10; }
            for (int s = 0; s < 10 - digits; s++) fixed (char* space = " \0") Terminal.Print(space);
            
            fixed (char* sep2 = " | \0") Terminal.Print(sep2);
            Terminal.SetColor(0x00FF00FF);
            if ((entries[i].Attributes & 0x10) != 0) fixed (char* dir = "<DIR>\n\0") Terminal.Print(dir);
            else fixed (char* file = "FILE\n\0") Terminal.Print(file);
        }
    }

    public static void Ls()
    {
        AcquireVfs(); 
        int callerThread = Scheduler.CurrentThreadId;

        if (UseDaemon && callerThread != 0) {
            IPC.Send(40, (uint)callerThread, DaemonId, 0);
            WakeDaemon(); 

            // [ĐÃ DỌN DẸP] Thay Message Struct bằng Raw Variables
            uint rType = 0, rSender = 0; ulong rPayload = 0;
            while(true) {
                if (IPC.ReceiveForRaw((uint)callerThread, &rType, &rSender, &rPayload) && rType == 41) {
                    Terminal.SetColor(0x00FFFF00);
                    fixed (char* header = "FILENAME    | SIZE       | TYPE\n---------------------------------\n\0") Terminal.Print(header);
                    Terminal.SetColor(0x00FFFFFF);
                    
                    KernelSharedMemBlock* shared = GetSharedMem();
                    if (shared == null) {
                        Terminal.SetColor(0x00FF0000);
                        fixed (char* err = "[!] FATAL: Failed to get shared memory in Ls!\n\0") Terminal.Print(err);
                        ReleaseVfs();
                        return;
                    }
                    // Protect shared memory read with kernel-side lock
                    bool sm_irq4 = Syscall.SharedMemLock.AcquireSafe();
                    Terminal.Print((char*)shared->FatResponseData);
                    Syscall.SharedMemLock.ReleaseSafe(sm_irq4);
                    ReleaseVfs(); return; 
                }
                Scheduler.Yield(); 
            }
        }

        if (!IsInitialized) { ReleaseVfs(); return; }
        byte* sectorBuf = (byte*)Heap.Alloc(512);

        Terminal.SetColor(0x00FFFF00);
        fixed (char* header = "FILENAME    | SIZE       | TYPE\n---------------------------------\n\0") Terminal.Print(header);

        if (CurrentDirCluster == 0) {
            // Kiểm tra xem RootDirSectors có hợp lệ không
            if (RootDirSectors > 0x10000) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Invalid root directory sectors in Ls!\n\0") Terminal.Print(err);
                Heap.Free(sectorBuf);
                ReleaseVfs();
                return;
            }

            for (uint s = 0; s < RootDirSectors; s++) {
                // Kiểm tra xem s có hợp lệ không
                if (s >= RootDirSectors) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Invalid root directory sector in Ls!\n\0") Terminal.Print(err);
                    Heap.Free(sectorBuf);
                    ReleaseVfs();
                    return;
                }

                ATA.ReadSector(RootDirLba + s, sectorBuf);
                PrintEntriesInline(sectorBuf);
            }
        } else {
            ushort cluster = CurrentDirCluster;
            byte* fatBuf = (byte*)Heap.Alloc(512);
            while (cluster >= 0x0002 && cluster <= 0xFFEF) {
                // Kiểm tra xem cluster có hợp lệ không
                if (cluster < 2 || cluster > 0xFFEF) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Invalid cluster number in Ls!\n\0") Terminal.Print(err);
                    Heap.Free(fatBuf);
                    Heap.Free(sectorBuf);
                    ReleaseVfs();
                    return;
                }
                uint clusterLba = FirstDataSector + ((uint)(cluster - 2) * (uint)CachedBPB.SectorsPerCluster);
                // Kiểm tra xem clusterLba có hợp lệ không
                if (clusterLba > 0xFFFFFF) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Invalid cluster LBA in Ls!\n\0") Terminal.Print(err);
                    Heap.Free(fatBuf);
                    Heap.Free(sectorBuf);
                    ReleaseVfs();
                    return;
                }

                for (int s = 0; s < CachedBPB.SectorsPerCluster; s++) {
                    ATA.ReadSector(clusterLba + (uint)s, sectorBuf);
                    PrintEntriesInline(sectorBuf);
                }
                uint fatOffset = (uint)cluster * 2;
                uint fatSector = FatStartLba + CachedBPB.ReservedSectorCount + (fatOffset / 512);
                
                // Kiểm tra xem fatSector có hợp lệ không
                if (fatSector > 0xFFFFFF) {
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Invalid FAT sector in Ls!\n\0") Terminal.Print(err);
                    Heap.Free(fatBuf);
                    Heap.Free(sectorBuf);
                    ReleaseVfs();
                    return;
                }

                ATA.ReadSector(fatSector, fatBuf);
                cluster = *(ushort*)(fatBuf + (fatOffset % 512));
            }
            Heap.Free(fatBuf);
        }
        Heap.Free(sectorBuf);
        ReleaseVfs(); 
    }

    public static void Cat(char* filename)
    {
        uint fileSize = 0;
        byte* buf = ReadFile(filename, &fileSize); 
        if (buf == null) return;

        Terminal.SetColor(0x00FFFFFF);
        for (uint i = 0; i < fileSize; i++) {
            char c = (char)buf[i];
            if (c != '\r') Terminal.DrawChar(c);
        }
        fixed(char* nl = "\n\0") Terminal.Print(nl);

        Heap.Free(buf);
    }

    public static void Run(char* filename)
    {
        uint fileSize = 0;
        byte* codeSegment = ReadFile(filename, &fileSize); 
        if (codeSegment == null) return;

        Terminal.SetColor(0x00FFFF00);
        fixed(char* msg = "[*] App loaded to RAM at \0") Terminal.Print(msg);
        Terminal.PrintHex((ulong)codeSegment);
        fixed(char* nl = "\n[*] Executing...\n\0") Terminal.Print(nl);

        delegate* unmanaged<void> appEntry = (delegate* unmanaged<void>)codeSegment;
        appEntry();

        Terminal.SetColor(0x0000FF00);
        fixed(char* msg2 = "[+] App exited gracefully. Freeing memory...\n\0") Terminal.Print(msg2);

        Heap.Free(codeSegment);
    }
}