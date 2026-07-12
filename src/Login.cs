// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

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

public unsafe class Login
{
    public static SharedMemoryBlock* SharedMem = null;
    public static uint FAT16_PID = 0;
    
    public static void SyscallYieldApp() { SyscallYield(); }
    public static bool StrCmp(char* a, char* b) { int i = 0; while(a[i] != '\0' && b[i] != '\0') { if (a[i] != b[i]) return false; i++; } return a[i] == b[i]; }
    public static void StringToSharedBuffer(char* source, char* dest) { int i = 0; while (source[i] != '\0') { dest[i] = source[i]; i++; } dest[i] = '\0'; }
    public static uint Atoi(char* str) { uint res = 0; for (int i = 0; str[i] != '\0'; ++i) { if (str[i] >= '0' && str[i] <= '9') res = res * 10 + (uint)(str[i] - '0'); else break; } return res; }

    // ==========================================================
    // [FIX BẢO MẬT] Helper hex cho định dạng PASSWD mới: user:salt:hash:UID:GID
    // salt/hash lưu dạng chuỗi hex - không còn plaintext password trên đĩa.
    // ==========================================================
    private static int HexNibble(char c) {
        if (c >= '0' && c <= '9') return c - '0';
        if (c >= 'a' && c <= 'f') return c - 'a' + 10;
        if (c >= 'A' && c <= 'F') return c - 'A' + 10;
        return -1;
    }

    public static int HexToBytes(char* hex, byte* outBytes, int maxOutBytes) {
        int i = 0, o = 0;
        while (hex[i] != '\0' && hex[i + 1] != '\0' && o < maxOutBytes) {
            int hi = HexNibble(hex[i]); int lo = HexNibble(hex[i + 1]);
            if (hi < 0 || lo < 0) break;
            outBytes[o++] = (byte)((hi << 4) | lo);
            i += 2;
        }
        return o;
    }

    public static void BytesToHex(byte* bytes, int len, char* outHex) {
        char* digits = stackalloc char[16] { '0','1','2','3','4','5','6','7','8','9','a','b','c','d','e','f' };
        for (int i = 0; i < len; i++) {
            outHex[i * 2] = digits[(bytes[i] >> 4) & 0xF];
            outHex[i * 2 + 1] = digits[bytes[i] & 0xF];
        }
        outHex[len * 2] = '\0';
    }

    // [FIX BẢO MẬT] So sánh constant-time: luôn duyệt hết độ dài cố định thay vì
    // thoát ngay khi gặp ký tự sai khác - tránh lộ thông tin qua thời gian thực thi
    // (timing side-channel), khác với StrCmp thông thường vốn return false sớm.
    public static bool ConstantTimeEq(char* a, char* b, int maxLen) {
        int diff = 0;
        bool endedA = false, endedB = false;
        for (int i = 0; i < maxLen; i++) {
            char ca = endedA ? '\0' : a[i];
            char cb = endedB ? '\0' : b[i];
            if (a[i] == '\0') endedA = true;
            if (b[i] == '\0') endedB = true;
            diff |= (ca ^ cb);
        }
        return diff == 0;
    }

    // [FIX BẢO MẬT - LOW] Xóa sạch buffer chứa dữ liệu nhạy cảm (mật khẩu, salt,
    // hash) khỏi RAM ngay sau khi dùng xong, tránh bị đọc lại qua memory dump/leak
    // ở tiến trình khác hoặc lần chạy sau tái sử dụng cùng vùng stack.
    public static void ZeroMemChar(char* buf, int len) { for (int i = 0; i < len; i++) buf[i] = '\0'; }
    public static void ZeroMemByte(byte* buf, int len) { for (int i = 0; i < len; i++) buf[i] = 0; }

    public static void PrintLineWithNum(char* prefix, uint num) {
        char* buf = stackalloc char[128];
        int idx = 0;
        
        while (*prefix != '\0') { buf[idx++] = *prefix++; }
        
        if (num == 0) { buf[idx++] = '0'; }
        else {
            char* rev = stackalloc char[16]; int c = 0;
            while (num > 0) { rev[c++] = (char)('0' + (num % 10)); num /= 10; }
            while (c > 0) { buf[idx++] = rev[--c]; }
        }
        
        buf[idx++] = '\n'; 
        buf[idx] = '\0';
        
        SyscallPrint(buf); 
    }

    public static uint ReadFileIPC(char* fileName, byte* fileBuffer, uint bufferCapacity) {
        StringToSharedBuffer(fileName, (char*)SharedMem->FatRequestName);
        SyscallSendIPC(FAT16_PID, 30, 0);
        Message res = default; uint fileSize = 0; byte* dataChunk = (byte*)SharedMem->FatResponseData;
        while (true) {
            if (SyscallReceiveIPC(&res) == 1) {
                if (res.Sender == FAT16_PID) {
                    // [FIX BẢO MẬT - CRITICAL] Chặn tràn stack: nếu file trên đĩa lớn hơn
                    // dung lượng buffer thật (VD: PASSWD phình to khi hệ thống có nhiều
                    // user), từ chối đọc thay vì ghi đè ra ngoài stack của Login.exe.
                    if (res.Type == 31) {
                        fileSize = (uint)res.Payload;
                        if (fileSize == 0) return 0;
                        if (fileSize > bufferCapacity) {
                            fixed (char* err = "\n[!!!] FATAL: File too large for buffer (potential overflow blocked)!\n\0") SyscallPrint(err);
                            SyscallSendIPC(FAT16_PID, 311, 0);
                            return 0;
                        }
                        SyscallSendIPC(FAT16_PID, 311, 0);
                    }
                    else if (res.Type == 38) { uint offset = (uint)res.Payload; for (int i = 0; i < 512; i++) { if (offset + i < fileSize && offset + i < bufferCapacity) fileBuffer[offset + i] = dataChunk[i]; } SyscallSendIPC(FAT16_PID, 39, 0); }
                    else if (res.Type == 42) { return fileSize; }
                }
                // ==========================================================
                // [FIX CHÍ MẠNG] BỎ QUA THƯ RÁC ĐỂ KHÔNG BỊ NGỦ QUÊN!
                // ==========================================================
                continue; 
            }
            SyscallWaitIPC();
        }
    }

    public static bool ChangeDirectoryIPC(char* dirName) {
        StringToSharedBuffer(dirName, (char*)SharedMem->FatRequestName);
        SyscallSendIPC(FAT16_PID, 36, 0);
        Message res = default;
        while (true) {
            if (SyscallReceiveIPC(&res) == 1) {
                if (res.Sender == FAT16_PID) {
                    if (res.Type == 37) return res.Payload == 1;
                }
                // ==========================================================
                // [FIX CHÍ MẠNG] BỎ QUA THƯ RÁC ĐỂ KHÔNG BỊ NGỦ QUÊN!
                // ==========================================================
                continue;
            }
            SyscallWaitIPC();
        }
    }

    // [HOME DIR] MKDIR_AS - chi goi khi con la root (truoc SyscallSetUID), tao thu
    // muc moi trong CurrentDirCluster hien tai va gan owner la targetUID/targetGID
    // (khong phai UID cua caller) - dung de tao home dir cho user khac ma khong can
    // noi long permission cua /HOME hay dua vao byte rac tren dia.
    public static bool MkdirAsIPC(char* dirName, uint targetUID, uint targetGID) {
        char* buf = (char*)SharedMem->FatRequestName;
        int n = 0; while (dirName[n] != '\0') { buf[n] = dirName[n]; n++; }
        buf[n] = '\0'; n++;

        char* numBuf = stackalloc char[16];
        int ni = 0; uint u = targetUID;
        if (u == 0) { numBuf[ni++] = '0'; } else { char* rev = stackalloc char[16]; int c = 0; while (u > 0) { rev[c++] = (char)('0' + (u % 10)); u /= 10; } while (c > 0) numBuf[ni++] = rev[--c]; }
        numBuf[ni] = '\0';
        int m = 0; while (numBuf[m] != '\0') { buf[n] = numBuf[m]; n++; m++; }
        buf[n] = ':'; n++;

        ni = 0; u = targetGID;
        if (u == 0) { numBuf[ni++] = '0'; } else { char* rev = stackalloc char[16]; int c = 0; while (u > 0) { rev[c++] = (char)('0' + (u % 10)); u /= 10; } while (c > 0) numBuf[ni++] = rev[--c]; }
        numBuf[ni] = '\0';
        m = 0; while (numBuf[m] != '\0') { buf[n] = numBuf[m]; n++; m++; }
        buf[n] = '\0';

        SyscallSendIPC(FAT16_PID, 56, 0);
        Message res = default;
        while (true) {
            if (SyscallReceiveIPC(&res) == 1) {
                if (res.Sender == FAT16_PID) {
                    if (res.Type == 57) return res.Payload == 1;
                }
                continue;
            }
            SyscallWaitIPC();
        }
    }

    // [HOME DIR] Tach thanh phan cuoi cua HOMEDIR ("/HOME/nekko" -> "nekko"), dung
    // de biet ten thu muc con can cd/mkdir ben trong /HOME.
    public static void ExtractLastComponent(char* path, char* outBuf, int outCap) {
        int len = 0; while (path[len] != '\0') len++;
        int lastSep = -1;
        for (int i = 0; i < len; i++) { if (path[i] == '/' || path[i] == '\\') lastSep = i; }
        int start = lastSep + 1;
        int o = 0;
        for (int i = start; i < len && o < outCap - 1; i++) outBuf[o++] = path[i];
        outBuf[o] = '\0';
    }

    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        InitAPI();

        ulong sharedAddr = SyscallGetSharedMem();
        SharedMem = (SharedMemoryBlock*)sharedAddr;
        char* sharedCmdBuffer = (char*)SharedMem->ShellCommandBuffer;

        fixed (char* fatName = "FAT16.EXE\0") 
        {
            int pid = SyscallGetPIDByName(fatName);
            if (pid == -1) {
                fixed(char* e = "[!] FATAL: FAT16.EXE Daemon not found! System Locked!\n\0") SyscallPrint(e);
                SyscallExit();
                while(true) SyscallWaitIPC(); 
            }
            FAT16_PID = (uint)pid;
        }

        fixed (char* msgPid = "FAT16 Daemon connected at PID: \0") {
            PrintLineWithNum(msgPid, FAT16_PID);
        }
        
        fixed(char* welcome = "\n=======================================================\n           NEKKO OS SECURITY GATEWAY (LOGIN)\n=======================================================\n\0") SyscallPrint(welcome);

        char* inputUser = stackalloc char[32];
        char* inputPass = stackalloc char[32];
        byte* passFileBuf = stackalloc byte[4096];
        char* lineUser = stackalloc char[32];
        char* lineSalt = stackalloc char[64];
        char* lineHash = stackalloc char[80];
        char* lineUID = stackalloc char[16];
        char* lineGID = stackalloc char[16];
        char* lineHome = stackalloc char[64];

        // [FIX BẢO MẬT] Buffer cho việc băm mật khẩu: salt (raw bytes) + password nhập vào,
        // rồi băm SHA-256 và so sánh dạng hex với hash lưu trong PASSWD - không bao giờ
        // so sánh trực tiếp plaintext password nữa.
        byte* saltBytes = stackalloc byte[32];
        byte* hashInputBuf = stackalloc byte[32 + 32];
        byte* computedHash = stackalloc byte[32];
        char* computedHashHex = stackalloc char[80];
        
        fixed(char* cmdRunShell = "run SHELL.EXE\0") 
        fixed(char* dirEtc = "ETC\0")            
        fixed(char* dirRoot = "\\\0")            
        fixed(char* passFileName = "PASSWD\0")   
        {
            int attempts = 3;

            while (attempts > 0)
            {
                fixed(char* pUser = "Username: \0") SyscallPrint(pUser);
                ReadInput(inputUser, 31, false);

                fixed(char* pPass = "Password: \0") SyscallPrint(pPass);
                ReadInput(inputPass, 31, true); 

                if (!ChangeDirectoryIPC(dirEtc)) { fixed(char* e = "\n[!!!] CRITICAL ERROR: /ETC DIRECTORY NOT FOUND!\n\0") SyscallPrint(e); break; }
                uint passSize = ReadFileIPC(passFileName, passFileBuf, 4096);
                ChangeDirectoryIPC(dirRoot);

                if (passSize == 0) { fixed(char* e = "\n[!!!] CRITICAL ERROR: /ETC/PASSWD NOT FOUND OR EMPTY!\n\0") SyscallPrint(e); break; }

                bool authSuccess = false; uint matchedUID = 0; uint matchedGID = 0;
                int i = 0;
                while (i < passSize) {
                    // [FIX BẢO MẬT] Định dạng PASSWD mới: user:salt:hash:UID:GID (5 field,
                    // salt/hash dạng hex) thay vì user:pass:UID:GID (plaintext) trước đây.
                    int u = 0, s = 0, h = 0, id = 0, gd = 0, hm = 0; int stage = 0;
                    while (i < passSize && passFileBuf[i] != '\n' && passFileBuf[i] != '\r') {
                        char c = (char)passFileBuf[i];
                        if (c == ':') { stage++; }
                        else {
                            if (stage == 0 && u < 31) lineUser[u++] = c;
                            else if (stage == 1 && s < 63) lineSalt[s++] = c;
                            else if (stage == 2 && h < 79) lineHash[h++] = c;
                            else if (stage == 3 && id < 15) lineUID[id++] = c;
                            else if (stage == 4 && gd < 15) lineGID[gd++] = c;
                            else if (stage == 5 && hm < 63) lineHome[hm++] = c;
                        }
                        i++;
                    }
                    lineUser[u] = '\0'; lineSalt[s] = '\0'; lineHash[h] = '\0'; lineUID[id] = '\0'; lineGID[gd] = '\0'; lineHome[hm] = '\0';

                    // [FIX BẢO MẬT - MEDIUM] Chặn "phantom account": nếu người dùng bỏ trống
                    // Username (Enter luôn), StrCmp("", "") giữa 2 chuỗi rỗng trả về true, có
                    // thể trùng khớp nhầm với dòng PASSWD bị hỏng/rỗng field user. Yêu cầu cả
                    // hai chuỗi đều phải KHÔNG rỗng thì mới coi là ứng viên hợp lệ để so khớp.
                    if (u > 0 && inputUser[0] != '\0' && StrCmp(inputUser, lineUser)) {
                        // Băm salt (đọc từ đĩa, dạng hex) + password người dùng nhập vào.
                        int saltLen = HexToBytes(lineSalt, saltBytes, 32);
                        int passLen = 0; while (inputPass[passLen] != '\0') passLen++;

                        int hashInputLen = 0;
                        for (int k = 0; k < saltLen; k++) hashInputBuf[hashInputLen++] = saltBytes[k];
                        for (int k = 0; k < passLen; k++) hashInputBuf[hashInputLen++] = (byte)inputPass[k];

                        SHA256.Compute(hashInputBuf, (ulong)hashInputLen, computedHash);
                        BytesToHex(computedHash, 32, computedHashHex);

                        // [FIX BẢO MẬT] So sánh hash bằng constant-time thay vì StrCmp thoát sớm,
                        // vá luôn lỗ hổng timing attack đã báo cáo trước đó.
                        if (ConstantTimeEq(computedHashHex, lineHash, 64)) {
                            authSuccess = true; matchedUID = Atoi(lineUID); matchedGID = Atoi(lineGID); break;
                        }
                    }
                    while (i < passSize && (passFileBuf[i] == '\n' || passFileBuf[i] == '\r')) i++;
                }

                // [FIX BẢO MẬT - LOW] Xóa sạch mọi dữ liệu nhạy cảm còn nằm trên stack
                // (password nhập vào, salt/hash đọc từ đĩa, buffer băm tạm) ngay khi vòng
                // thử này kết thúc, bất kể thành công hay thất bại.
                ZeroMemChar(inputPass, 32);
                ZeroMemChar(lineSalt, 64);
                ZeroMemChar(lineHash, 80);
                ZeroMemByte(saltBytes, 32);
                ZeroMemByte(hashInputBuf, 64);
                ZeroMemByte(computedHash, 32);
                ZeroMemChar(computedHashHex, 80);

                if (authSuccess) {
                    fixed(char* ok1 = "\n[+] AUTHENTICATED! Welcome to the Multiverse!\n\0") SyscallPrint(ok1);

                    // [HOME DIR] Con dang la root (chua SyscallSetUID) - dam bao /HOME ton tai
                    // va thu muc rieng cua user (theo HOMEDIR trong PASSWD) da duoc tao, so huu
                    // dung boi chinh user do (khong phai root) qua MKDIR_AS.
                    char* homeSub = stackalloc char[64];
                    ExtractLastComponent(lineHome, homeSub, 64);
                    if (homeSub[0] != '\0') {
                        fixed (char* dirHome = "HOME\0") {
                            ChangeDirectoryIPC(dirRoot);
                            if (!ChangeDirectoryIPC(dirHome)) {
                                MkdirAsIPC(dirHome, 0, 0);
                                ChangeDirectoryIPC(dirHome);
                            }
                            if (!ChangeDirectoryIPC(homeSub)) {
                                MkdirAsIPC(homeSub, matchedUID, matchedGID);
                            }
                        }
                    }
                    ChangeDirectoryIPC(dirRoot);

                    SyscallSetUID(matchedUID); SyscallSetGID(matchedGID);

                    // [HOME DIR] SHELL.EXE nam o "/" - phai o cwd = root luc goi RunCmd, neu
                    // khong FAT16 Daemon se tim SHELL.EXE trong cwd sai (vd /HOME/<user>) va
                    // bao "File not found". CurrentDirCluster la bien global dung chung cho
                    // toan bo daemon (khong phai per-client), nen cd vao home dir PHAI thuc
                    // hien SAU khi RunCmd da nap xong SHELL.EXE, de shell vua khoi dong "thua
                    // ke" dung cwd la home dir cua user.
                    ChangeDirectoryIPC(dirRoot);

                    sharedCmdBuffer = (char*)SharedMem->ShellCommandBuffer;
                    StringToSharedBuffer(cmdRunShell, sharedCmdBuffer);
                    SyscallRunCmd(sharedCmdBuffer, 0);

                    // [HOME DIR] Da ha quyen - cd that vao home dir voi danh nghia chinh user
                    // do de xac nhan quyen thuc te; fallback ve "/" neu that bai (khong chan
                    // dang nhap).
                    if (homeSub[0] != '\0') {
                        fixed (char* dirHome = "HOME\0") {
                            if (!ChangeDirectoryIPC(dirHome) || !ChangeDirectoryIPC(homeSub)) {
                                ChangeDirectoryIPC(dirRoot);
                                fixed (char* warn = "[!] Warning: Could not enter home directory, staying at /.\n\0") SyscallPrint(warn);
                            }
                        }
                    }

                    SyscallExit();
                    while(true) { SyscallWaitIPC(); }
                } else {
                    attempts--;
                    fixed(char* err = "\n[!] ACCESS DENIED! Incorrect Username or Password.\n\0") SyscallPrint(err);
                    if (attempts > 0) {
                        fixed(char* warn = "[!] Invalid credentials. Try again.\n\n\0") SyscallPrint(warn);
                        // [FIX BẢO MẬT - HIGH] Chống brute-force: tăng dần thời gian chờ sau
                        // mỗi lần sai (1s, rồi 2s...) thay vì cho thử lại ngay lập tức - làm
                        // chậm đáng kể tốc độ dò mật khẩu tự động mà không ảnh hưởng người
                        // dùng thật gõ tay.
                        uint failedCount = (uint)(3 - attempts);
                        SyscallSleep((ulong)(1000 * failedCount));
                    }
                }
            }

            // [FIX BẢO MẬT - HIGH] Hết lượt thử: khóa hẳn phiên đăng nhập này (không cho
            // vòng lặp tiếp tục), buộc phải khởi động lại tiến trình Login để thử tiếp,
            // kết hợp với delay tăng dần ở trên để hạn chế brute-force qua nhiều phiên.
            fixed(char* fatal = "\n[!!!] SYSTEM LOCKDOWN INITIATED [!!!]\n\0") SyscallPrint(fatal);
            SyscallExit();
            while(true) { SyscallWaitIPC(); }
        }
    }

    private static void ReadInput(char* buffer, int maxLen, bool isPassword) {
        int len = 0; char* charBuf = stackalloc char[2]; charBuf[1] = '\0';
        while (true) {
            char c = (char)SyscallGetChar();
            if (c == '\0') { SyscallWaitIPC(); continue; }
            
            if (c == '\n' || c == '\r') { fixed(char* nl = "\n\0") SyscallPrint(nl); buffer[len] = '\0'; break; }
            else if (c == '\b' && len > 0) { len--; fixed(char* bs = "\b \b\0") SyscallPrint(bs); }
            else if (c >= 32 && c <= 126 && len < maxLen) { 
                buffer[len++] = c; 
                if (isPassword) { charBuf[0] = '*'; SyscallPrint(charBuf); } 
                else { charBuf[0] = c; SyscallPrint(charBuf); } 
            }
        }
    }
}