// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;
namespace NekkoApp;

using static NekkoApp.API;

public static unsafe class NekkoTop
{
    // [DllImport("*", EntryPoint = "SyscallPrint")] public static extern void Print(char* str);
    // [DllImport("*", EntryPoint = "SyscallClear")] public static extern void Clear(uint color);
    // [DllImport("*", EntryPoint = "SyscallGetProcessInfo")] public static extern int GetProcessInfo(uint id, ProcessInfo* info);
    // [DllImport("*", EntryPoint = "SyscallYield")] public static extern void Yield();
    // [DllImport("*", EntryPoint = "SyscallGetChar")] public static extern byte GetChar();
    // [DllImport("*", EntryPoint = "SyscallExit")] public static extern void Exit();
    // // [SYSTEM CALL] Direct IPC wait system call
    // [DllImport("*", EntryPoint = "SyscallWaitIPC")] public static extern void WaitIPC();
    // [DllImport("*", EntryPoint = "SyscallResetCursor")] public static extern void ResetCursor();

    public static int BufIndex = 0;
    
    public static void AppendChar(char* buf, char c) {
        if (BufIndex < 4000) buf[BufIndex++] = c;
    }

    public static void AppendStr(char* buf, char* str) {
        int i = 0;
        while (str[i] != '\0' && BufIndex < 4000) { buf[BufIndex++] = str[i++]; }
    }

    public static void AppendNumAligned(char* buf, ulong num, char* suffix, int width) {
        char* temp = stackalloc char[32];
        int idx = 0;
        if (num == 0) { temp[idx++] = '0'; }
        else {
            char* rev = stackalloc char[20]; int c = 0;
            while (num > 0) { rev[c++] = (char)('0' + (num % 10)); num /= 10; }
            while (c > 0) { temp[idx++] = rev[--c]; }
        }
        
        if (suffix != null) {
            int sIdx = 0;
            while(suffix[sIdx] != '\0') temp[idx++] = suffix[sIdx++];
        }
        
        temp[idx] = '\0';
        
        for (int i = 0; i < idx; i++) AppendChar(buf, temp[i]);
        for (int i = idx; i < width; i++) AppendChar(buf, ' ');
    }

    [UnmanagedCallersOnly(EntryPoint = "AppMain")]
    public static void AppMain()
    {
        InitAPI();

        ProcessInfo info = default;
        ulong* lastTicks = stackalloc ulong[32];
        for (int i = 0; i < 32; i++) lastTicks[i] = 0;
        ulong* deltas = stackalloc ulong[32];
        
        char* frameBuffer = stackalloc char[4096];

        for (uint i = 0; i < 32; i++) {
            if (SyscallGetProcessInfo(i, &info) == 1 && (info.Active == 1 || info.Active == 2)) {
                lastTicks[i] = info.CpuTicks;
            }
        }

        SyscallClear(0x00111111);

        while (true)
        {
            ulong totalDelta = 0;
            for (uint i = 0; i < 32; i++) {
                if (SyscallGetProcessInfo(i, &info) == 1 && (info.Active == 1 || info.Active == 2)) {
                    if (lastTicks[i] == 0) { deltas[i] = 0; } 
                    else {
                        if (info.CpuTicks >= lastTicks[i]) deltas[i] = info.CpuTicks - lastTicks[i];
                        else deltas[i] = 0;
                    }
                    lastTicks[i] = info.CpuTicks;
                    totalDelta += deltas[i];
                } else {
                    lastTicks[i] = 0; deltas[i] = 0;
                }
            }
            if (totalDelta == 0) totalDelta = 1;

            BufIndex = 0; 
            
            fixed (char* h1 = "================================================================================\n") AppendStr(frameBuffer, h1);
            fixed (char* h2 = "                     NEKKOTOP - REALTIME RESOURCE MONITOR                       \n") AppendStr(frameBuffer, h2);
            fixed (char* h3 = "================================================================================\n") AppendStr(frameBuffer, h3);
            fixed (char* cols = "PID  NAME             CPU%   RES(KB)  VIRT(KB)  UID   STATE\n") AppendStr(frameBuffer, cols);
            fixed (char* sep =  "--------------------------------------------------------------------------------\n") AppendStr(frameBuffer, sep);
            
            for (uint i = 0; i < 32; i++)
            {
                if (SyscallGetProcessInfo(i, &info) == 1 && (info.Active == 1 || info.Active == 2))
                {
                    AppendNumAligned(frameBuffer, info.ID, null, 5);
                    
                    int nameLen = 0;
                    for (int k = 0; k < 16; k++) {
                        if (info.Name[k] == 0) break;
                        AppendChar(frameBuffer, (char)info.Name[k]);
                        nameLen++;
                    }
                    for(int k = nameLen; k < 17; k++) AppendChar(frameBuffer, ' '); 
                    
                    ulong cpuPercent = (deltas[i] * 100) / totalDelta;
                    if (cpuPercent > 100) cpuPercent = 100; 
                    fixed (char* pct = "%") AppendNumAligned(frameBuffer, cpuPercent, pct, 7);
                    
                    ulong resKb = (ulong)info.PhysPages * 4;
                    ulong virtKb = (ulong)info.VirtPages * 4;
                    
                    fixed (char* kb = " K") 
                    {
                        AppendNumAligned(frameBuffer, resKb, kb, 9);
                        AppendNumAligned(frameBuffer, virtKb, kb, 10);
                    }

                    AppendNumAligned(frameBuffer, info.UID, null, 6);
                    
                    if (info.IsPhantomDead == 1) { fixed (char* st = "[DEAD]      ") AppendStr(frameBuffer, st); }
                    else if (info.Active == 2)   { fixed (char* st = "[SLEEP]     ") AppendStr(frameBuffer, st); } 
                    else if (info.IsJailed == 1) { fixed (char* st = "[NORMAL]    ") AppendStr(frameBuffer, st); }
                    else if (info.UID == 0)      { fixed (char* st = "[ROOT]      ") AppendStr(frameBuffer, st); }
                    else                         { fixed (char* st = "[USER]      ") AppendStr(frameBuffer, st); }

                    AppendChar(frameBuffer, '\n');
                }
            }

            fixed (char* footer = "\n================================================================================\n") AppendStr(frameBuffer, footer);
            fixed (char* hint = "                 Press 'q' to Quit NekkoTop and return to Shell            \n") AppendStr(frameBuffer, hint);
            fixed (char* blank = "                                                                                \n") {
                AppendStr(frameBuffer, blank); AppendStr(frameBuffer, blank); AppendStr(frameBuffer, blank);
            }
            
            frameBuffer[BufIndex] = '\0'; 

            SyscallResetCursor();
            SyscallPrint(frameBuffer);

            // ==========================================================
            // [CPU OPTIMIZATION] Non-blocking keyboard polling with sleep loop
            // Polls 100 times with a short sleep interval to update the screen once per second.
            // This prevents CPU resource starvation during key checking.
            // ==========================================================
            for (int wait = 0; wait < 100; wait++) 
            {
                char c = (char)SyscallGetChar();
                if (c == 'q' || c == 'Q') { 
                    SyscallClear(0x00111111); 
                    SyscallExit(); 
                    while(true) SyscallWaitIPC(); // CÓ CHẾT CŨNG CHẾT ĐẸP!
                }
                SyscallWaitIPC(); // Ngủ sâu 20ms nhường CPU cho cả vũ trụ!
            }
        }
    }
    public static void Main() { }
}