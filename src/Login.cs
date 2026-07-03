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

    public static uint ReadFileIPC(char* fileName, byte* fileBuffer) {
        StringToSharedBuffer(fileName, (char*)SharedMem->FatRequestName);
        SyscallSendIPC(FAT16_PID, 30, 0);
        Message res = default; uint fileSize = 0; byte* dataChunk = (byte*)SharedMem->FatResponseData;
        while (true) {
            if (SyscallReceiveIPC(&res) == 1) {
                if (res.Sender == FAT16_PID) {
                    if (res.Type == 31) { fileSize = (uint)res.Payload; if (fileSize == 0) return 0; SyscallSendIPC(FAT16_PID, 311, 0); }
                    else if (res.Type == 38) { uint offset = (uint)res.Payload; for (int i = 0; i < 512; i++) { if (offset + i < fileSize) fileBuffer[offset + i] = dataChunk[i]; } SyscallSendIPC(FAT16_PID, 39, 0); }
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
        char* linePass = stackalloc char[32];
        char* lineUID = stackalloc char[16];
        char* lineGID = stackalloc char[16];
        
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
                uint passSize = ReadFileIPC(passFileName, passFileBuf);
                ChangeDirectoryIPC(dirRoot);

                if (passSize == 0) { fixed(char* e = "\n[!!!] CRITICAL ERROR: /ETC/PASSWD NOT FOUND OR EMPTY!\n\0") SyscallPrint(e); break; }

                bool authSuccess = false; uint matchedUID = 0; uint matchedGID = 0;
                int i = 0;
                while (i < passSize) {
                    int u = 0, p = 0, id = 0, gd = 0; int stage = 0; 
                    while (i < passSize && passFileBuf[i] != '\n' && passFileBuf[i] != '\r') {
                        char c = (char)passFileBuf[i];
                        if (c == ':') { stage++; }
                        else {
                            if (stage == 0 && u < 31) lineUser[u++] = c;
                            else if (stage == 1 && p < 31) linePass[p++] = c;
                            else if (stage == 2 && id < 15) lineUID[id++] = c;
                            else if (stage == 3 && gd < 15) lineGID[gd++] = c;
                        }
                        i++;
                    }
                    lineUser[u] = '\0'; linePass[p] = '\0'; lineUID[id] = '\0'; lineGID[gd] = '\0';

                    if (StrCmp(inputUser, lineUser) && StrCmp(inputPass, linePass)) {
                        authSuccess = true; matchedUID = Atoi(lineUID); matchedGID = Atoi(lineGID); break;
                    }
                    while (i < passSize && (passFileBuf[i] == '\n' || passFileBuf[i] == '\r')) i++;
                }

                if (authSuccess) {
                    fixed(char* ok1 = "\n[+] AUTHENTICATED! Welcome to the Multiverse!\n\0") SyscallPrint(ok1);
                    
                    SyscallSetUID(matchedUID); SyscallSetGID(matchedGID);
                    
                    sharedCmdBuffer = (char*)SharedMem->ShellCommandBuffer;
                    StringToSharedBuffer(cmdRunShell, sharedCmdBuffer);
                    SyscallRunCmd(sharedCmdBuffer, 0); 
                    
                    SyscallExit();
                    while(true) { SyscallWaitIPC(); } 
                } else {
                    attempts--;
                    fixed(char* err = "\n[!] ACCESS DENIED! Incorrect Username or Password.\n\0") SyscallPrint(err);
                    if (attempts > 0) { 
                        fixed(char* warn = "[!] Invalid credentials. Try again.\n\n\0") SyscallPrint(warn); 
                    }
                }
            }

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