// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

// Display server (The Compositor - BỌC THÉP CLIPPING TUYỆT ĐỐI)
using System.Runtime.InteropServices;
namespace NekkoApp;
using static NekkoApp.API;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct WindowHeader {
    public int X; public int Y; 
    public uint Width; public uint Height;
    public fixed byte Title[32]; public fixed byte Padding[208]; 
}

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct Window {
    public uint ID; public uint OwnerPID; public byte IsActive; public byte IsExplorer; public ulong BackingStore; 
}

public static unsafe class DWM
{
    public static uint* Framebuffer; public static uint* Backbuffer;
    public static ulong ScreenWidth; public static ulong ScreenHeight; public static ulong ScanLine;
    public static Window* Windows; 
    public static int mouseX = 0; public static int mouseY = 0; public static byte mouseClicks = 0;
    public static int draggedWindow = -1; public static int dragOffsetX = 0; public static int dragOffsetY = 0;

    const uint TASKBAR_COLOR = 0x00C0C0C0U; const uint TITLE_BAR_COLOR = 0x00000080U; 
    const uint BORDER_LIGHT = 0x00FFFFFFU;  const uint BORDER_DARK = 0x00000000U;   

    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        InitAPI();
        fixed (ulong* pw = &ScreenWidth) fixed (ulong* ph = &ScreenHeight) fixed (ulong* ps = &ScanLine) {
            if (SyscallGetScreenInfo(pw, ph, ps) != 1 || ScreenWidth == 0) SyscallExit();
        }

        ulong fbVirt = SyscallRequestFramebuffer(); if (fbVirt == 0) SyscallExit(); Framebuffer = (uint*)fbVirt;
        Backbuffer = (uint*)SyscallAllocMem(((ScanLine * ScreenHeight * 4) + 4095) / 4096);
        Windows = (Window*)SyscallAllocMem(1); for(int i = 0; i < 32; i++) Windows[i].IsActive = 0;

        mouseX = (int)(ScreenWidth / 2); mouseY = (int)(ScreenHeight / 2);
        Message rMsg; while (SyscallReceiveIPC(&rMsg) == 1) { } 

        while (true) {
            Message msg;
            if (SyscallReceiveIPC(&msg) == 1) {
                if (msg.Type == 3) {
                    ulong payload = msg.Payload; short dy = (short)(payload & 0xFFFF); short dx = (short)((payload >> 16) & 0xFFFF);
                    byte oldClicks = mouseClicks; mouseClicks = (byte)((payload >> 32) & 0xFF);
                    int oldX = mouseX; int oldY = mouseY;
                    mouseX += dx; mouseY += dy;
                    if (mouseX < 0) mouseX = 0; if (mouseX > (int)ScreenWidth - 5) mouseX = (int)ScreenWidth - 5;
                    if (mouseY < 0) mouseY = 0; if (mouseY > (int)ScreenHeight - 5) mouseY = (int)ScreenHeight - 5; 

                    RestoreMouseRect(oldX, oldY);

                    bool isDown = (mouseClicks & 1) != 0; bool wasDown = (oldClicks & 1) != 0;
                    if (isDown && !wasDown) {
                        for (int i = 31; i >= 1; i--) {
                            if (Windows[i].IsActive != 0) {
                                WindowHeader* header = (WindowHeader*)Windows[i].BackingStore;
                                int wx = header->X; int wy = header->Y; int ww = (int)header->Width; int wh = (int)header->Height;
                                int btnX = wx + ww - 24; int btnY = wy - 20;

                                if (mouseX >= btnX && mouseX <= btnX + 18 && mouseY >= btnY && mouseY <= btnY + 18) {
                                    SyscallSendIPC(Windows[i].OwnerPID, 0xDEAD, 0); 
                                    Windows[i].IsActive = 0; RenderFullFrame(); break; 
                                }
                                else if (mouseX >= wx - 4 && mouseX <= wx + ww + 4 && mouseY >= wy - 26 && mouseY <= wy) {
                                    draggedWindow = i; dragOffsetX = mouseX - wx; dragOffsetY = mouseY - wy;
                                    int topSlot = i; for(int j = i + 1; j < 32; j++) { if (Windows[j].IsActive != 0) topSlot = j; }
                                    if (topSlot != i) { Window temp = Windows[i]; Windows[i] = Windows[topSlot]; Windows[topSlot] = temp; draggedWindow = topSlot; }
                                    RenderFullFrame(); break;
                                }
                            }
                        }
                    }
                    else if (!isDown && wasDown) { draggedWindow = -1; }
                    else if (isDown && draggedWindow != -1) {
                        WindowHeader* header = (WindowHeader*)Windows[draggedWindow].BackingStore;
                        header->X = mouseX - dragOffsetX; header->Y = mouseY - dragOffsetY;
                        RenderFullFrame(); 
                    }

                    uint cursorColor = (mouseClicks & 1) != 0 ? 0x00FF0000U : 0x00FFFFFFU; 
                    DrawCrosshairDirect(mouseX, mouseY, cursorColor);
                    if (oldClicks != mouseClicks && Windows[0].IsActive != 0) {
                        SyscallSendIPC(Windows[0].OwnerPID, 20, ((ulong)mouseClicks << 32) | ((ulong)mouseY << 16) | (ulong)mouseX); 
                    }
                }
                else if (msg.Type == 10) { Windows[0].OwnerPID = msg.Sender; Windows[0].BackingStore = msg.Payload; Windows[0].IsActive = 1; RenderFullFrame(); }
                else if (msg.Type == 11) {
                    int slot = -1; for(int i = 1; i < 32; i++) { if (Windows[i].IsActive != 0 && Windows[i].OwnerPID == msg.Sender) { slot = i; break; } }
                    if (slot == -1) { for(int i = 1; i < 32; i++) { if (Windows[i].IsActive == 0) { slot = i; break; } } }
                    if (slot != -1) { Windows[slot].OwnerPID = msg.Sender; Windows[slot].BackingStore = msg.Payload; Windows[slot].IsActive = 1; RenderFullFrame(); }
                }
            } else { SyscallWaitIPC(); }
        }
    }

    public static void RenderFullFrame() {
        if (Windows[0].IsActive != 0) {
            ulong* finalDst = (ulong*)Backbuffer; ulong* finalSrc = (ulong*)Windows[0].BackingStore;
            ulong maxF = (ScanLine * ScreenHeight) / 2; ulong blks = maxF / 8; ulong r = maxF % 8;
            while(blks-- > 0) { *finalDst++ = *finalSrc++; *finalDst++ = *finalSrc++; *finalDst++ = *finalSrc++; *finalDst++ = *finalSrc++; *finalDst++ = *finalSrc++; *finalDst++ = *finalSrc++; *finalDst++ = *finalSrc++; *finalDst++ = *finalSrc++; }
            while(r-- > 0) { *finalDst++ = *finalSrc++; }
        }

        for(int i = 1; i < 32; i++) {
            if (Windows[i].IsActive != 0) {
                WindowHeader* header = (WindowHeader*)Windows[i].BackingStore;
                uint* appPixels = (uint*)(Windows[i].BackingStore + 256); 
                int w = (int)header->Width; int h = (int)header->Height; int x = header->X; int y = header->Y;

                DrawRectBackbuffer(x - 4, y - 26, w + 8, h + 30, TASKBAR_COLOR); 
                DrawRectBackbuffer(x - 4, y - 26, w + 8, 2, BORDER_LIGHT); DrawRectBackbuffer(x - 4, y - 26, 2, h + 30, BORDER_LIGHT);
                DrawRectBackbuffer(x - 4, y + h + 2, w + 8, 2, BORDER_DARK); DrawRectBackbuffer(x + w + 2, y - 26, 2, h + 30, BORDER_DARK);
                DrawRectBackbuffer(x, y - 22, w, 20, TITLE_BAR_COLOR); 
                DrawStringBackbuffer(header->Title, x + 4, y - 16, 0x00FFFFFFU); 

                // ==========================================================
                // THUẬT TOÁN CLIPPING BỌC THÉP NGUYÊN TỬ!!!
                // ==========================================================
                int startX = x; int startY = y; int endX = x + w; int endY = y + h;
                
                // Nếu cửa sổ bay mẹ ra khỏi màn hình thì ĐÉO VẼ GÌ HẾT!
                if (startX >= (int)ScreenWidth || startY >= (int)ScreenHeight || endX <= 0 || endY <= 0) continue;

                int srcXOffset = 0; int srcYOffset = 0;
                if (startX < 0) { srcXOffset = -startX; startX = 0; }
                if (startY < 0) { srcYOffset = -startY; startY = 0; }
                
                // Ép kiểu ScreenWidth về (int) để so sánh CHUẨN SỐ CÓ DẤU!
                if (endX > (int)ScreenWidth) endX = (int)ScreenWidth;
                if (endY > (int)ScreenHeight) endY = (int)ScreenHeight;

                int copyW = endX - startX;
                if (copyW <= 0) continue; // Chặn đứng mọi trường hợp âm

                for(int row = startY; row < endY; row++) {
                    uint* dest = Backbuffer + ((ulong)row * ScanLine + (ulong)startX); 
                    uint* src = appPixels + ((ulong)(srcYOffset + (row - startY)) * (ulong)w + (ulong)srcXOffset);
                    for(int col = 0; col < copyW; col++) *dest++ = *src++;
                }
            }
        }
        
        ulong* d = (ulong*)Framebuffer; ulong* s = (ulong*)Backbuffer; ulong maxFast = (ScanLine * ScreenHeight) / 2; 
        ulong blocks = maxFast / 8; ulong rem = maxFast % 8;
        while(blocks-- > 0) { *d++ = *s++; *d++ = *s++; *d++ = *s++; *d++ = *s++; *d++ = *s++; *d++ = *s++; *d++ = *s++; *d++ = *s++; }
        while(rem-- > 0) { *d++ = *s++; }
        DrawCrosshairDirect(mouseX, mouseY, (mouseClicks & 1) != 0 ? 0x00FF0000U : 0x00FFFFFFU);
    }

    public static void RestoreMouseRect(int cx, int cy) {
        int startX = cx - 10; int startY = cy - 10; int endX = cx + 10; int endY = cy + 10;
        if (startX < 0) startX = 0; if (startY < 0) startY = 0;
        
        // FIX TƯƠNG TỰ CHO CHUỘT
        if (endX > (int)ScreenWidth) endX = (int)ScreenWidth; 
        if (endY > (int)ScreenHeight) endY = (int)ScreenHeight;
        
        if (endX <= startX || endY <= startY) return;

        for (int y = startY; y < endY; y++) {
            ulong offset = (ulong)y * ScanLine + (ulong)startX;
            uint* dst = Framebuffer + offset; uint* src = Backbuffer + offset;
            int widthToCopy = endX - startX; for(int x = 0; x < widthToCopy; x++) { *dst++ = *src++; }
        }
    }

// ==========================================================
    // [VŨ KHÍ MỚI] DRAW RECT DIRECT - BỌC THÉP VỚI SỐ CÓ DẤU (INT)
    // ==========================================================
    public static void DrawRectDirect(int x, int y, int width, int height, uint color) {
        int startX = x; int startY = y; int endX = x + width; int endY = y + height;
        
        // Clipping siêu an toàn
        if (startX < 0) startX = 0; 
        if (startY < 0) startY = 0; 
        if (endX > (int)ScreenWidth) endX = (int)ScreenWidth; 
        if (endY > (int)ScreenHeight) endY = (int)ScreenHeight;
        
        if (endX <= startX || endY <= startY) return;

        int w = endX - startX;
        for (int r = startY; r < endY; r++) { 
            uint* dest = Framebuffer + ((ulong)r * ScanLine + (ulong)startX); 
            for(int c = 0; c < w; c++) *dest++ = color; 
        }
    }

    // ==========================================================
    // [VŨ KHÍ MỚI] DRAW CROSSHAIR - TRUYỀN VÀO SỐ INT!
    // ==========================================================
    public static void DrawCrosshairDirect(int cx, int cy, uint color) { 
        DrawRectDirect(cx - 10, cy - 1, 20, 3, color); 
        DrawRectDirect(cx - 1, cy - 10, 3, 20, color); 
    }

    public static ulong GetFontBitmap(char c) {
        switch (c) {
            case 'A': return 0x0042427E42422418; case 'B': return 0x0078444478444478; case 'C': return 0x003C42404040423C; case 'D': return 0x0078444242424478; case 'E': return 0x007E40407C40407E; case 'F': return 0x004040407C40407E; case 'G': return 0x003C42424E40423C; case 'H': return 0x004242427E424242; case 'I': return 0x003C18181818183C; case 'J': return 0x003048480808081C; case 'K': return 0x0044485060504844; case 'L': return 0x007E404040404040; case 'M': return 0x00424242425A6642; case 'N': return 0x004242464A526242; case 'O': return 0x003C42424242423C; case 'P': return 0x004040407C42427C; case 'Q': return 0x003A444A4242423C; case 'R': return 0x004448507C42427C; case 'S': return 0x003C42023C40423C; case 'T': return 0x001818181818187E; case 'U': return 0x003C424242424242; case 'V': return 0x0018242442424242; case 'W': return 0x0042665A42424242; case 'X': return 0x0042241818182442; case 'Y': return 0x0018181818182442; case 'Z': return 0x007E40201008047E; case 'a': return 0x003F423E023C0000; case 'b': return 0x005C6242625C4040; case 'c': return 0x003C4240423C0000; case 'd': return 0x003B4642463A0202; case 'e': return 0x003C407E423C0000; case 'f': return 0x001010107C10120C; case 'g': return 0x3844023E463A0000; case 'h': return 0x00424242625C4040; case 'i': return 0x0038101010300010; case 'j': return 0x38440404040C0004; case 'k': return 0x0044487048444040; case 'l': return 0x000C121010101018; case 'm': return 0x00525252526C0000; case 'n': return 0x00424242625C0000; case 'o': return 0x003C4242423C0000; case 'p': return 0x405C6242625C0000; case 'q': return 0x023A4642463A0000; case 'r': return 0x0040404064580000; case 's': return 0x003C023C403C0000; case 't': return 0x000C121010103C10; case 'u': return 0x003B464242420000; case 'v': return 0x0018242442420000; case 'w': return 0x00245A5A5A420000; case 'x': return 0x0042241824420000; case 'y': return 0x3844023E42420000; case 'z': return 0x007E2010087E0000; case '0': return 0x003C4262524A463C; case '1': return 0x003E080808083808; case '2': return 0x007E40300C02423C; case '3': return 0x003C42021C02423C; case '4': return 0x0004047E4424140C; case '5': return 0x003C4202027C407E; case '6': return 0x003C42427C40201C; case '7': return 0x001010100804027E; case '8': return 0x003C42423C42423C; case '9': return 0x003804023E42423C; case '!': return 0x0018001818181818; case '@': return 0x003C425A56524C38; case '#': return 0x00247E24247E2400; case '$': return 0x00183E083E143E18; case '%': return 0x0046261008646200; case '^': return 0x0000000042241800; case '&': return 0x003A443A14281020; case '*': return 0x0000663CFF3C6600; case '(': return 0x0008102020100800; case ')': return 0x0010080404081000; case '-': return 0x000000007E000000; case '_': return 0x007E000000000000; case '=': return 0x0000007E007E0000; case '+': return 0x000018187E181800; case '[': return 0x003C202020203C00; case ']': return 0x003C040404043C00; case '{': return 0x000E1030100E0000; case '}': return 0x0070080C08700000; case '\\':return 0x0004081020400000; case '|': return 0x0018181818181800; case ';': return 0x2010100010100000; case ':': return 0x0000101000101000; case '\'':return 0x0000000000081030; case '"': return 0x0000000000242466; case ',': return 0x2010100000000000; case '<': return 0x0008102040201008; case '.': return 0x0000101000000000; case '>': return 0x0010080402040810; case '/': return 0x0040201008040000; case '?': return 0x0018001804443800; case '`': return 0x0000000000201008; case '~': return 0x00000000324C0000; case ' ': return 0x0000000000000000; default:  return 0x0000000000000000;
        }
    }
    
    public static void DrawCharBackbuffer(char c, int x, int y, uint color) {
        ulong fontData = GetFontBitmap(c); 
        for(int row = 0; row < 8; row++) { byte b = (byte)(fontData & 0xFF); fontData >>= 8; 
            for(int col = 0; col < 8; col++) { if ((b & (1 << (7 - col))) != 0) { 
                int px = x + col; int py = y + row; 
                // FIX TƯƠNG TỰ CHO VẼ TEXT!
                if (px >= 0 && px < (int)ScreenWidth && py >= 0 && py < (int)ScreenHeight) Backbuffer[(ulong)py * ScanLine + (ulong)px] = color; } } }
    }
    public static void DrawStringBackbuffer(byte* str, int x, int y, uint color) { int cx = x; while(*str != 0) { DrawCharBackbuffer((char)*str, cx, y, color); cx += 8; str++; } }
    
    public static void DrawRectBackbuffer(int x, int y, int width, int height, uint color) {
        int startX = x; int startY = y; int endX = x + width; int endY = y + height;
        if (startX < 0) startX = 0; if (startY < 0) startY = 0; 
        
        // FIX TƯƠNG TỰ CHO VẼ RECT!
        if (endX > (int)ScreenWidth) endX = (int)ScreenWidth; 
        if (endY > (int)ScreenHeight) endY = (int)ScreenHeight;
        if (endX <= startX || endY <= startY) return;

        for (int r = startY; r < endY; r++) { uint* dest = Backbuffer + ((ulong)r * ScanLine + (ulong)startX); int w = endX - startX; for(int c = 0; c < w; c++) *dest++ = color; }
    }
    public static void Main() {}
}