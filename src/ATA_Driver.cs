using System.Runtime.InteropServices;
namespace NekkoApp;

using static NekkoApp.API;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct SharedMemoryBlock
{
    public fixed byte ShellCommandBuffer[4096];    
    public fixed byte FatRequestName[4096];        
    public fixed byte FatResponseData[8192];      
    public fixed byte AtaRawBuffer[4096];           
}

public unsafe class Program
{
    public static void SyscallYieldApp() 
    { 
        SyscallYield(); 
    }

    // Thêm hàm kiểm tra cổng I/O có được cấp phát không
    private static bool IsPortGranted(ushort port)
    {
        // Kiểm tra xem cổng có nằm trong phạm vi được cấp phát không
        for (ushort p = 0x1F0; p <= 0x1F7; p++) {
            if (p == port) return true;
        }
        return (port == 0x3F6);
    }

    // Thêm hàm kiểm tra API có được khởi tạo chưa
    private static bool IsAPIInitialized()
    {
        // Kiểm tra các hàm API cơ bản có khả dụng không
        return SyscallGetSharedMem != null && 
            SyscallSendIPC != null && 
            SyscallReceiveIPC != null &&
            SyscallPrint != null &&
            SyscallExit != null;
    }

    // Thêm hàm kiểm tra ATA controller có được hỗ trợ không
    private static bool IsATAControllerSupported()
    {
        // Kiểm tra xem cổng 0x1F7 có khả dụng không
        if (!IsPortGranted(0x1F7)) return false;
        
        // [FIX RACE CONDITION ATA/SMP] Khóa phần cứng trước khi đụng vào cổng IDE,
        // vì Kernel (Ring 0) có thể vẫn đang đọc ATA.EXE/FAT16.EXE/MOUSE.EXE
        // qua raw driver trên lõi CPU khác ngay lúc này!
        SyscallAcquireAtaHw();
        // Đọc status register
        byte status = AppInByte(0x1F7);
        SyscallReleaseAtaHw();
        
        // Kiểm tra xem ATA controller có phản hồi không
        return (status != 0xFF);
    }
    
    // ==========================================================
    // [FIX LỖI CÚ PHÁP] Không dùng WaitATA như một hàm public static bool, 
    // vì nó gọi AppInByte (đòi hỏi context của App). Đưa nó vào trong hoặc 
    // giữ nguyên nhưng phải hiểu rõ nó là blocking nhẹ.
    // ==========================================================
    public static bool WaitATA()
    {
        int timeout = 300000;
        while (timeout > 0)
        {
            // Kiểm tra xem cổng 0x1F7 có được cấp phát không
            if (!IsPortGranted(0x1F7)) {
                fixed (char* err = "[!] FATAL: ATA port 0x1F7 not granted!\n\0") {
                    SyscallPrint(err);
                }
                return false;
            }
            byte status = AppInByte(0x1F7);
            if ((status & 0x80) == 0) return true; 
            SyscallYieldApp(); 
            timeout--;
        }
        return false; 
    }

    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        InitAPI();

        // Kiểm tra xem API có được khởi tạo chưa
        if (!IsAPIInitialized()) {
            fixed (char* err = "[!] FATAL: API not initialized in ATA Driver!\n\0") {
                SyscallPrint(err);
            }
            SyscallExit();
            return;
        }

        // Kiểm tra xem ATA controller có được hỗ trợ không
        if (!IsATAControllerSupported()) {
            fixed (char* err = "[!] FATAL: ATA controller not supported!\n\0") {
                SyscallPrint(err);
            }
            SyscallExit();
            return;
        }

        for (ushort p = 0x1F0; p <= 0x1F7; p++) SyscallGrantPort(p);
        SyscallGrantPort(0x3F6);

        ulong sharedBufferAddr = SyscallGetSharedMem();
        // Kiểm tra xem sharedBufferAddr có hợp lệ không
        if (sharedBufferAddr == 0) {
            fixed (char* err = "[!] FATAL: Failed to get shared memory in ATA Driver!\n\0") {
                SyscallPrint(err);
            }
            SyscallExit();
            return;
        }
        SharedMemoryBlock* shared = (SharedMemoryBlock*)sharedBufferAddr;

        SyscallSendIPC(0, 9, sharedBufferAddr); 

        fixed (char* msg1 = "[+] ATA Daemon (Ring 3) Forged in Steel & Waiting...\n\0") 
        {
            SyscallPrint(msg1);
        }

        while (true)
        {
            Message msg = default;
            
            if (SyscallReceiveIPC(&msg) == 1)
            {
                // Kiểm tra xem IPC có được nhận thành công không
                if (msg.Sender == 0 && msg.Type == 0 && msg.Payload == 0) {
                    fixed(char* err = "[!] FATAL: Invalid IPC message received!\n\0") {
                        SyscallPrint(err);
                    }
                    continue;
                }
                
                uint clientId = msg.Sender; 
                uint lba = (uint)msg.Payload; 

                // ==========================================================
                // LỆNH 10: ĐỌC Ổ CỨNG (READ)
                // ==========================================================
                if (msg.Type == 10) 
                {
                    // Kiểm tra xem lba có nằm trong phạm vi hợp lệ không
                    if (lba > 0xFFFFFF) {
                        fixed(char* err = "[!] FATAL: Invalid LBA address in ATA Read!\n\0") {
                            SyscallPrint(err);
                        }
                        SyscallSendIPC(clientId, 111, 0);
                        continue;
                    }

                    // [FIX RACE CONDITION ATA/SMP] Khóa toàn bộ giao dịch đọc đĩa TRƯỚC KHI
                    // đụng vào bất kỳ cổng IDE nào, vì Kernel (Ring 0) có thể đang dùng chung
                    // cổng này trên lõi CPU khác ngay lúc này.
                    SyscallAcquireAtaHw();

                    AppOutByte(0x1F6, (byte)(0xE0 | ((lba >> 24) & 0x0F)));

                    if (!WaitATA()) { SyscallReleaseAtaHw(); SyscallSendIPC(clientId, 111, 0); continue; }

                    AppOutByte(0x1F2, 1);
                    AppOutByte(0x1F3, (byte)(lba & 0xFF));
                    AppOutByte(0x1F4, (byte)((lba >> 8) & 0xFF));
                    AppOutByte(0x1F5, (byte)((lba >> 16) & 0xFF));
                    AppOutByte(0x1F7, 0x20); 

                    bool isError = false; 

                    while (true)
                    {
                        byte status = AppInByte(0x1F7);
                        if ((status & 0x80) != 0) { SyscallYieldApp(); continue; } 
                        if ((status & 0x01) != 0 || (status & 0x20) != 0) {
                            fixed(char* err = "[!] ATA Ring 3: Read Error!\n\0") SyscallPrint(err);
                            isError = true; 
                            break;
                        }
                        if ((status & 0x08) != 0) break; 
                    }

                    if (!isError)
                    {
                        // ==========================================================
                        // [FIX CHÍ MẠNG] Ép kiểu và dùng ngay tại chỗ! Đéo cần lệnh fixed!
                        // ==========================================================
                        ushort* buffer16 = (ushort*)shared->AtaRawBuffer;
                        for (int i = 0; i < 256; i++) {
                            buffer16[i] = AppInWord(0x1F0);
                        }
                        SyscallReleaseAtaHw();
                        SyscallSendIPC(clientId, 11, sharedBufferAddr); 
                    }
                    else { SyscallReleaseAtaHw(); SyscallSendIPC(clientId, 111, 0); }
                }

                // ==========================================================
                // LỆNH 12: GHI Ổ CỨNG (WRITE)
                // ==========================================================
                else if (msg.Type == 12) 
                {
                    // Kiểm tra xem lba có nằm trong phạm vi hợp lệ không
                    if (lba > 0xFFFFFF) {
                        fixed(char* err = "[!] FATAL: Invalid LBA address in ATA Write!\n\0") {
                            SyscallPrint(err);
                        }
                        SyscallSendIPC(clientId, 111, 0);
                        continue;
                    }

                    // [FIX RACE CONDITION ATA/SMP] Khóa toàn bộ giao dịch ghi đĩa TRƯỚC KHI
                    // đụng vào bất kỳ cổng IDE nào.
                    SyscallAcquireAtaHw();

                    AppOutByte(0x1F6, (byte)(0xE0 | ((lba >> 24) & 0x0F)));

                    if (!WaitATA()) { SyscallReleaseAtaHw(); SyscallSendIPC(clientId, 111, 0); continue; }

                    AppOutByte(0x1F2, 1);
                    AppOutByte(0x1F3, (byte)(lba & 0xFF));
                    AppOutByte(0x1F4, (byte)((lba >> 8) & 0xFF));
                    AppOutByte(0x1F5, (byte)((lba >> 16) & 0xFF));
                    AppOutByte(0x1F7, 0x30); 

                    bool isError = false; 

                    while (true)
                    {
                        byte status = AppInByte(0x1F7);
                        if ((status & 0x80) != 0) { SyscallYieldApp(); continue; }
                        if ((status & 0x01) != 0 || (status & 0x20) != 0) {
                            fixed(char* err = "[!] ATA Ring 3: Write Timeout!\n\0") SyscallPrint(err);
                            isError = true; 
                            break;
                        }
                        if ((status & 0x08) != 0) break; 
                    }

                    if (!isError) 
                    {
                        // Kiểm tra xem shared->AtaRawBuffer có null không
                        if (shared->AtaRawBuffer == null) {
                            fixed(char* err = "[!] FATAL: Null ATA raw buffer in Read!\n\0") {
                                SyscallPrint(err);
                            }
                            SyscallReleaseAtaHw();
                            SyscallSendIPC(clientId, 111, 0);
                            continue;
                        }

                        // ==========================================================
                        // [FIX CHÍ MẠNG] Ép kiểu và dùng ngay tại chỗ!
                        // ==========================================================
                        ushort* buffer16 = (ushort*)shared->AtaRawBuffer;
                        for (int i = 0; i < 256; i++) {
                            AppOutWord(0x1F0, buffer16[i]);
                        }

                        AppOutByte(0x1F7, 0xE7); 
                        
                        while (true)
                        {
                            byte status = AppInByte(0x1F7);
                            if ((status & 0x80) != 0) { SyscallYieldApp(); continue; } 
                            if ((status & 0x01) != 0 || (status & 0x20) != 0) {
                                fixed(char* err = "[!] ATA Ring 3: Platter write/flush failed!\n\0") SyscallPrint(err);
                                isError = true;
                                break;
                            }
                            break; 
                        }
                    }
                    
                    SyscallReleaseAtaHw();
                    if (!isError) SyscallSendIPC(clientId, 13, sharedBufferAddr); 
                    else SyscallSendIPC(clientId, 111, 0); 
                }

                // LỆNH 14: XẢ BỘ NHỚ ĐỆM ĐỘC LẬP (FLUSH)
                else if (msg.Type == 14) 
                {
                    // [FIX RACE CONDITION ATA/SMP] Khóa toàn bộ trước khi đụng cổng IDE.
                    SyscallAcquireAtaHw();

                    AppOutByte(0x1F7, 0xE7); 
                    bool isError = false;
                    
                    while (true)
                    {
                        byte status = AppInByte(0x1F7);
                        if ((status & 0x80) == 0) break; 
                        if ((status & 0x01) != 0)
                        {
                            fixed(char* err = "[!] ATA Ring 3: Cache flush failed!\n\0") SyscallPrint(err);
                            isError = true;
                            break;
                        }
                        SyscallYieldApp(); 
                    }
                    
                    SyscallReleaseAtaHw();
                    if (!isError) SyscallSendIPC(clientId, 15, 0); 
                    else SyscallSendIPC(clientId, 111, 0);
                }

                else if (msg.Type == 0xDEAD) 
                {
                    fixed(char* dieMsg = "\n[*] ATA: SIGTERM received. Sweeping workspace and signing off. Goodbye!\n\0") SyscallPrint(dieMsg);
                    CleanupResources();
                    SyscallExit();
                }
            }
            else
            {
                SyscallWaitIPC();
            }
        }
    }

    // Thêm hàm dọn dẹp tài nguyên
    private static void CleanupResources()
    {
        return;
    }

    public static void Main() { }
}