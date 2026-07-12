// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

public static unsafe class Terminal
{
    [DllImport("*", EntryPoint = "GetRflags")] public static extern ulong GetRflags();

    public static uint* fb;
    public static uint* backbuffer;
    public static uint scanLine;
    public static uint width;
    public static uint height;

    private static uint cursorX = 0;
    private static uint cursorY = 0;
    // [FIX MÀU CHỮ] bootColor chỉ dùng làm fallback cho các dòng log CỰC SỚM lúc
    // Scheduler chưa sẵn sàng (trước khi có CurrentThreadId hợp lệ) - còn lại mỗi
    // tiến trình tự giữ màu chữ RIÊNG trong Scheduler.Threads[id].TextColor, tránh
    // đụng độ khi nhiều luồng/core in màn hình song song.
    private static uint bootColor = 0x00FFFFFF;
    private static uint bgColor = 0x00000000;

    private static uint fgColor {
        get {
            if (!Scheduler.Ready || Scheduler.CurrentThreadIds == null) return bootColor;
            int cur = Scheduler.CurrentThreadId;
            if (cur < 0 || cur >= Scheduler.ThreadCount) return bootColor;
            return Scheduler.Threads[cur].TextColor;
        }
        set {
            if (!Scheduler.Ready || Scheduler.CurrentThreadIds == null) { bootColor = value; return; }
            int cur = Scheduler.CurrentThreadId;
            if (cur < 0 || cur >= Scheduler.ThreadCount) { bootColor = value; return; }
            Scheduler.Threads[cur].TextColor = value;
        }
    }

    private const int SCALE = 2;
    public const int CHAR_WIDTH = 8 * SCALE;
    public const int CHAR_HEIGHT = 8 * SCALE;
    private const int LINE_SPACING = 2 * SCALE; 

    public static uint CursorX { get { bool irq = ScreenLock.AcquireSafe(); uint val = cursorX; ScreenLock.ReleaseSafe(irq); return val; } set { bool irq = ScreenLock.AcquireSafe(); cursorX = value; ScreenLock.ReleaseSafe(irq); } }
    public static uint CursorY { get { bool irq = ScreenLock.AcquireSafe(); uint val = cursorY; ScreenLock.ReleaseSafe(irq); return val; } set { bool irq = ScreenLock.AcquireSafe(); cursorY = value; ScreenLock.ReleaseSafe(irq); } }
    public static uint CurrentColor { get => fgColor; set => fgColor = value; }

    public static class ScreenLock
    {
        private static Spinlock rawLock = new Spinlock();
        private static uint lockOwnerCore = 0xFFFFFFFF; 
        private static int lockDepth = 0;
        private static bool lastIrq = false;

        public static bool AcquireSafe() {
            bool irq = false;
            if (Scheduler.Ready) irq = (GetRflags() & 0x200) != 0;
            IO.Cli(); 
            uint coreId = 0;
            if (APIC.IsAwake) coreId = APIC.Read(0x020) >> 24;

            if (lockOwnerCore == coreId) {
                lockDepth++;
                return irq;
            }

            rawLock.Acquire(); 
            lastIrq = irq;
            lockOwnerCore = coreId;
            lockDepth = 1;
            return irq;
        }

        public static void ReleaseSafe(bool irq) {
            uint coreId = 0;
            if (APIC.IsAwake) coreId = APIC.Read(0x020) >> 24;

            if (lockOwnerCore == coreId) {
                lockDepth--;
                if (lockDepth <= 0) {
                    lockOwnerCore = 0xFFFFFFFF;
                    lockDepth = 0;
                    rawLock.Release();
                    if (lastIrq) IO.EnableInterrupts(); 
                }
            } else {
                lockOwnerCore = 0xFFFFFFFF;
                lockDepth = 0;
                rawLock.Release();
                if (lastIrq) IO.EnableInterrupts();
            }
        }
        
        public static void Acquire() { AcquireSafe(); }
        public static void Release() { ReleaseSafe(lastIrq); }
    }

    public static unsafe void PrintObfuscated(byte* encryptedBytes, int length)
    {
        bool irq = ScreenLock.AcquireSafe(); 
        // Kiểm tra xem encryptedBytes có null không
        if (encryptedBytes == null) {
            ScreenLock.ReleaseSafe(irq);
            return;
        }
        
        if (length > 255) { ScreenLock.ReleaseSafe(irq); return; }
        char* buffer = stackalloc char[256]; 
        for (int i = 0; i < length; i++) {
            byte dynamicKey = (byte)((i * 13) + 7);
            buffer[i] = (char)(encryptedBytes[i] ^ dynamicKey);
        }
        buffer[length] = '\0'; 
        PrintUnsafe(buffer); 
        ScreenLock.ReleaseSafe(irq);
    }

    private static ulong GetFontBitmap(char c)
    {
        // Kiểm tra xem c có nằm trong phạm vi hợp lệ không
        if (c < 0x20 || c > 0x7E) {
            return 0x0000000000000000; // Trả về bitmap rỗng cho ký tự không hợp lệ
        }

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
            case '8': return 0x003C42423C42423C; case '9': return 0x003804023E42423C; case '!': return 0x0018001818181818; case '@': return 0x003C425A56524C38;
            case '#': return 0x00247E24247E2400; case '$': return 0x00183E083E143E18; case '%': return 0x0046261008646200; case '^': return 0x0000000042241800;
            case '&': return 0x003A443A14281020; case '*': return 0x0000663CFF3C6600; case '(': return 0x0008102020100800; case ')': return 0x0010080404081000;
            case '-': return 0x000000007E000000; case '_': return 0x007E000000000000; case '=': return 0x0000007E007E0000; case '+': return 0x000018187E181800;
            case '[': return 0x003C202020203C00; case ']': return 0x003C040404043C00; case '{': return 0x000E1030100E0000; case '}': return 0x0070080C08700000;
            case '\\':return 0x0004081020400000; case '|': return 0x0018181818181800; case ';': return 0x2010100010100000; case ':': return 0x0000101000101000;
            case '\'':return 0x0000000000081030; case '"': return 0x0000000000242466; case ',': return 0x2010100000000000; case '<': return 0x0008102040201008;
            case '.': return 0x0000101000000000; case '>': return 0x0010080402040810; case '/': return 0x0040201008040000; case '?': return 0x0018001804443800;
            case '`': return 0x0000000000201008; case '~': return 0x00000000324C0000; case ' ': return 0x0000000000000000; default:  return 0x0000000000000000;
        }
    }

    public static void Init(NekkoBootInfo* bootInfo) {
        fb = (uint *)bootInfo->FrameBufferBase; scanLine = bootInfo->PixelsPerScanLine;
        width = bootInfo->HorizontalResolution; height = bootInfo->VerticalResolution;
        backbuffer = null; 
        ClearUnsafe(0x00111111);
    }

    public static void EnableShadowBuffer() {
        bool irq = ScreenLock.AcquireSafe(); 
        ulong bufferBytes = (ulong)scanLine * (ulong)height * 4UL; 
        ulong numPages = (bufferBytes + 4095UL) / 4096UL;
        backbuffer = (uint*)PMM.AllocateContiguousPages(numPages);
        if (backbuffer == null) {
            ScreenLock.ReleaseSafe(irq); SetColor(0x00FF0000);
            fixed (char* err = "[!] Terminal: Out of Contiguous RAM! Shadow Buffer failed!\n\0") Print(err);
            return;
        }
        LibC.MemCpy(backbuffer, fb, (uint)bufferBytes); ScreenLock.ReleaseSafe(irq);
        SetColor(0x0000FF00);
        fixed (char* msg = "[+] Terminal Shadow Buffer Activated!\n\0") Print(msg);
    }

    public static void SyncRect(uint startX, uint startY, uint rectWidth, uint rectHeight) {
        if (backbuffer == null) return;
        for (uint y = 0; y < rectHeight; y++) {
            uint drawY = startY + y; if (drawY >= height) break;
            uint* dest = fb + (drawY * scanLine + startX); uint* src = backbuffer + (drawY * scanLine + startX);
            LibC.MemCpy(dest, src, rectWidth * 4); 
        }
    }

    public static void ClearUnsafe(uint color) {
        bgColor = color; ulong totalPixels = (ulong)scanLine * (ulong)height;
        if (backbuffer != null) {
            for (ulong i = 0; i < totalPixels; i++) backbuffer[i] = color; 
            LibC.MemCpy(fb, backbuffer, (uint)(totalPixels * 4));
        } else {
            for (ulong i = 0; i < totalPixels; i++) fb[i] = color;
        }
        cursorX = 0; cursorY = 0; 
    }

    public static void Clear(uint color) {
        bool irq = ScreenLock.AcquireSafe(); 
        ClearUnsafe(color);
        ScreenLock.ReleaseSafe(irq);
    }

    public static void SetColor(uint fg) => fgColor = fg;

    // ==========================================================
    // [VŨ KHÍ MỚI] CUỘN MÀN HÌNH NHƯ LINUX TTY!
    // Bất kể có Shadow Buffer hay không, cày nát pixel ném lên trên!
    // ==========================================================
    // ==========================================================
    // [VŨ KHÍ MỚI] SCROLL THÔ BẠO BẰNG SỨC NGƯỜI CHỐNG OVERLAPPING!
    // Trượt ván toàn bộ Pixel lên 1 dòng, bất chấp có Shadow Buffer hay không!
    // ==========================================================
    private static void Scroll()
    {
        uint lineHeight = CHAR_HEIGHT + LINE_SPACING;
        uint movePixels = scanLine * (height - lineHeight); // Số lượng Pixel cần giữ lại
        uint rowPixels = scanLine * lineHeight;             // Số lượng Pixel của 1 dòng

        uint* dest = backbuffer != null ? backbuffer : fb;

        // 1. Tự tay bốc vác từng Pixel đẩy lên trên để chống Overlapping 100%!
        for (uint i = 0; i < movePixels; i++) {
            dest[i] = dest[i + rowPixels];
        }

        // 2. Tẩy đen dòng cuối cùng (Dọn chỗ cho chữ mới chui vào)
        for (uint i = movePixels; i < movePixels + rowPixels; i++) {
            dest[i] = bgColor;
        }

        // 3. Nếu xài Shadow Buffer thì đập nguyên khung hình ra màn hình thật
        if (backbuffer != null) {
            LibC.MemCpy((byte*)fb, (byte*)backbuffer, scanLine * height * 4);
        }

        // 4. Kéo con trỏ Y lùi lên đúng 1 dòng!
        cursorY -= lineHeight; 
    }

    public static void DrawCharUnsafe(char c, bool toSerial = true) {
        if (toSerial) {
            if (c == '\n') Serial.WriteChar('\r'); 
            Serial.WriteChar(c);                   
        }

        uint lineHeight = CHAR_HEIGHT + LINE_SPACING;

        if (c == '\n') { 
            cursorX = 0; 
            cursorY += lineHeight; 
        }
        else if (c == '\r') {
            cursorX = 0;
        }
        else if (c == '\b') {
            if (cursorX >= CHAR_WIDTH) cursorX -= CHAR_WIDTH;
            else if (cursorY >= lineHeight) { cursorY -= lineHeight; cursorX = (width / CHAR_WIDTH) * CHAR_WIDTH - CHAR_WIDTH; }
            
            // Tẩy pixel của ký tự vừa bị Backspace
            for (int y = 0; y < CHAR_HEIGHT; y++) {
                for (int x = 0; x < CHAR_WIDTH; x++) {
                    uint idx = (cursorY + (uint)y) * scanLine + (cursorX + (uint)x);
                    if (backbuffer != null) backbuffer[idx] = bgColor; else fb[idx] = bgColor;
                }
            }
            SyncRect(cursorX, cursorY, CHAR_WIDTH, CHAR_HEIGHT);
        }
        else {
            ulong bitmap = GetFontBitmap(c);
            for (int row = 0; row < 8; row++) {
                byte rowData = (byte)((bitmap >> (row * 8)) & 0xFF);
                for (int col = 0; col < 8; col++) {
                    if (((rowData >> (7 - col)) & 1) == 1) {
                        for (int sy = 0; sy < SCALE; sy++) {
                            for (int sx = 0; sx < SCALE; sx++) {
                                uint drawX = cursorX + (uint)(col * SCALE + sx); uint drawY = cursorY + (uint)(row * SCALE + sy);
                                if (drawX < width && drawY < height) {
                                    uint idx = drawY * scanLine + drawX;
                                    if (backbuffer != null) backbuffer[idx] = fgColor; else fb[idx] = fgColor; 
                                }
                            }
                        }
                    } else {
                        for (int sy = 0; sy < SCALE; sy++) {
                            for (int sx = 0; sx < SCALE; sx++) {
                                uint drawX = cursorX + (uint)(col * SCALE + sx); uint drawY = cursorY + (uint)(row * SCALE + sy);
                                if (drawX < width && drawY < height) {
                                    uint idx = drawY * scanLine + drawX;
                                    if (backbuffer != null) backbuffer[idx] = bgColor; else fb[idx] = bgColor; 
                                }
                            }
                        }
                    }
                }
            }
            SyncRect(cursorX, cursorY, CHAR_WIDTH, CHAR_HEIGHT);
            
            cursorX += CHAR_WIDTH;
            if (cursorX + CHAR_WIDTH > width) { 
                cursorX = 0; 
                cursorY += lineHeight; 
            }
        }

        // [BỨC TƯỜNG CUỘN] Hễ Y vượt giới hạn thì Cuộn cmn lên!
        if (cursorY + lineHeight > height) {
            Scroll();
        }
    }

    public static void DrawChar(char c) {
        bool irq = ScreenLock.AcquireSafe(); DrawCharUnsafe(c); ScreenLock.ReleaseSafe(irq);
    }

    public static void Print(char* str) {
        bool irq = ScreenLock.AcquireSafe(); PrintUnsafe(str); ScreenLock.ReleaseSafe(irq);
    }

    public static void PrintUnsafe(char* str) {
        int i = 0; while (str[i] != '\0') { DrawCharUnsafe(str[i]); i++; }
    }

    public static void PrintHex(ulong val) {
        bool irq = ScreenLock.AcquireSafe(); 
        char* hexChars = stackalloc char[] { '0','1','2','3','4','5','6','7','8','9','A','B','C','D','E','F' };
        char* buffer = stackalloc char[19]; buffer[0] = '0'; buffer[1] = 'x'; buffer[18] = '\0';
        for (int i = 0; i < 16; i++) { buffer[17 - i] = hexChars[(val >> (i * 4)) & 0xF]; }
        PrintUnsafe(buffer); ScreenLock.ReleaseSafe(irq);
    }

    public static void PrintDec(ulong val) {
        bool irq = ScreenLock.AcquireSafe(); 
        if (val == 0) { fixed (char* z = "0\0") PrintUnsafe(z); ScreenLock.ReleaseSafe(irq); return; }
        char* buffer = stackalloc char[21]; int pos = 20; buffer[pos] = '\0';
        while (val > 0) { pos--; buffer[pos] = (char)('0' + (val % 10)); val /= 10; }
        PrintUnsafe(buffer + pos); ScreenLock.ReleaseSafe(irq);
    }

    public static void RedirectOutput(uint* newFb, uint newWidth, uint newHeight, uint newScanLine) {
        bool irq = ScreenLock.AcquireSafe();
        // Kiểm tra xem các tham số có hợp lệ không
        if (newFb == null || newWidth == 0 || newHeight == 0 || newScanLine == 0) {
            ScreenLock.ReleaseSafe(irq);
            return;
        }
        
        // Kiểm tra xem newFb có được căn chỉnh đúng không
        if (((ulong)newFb & 0x7) != 0) {
            ScreenLock.ReleaseSafe(irq);
            return;
        }
        fb = newFb;
        width = newWidth;
        height = newHeight;
        scanLine = newScanLine;
        backbuffer = null; 
        cursorX = 0; 
        cursorY = 0;
        ClearUnsafe(0x00000000); 
        ScreenLock.ReleaseSafe(irq);
    }
}