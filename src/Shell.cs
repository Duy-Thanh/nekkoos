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

// ==========================================================
// [VÃ CỤC NÀY VÀO ĐÂY ĐẠI CA!!!] BẢN VẼ HEADER CHO DWM
// ==========================================================
[StructLayout(LayoutKind.Sequential, Pack = 1)]
public unsafe struct WindowHeader {
    public uint X;
    public uint Y;
    public uint Width;
    public uint Height;
    public fixed byte Title[32];
    public fixed byte Padding[208]; 
}

public unsafe class Shell
{
    // [DllImport("*", EntryPoint = "ShellPrint")] public static extern void ShellPrint(char* msg);
    // [DllImport("*", EntryPoint = "SyscallGetChar")] public static extern byte SyscallGetChar();
    // [DllImport("*", EntryPoint = "SyscallGetSharedMem")] public static extern ulong SyscallGetSharedMem();
    // [DllImport("*", EntryPoint = "SyscallRunCmd")] public static extern void SyscallRunCmd(char* cmdPtr);
    // [DllImport("*", EntryPoint = "SyscallSendIPC")] public static extern void SyscallSendIPC(uint receiver, uint type, ulong payload);
    // [DllImport("*", EntryPoint = "SyscallReceiveIPC")] public static extern int SyscallReceiveIPC(Message* outMsg);
    // [DllImport("*", EntryPoint = "SyscallExit")] public static extern void SyscallExit();
    // [DllImport("*", EntryPoint = "SyscallGetUID")] public static extern uint SyscallGetUID();
    // [DllImport("*", EntryPoint = "SyscallYield")] public static extern void SyscallYield();
    // [DllImport("*", EntryPoint = "SyscallWaitIPC")] public static extern void SyscallWaitIPC();
    
    // [DllImport("*", EntryPoint = "SyscallGetPIDByName")] public static extern int SyscallGetPIDByName(char* name);
    
    public static uint FAT16_PID = 0; public static int DWM_PID = -1; public static ulong GuiVAddr = 0;
    
    // BỘ NHỚ CỦA TERMINAL ẢO
    public static uint* GuiPixels = null; public static int GuiWidth = 640; public static int GuiHeight = 400;
    public static int GuiCursorX = 0; public static int GuiCursorY = 0;

    public static void SyscallYieldApp() { SyscallYield(); }

    // ==========================================================
    // BỘ TỪ ĐIỂN FONT CỤC BỘ DÀNH RIÊNG CHO SHELL
    // ==========================================================
    public static ulong GetFontBitmap(char c) {
        switch (c) {
            case 'A': return 0x0042427E42422418; case 'B': return 0x0078444478444478; case 'C': return 0x003C42404040423C; case 'D': return 0x0078444242424478; case 'E': return 0x007E40407C40407E; case 'F': return 0x004040407C40407E; case 'G': return 0x003C42424E40423C; case 'H': return 0x004242427E424242; case 'I': return 0x003C18181818183C; case 'J': return 0x003048480808081C; case 'K': return 0x0044485060504844; case 'L': return 0x007E404040404040; case 'M': return 0x00424242425A6642; case 'N': return 0x004242464A526242; case 'O': return 0x003C42424242423C; case 'P': return 0x004040407C42427C; case 'Q': return 0x003A444A4242423C; case 'R': return 0x004448507C42427C; case 'S': return 0x003C42023C40423C; case 'T': return 0x001818181818187E; case 'U': return 0x003C424242424242; case 'V': return 0x0018242442424242; case 'W': return 0x0042665A42424242; case 'X': return 0x0042241818182442; case 'Y': return 0x0018181818182442; case 'Z': return 0x007E40201008047E; case 'a': return 0x003F423E023C0000; case 'b': return 0x005C6242625C4040; case 'c': return 0x003C4240423C0000; case 'd': return 0x003B4642463A0202; case 'e': return 0x003C407E423C0000; case 'f': return 0x001010107C10120C; case 'g': return 0x3844023E463A0000; case 'h': return 0x00424242625C4040; case 'i': return 0x0038101010300010; case 'j': return 0x38440404040C0004; case 'k': return 0x0044487048444040; case 'l': return 0x000C121010101018; case 'm': return 0x00525252526C0000; case 'n': return 0x00424242625C0000; case 'o': return 0x003C4242423C0000; case 'p': return 0x405C6242625C0000; case 'q': return 0x023A4642463A0000; case 'r': return 0x0040404064580000; case 's': return 0x003C023C403C0000; case 't': return 0x000C121010103C10; case 'u': return 0x003B464242420000; case 'v': return 0x0018242442420000; case 'w': return 0x00245A5A5A420000; case 'x': return 0x0042241824420000; case 'y': return 0x3844023E42420000; case 'z': return 0x007E2010087E0000; case '0': return 0x003C4262524A463C; case '1': return 0x003E080808083808; case '2': return 0x007E40300C02423C; case '3': return 0x003C42021C02423C; case '4': return 0x0004047E4424140C; case '5': return 0x003C4202027C407E; case '6': return 0x003C42427C40201C; case '7': return 0x001010100804027E; case '8': return 0x003C42423C42423C; case '9': return 0x003804023E42423C; case '!': return 0x0018001818181818; case '@': return 0x003C425A56524C38; case '#': return 0x00247E24247E2400; case '$': return 0x00183E083E143E18; case '%': return 0x0046261008646200; case '^': return 0x0000000042241800; case '&': return 0x003A443A14281020; case '*': return 0x0000663CFF3C6600; case '(': return 0x0008102020100800; case ')': return 0x0010080404081000; case '-': return 0x000000007E000000; case '_': return 0x007E000000000000; case '=': return 0x0000007E007E0000; case '+': return 0x000018187E181800; case '[': return 0x003C202020203C00; case ']': return 0x003C040404043C00; case '{': return 0x000E1030100E0000; case '}': return 0x0070080C08700000; case '\\':return 0x0004081020400000; case '|': return 0x0018181818181800; case ';': return 0x2010100010100000; case ':': return 0x0000101000101000; case '\'':return 0x0000000000081030; case '"': return 0x0000000000242466; case ',': return 0x2010100000000000; case '<': return 0x0008102040201008; case '.': return 0x0000101000000000; case '>': return 0x0010080402040810; case '/': return 0x0040201008040000; case '?': return 0x0018001804443800; case '`': return 0x0000000000201008; case '~': return 0x00000000324C0000; case ' ': return 0x0000000000000000; default:  return 0x0000000000000000;
        }
    }

    public static bool StrCmp(char* a, char* b) {
        int i = 0; while(a[i] != '\0' && b[i] != '\0') { if (a[i] != b[i]) return false; i++; }
        return a[i] == b[i];
    }
    public static bool StrStartsWith(char* a, char* b) {
        int i = 0; while (b[i] != '\0') { if (a[i] != b[i]) return false; i++; }
        return true;
    }

    public static void ClearBuffer(byte* ptr, int sizeBytes) {
        for(int i = 0; i < sizeBytes; i++) ptr[i] = 0;
    }

    public static void SweepMailbox() {
        Message trash = default;
        while (SyscallReceiveIPC(&trash) == 1) { /* Đốt thư */ }
    }

    // [CHMOD/CHOWN] Tach dong lenh (sau tien to, vd sau "chmod ") thanh 2 token
    // cach nhau boi khoang trang: token dau (mode hoac uid:gid) va phan con lai
    // (path, co the chua khoang trang nen lay tron phan sau token dau).
    public static bool SplitTwoArgs(char* rest, char* outFirst, int firstCap, char* outSecond, int secondCap) {
        int i = 0; int f = 0;
        while (rest[i] != '\0' && rest[i] != ' ' && f < firstCap - 1) outFirst[f++] = rest[i++];
        outFirst[f] = '\0';
        if (f == 0) return false;
        while (rest[i] == ' ') i++;
        if (rest[i] == '\0') return false;
        int s = 0; while (rest[i] != '\0' && s < secondCap - 1) outSecond[s++] = rest[i++];
        outSecond[s] = '\0';
        return true;
    }

    // [CHMOD] Chuyen chuoi so nguoi dung go (vd "755") - hieu la OCTAL giong UNIX
    // chmod that su - thanh gia tri Permissions dang so thap phan luu tren dia
    // (vd 0755 octal = 493 decimal).
    public static uint OctalStrToUInt(char* str) {
        uint res = 0;
        for (int i = 0; str[i] != '\0'; i++) {
            if (str[i] < '0' || str[i] > '7') break;
            res = res * 8 + (uint)(str[i] - '0');
        }
        return res;
    }

    // [STACK ISOLATION] Tach ra ham rieng de tranh stack overflow trong Main.
    // bflat AOT allocate TẤT CẢ stackalloc cua 1 ham upfront - neu de inline trong
    // Main thi 8192+8192+256+256 bytes duoc cap phat DONG THOI du chi dung 1 nhanh.
    // Tach thanh ham rieng -> moi ham co stack frame doc lap, khong chong le nhau.

    // Doc noi dung tu ban phim vao buf, tra ve so byte. Buf phai >= 8192.
    public static int CaptureWriteContent(byte* buf) {
        const int ContentCap = 8192;
        int contentLen = 0;
        char* lineBuf = stackalloc char[256];
        char* charBuf = stackalloc char[2]; charBuf[1] = '\0';

        while (true) {
            int lineLen = 0;
            while (true) {
                char c = (char)SyscallGetChar();
                if (c == '\0') { SyscallWaitIPC(); continue; }
                if (c == '\n') { fixed(char* nl = "\n\0") ShellPrint(nl); break; }
                else if (c == '\b' && lineLen > 0) { lineLen--; fixed(char* bs = "\b \b\0") ShellPrint(bs); }
                else if (c >= 32 && c <= 126 && lineLen < 255) {
                    lineBuf[lineLen++] = c;
                    charBuf[0] = c; ShellPrint(charBuf);
                }
            }
            if (lineLen == 1 && lineBuf[0] == '.') break;
            for (int i = 0; i < lineLen && contentLen < ContentCap - 1; i++) buf[contentLen++] = (byte)lineBuf[i];
            if (contentLen < ContentCap - 1) buf[contentLen++] = (byte)'\n';
        }
        return contentLen;
    }

    // Xu ly lenh "write <path>" - doc noi dung roi gui IPC toi FAT16 daemon.
    public static void DoWriteCmd(char* fileName, SharedMemoryBlock* SharedMem) {
        char* sharedNameBuf = (char*)SharedMem->FatRequestName;
        int n = 0; while(fileName[n] != '\0' && n < 255) { sharedNameBuf[n] = fileName[n]; n++; }
        sharedNameBuf[n] = '\0';

        fixed(char* wmsg = "[*] Enter content. End with a single '.' on its own line:\n\0") ShellPrint(wmsg);

        const int ContentCap = 8192;
        byte* content = stackalloc byte[ContentCap];
        int contentLen = CaptureWriteContent(content);

        uint payloadSize = (uint)contentLen;
        SyscallSendIPC(FAT16_PID, 32, payloadSize);

        Message res = default; byte* dataChunk = (byte*)SharedMem->FatResponseData;
        while(true) {
            if (SyscallReceiveIPC(&res) == 1 && res.Sender == FAT16_PID) {
                if (res.Type == 33) {
                    uint offset = (uint)res.Payload;
                    for(int i = 0; i < 512; i++) dataChunk[i] = (offset + i < payloadSize) ? content[offset + i] : (byte)0;
                    SyscallSendIPC(FAT16_PID, 34, 0);
                }
                else if (res.Type == 35) {
                    if (res.Payload == 1) { fixed(char* ok = "[+] File written successfully!\n\0") ShellPrint(ok); }
                    else { fixed(char* err = "[!] Failed! Disk Full, Access Denied or File is a Directory!\n\0") ShellPrint(err); }
                    break;
                }
            }
            else SyscallWaitIPC();
        }
    }

    public static void AppendDecimalToBuffer(uint num, char* buf, ref int idx) {
        char* rev = stackalloc char[16]; int c = 0;
        if (num == 0) { buf[idx++] = '0'; return; }
        while (num > 0) { rev[c++] = (char)('0' + (num % 10)); num /= 10; }
        while (c > 0) buf[idx++] = rev[--c];
    }

    // [SUDO] Doc mat khau an ky tu - copy y het logic ReadInput cua Login.cs
    // (khong the dung chung vi Shell.exe va SysLogon.exe build rieng, khong link chung).
    public static void ReadInput(char* buffer, int maxLen, bool isPassword) {
        int len = 0; char* charBuf = stackalloc char[2]; charBuf[1] = '\0';
        while (true) {
            char c = (char)SyscallGetChar();
            if (c == '\0') { SyscallWaitIPC(); continue; }
            if (c == '\n' || c == '\r') { fixed(char* nl = "\n\0") ShellPrint(nl); buffer[len] = '\0'; break; }
            else if (c == '\b' && len > 0) { len--; fixed(char* bs = "\b \b\0") ShellPrint(bs); }
            else if (c >= 32 && c <= 126 && len < maxLen) {
                buffer[len++] = c;
                if (isPassword) { charBuf[0] = '*'; ShellPrint(charBuf); }
                else { charBuf[0] = c; ShellPrint(charBuf); }
            }
        }
    }

    // // ==========================================================
    // // VẼ CHỮ TRỰC TIẾP VÀO RAM ẢO MÀ KHÔNG CẦN NHỜ KERNEL!
    // // ==========================================================
    // public static void GuiDrawChar(char c) {
    //     if (GuiPixels == null) return;
    //     if (c == '\n') { GuiCursorX = 0; GuiCursorY += 16; GuiCheckScroll(); return; }
    //     if (c == '\r') { GuiCursorX = 0; return; }
    //     if (c == '\b') { 
    //         if (GuiCursorX >= 16) GuiCursorX -= 16; 
    //         for(int y=0; y<16; y++) for(int x=0; x<16; x++) GuiPixels[(GuiCursorY + y) * GuiWidth + (GuiCursorX + x)] = 0; 
    //         return; 
    //     }

    //     if (GuiCursorX + 16 > GuiWidth) { GuiCursorX = 0; GuiCursorY += 16; GuiCheckScroll(); }

    //     ulong fontData = GetFontBitmap(c); // Dùng font cục bộ
    //     for(int row = 0; row < 8; row++) { byte b = (byte)(fontData & 0xFF); fontData >>= 8;
    //         for(int col = 0; col < 8; col++) { 
    //             if ((b & (1 << (7 - col))) != 0) { 
    //                 GuiPixels[(GuiCursorY + row*2) * GuiWidth + (GuiCursorX + col*2)] = 0x0000FF00; 
    //                 GuiPixels[(GuiCursorY + row*2+1) * GuiWidth + (GuiCursorX + col*2)] = 0x0000FF00; 
    //                 GuiPixels[(GuiCursorY + row*2) * GuiWidth + (GuiCursorX + col*2+1)] = 0x0000FF00; 
    //                 GuiPixels[(GuiCursorY + row*2+1) * GuiWidth + (GuiCursorX + col*2+1)] = 0x0000FF00; 
    //             } 
    //         } 
    //     }
    //     GuiCursorX += 16;
    // }

    // public static void GuiCheckScroll() {
    //     if (GuiCursorY + 16 > GuiHeight) {
    //         ulong pxToMove = (ulong)GuiWidth * (ulong)(GuiHeight - 16);
    //         ulong* d = (ulong*)GuiPixels; ulong* s = (ulong*)(GuiPixels + (GuiWidth * 16));
    //         ulong blocks = (pxToMove * 4) / 8; while(blocks-- > 0) { *d++ = *s++; }
    //         for (int i = GuiHeight - 16; i < GuiHeight; i++) for (int j = 0; j < GuiWidth; j++) GuiPixels[i * GuiWidth + j] = 0;
    //         GuiCursorY -= 16;
    //     }
    // }

    public static void ShellPrint(char* msg) {
        // if (GuiPixels != null) {
        //     while (*msg != '\0') { GuiDrawChar(*msg); msg++; }
        //     SyscallSendIPC((uint)DWM_PID, 11, GuiVAddr); // Gọi DWM cập nhật Cửa sổ
        // } else { SyscallPrint(msg); } // Rớt về Console Mode
        SyscallPrint(msg);
    }

    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        InitAPI();
        
        fixed (char* fatName = "FAT16.EXE\0") 
        {
            int pid = SyscallGetPIDByName(fatName);
            if (pid == -1) {
                fixed(char* e = "[!] FATAL: FAT16.EXE Daemon not found! Shell Locked!\n\0") ShellPrint(e);
                SyscallExit();
                // [FIX] CÓ CHẾT CŨNG PHẢI NGỦ!
                while(true) SyscallWaitIPC();
            }
            FAT16_PID = (uint)pid;
        }

        fixed (char* targetName = "DSRV.EXE\0") { DWM_PID = SyscallGetPIDByName(targetName); }

        if (DWM_PID > 0) {
            ulong totalBytes = ((uint)GuiWidth * (uint)GuiHeight * 4) + 256; 
            ulong numPages = (totalBytes + 4095) / 4096;
            ulong targetDwmVAddr = 0;
            ulong myBuffer = SyscallCreateSharedBuffer((uint)DWM_PID, numPages, &targetDwmVAddr);
            
            if (myBuffer != 0) {
                GuiVAddr = targetDwmVAddr; GuiPixels = (uint*)(myBuffer + 256);
                WindowHeader* header = (WindowHeader*)myBuffer;
                header->X = 150; header->Y = 150; header->Width = (uint)GuiWidth; header->Height = (uint)GuiHeight;
                fixed(char* t = "Nekko CMD\0") { int idx = 0; while (t[idx] != 0) { header->Title[idx] = (byte)t[idx]; idx++; } header->Title[idx] = 0; }
                for(int i = 0; i < GuiWidth * GuiHeight; i++) GuiPixels[i] = 0; // Đổ nền Đen
                
                SyscallSendIPC((uint)DWM_PID, 11, GuiVAddr);
            }
        }

        ulong sharedAddr = SyscallGetSharedMem();
        SharedMemoryBlock* SharedMem = (SharedMemoryBlock*)sharedAddr;
        char* sharedCmdBuffer = (char*)SharedMem->ShellCommandBuffer;

        fixed(char* welcome = "\n=======================================================\n           NEKKO OS USERLAND SHELL (RING 3)\n=======================================================\n\0") ShellPrint(welcome);

        fixed(char* cmdLs = "ls\0") fixed(char* cmdLl = "ll\0") fixed(char* cmdCat = "cat \0")
        fixed(char* cmdCd = "cd \0") fixed(char* cmdWrite = "write \0") fixed(char* cmdShutdown = "shutdown\0")
        fixed(char* cmdMkdir = "mkdir \0") fixed(char* cmdRm = "rm \0") fixed(char* cmdRmdir = "rmdir \0")
        fixed(char* cmdChmod = "chmod \0") fixed(char* cmdChown = "chown \0")
        fixed(char* cmdChmodBare = "chmod\0") fixed(char* cmdChownBare = "chown\0")
        fixed(char* cmdReboot = "reboot\0") fixed(char* cmdSudo = "sudo \0")
        fixed(char* cmdCatBare = "cat\0") fixed(char* cmdWriteBare = "write\0") fixed(char* cmdCdBare = "cd\0")
        fixed(char* cmdMkdirBare = "mkdir\0") fixed(char* cmdRmBare = "rm\0") fixed(char* cmdRmdirBare = "rmdir\0")
        fixed(char* cmdSudoBare = "sudo\0")
        { 
            char* charBuf = stackalloc char[2];
            char* catTempStr = stackalloc char[513];

            while (true)
            {
                uint myUID = SyscallGetUID();
                if (myUID == 0) { fixed(char* prompt = "root@nekkoOS# \0") ShellPrint(prompt); } 
                else { fixed(char* prompt = "nekko@user$ \0") ShellPrint(prompt); }

                int cmdLen = 0;

                Message flushMsg = default;
                while (SyscallReceiveIPC(&flushMsg) == 1)
                {
                    if (flushMsg.Type == 0xDEAD) 
                    {
                        ClearBuffer((byte*)SharedMem->FatResponseData, 8192);
                        ClearBuffer((byte*)SharedMem->FatRequestName, 512);
                        ClearBuffer((byte*)SharedMem->ShellCommandBuffer, 512);

                        fixed(char* dieMsg = "\n[*] Shell: SIGTERM received. Sweeping workspace and signing off. Goodbye!\n\0") ShellPrint(dieMsg);
                        SyscallExit();
                        // [FIX] CÓ CHẾT CŨNG PHẢI NGỦ!
                        while(true) SyscallWaitIPC();
                    }
                }

                while (true) {
                    char c = (char)SyscallGetChar(); 
                    // [FIX CHÍ MẠNG] Đợi bàn phím thì phải đi ngủ! Gõ phím nó sẽ tát dậy!
                    if (c == '\0') { SyscallWaitIPC(); continue; }

                    if (c == '\n') {
                        fixed(char* nl = "\n\0") ShellPrint(nl);
                        while (cmdLen > 0 && sharedCmdBuffer[cmdLen - 1] == ' ') cmdLen--;
                        sharedCmdBuffer[cmdLen] = '\0'; 
                        break; 
                    }
                    else if (c == '\b' && cmdLen > 0) { cmdLen--; fixed(char* bs = "\b \b\0") ShellPrint(bs); }
                    else if (c >= 32 && c <= 126 && cmdLen < 255) {
                        sharedCmdBuffer[cmdLen++] = c;
                        charBuf[0] = c; charBuf[1] = '\0'; 
                        ShellPrint(charBuf);
                    }
                }

                if (cmdLen > 0)
                {
                    if (StrCmp(sharedCmdBuffer, cmdLs) || StrCmp(sharedCmdBuffer, cmdLl))
                    {
                        SweepMailbox(); 
                        ClearBuffer((byte*)SharedMem->FatResponseData, 8192);
                        SyscallSendIPC(FAT16_PID, 40, 0); 
                        Message res = default;
                        while(true) {
                            if (SyscallReceiveIPC(&res) == 1 && res.Sender == FAT16_PID && res.Type == 41) {
                                ShellPrint((char*)SharedMem->FatResponseData); break;
                            }
                            // [FIX] Ngóng thư thì phải NGỦ!
                            SyscallWaitIPC();
                        }
                    }
                    else if (StrCmp(sharedCmdBuffer, cmdCatBare))
                    {
                        fixed(char* err = "[!] Usage: cat <path>\n\0") ShellPrint(err);
                    }
                    else if (StrStartsWith(sharedCmdBuffer, cmdCat))
                    {
                        SweepMailbox(); 
                        char* sharedNameBuf = (char*)SharedMem->FatRequestName;
                        char* fileName = sharedCmdBuffer + 4;
                        int n = 0; while(fileName[n] != '\0' && n < 255) { sharedNameBuf[n] = fileName[n]; n++; }
                        sharedNameBuf[n] = '\0';

                        SyscallSendIPC(FAT16_PID, 30, 0);
                        
                        Message res = default; uint fileSize = 0; 
                        byte* dataChunk = (byte*)SharedMem->FatResponseData;

                        while (true) {
                            if (SyscallReceiveIPC(&res) == 1 && res.Sender == FAT16_PID) { 
                                if (res.Type == 31) {
                                    fileSize = (uint)res.Payload;
                                    if (fileSize == 0) { fixed(char* e = "[!] Shell: File not found or Access Denied!\n\0") ShellPrint(e); break; }
                                    SyscallSendIPC(FAT16_PID, 311, 0);
                                }
                                else if (res.Type == 38) {
                                    uint offset = (uint)res.Payload; int tIdx = 0;
                                    for(int i = 0; i < 512; i++) {
                                        if (offset + i < fileSize && dataChunk[i] != '\r') catTempStr[tIdx++] = (char)dataChunk[i];
                                    }
                                    catTempStr[tIdx] = '\0'; ShellPrint(catTempStr); 
                                    SyscallSendIPC(FAT16_PID, 39, 0);
                                }
                                else if (res.Type == 42) { fixed(char* nl = "\n\0") ShellPrint(nl); break; }
                            }
                            // [FIX] Ngóng thư thì phải NGỦ!
                            else SyscallWaitIPC();
                        }
                    }
                    else if (StrCmp(sharedCmdBuffer, cmdWriteBare))
                    {
                        fixed(char* err = "[!] Usage: write <path>\n\0") ShellPrint(err);
                    }
                    else if (StrStartsWith(sharedCmdBuffer, cmdWrite))
                    {
                        SweepMailbox();
                        DoWriteCmd(sharedCmdBuffer + 6, SharedMem);
                    }
                    else if (StrCmp(sharedCmdBuffer, cmdCdBare))
                    {
                        fixed(char* err = "[!] Usage: cd <path>\n\0") ShellPrint(err);
                    }
                    else if (StrStartsWith(sharedCmdBuffer, cmdCd))
                    {
                        SweepMailbox(); 
                        char* sharedNameBuf = (char*)SharedMem->FatRequestName;
                        char* dirName = sharedCmdBuffer + 3;
                        int n = 0; while(dirName[n] != '\0' && n < 255) { sharedNameBuf[n] = dirName[n]; n++; }
                        sharedNameBuf[n] = '\0';

                        SyscallSendIPC(FAT16_PID, 36, 0);
                        Message res = default;
                        while(true) {
                            if (SyscallReceiveIPC(&res) == 1 && res.Sender == FAT16_PID) {
                                if (res.Type == 37) {
                                    if (res.Payload == 0) { fixed(char* e = "[!] Directory not found or Access Denied!\n\0") ShellPrint(e); }
                                    break;
                                }
                            }
                            // [FIX] Ngóng thư thì phải NGỦ!
                            else SyscallWaitIPC();
                        }
                    }
                    else if (StrCmp(sharedCmdBuffer, cmdShutdown))
                    {
                        fixed(char* dieMsg = "\n[*] Shell: Initiating System Shutdown. Sweeping workspace and signing off. Goodbye!\n\0") ShellPrint(dieMsg);
                        ClearBuffer((byte*)SharedMem->FatResponseData, 8192);
                        ClearBuffer((byte*)SharedMem->FatRequestName, 512);
                        SyscallRunCmd(sharedCmdBuffer, (ulong)GuiPixels);
                    }
                    else if (StrCmp(sharedCmdBuffer, cmdReboot))
                    {
                        fixed(char* rbMsg = "\n[*] Shell: Initiating System Reboot. Sweeping workspace... See you on the other side!\n\0") ShellPrint(rbMsg);
                        ClearBuffer((byte*)SharedMem->FatResponseData, 8192); ClearBuffer((byte*)SharedMem->FatRequestName, 512);
                        SyscallRunCmd(sharedCmdBuffer, (ulong)GuiPixels);
                    }
                    else if (StrCmp(sharedCmdBuffer, cmdMkdirBare))
                    {
                        fixed(char* err = "[!] Usage: mkdir <path>\n\0") ShellPrint(err);
                    }
                    else if (StrStartsWith(sharedCmdBuffer, cmdMkdir))
                    {
                        SweepMailbox(); 
                        char* sharedNameBuf = (char*)SharedMem->FatRequestName;
                        char* dirName = sharedCmdBuffer + 6;
                        int n = 0; while(dirName[n] != '\0' && n < 255) { sharedNameBuf[n] = dirName[n]; n++; }
                        sharedNameBuf[n] = '\0';

                        SyscallSendIPC(FAT16_PID, 44, 0); 
                        Message res = default;
                        while(true) {
                            if (SyscallReceiveIPC(&res) == 1 && res.Sender == FAT16_PID) {
                                if (res.Type == 45) {
                                    if (res.Payload == 1) { fixed(char* ok = "[+] Directory Created Successfully!\n\0") ShellPrint(ok); }
                                    else { fixed(char* err = "[!] Failed! Directory already exists, Access Denied or Disk Full.\n\0") ShellPrint(err); }
                                    break;
                                }
                            }
                            // [FIX] Ngóng thư thì phải NGỦ!
                            else SyscallWaitIPC();
                        }
                    }
                    else if (StrCmp(sharedCmdBuffer, cmdRmBare))
                    {
                        fixed(char* err = "[!] Usage: rm <path>\n\0") ShellPrint(err);
                    }
                    else if (StrStartsWith(sharedCmdBuffer, cmdRm))
                    {
                        SweepMailbox(); 
                        char* sharedNameBuf = (char*)SharedMem->FatRequestName;
                        char* fileName = sharedCmdBuffer + 3;
                        int n = 0; while(fileName[n] != '\0' && n < 255) { sharedNameBuf[n] = fileName[n]; n++; }
                        sharedNameBuf[n] = '\0';

                        SyscallSendIPC(FAT16_PID, 46, 0); 
                        Message res = default;
                        while(true) {
                            if (SyscallReceiveIPC(&res) == 1 && res.Sender == FAT16_PID) {
                                if (res.Type == 47) {
                                    if (res.Payload == 1) { fixed(char* ok = "[+] File Removed and Clusters Recycled!\n\0") ShellPrint(ok); }
                                    else if (res.Payload == 2) { fixed(char* err = "[!] Cannot use RM on a Directory! Access Denied.\n\0") ShellPrint(err); }
                                    else { fixed(char* err = "[!] File Not Found or Access Denied.\n\0") ShellPrint(err); }
                                    break;
                                }
                            }
                            // [FIX] Ngóng thư thì phải NGỦ!
                            else SyscallWaitIPC();
                        }
                    }
                    else if (StrCmp(sharedCmdBuffer, cmdRmdirBare))
                    {
                        fixed(char* err = "[!] Usage: rmdir <path>\n\0") ShellPrint(err);
                    }
                    else if (StrStartsWith(sharedCmdBuffer, cmdRmdir))
                    {
                        SweepMailbox(); 
                        char* sharedNameBuf = (char*)SharedMem->FatRequestName;
                        char* dirName = sharedCmdBuffer + 6;
                        int n = 0; while(dirName[n] != '\0' && n < 255) { sharedNameBuf[n] = dirName[n]; n++; }
                        sharedNameBuf[n] = '\0';

                        SyscallSendIPC(FAT16_PID, 48, 0); 
                        Message res = default;
                        while(true) {
                            if (SyscallReceiveIPC(&res) == 1 && res.Sender == FAT16_PID) {
                                if (res.Type == 49) {
                                    if (res.Payload == 1) { fixed(char* ok = "[+] Directory and ALL its contents obliterated recursively!\n\0") ShellPrint(ok); }
                                    else if (res.Payload == 2) { fixed(char* err = "[!] Target is a File. Use 'rm' instead.\n\0") ShellPrint(err); }
                                    else { fixed(char* err = "[!] Directory Not Found or Access Denied.\n\0") ShellPrint(err); }
                                    break;
                                }
                            }
                            // [FIX] Ngóng thư thì phải NGỦ!
                            else SyscallWaitIPC();
                        }
                    }
                    else if (StrCmp(sharedCmdBuffer, cmdChmodBare))
                    {
                        fixed(char* err = "[!] Usage: chmod <mode> <path>\n\0") ShellPrint(err);
                    }
                    else if (StrStartsWith(sharedCmdBuffer, cmdChmod))
                    {
                        SweepMailbox();
                        char* rest = sharedCmdBuffer + 6;
                        char* modeStr = stackalloc char[16];
                        char* path = stackalloc char[256];
                        if (!SplitTwoArgs(rest, modeStr, 16, path, 256)) {
                            fixed(char* err = "[!] Usage: chmod <mode> <path>\n\0") ShellPrint(err);
                        } else {
                            uint mode = OctalStrToUInt(modeStr);
                            char* sharedNameBuf = (char*)SharedMem->FatRequestName;
                            int idx = 0; while(path[idx] != '\0' && idx < 255) { sharedNameBuf[idx] = path[idx]; idx++; }
                            sharedNameBuf[idx] = '\0'; idx++;
                            AppendDecimalToBuffer(mode, sharedNameBuf, ref idx);
                            sharedNameBuf[idx] = '\0';

                            SyscallSendIPC(FAT16_PID, 58, 0);
                            Message res = default;
                            while(true) {
                                if (SyscallReceiveIPC(&res) == 1 && res.Sender == FAT16_PID) {
                                    if (res.Type == 59) {
                                        if (res.Payload == 1) { fixed(char* ok = "[+] Permissions Changed Successfully!\n\0") ShellPrint(ok); }
                                        else { fixed(char* err = "[!] Failed! Not Found or Access Denied (only owner or root).\n\0") ShellPrint(err); }
                                        break;
                                    }
                                }
                                else SyscallWaitIPC();
                            }
                        }
                    }
                    else if (StrCmp(sharedCmdBuffer, cmdChownBare))
                    {
                        fixed(char* err = "[!] Usage: chown <uid>:<gid> <path>\n\0") ShellPrint(err);
                    }
                    else if (StrStartsWith(sharedCmdBuffer, cmdChown))
                    {
                        SweepMailbox();
                        char* rest = sharedCmdBuffer + 6;
                        char* ownerStr = stackalloc char[32];
                        char* path = stackalloc char[256];
                        if (!SplitTwoArgs(rest, ownerStr, 32, path, 256)) {
                            fixed(char* err = "[!] Usage: chown <uid>:<gid> <path>\n\0") ShellPrint(err);
                        } else {
                            char* sharedNameBuf = (char*)SharedMem->FatRequestName;
                            int idx = 0; while(path[idx] != '\0' && idx < 255) { sharedNameBuf[idx] = path[idx]; idx++; }
                            sharedNameBuf[idx] = '\0'; idx++;
                            int oi = 0; while(ownerStr[oi] != '\0' && idx < 4095) { sharedNameBuf[idx] = ownerStr[oi]; idx++; oi++; }
                            sharedNameBuf[idx] = '\0';

                            SyscallSendIPC(FAT16_PID, 60, 0);
                            Message res = default;
                            while(true) {
                                if (SyscallReceiveIPC(&res) == 1 && res.Sender == FAT16_PID) {
                                    if (res.Type == 61) {
                                        if (res.Payload == 1) { fixed(char* ok = "[+] Ownership Changed Successfully!\n\0") ShellPrint(ok); }
                                        else { fixed(char* err = "[!] Failed! Not Found or Access Denied (root only).\n\0") ShellPrint(err); }
                                        break;
                                    }
                                }
                                else SyscallWaitIPC();
                            }
                        }
                    }
                    else if (StrCmp(sharedCmdBuffer, cmdSudoBare))
                    {
                        fixed(char* err = "[!] Usage: sudo <app>\n\0") ShellPrint(err);
                    }
                    else if (StrStartsWith(sharedCmdBuffer, cmdSudo))
                    {
                        char* appName = sharedCmdBuffer + 5;
                        if (appName[0] == '\0') {
                            fixed(char* err = "[!] Usage: sudo <app>\n\0") ShellPrint(err);
                        } else {
                            DoSudoCmd(appName);
                        }
                    }
                    else { SyscallRunCmd(sharedCmdBuffer, (ulong)GuiPixels); }

                    for (int i = 0; i < 255; i++) sharedCmdBuffer[i] = '\0';
                }
            }
        }
    }
    // [STACK ISOLATION] Toan bo logic sudo (bao gom capture content cho "write")
    // nam trong ham rieng de stack frame doc lap voi Main, tranh stackalloc chong le.
    public static void DoSudoCmd(char* appName) {
        fixed(char* cmdWrite = "write \0") {
        bool isSudoWrite = StrStartsWith(appName, cmdWrite);
        byte* sudoContent = null;
        int sudoContentLen = 0;
        // Dung heap? Khong - dung stackalloc trong ham NAY (frame rieng, an toan).
        byte* sudoContentBuf = stackalloc byte[8192];

        if (isSudoWrite) {
            char* wpath = appName + 6;
            if (wpath[0] == '\0') {
                fixed(char* err = "[!] Usage: sudo write <path>\n\0") ShellPrint(err);
                return;
            }
            fixed(char* wmsg = "[*] Enter content. End with a single '.' on its own line:\n\0") ShellPrint(wmsg);
            sudoContentLen = CaptureWriteContent(sudoContentBuf);
            sudoContent = sudoContentBuf;
        }

        fixed(char* prompt = "[sudo] Password: \0") ShellPrint(prompt);
        char* passBuf = stackalloc char[64];
        ReadInput(passBuf, 63, true);

        ulong sudoResult = SyscallSudoRun(appName, passBuf, sudoContent, (ulong)sudoContentLen);

        for (int i = 0; i < 64; i++) passBuf[i] = '\0';
        if (isSudoWrite) for (int i = 0; i < sudoContentLen; i++) sudoContentBuf[i] = 0;

        if (sudoResult == 1) { /* Thanh cong */ }
        else if (sudoResult == 2) { fixed(char* err = "[!] User is not in the sudoers file. This incident will be reported.\n\0") ShellPrint(err); }
        else if (sudoResult == 3) { fixed(char* err = "[!] Target application not found or corrupted.\n\0") ShellPrint(err); }
        else { fixed(char* err = "[!] Sorry, try again.\n\0") ShellPrint(err); }
        } // end fixed cmdWrite
    }

    public static void Main() { }
}