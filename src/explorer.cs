using System.Runtime.InteropServices;
namespace NekkoApp;
using static NekkoApp.API;

public static unsafe class Explorer
{
    const uint DESKTOP_COLOR = 0x00008080U; 
    const uint TASKBAR_COLOR = 0x00C0C0C0U;
    const uint START_BTN_COLOR = 0x00C0C0C0U;
    const uint BORDER_LIGHT = 0x00FFFFFFU;  
    const uint BORDER_DARK = 0x00000000U;   
    const uint TEXT_WHITE = 0x00FFFFFFU;
    const uint TEXT_BLACK = 0x00000000U;
    const uint ICON_COLOR = 0x00FFFF00U; // Màu vàng óng ả cho Thư mục/Shortcut

    // ==========================================================
    // VŨ KHÍ VẼ TEXT VÀ HÌNH HỌC (ĐÃ CHUẨN HÓA)
    // ==========================================================
    // ==========================================================
    // [VŨ KHÍ MỚI] BỘ TỪ ĐIỂN FONT CHỮ 8x8 ASCII BỌC THÉP!
    // ==========================================================
    public static ulong GetFontBitmap(char c) {
        switch (c) {
            case 'A': return 0x0042427E42422418; case 'B': return 0x0078444478444478; case 'C': return 0x003C42404040423C; case 'D': return 0x0078444242424478;
            case 'E': return 0x007E40407C40407E; case 'F': return 0x004040407C40407E; case 'G': return 0x003C42424E40423C; case 'H': return 0x004242427E424242;
            case 'I': return 0x003C18181818183C; case 'J': return 0x003048480808081C; case 'K': return 0x0044485060504844; case 'L': return 0x007E404040404040;
            case 'M': return 0x00424242425A6642; case 'N': return 0x004242464A526242; case 'O': return 0x003C42424242423C; case 'P': return 0x004040407C42427C;
            case 'Q': return 0x003A444A4242423C; case 'R': return 0x004448507C42427C; case 'S': return 0x003C42023C40423C; case 'T': return 0x001818181818187E;
            case 'U': return 0x003C424242424242; case 'V': return 0x0018242442424242; case 'W': return 0x0042665A42424242; case 'X': return 0x0042241818182442;
            case 'Y': return 0x0018181818182442; case 'Z': return 0x007E40201008047E; case 'a': return 0x003F423E023C0000; case 'b': return 0x005C6242625C4040;
            case 'c': return 0x003C4240423C0000; case 'd': return 0x003B4642463A0202; case 'e': return 0x003C407E423C0000; case 'f': return 0x001010107C10120C;
            case 'g': return 0x3844023E463A0000; case 'h': return 0x00424242625C4040; case 'i': return 0x0038101010300010; case 'j': return 0x38440404040C0004;
            case 'k': return 0x0044487048444040; case 'l': return 0x000C121010101018; case 'm': return 0x00525252526C0000; case 'n': return 0x00424242625C0000;
            case 'o': return 0x003C4242423C0000; case 'p': return 0x405C6242625C0000; case 'q': return 0x023A4642463A0000; case 'r': return 0x0040404064580000;
            case 's': return 0x003C023C403C0000; case 't': return 0x000C121010103C10; case 'u': return 0x003B464242420000; case 'v': return 0x0018242442420000;
            case 'w': return 0x00245A5A5A420000; case 'x': return 0x0042241824420000; case 'y': return 0x3844023E42420000; case 'z': return 0x007E2010087E0000;
            case '0': return 0x003C4262524A463C; case '1': return 0x003E080808083808; case '2': return 0x007E40300C02423C; case '3': return 0x003C42021C02423C;
            case '4': return 0x0004047E4424140C; case '5': return 0x003C4202027C407E; case '6': return 0x003C42427C40201C; case '7': return 0x001010100804027E;
            case '8': return 0x003C42423C42423C; case '9': return 0x003804023E42423C; case ' ': return 0x0000000000000000; 
            default:  return 0x0000000000000000;
        }
    }

    public static void DrawChar(uint* buffer, ulong scanLine, ulong maxPixels, char c, ulong x, ulong y, uint color) {
        ulong fontData = GetFontBitmap(c);
        for(int row = 0; row < 8; row++) { 
            byte b = (byte)(fontData & 0xFF); 
            fontData >>= 8;
            for(int col = 0; col < 8; col++) { 
                if ((b & (1 << (7 - col))) != 0) { 
                    ulong idx = (y + (ulong)row) * scanLine + (x + (ulong)col); 
                    if (idx < maxPixels) buffer[idx] = color; 
                } 
            } 
        }
    }
    public static void DrawString(uint* buffer, ulong scanLine, ulong maxPixels, char* str, ulong x, ulong y, uint color) {
        ulong currentX = x; while(*str != '\0') { DrawChar(buffer, scanLine, maxPixels, *str, currentX, y, color); currentX += 8; str++; }
    }
    public static void DrawRect(uint* buffer, ulong scanLine, ulong maxPixels, ulong x, ulong y, ulong w, ulong h, uint color) {
        for (ulong row = 0; row < h; row++) { for (ulong col = 0; col < w; col++) { ulong idx = (y + row) * scanLine + (x + col); if (idx < maxPixels) buffer[idx] = color; } }
    }

    public static void DrawStartButton(uint* buffer, ulong scanLine, ulong maxPixels, ulong y, bool isPressed) {
        DrawRect(buffer, scanLine, maxPixels, 2, y + 4, 60, 24, START_BTN_COLOR);
        if (isPressed) { 
            DrawRect(buffer, scanLine, maxPixels, 2, y + 4, 60, 2, BORDER_DARK); DrawRect(buffer, scanLine, maxPixels, 2, y + 4, 2, 24, BORDER_DARK);
            DrawRect(buffer, scanLine, maxPixels, 2, y + 26, 60, 2, BORDER_LIGHT); DrawRect(buffer, scanLine, maxPixels, 60, y + 4, 2, 24, BORDER_LIGHT);
            fixed(char* s = "START\0") DrawString(buffer, scanLine, maxPixels, s, 13, y + 13, TEXT_BLACK); 
        } else { 
            DrawRect(buffer, scanLine, maxPixels, 2, y + 4, 60, 2, BORDER_LIGHT); DrawRect(buffer, scanLine, maxPixels, 2, y + 4, 2, 24, BORDER_LIGHT);
            DrawRect(buffer, scanLine, maxPixels, 2, y + 26, 60, 2, BORDER_DARK); DrawRect(buffer, scanLine, maxPixels, 60, y + 4, 2, 24, BORDER_DARK);
            fixed(char* s = "START\0") DrawString(buffer, scanLine, maxPixels, s, 12, y + 12, TEXT_BLACK);
        }
    }

    // ==========================================================
    // [VŨ KHÍ MỚI] ĐÚC ICON SHORTCUT (HÌNH VUÔNG + TÊN FILE)
    // ==========================================================
    public static void DrawIcon(uint* buffer, ulong scanLine, ulong maxPixels, ulong x, ulong y, char* name) {
        DrawRect(buffer, scanLine, maxPixels, x, y, 32, 32, BORDER_LIGHT);      // Viền ngoài Trắng
        DrawRect(buffer, scanLine, maxPixels, x+2, y+2, 28, 28, ICON_COLOR);    // Ruột Vàng Khè
        
        int nameLen = 0; while(name[nameLen] != '\0') nameLen++;
        ulong textWidth = (ulong)nameLen * 8;
        
        // Tính nhẩm để chữ nằm ngay giữa cái Icon (Icon rộng 32)
        ulong textX = x;
        if (textWidth < 32) textX = x + ((32 - textWidth) / 2);
        else textX = (x + 16 > textWidth / 2) ? x + 16 - (textWidth / 2) : 0; 
        
        DrawString(buffer, scanLine, maxPixels, name, textX, y + 36, TEXT_WHITE);
    }

    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        InitAPI();
        
        int dwmId = -1;
        fixed (char* targetName = "DSRV.EXE\0") { 
            while (dwmId == -1) { dwmId = SyscallGetPIDByName(targetName); if (dwmId == -1) SyscallYieldApp(); } 
        }

        ulong ScreenWidth = 0, ScreenHeight = 0, ScanLine = 0;
        if (SyscallGetScreenInfo(&ScreenWidth, &ScreenHeight, &ScanLine) != 1 || ScreenWidth == 0) SyscallExit();

        ulong targetDwmVAddr = 0;
        ulong myBuffer = SyscallCreateSharedBuffer((uint)dwmId, 2048, &targetDwmVAddr);
        if (myBuffer == 0 || targetDwmVAddr == 0) SyscallExit();

        uint* buffer = (uint*)myBuffer;
        ulong maxPixels = ScanLine * ScreenHeight;
        if (maxPixels > 2000000) maxPixels = 2000000; 

        // 1. Đổ Nền
        uint* dest = buffer; for(ulong i = 0; i < maxPixels; i++) *dest++ = DESKTOP_COLOR;

        // 2. Rải Shortcut Icon
        ulong iconX = 20; ulong startY = 20;
        fixed(char* i1 = "Terminal\0") DrawIcon(buffer, ScanLine, maxPixels, iconX, startY, i1);
        fixed(char* i2 = "NekkoTop\0") DrawIcon(buffer, ScanLine, maxPixels, iconX, startY + 70, i2);
        fixed(char* i3 = "My PC\0")    DrawIcon(buffer, ScanLine, maxPixels, iconX, startY + 140, i3);
        fixed(char* i4 = "Settings\0") DrawIcon(buffer, ScanLine, maxPixels, iconX, startY + 210, i4);

        // 3. Vẽ Taskbar
        ulong taskbarY = ScreenHeight - 32;
        if (ScreenHeight > 40 && ScreenWidth > 100) {
            DrawRect(buffer, ScanLine, maxPixels, 0, taskbarY, ScreenWidth, 32, TASKBAR_COLOR);
            DrawRect(buffer, ScanLine, maxPixels, 0, taskbarY, ScreenWidth, 2, BORDER_LIGHT); 
            DrawStartButton(buffer, ScanLine, maxPixels, taskbarY, false);
        }

        SyscallSendIPC((uint)dwmId, 10, targetDwmVAddr);

        // Biến khóa chống Click liên thanh
        bool iconClicked = false; 

        while (true) {
            Message msg;
            if (SyscallReceiveIPC(&msg) == 1) {
                if (msg.Type == 20) { 
                    ulong clickX = msg.Payload & 0xFFFF; 
                    ulong clickY = (msg.Payload >> 16) & 0xFFFF; 
                    byte isDown = (byte)((msg.Payload >> 32) & 0xFF);
                    
                    if (clickX >= 2 && clickX <= 62 && clickY >= taskbarY + 4 && clickY <= taskbarY + 28) {
                        DrawStartButton(buffer, ScanLine, maxPixels, taskbarY, isDown == 1);
                        SyscallSendIPC((uint)dwmId, 10, targetDwmVAddr); 
                    }
                    
                    if (isDown == 1) 
                    {
                        if (!iconClicked) 
                        {
                            if (clickX >= 20 && clickX <= 52 && clickY >= 20 && clickY <= 52) {
                                fixed(char* cmd = "daemon SHELL.EXE\0") SyscallRunCmd(cmd, 0); // <--- THÊM SỐ 0
                                iconClicked = true;
                            }
                            else if (clickX >= 20 && clickX <= 52 && clickY >= 90 && clickY <= 122) {
                                fixed(char* cmd = "daemon TOP.EXE\0") SyscallRunCmd(cmd, 0); // <--- THÊM SỐ 0
                                iconClicked = true;
                            }
                            else if (clickX >= 20 && clickX <= 52 && clickY >= 160 && clickY <= 192) {
                                fixed(char* cmd = "daemon MYPC.EXE\0") SyscallRunCmd(cmd, 0); // <--- THÊM SỐ 0
                                iconClicked = true;
                            }
                            else if (clickX >= 20 && clickX <= 52 && clickY >= 230 && clickY <= 262) {
                                fixed(char* cmd = "daemon SETTING.EXE\0") SyscallRunCmd(cmd, 0); // <--- THÊM SỐ 0
                                iconClicked = true;
                            }
                        }
                    }
                    else {
                        // Nhả chuột ra thì reset cờ khóa!
                        iconClicked = false;
                    }
                }
            } else { SyscallWaitIPC(); }
        }
    }
    public static void Main() {}
}