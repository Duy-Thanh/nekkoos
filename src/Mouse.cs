using System.Runtime.InteropServices;
namespace NekkoApp;
using static NekkoApp.API;

public static unsafe class MouseDaemon
{
    // ==========================================================
    // [FIX CHÍ MẠNG 1] BỌC THÉP VÒNG LẶP CHỜ BẰNG THUỐC NGỦ!
    // Tuyệt đối không dùng Yield()! Dùng Sleep() để ép Thread 
    // này đi ngủ, trả lại 100% tài nguyên CPU cho HĐH!
    // ==========================================================
    public static void WaitWrite() { 
        while ((AppInByte(0x64) & 2) != 0) { 
            SyscallSleep(1); // Ngủ 1ms (Tương đương 1 nhịp Timer)
        } 
    }
    public static void WaitRead() { 
        while ((AppInByte(0x64) & 1) == 0) { 
            SyscallSleep(1); // Ngủ 1ms chờ phần cứng
        } 
    }
    
    public static void WriteMouse(byte write) {
        WaitWrite(); AppOutByte(0x64, 0xD4); 
        WaitWrite(); AppOutByte(0x60, write);
        WaitRead(); AppInByte(0x60); 
    }

    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        InitAPI();

        // 1. XIN QUYỀN ĐẾ VƯƠNG (Port I/O)
        SyscallGrantPort(0x60);
        SyscallGrantPort(0x64);

        // 2. XẢ RÁC CỔNG 0x60 TRƯỚC KHI KHỞI TẠO!
        while ((AppInByte(0x64) & 1) != 0) {
            AppInByte(0x60);
        }

        // 3. TÁT CHO CON CHUỘT TỈNH DẬY!
        WaitWrite(); AppOutByte(0x64, 0xA8); 
        WaitWrite(); AppOutByte(0x64, 0x20); 
        WaitRead(); byte status = AppInByte(0x60); 
        status |= 2; 
        WaitWrite(); AppOutByte(0x64, 0x60); 
        WaitWrite(); AppOutByte(0x60, status);
        
        WriteMouse(0xF6); 
        WriteMouse(0xF4); 

        // 4. GỬI THƯ BÁO KERNEL LÀ TAO ĐÃ SẴN SÀNG (Type 44)
        SyscallSendIPC(0, 44, 0);

        // ==========================================================
        // [FIX CHÍ MẠNG 2] NGỦ MỖI KHI TÌM DWM!
        // DWM load sau Mouse, vòng lặp này sẽ chạy cực lâu!
        // Dùng Sleep(5) để tiết kiệm CPU tối đa.
        // ==========================================================
        int dwmId = -1;
        fixed (char* targetName = "DSRV.EXE\0") 
        {
            while (dwmId == -1) {
                dwmId = SyscallGetPIDByName(targetName);
                if (dwmId == -1) SyscallSleep(5);
            }
        }

        fixed(char* m = "[MOUSE] Hardware awake! Pumping data to DWM...\n\0") SyscallPrint(m);

        int cycle = 0;

        // VÒNG LẶP TIÊU HÓA RAW DATA VÀ NÃ IPC CHO DWM
        while (true)
        {
            Message msg;
            if (SyscallReceiveIPC(&msg) == 1) {
                if (msg.Type == 2) {
                    // Bung hàng từ Payload
                    byte p0 = (byte)(msg.Payload & 0xFF);
                    byte p1 = (byte)((msg.Payload >> 8) & 0xFF);
                    byte p2 = (byte)((msg.Payload >> 16) & 0xFF);
                    
                    int dx = p1;
                    int dy = p2;
                    
                    // Căn dấu Âm/Dương
                    if ((p0 & 0x10) != 0) dx |= unchecked((int)0xFFFFFF00); 
                    if ((p0 & 0x20) != 0) dy |= unchecked((int)0xFFFFFF00); 

                    dy = -dy; // Màn hình máy tính lật ngược trục Y
                    byte clicks = (byte)(p0 & 0x07);

                    ulong finalPayload = ((ulong)clicks << 32) | ((ulong)(ushort)dx << 16) | (ulong)(ushort)dy;
                    SyscallSendIPC((uint)dwmId, 3, finalPayload); 
                }
            } else {
                SyscallWaitIPC(); 
            }
        }
    }
    public static void Main() {}
}