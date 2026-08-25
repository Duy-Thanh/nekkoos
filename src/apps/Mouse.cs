// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoApp;
using static NekkoApp.API;

public static unsafe class MouseDaemon
{
    // ==========================================================
    // [FIX PS/2 TIMEOUT] PS/2 controller phản hồi trong MICRO-giây.
    // KHÔNG dùng SyscallSleep trong vòng lặp này — 100000 * Sleep(1)
    // = ~400 giây worst case, khiến Mouse không kịp gửi handshake!
    // Busy-wait thuần túy với counter nhỏ là đủ.
    // ==========================================================
    public static bool WaitWrite() { 
        int t = 5000;
        while ((AppInByte(0x64) & 2) != 0) { 
            if (--t <= 0) return false;
        }
        return true;
    }
    public static bool WaitRead() { 
        int t = 5000;
        while ((AppInByte(0x64) & 1) == 0) { 
            if (--t <= 0) return false;
        }
        return true;
    }
    
    // Trả về false nếu mouse không phản hồi (timeout)
    public static bool WriteMouse(byte write) {
        if (!WaitWrite()) return false;
        AppOutByte(0x64, 0xD4); 
        if (!WaitWrite()) return false;
        AppOutByte(0x60, write);
        if (!WaitRead()) return false;
        AppInByte(0x60);  // ACK byte
        return true;
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
        // [FIX KVM] Mỗi bước đều có timeout. Nếu lỗi → vẫn gửi handshake,
        // chỉ là mouse không nhận input phần cứng.
        bool mouseOk = true;
        if (WaitWrite()) AppOutByte(0x64, 0xA8); else mouseOk = false;
        if (mouseOk && WaitWrite()) AppOutByte(0x64, 0x20); else mouseOk = false;
        if (mouseOk && WaitRead()) {
            byte status = AppInByte(0x60); 
            status |= 2; 
            if (WaitWrite()) AppOutByte(0x64, 0x60);
            if (WaitWrite()) AppOutByte(0x60, status);
        } else mouseOk = false;
        
        if (mouseOk) {
            WriteMouse(0xF6); 
            WriteMouse(0xF4); 
        }

        // 4. GỬI THƯ BÁO KERNEL LÀ TAO ĐÃ SẴN SÀNG (Type 44)
        // Luôn gửi handshake dù mouse có lỗi hay không — kernel phải unblock!
        SyscallSendIPC(0, 44, 0);

        // ==========================================================
        // [FIX DEADLOCK] DSRV.EXE có thể không tồn tại (bị disabled).
        // Chờ tối đa 2 giây. Nếu không tìm thấy thì bỏ qua.
        // Mouse vẫn nhận IRQ12, chỉ không forward cho DWM.
        // ==========================================================
        int dwmId = -1;
        fixed (char* targetName = "DSRV.EXE\0") 
        {
            int waitMs = 0;
            while (dwmId == -1 && waitMs < 1000) {
                dwmId = SyscallGetPIDByName(targetName);
                if (dwmId == -1) { SyscallSleep(5); waitMs += 5; }
            }
        }

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
                    // [FIX] Chỉ forward khi dwmId hợp lệ
                    if (dwmId != -1) SyscallSendIPC((uint)dwmId, 3, finalPayload); 
                }
                // [FIX SPIN LOOP] Các message type khác (0xDEAD, stray IPC...):
                // Không làm gì, tiếp tục nhận — WaitIPC sẽ được gọi khi queue rỗng
            } else {
                SyscallWaitIPC(); 
            }
        }
    }
    public static void Main() {}
}