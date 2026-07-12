// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoApp;

using static NekkoApp.API;

public static unsafe class StressTest
{
    [DllImport("*", EntryPoint = "AppMainAsm")]
    public static extern void AppMainAsm();

    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        AppMainAsm();
    }

    // =================================================================
    // PROXY BRIDGE: Export các Syscall từ API.cs ra ngoài cho ASM dùng
    // =================================================================

    [UnmanagedCallersOnly(EntryPoint = "InitAPI")]
    public static void ProxyInitAPI() => InitAPI();

    [UnmanagedCallersOnly(EntryPoint = "SyscallClear")]
    public static void ProxySyscallClear(uint color) => SyscallClear(color);

    [UnmanagedCallersOnly(EntryPoint = "SyscallPrint")]
    public static void ProxySyscallPrint(char* str) => SyscallPrint(str);

    [UnmanagedCallersOnly(EntryPoint = "SyscallGetProcessInfo")]
    public static int ProxySyscallGetProcessInfo(uint pid, ProcessInfo* info) => SyscallGetProcessInfo(pid, info);

    [UnmanagedCallersOnly(EntryPoint = "SyscallSendIPC")]
    public static void ProxySyscallSendIPC(uint pid, byte type, ulong val) => SyscallSendIPC(pid, type, val);

    [UnmanagedCallersOnly(EntryPoint = "SyscallGetThreadUID")]
    public static uint ProxySyscallGetThreadUID(uint pid) => SyscallGetThreadUID(pid);

    [UnmanagedCallersOnly(EntryPoint = "SyscallGetThreadGID")]
    public static uint ProxySyscallGetThreadGID(uint pid) => SyscallGetThreadGID(pid);

    [UnmanagedCallersOnly(EntryPoint = "SyscallReceiveIPC")]
    public static void ProxySyscallReceiveIPC(Message* msg) => SyscallReceiveIPC(msg);

    [UnmanagedCallersOnly(EntryPoint = "SyscallAllocMem")]
    public static ulong ProxySyscallAllocMem(ulong pages) => SyscallAllocMem(pages);

    [UnmanagedCallersOnly(EntryPoint = "SyscallCreateSharedBuffer")]
    public static ulong ProxySyscallCreateSharedBuffer(uint flags, ulong size, ulong* outV) => SyscallCreateSharedBuffer(flags, size, outV);

    [UnmanagedCallersOnly(EntryPoint = "SyscallResetCursor")]
    public static void ProxySyscallResetCursor() => SyscallResetCursor();

    [UnmanagedCallersOnly(EntryPoint = "SyscallYield")]
    public static void ProxySyscallYield() => SyscallYield();

    [UnmanagedCallersOnly(EntryPoint = "SyscallGetChar")]
    public static byte ProxySyscallGetChar() => SyscallGetChar();

    [UnmanagedCallersOnly(EntryPoint = "SyscallExit")]
    public static void ProxySyscallExit() => SyscallExit();

    [UnmanagedCallersOnly(EntryPoint = "SyscallWaitIPC")]
    public static void ProxySyscallWaitIPC() => SyscallWaitIPC();

    [UnmanagedCallersOnly(EntryPoint = "SyscallSleep")]
    public static void ProxySyscallSleep(uint ms) => SyscallSleep(ms);

    public static void AppendChar(char* buf, int* idx, char c)
    {
        if (*idx < 500) { buf[*idx] = c; (*idx)++; }
    }

    public static void AppendStr(char* buf, int* idx, char* str)
    {
        int i = 0;
        while (str[i] != '\0' && *idx < 500) { buf[*idx] = str[i]; (*idx)++; i++; }
    }

    public static void AppendHex(char* buf, int* idx, uint v)
    {
        char* digits = stackalloc char[16];
        digits[0] = '0'; digits[1] = '1'; digits[2] = '2'; digits[3] = '3';
        digits[4] = '4'; digits[5] = '5'; digits[6] = '6'; digits[7] = '7';
        digits[8] = '8'; digits[9] = '9'; digits[10] = 'A'; digits[11] = 'B';
        digits[12] = 'C'; digits[13] = 'D'; digits[14] = 'E'; digits[15] = 'F';
        for (int shift = 28; shift >= 0; shift -= 4)
        {
            uint digit = (v >> shift) & 15u;
            AppendChar(buf, idx, digits[(int)digit]);
        }
    }

    [UnmanagedCallersOnly(EntryPoint = "UpdateDisplayCsharp")]
    public static void UpdateDisplayCsharp(uint frame, uint sends, uint recvs, uint mem, uint shm, uint yld, uint slp, uint rst, uint flt)
    {
        char* buf = stackalloc char[512];
        int bufIndex = 0;
        int* idx = &bufIndex;

        fixed (char* b1 = "[STRESS TEST] Comprehensive OS Stability Test\n")
        fixed (char* b2 = "[STRESS] 'q'=quit | 'f'=page fault | 'z'=div by zero | 'g'=GPF | 'i'=ISR test\n")
        fixed (char* sF = "[STATS] F=")
        fixed (char* sS = " IPCS=")
        fixed (char* sR = " IPCR=")
        fixed (char* sM = " MEM=")
        fixed (char* sSH = " SHM=")
        fixed (char* sY = "\n[STATS] YLD=")
        fixed (char* sSL = " SLP=")
        fixed (char* sRS = " RST=")
        fixed (char* sFL = " FLT=")
        fixed (char* nl = "\n")
        {
            AppendStr(buf, idx, b1);
            AppendStr(buf, idx, b2);

            AppendStr(buf, idx, sF);
            AppendHex(buf, idx, frame);

            AppendStr(buf, idx, sS);
            AppendHex(buf, idx, sends);

            AppendStr(buf, idx, sR);
            AppendHex(buf, idx, recvs);

            AppendStr(buf, idx, sM);
            AppendHex(buf, idx, mem);

            AppendStr(buf, idx, sSH);
            AppendHex(buf, idx, shm);

            AppendStr(buf, idx, sY);
            AppendHex(buf, idx, yld);

            AppendStr(buf, idx, sSL);
            AppendHex(buf, idx, slp);

            AppendStr(buf, idx, sRS);
            AppendHex(buf, idx, rst);

            AppendStr(buf, idx, sFL);
            AppendHex(buf, idx, flt);

            AppendStr(buf, idx, nl);
        }

        // Thêm bảng chú giải thuật ngữ
        fixed (char* legend1 = "\n[LEGEND] F=Frames | IPCS=IPC Sends | IPCR=IPC Receives | MEM=Memory Allocs\n")
        fixed (char* legend2 = "         SHM=Shared Mem | YLD=Yields | SLP=Sleeps | RST=Resets | FLT=Faults\n")
        {
            AppendStr(buf, idx, legend1);
            AppendStr(buf, idx, legend2);
        }

        buf[*idx] = '\0';

        SyscallResetCursor();
        SyscallPrint(buf);
    }

    // Giữ nguyên hàm in Hex phục vụ ASM hiển thị
    [UnmanagedCallersOnly(EntryPoint = "PrintHexCsharp")]
    public static void PrintHexCsharp(uint v)
    {
        int idx = 0;
        char* num = stackalloc char[32];
        char* rev = stackalloc char[32];
        
        if (v == 0u) { num[idx++] = '0'; }
        else
        {
            int c = 0;
            char* digits = stackalloc char[16];
            digits[0] = '0'; digits[1] = '1'; digits[2] = '2'; digits[3] = '3';
            digits[4] = '4'; digits[5] = '5'; digits[6] = '6'; digits[7] = '7';
            digits[8] = '8'; digits[9] = '9'; digits[10] = 'A'; digits[11] = 'B';
            digits[12] = 'C'; digits[13] = 'D'; digits[14] = 'E'; digits[15] = 'F';

            int shift = 28;
            while (shift >= 0)
            {
                uint digit = (v >> shift) & 15u;
                if (digit != 0u || c != 0 || shift == 0)
                {
                    rev[c++] = digits[(int)digit];
                }
                shift -= 4;
            }
            while (c > 0) { num[idx++] = rev[--c]; }
        }
        num[idx] = '\0';
        SyscallPrint(num);
    }

    public static void Main() { }
}