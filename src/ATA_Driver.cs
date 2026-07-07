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

    // [FIX LOW] Dung lượng đĩa thật - dò động bằng lệnh IDENTIFY DEVICE (0xEC) lúc
    // khởi động, TUYỆT ĐỐI không hardcode số sector theo kích thước hdd.img hiện tại
    // (build.sh có thể đổi kích thước ảnh đĩa bất kỳ lúc nào, hardcode sẽ sai lệch
    // ngay khi đó). 0 nghĩa là chưa dò được (dùng mốc an toàn 0xFFFFFF cũ làm dự phòng).
    private static uint DetectedSectorCount = 0;

    private static void DetectDiskSize()
    {
        if (!WaitATA()) return;

        AppOutByte(0x1F6, 0xA0); // Chọn ổ Master, không set bit LBA vì IDENTIFY không cần địa chỉ
        AppOutByte(0x1F2, 0); AppOutByte(0x1F3, 0); AppOutByte(0x1F4, 0); AppOutByte(0x1F5, 0);
        AppOutByte(0x1F7, 0xEC); // Lệnh IDENTIFY DEVICE

        byte status = AppInByte(0x1F7);
        if (status == 0) return; // Không có ổ đĩa nào gắn ở vị trí này

        int timeout = 300000;
        while (timeout > 0)
        {
            status = AppInByte(0x1F7);
            if ((status & 0x80) == 0) break; // Đợi BSY tắt
            SyscallYieldApp();
            timeout--;
        }
        if (timeout <= 0 || (status & 0x01) != 0) return; // Timeout hoặc lỗi -> giữ nguyên 0 (chưa dò được)

        while (true)
        {
            status = AppInByte(0x1F7);
            if ((status & 0x01) != 0) return; // Lỗi giữa chừng
            if ((status & 0x08) != 0) break; // DRQ sẵn sàng
        }

        ushort* identifyData = stackalloc ushort[256];
        for (int i = 0; i < 256; i++) identifyData[i] = AppInWord(0x1F0);

        // Word 60-61 (theo chuẩn ATA/ATAPI): Tổng số sector địa chỉ được kiểu LBA28 (32-bit)
        uint totalSectors = (uint)identifyData[60] | ((uint)identifyData[61] << 16);
        if (totalSectors > 0) DetectedSectorCount = totalSectors;
    }

    private static bool IsLbaInRange(uint lba)
    {
        if (DetectedSectorCount != 0) return lba < DetectedSectorCount;
        return lba <= 0xFFFFFF; // Dự phòng khi chưa dò được dung lượng thật
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

        // [FIX LOW] Dò dung lượng đĩa thật ngay khi có quyền cổng, TRƯỚC khi nhận
        // request I/O đầu tiên - tránh dùng mốc 24-bit cũ (~8GB) không phản ánh
        // dung lượng ảnh đĩa thật đang gắn.
        SyscallAcquireAtaHw();
        DetectDiskSize();
        SyscallReleaseAtaHw();

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
                    if (!IsLbaInRange(lba)) {
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
                    if (!IsLbaInRange(lba)) {
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
                // [FIX SPIN] Unknown type → bỏ qua, không spin
                // else: fall through to SyscallWaitIPC below
            }
            else
            {
                SyscallWaitIPC();
            }
        }
    }

    // [FIX AN TOÀN SHUTDOWN] Lớp bảo vệ cuối cùng ở tầng ATA Daemon: tự flush cache
    // phần cứng thật (lệnh 0xE7) trước khi thoát, độc lập với Driver.ATA.FlushCache()
    // ở Ring 0 (Power.cs) - phòng trường hợp daemon bị kill trong lúc Power.cs chưa
    // kịp chạy tới bước flush của nó (ví dụ do lỗi luồng thực thi khác trong tương lai).
    // [FIX] Retry có giới hạn khi lệnh flush báo lỗi (bit ERR) - status ERR đôi khi chỉ
    // là nhiễu tức thời của controller, không nên bỏ cuộc ngay sau 1 lần fail. Nếu vẫn
    // fail sau khi hết lượt retry, in cảnh báo NGHIÊM TRỌNG (không chỉ 1 dòng im lặng)
    // để log phản ánh đúng mức độ nguy hiểm - có thể mất dữ liệu chưa ghi xuống platter.
    private static void CleanupResources()
    {
        SyscallAcquireAtaHw();

        const int maxAttempts = 3;
        bool flushed = false;

        for (int attempt = 1; attempt <= maxAttempts && !flushed; attempt++)
        {
            AppOutByte(0x1F7, 0xE7);
            int timeout = 300000;
            bool error = false;

            while (timeout > 0)
            {
                byte status = AppInByte(0x1F7);
                if ((status & 0x80) == 0) break;
                if ((status & 0x01) != 0) { error = true; break; }
                SyscallYieldApp();
                timeout--;
            }

            if (!error && timeout > 0) { flushed = true; }
            else if (attempt < maxAttempts) {
                fixed (char* warn = "[!] ATA: Flush-on-exit attempt failed, retrying...\n\0") SyscallPrint(warn);
            }
        }

        if (!flushed) {
            fixed (char* err = "[!!!] ATA FATAL: Cache flush-on-exit failed after all retries! DATA LOSS POSSIBLE!\n\0") SyscallPrint(err);
        }

        SyscallReleaseAtaHw();
    }

    public static void Main() { }
}