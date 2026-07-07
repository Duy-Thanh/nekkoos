using System.Runtime.InteropServices;

namespace NekkoOS.Kernel.Driver;

public static unsafe class ATA
{
    public static bool UseDaemon = false;
    public static uint DaemonId = 0;
    
    private static KernelSharedMemBlock* GetSharedMem() {
        if (Syscall.GlobalSharedRAM_Phys == 0) {
            // Serialize allocation to avoid concurrent alloc races
            bool irqAlloc = Scheduler.AcquireSchedLockSafe();
            if (Syscall.GlobalSharedRAM_Phys == 0) {
                Syscall.GlobalSharedRAM_Phys = (ulong)PMM.AllocateContiguousPages(5);
                if (Syscall.GlobalSharedRAM_Phys == 0) {
                    Scheduler.ReleaseSchedLockSafe(irqAlloc);
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* err = "[!] FATAL: Failed to allocate shared memory for ATA!\n\0") Terminal.Print(err);
                    return null;
                }
                LibC.MemSet((byte*)Syscall.GlobalSharedRAM_Phys, 0, 5 * 4096);
            }
            Scheduler.ReleaseSchedLockSafe(irqAlloc);
        }
        // Validate physical address before casting
        if (Syscall.GlobalSharedRAM_Phys == 0 || Syscall.GlobalSharedRAM_Phys >= PMM.TotalPages * 4096UL) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Invalid GlobalSharedRAM_Phys in ATA GetSharedMem!\n\0") Terminal.Print(err);
            return null;
        }

        return (KernelSharedMemBlock*)Syscall.GlobalSharedRAM_Phys;
    }

    private static void WakeDaemon() {
        if (DaemonId != 0 && DaemonId < Scheduler.ThreadCount) {
            bool irq = Scheduler.AcquireSchedLockSafe();
            if (irq) {
                // Kiểm tra xem thread có active không
                if (Scheduler.Threads[DaemonId].Active != 0) {
                    Scheduler.Threads[DaemonId].Active = 1; 
                }
                Scheduler.ReleaseSchedLockSafe(irq);
            }
        }
    }

    private static Spinlock AtaStateLock = new Spinlock();
    private static bool AtaIsBusy = false;

    public static void AcquireAtaAsync()
    {
        while (true) {
            bool irq = AtaStateLock.AcquireSafe();
            if (!AtaIsBusy) {
                AtaIsBusy = true;
                AtaStateLock.ReleaseSafe(irq);
                return;
            }
            AtaStateLock.ReleaseSafe(irq);
            Scheduler.Yield(); 
        }
    }

    public static void ReleaseAtaAsync()
    {
        bool irq = AtaStateLock.AcquireSafe();
        AtaIsBusy = false;
        AtaStateLock.ReleaseSafe(irq);
    }

    public static Spinlock AtaHardwareLock = new Spinlock();

    private static bool WaitAtaHardware()
    {
        int timeout = 1000000;
        while (timeout > 0)
        {
            byte status = IO.In8(0x1F7);
            if ((status & 0x80) == 0) return true;
            timeout--;
        }
        return false;
    }

    // [FIX LOW] Dung lượng đĩa thật - dò động bằng IDENTIFY DEVICE (0xEC), giống hệt
    // ATA_Driver.cs (Ring 3), TUYỆT ĐỐI không hardcode theo kích thước hdd.img hiện tại.
    // Đường Ring0 này chỉ chạy khi UseDaemon == false (trước khi ATA Daemon online).
    private static uint DetectedSectorCount = 0;

    private static void DetectDiskSize()
    {
        if (!WaitAtaHardware()) return;

        IO.Out8(0x1F6, 0xA0);
        IO.Out8(0x1F2, 0); IO.Out8(0x1F3, 0); IO.Out8(0x1F4, 0); IO.Out8(0x1F5, 0);
        IO.Out8(0x1F7, 0xEC); // IDENTIFY DEVICE

        byte status = IO.In8(0x1F7);
        if (status == 0) return;

        int timeout = 1000000;
        while (timeout > 0)
        {
            status = IO.In8(0x1F7);
            if ((status & 0x80) == 0) break;
            timeout--;
        }
        if (timeout <= 0 || (status & 0x01) != 0) return;

        while (true)
        {
            status = IO.In8(0x1F7);
            if ((status & 0x01) != 0) return;
            if ((status & 0x08) != 0) break;
        }

        ushort* identifyData = stackalloc ushort[256];
        for (int i = 0; i < 256; i++) identifyData[i] = IO.In16(0x1F0);

        uint totalSectors = (uint)identifyData[60] | ((uint)identifyData[61] << 16);
        if (totalSectors > 0) DetectedSectorCount = totalSectors;
    }

    private static bool IsLbaInRange(uint lba)
    {
        bool hwIrq = AtaHardwareLock.AcquireSafe();
        if (DetectedSectorCount == 0) DetectDiskSize();
        AtaHardwareLock.ReleaseSafe(hwIrq);

        if (DetectedSectorCount != 0) return lba < DetectedSectorCount;
        return lba <= 0xFFFFFF;
    }

    public static void ReadSector(uint lba, byte* buffer)
    {
        // Kiểm tra xem buffer có null không
        if (buffer == null) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Null buffer in ATA ReadSector!\n\0") Terminal.Print(err);
            Terminal.SetColor(0x00FFFFFF);
            return;
        }

        if (!IsLbaInRange(lba)) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid LBA address in ATA ReadSector!\n\0") Terminal.Print(err);
            Terminal.SetColor(0x00FFFFFF);
            return;
        }
        
        int callerThread = Scheduler.CurrentThreadId;

        if (UseDaemon && callerThread != 0)
        {
            AcquireAtaAsync(); 

            IPC.Send(10, (uint)callerThread, DaemonId, lba);
            WakeDaemon(); 

            // [ĐÃ DỌN DẸP] Dùng biến Raw, không đẻ Struct!
            uint rType = 0, rSender = 0; ulong rPayload = 0;
            while (true)
            {
                if (IPC.ReceiveForRaw((uint)callerThread, &rType, &rSender, &rPayload))
                {
                    if (rType == 11) { 
                        KernelSharedMemBlock* sharedMem = GetSharedMem();
                        if (sharedMem == null) {
                            Terminal.SetColor(0x00FF0000);
                            fixed(char* err = "[!] FATAL: Failed to get shared memory in ATA ReadSector!\n\0") Terminal.Print(err);
                            Terminal.SetColor(0x00FFFFFF);
                            ReleaseAtaAsync(); 
                            return; 
                        }
                        // Validate that AtaRawBuffer lies within physical memory bounds
                        ulong sharedBase = (ulong)sharedMem;
                        ulong ataOffset = 4096 + 4096 + 8192; // ShellCommand(4K) + FatRequest(4K) + FatResponse(8K)
                        if (sharedBase == 0 || sharedBase + ataOffset + 512 > PMM.TotalPages * 4096UL) {
                            Terminal.SetColor(0x00FF0000);
                            fixed(char* err = "[!] FATAL: Shared memory AtaRawBuffer out of bounds in ATA ReadSector!\n\0") Terminal.Print(err);
                            Terminal.SetColor(0x00FFFFFF);
                            ReleaseAtaAsync(); return; 
                        }
                        bool sm_irq = Syscall.SharedMemLock.AcquireSafe();
                        LibC.MemCpy(buffer, sharedMem->AtaRawBuffer, 512); 
                        Syscall.SharedMemLock.ReleaseSafe(sm_irq);
                        ReleaseAtaAsync(); 
                        return; 
                    }
                    else if (rType == 111) 
                    {
                        Terminal.SetColor(0x00FF0000);
                        fixed(char* err = "[!] ATA Ring 0: Read Error from Daemon!\n\0") Terminal.Print(err);
                        Terminal.SetColor(0x00FFFFFF); 
                        ReleaseAtaAsync(); 
                        return;
                    }
                }
                Scheduler.Yield(); 
            }
        }

        bool hwIrq = AtaHardwareLock.AcquireSafe(); 

        IO.Out8(0x1F6, (byte)(0xE0 | ((lba >> 24) & 0x0F)));
        
        if (!WaitAtaHardware()) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] ATA HW Read Error: Drive Select Timeout!\n\0") Terminal.Print(err);
            Terminal.SetColor(0x00FFFFFF);
            AtaHardwareLock.ReleaseSafe(hwIrq);
            return;
        }

        IO.Out8(0x1F2, 1);
        IO.Out8(0x1F3, (byte)(lba & 0xFF));
        IO.Out8(0x1F4, (byte)((lba >> 8) & 0xFF));
        IO.Out8(0x1F5, (byte)((lba >> 16) & 0xFF));
        IO.Out8(0x1F7, 0x20); // Lệnh READ PIO

        while (true)
        {
            byte status = IO.In8(0x1F7);
            
            if ((status & 0x80) != 0) continue; // Đợi BSY tắt

            if ((status & 0x01) != 0 || (status & 0x20) != 0) 
            {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] ATA HW Read Error!\n\0") Terminal.Print(err);
                Terminal.SetColor(0x00FFFFFF);
                AtaHardwareLock.ReleaseSafe(hwIrq); 
                return;
            }

            if ((status & 0x08) != 0) break; // DRQ bật -> Kéo Data ra
        }

        ushort* ptr = (ushort*)buffer;
        for (int i = 0; i < 256; i++) ptr[i] = IO.In16(0x1F0);

        AtaHardwareLock.ReleaseSafe(hwIrq); 
    }

    public static void WriteSector(uint lba, byte* buffer)
    {
        // Kiểm tra xem buffer có null không
        if (buffer == null) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Null buffer in ATA WriteSector!\n\0") Terminal.Print(err);
            Terminal.SetColor(0x00FFFFFF);
            return;
        }

        if (!IsLbaInRange(lba)) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid LBA address in ATA WriteSector!\n\0") Terminal.Print(err);
            Terminal.SetColor(0x00FFFFFF);
            return;
        }
        
        int callerThread = Scheduler.CurrentThreadId;

        if (UseDaemon && callerThread != 0)
        {
            AcquireAtaAsync(); 

            KernelSharedMemBlock* sharedMem = GetSharedMem();
            if (sharedMem == null) {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL: Failed to get shared memory in ATA WriteSector!\n\0") Terminal.Print(err);
                Terminal.SetColor(0x00FFFFFF);
                return;
            }
            
            bool sm_irq = Syscall.SharedMemLock.AcquireSafe();
            LibC.MemCpy(sharedMem->AtaRawBuffer, buffer, 512);
            Syscall.SharedMemLock.ReleaseSafe(sm_irq);

            IPC.Send(12, (uint)callerThread, DaemonId, lba);
            WakeDaemon(); 

            // [ĐÃ DỌN DẸP] Dùng biến Raw, không đẻ Struct!
            uint rType = 0, rSender = 0; ulong rPayload = 0;
            
            // Note: comparing addresses of local variables (&...) to null is meaningless
            // Remove the invalid check; rely on ReceiveForRaw return value and daemon logic.

            while (true)
            {
                if (IPC.ReceiveForRaw((uint)callerThread, &rType, &rSender, &rPayload)) { 
                    if (rType == 13) {
                        ReleaseAtaAsync(); 
                        return; 
                    }
                    else if (rType == 111) {
                        Terminal.SetColor(0x00FF0000);
                        fixed(char* err = "[!] ATA Ring 0: Write Error from Daemon!\n\0") Terminal.Print(err);
                        Terminal.SetColor(0x00FFFFFF); 
                        ReleaseAtaAsync(); 
                        return;
                    }
                }
                Scheduler.Yield(); 
            }
        }

        bool hwIrq = AtaHardwareLock.AcquireSafe(); 

        if (!WaitAtaHardware()) { // Đợi rảnh trước khi làm gì đó
            AtaHardwareLock.ReleaseSafe(hwIrq); return;
        }

        IO.Out8(0x1F6, (byte)(0xE0 | ((lba >> 24) & 0x0F)));
        
        if (!WaitAtaHardware()) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] ATA HW Write Error: Drive Select Timeout!\n\0") Terminal.Print(err);
            Terminal.SetColor(0x00FFFFFF);
            AtaHardwareLock.ReleaseSafe(hwIrq);
            return;
        }
        
        IO.Out8(0x1F2, 1); 
        IO.Out8(0x1F3, (byte)(lba & 0xFF));
        IO.Out8(0x1F4, (byte)((lba >> 8) & 0xFF));
        IO.Out8(0x1F5, (byte)((lba >> 16) & 0xFF));
        IO.Out8(0x1F7, 0x30); // Lệnh WRITE PIO

        while (true)
        {
            byte status = IO.In8(0x1F7);
            if ((status & 0x80) != 0) continue; 
            
            if ((status & 0x01) != 0 || (status & 0x20) != 0) { 
                Terminal.SetColor(0x00FF0000); 
                fixed (char* err = "[!] ATA HW Write error: DRQ Timeout!\n\0") Terminal.Print(err); 
                Terminal.SetColor(0x00FFFFFF); 
                AtaHardwareLock.ReleaseSafe(hwIrq); 
                return; 
            }
            if ((status & 0x08) != 0) break;
        }

        ushort* ptr = (ushort*)buffer;
        for (int i = 0; i < 256; i++) IO.Out16(0x1F0, ptr[i]);

        IO.Out8(0x1F7, 0xE7); // Lệnh E7 = Cache Flush
        
        while (true)
        {
            byte status = IO.In8(0x1F7);
            if ((status & 0x80) != 0) continue; 
            
            if ((status & 0x01) != 0 || (status & 0x20) != 0) { 
                Terminal.SetColor(0x00FF0000); 
                fixed (char* err = "[!] ATA HW Write error: Platter write/flush failed!\n\0") Terminal.Print(err); 
                Terminal.SetColor(0x00FFFFFF); 
                AtaHardwareLock.ReleaseSafe(hwIrq); 
                return; 
            }
            break;
        }

        AtaHardwareLock.ReleaseSafe(hwIrq); 
    }

    public static void FlushCache()
    {
        int callerThread = Scheduler.CurrentThreadId;

        if (UseDaemon && callerThread != 0)
        {
            AcquireAtaAsync(); 

            IPC.Send(14, (uint)callerThread, DaemonId, 0);
            WakeDaemon();

            // [ĐÃ DỌN DẸP] Dùng biến Raw, không đẻ Struct!
            uint rType = 0, rSender = 0; ulong rPayload = 0;

            // Note: comparing addresses of local variables (&...) to null is meaningless
            // Remove the invalid check; rely on ReceiveForRaw return value and daemon logic.
            
            while (true)
            {
                if (IPC.ReceiveForRaw((uint)callerThread, &rType, &rSender, &rPayload)) { 
                    if (rType == 15) {
                        ReleaseAtaAsync(); 
                        return; 
                    }
                    else if (rType == 111) {
                        Terminal.SetColor(0x00FF0000);
                        fixed(char* err = "[!] ATA Ring 0: Flush Error from Daemon!\n\0") Terminal.Print(err);
                        Terminal.SetColor(0x00FFFFFF); 
                        ReleaseAtaAsync(); 
                        return;
                    }
                }
                Scheduler.Yield(); 
            }
        }
        
        bool hwIrq = AtaHardwareLock.AcquireSafe(); 

        IO.Out8(0x1F7, 0xE7); // Sửa 0xEA thành 0xE7 cho chuẩn xác!

        while (true)
        {
            byte status = IO.In8(0x1F7); 
            if ((status & 0x80) == 0) break; 
            if ((status & 0x01) != 0) { 
                Terminal.SetColor(0x00FF0000); 
                fixed (char* err = "[!] ATA HW Write error: Cache flush failed!\n\0") Terminal.Print(err); 
                Terminal.SetColor(0x00FFFFFF); 
                AtaHardwareLock.ReleaseSafe(hwIrq); 
                return; 
            }
        }

        AtaHardwareLock.ReleaseSafe(hwIrq); 
    }
}