// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
// MODULE: InternalShell - syscall 88 dispatcher (Kernel builtin shell).
// Extracted from Syscall.cs to keep that file small. This module handles
// the kernel-side command interpreter for builtins (clear, help, mem, ...,
// cat, run, daemon, logout, shutdown, reboot).
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

public static unsafe class InternalShell
{
    [DllImport("*", EntryPoint = "IsValidUserPtr_Pas")]
    private static extern byte IsValidUserPtr_Pas(int threadId, ulong virtAddr, ulong pml4Phys, ulong totalPages);

    [DllImport("*", EntryPoint = "IsPrintableChar_Pas")]
    private static extern byte IsPrintableChar_Pas(ushort c);

    [DllImport("*", EntryPoint = "StrCmp_Pas")]
    private static extern byte StrCmp_Pas(char* s1, char* s2);

    [DllImport("*", EntryPoint = "StrStartsWith_Pas")]
    private static extern byte StrStartsWith_Pas(char* s, char* prefix);

    [DllImport("*", EntryPoint = "SplitTwoArgs_Pas")]
    private static extern byte SplitTwoArgs_Pas(char* rest, char* outFirst, int firstCap, char* outSecond, int secondCap);

    [DllImport("*", EntryPoint = "OctalStrToUInt_Pas")]
    private static extern uint OctalStrToUInt_Pas(char* str);

    public static ulong Dispatch(int id, ulong currentTicks, bool isKing, RegisterContext* ctx)
    {
        if (ArchCtx.GetArg(ctx, 1) == 0 || IsValidUserPtr_Pas(id, ArchCtx.GetArg(ctx, 1), Scheduler.Threads[id].AddrSpace, PMM.TotalPages) == 0)
        { ArchCtx.SetRet(ctx, 0); return 0; }
        char* cmdStr = (char*)ArchCtx.GetArg(ctx, 1);
        ulong targetFb = ArchCtx.GetArg(ctx, 2);

        uint* oldFb = Terminal.fb;
        uint oldW = Terminal.width;
        uint oldH = Terminal.height;
        uint oldSl = Terminal.scanLine;

        fixed (char* cmdClear = "clear\0")
        fixed (char* cmdHelp = "help\0")
        fixed (char* cmdMem = "mem\0")
        fixed (char* cmdUptime = "uptime\0")
        fixed (char* cmdPci = "pci\0")
        fixed (char* cmdDate = "date\0")
        fixed (char* cmdUname = "uname\0")
        fixed (char* cmdRun = "run \0")
        fixed (char* cmdDaemon = "daemon \0")
        fixed (char* cmdPoweroff = "shutdown\0")
        fixed (char* cmdLogout = "logout\0")
        fixed (char* cmdReboot = "reboot\0")
        fixed (char* cmdCat = "cat \0")
        {
            if (StrCmp_Pas(cmdStr, cmdClear) != 0) { Terminal.Clear(0x00111111); }
            else if (StrCmp_Pas(cmdStr, cmdHelp) != 0) { fixed (char* msg = "NekkoOS Microkernel\nCommands: clear, help, mem, uptime, pci, date, uname, run, daemon, ls, cat, cd, write\n\0") Terminal.Print(msg); }
            else if (StrCmp_Pas(cmdStr, cmdMem) != 0) { fixed (char* msg = "Free memory:\t\t\0") Terminal.Print(msg); Terminal.PrintHex(PMM.FreePages * 4096 / (1024 * 1024)); fixed (char* msg2 = " MB\n\0") Terminal.Print(msg2); }
            else if (StrCmp_Pas(cmdStr, cmdUptime) != 0) { ulong totalSeconds = currentTicks / 1000; ulong ms = currentTicks % 1000; fixed (char* msg = "System Uptime: \0") Terminal.Print(msg); Terminal.PrintHex(totalSeconds); fixed (char* msg2 = " seconds, \0") Terminal.Print(msg2); Terminal.PrintHex(ms); fixed (char* msg3 = " ms\n\n\0") Terminal.Print(msg3); }
            else if (StrCmp_Pas(cmdStr, cmdPci) != 0) { PCI.ScanBus(); }
            else if (StrCmp_Pas(cmdStr, cmdDate) != 0) { RTC.PrintCurrentTime(); }
            else if (StrCmp_Pas(cmdStr, cmdPoweroff) != 0) {
                if (isKing) Power.Shutdown();
                else { Terminal.SetColor(0x00FF0000); fixed(char* e = "[!] Permission Denied: Only Root can shutdown the system!\n\0") Terminal.Print(e); }
            }
            else if (StrCmp_Pas(cmdStr, cmdReboot) != 0) {
                if (isKing) Power.Reboot();
                else { Terminal.SetColor(0x00FF0000); fixed(char* e = "[!] Permission Denied: Only Root can reboot the system!\n\0") Terminal.Print(e); }
            }
            else if (StrCmp_Pas(cmdStr, cmdUname) != 0) { fixed (char* buildDate = "NekkoOS Microkernel x86_64\n\0") Terminal.Print(buildDate); }
            else if (StrStartsWith_Pas(cmdStr, cmdCat) != 0)
            {
                HandleCat(cmdStr);
            }
            else if (StrStartsWith_Pas(cmdStr, cmdRun) != 0 || StrStartsWith_Pas(cmdStr, cmdDaemon) != 0)
            {
                bool isDaemon = StrStartsWith_Pas(cmdStr, cmdDaemon) != 0;
                if (!isKing && isDaemon) {
                    Terminal.SetColor(0x00FF0000);
                    fixed(char* e = "[!] Permission Denied: Only Root can spawn Daemons!\n\0") Terminal.Print(e);
                    Terminal.SetColor(0x00FFFFFF);
                    ArchCtx.SetRet(ctx, 0); return 0;
                }
                char* appName = isDaemon ? cmdStr + 7 : cmdStr + 4;
                if (*appName == '\0') { ArchCtx.SetRet(ctx, 0); return 0; }
                HandleRunOrDaemon(id, appName, isDaemon, ctx);
            }
            else if (StrCmp_Pas(cmdStr, cmdLogout) != 0)
            {
                HandleLogout(id, ctx);
                // HandleLogout may terminate this thread; reset/return signaled
            }
            else
            {
                Terminal.SetColor(0x00FF0000);
                fixed (char* msg = "Kernel: Unknown Command or handled by Ring 3: \0") Terminal.Print(msg);
                Terminal.Print(cmdStr); fixed (char* nl = "\n\0") Terminal.Print(nl);
            }
        }

        Terminal.SetColor(0x00FFFFFF); ArchCtx.SetRet(ctx, 1);
        return 0;
    }

    private static void HandleCat(char* cmdStr)
    {
        char* fileName = cmdStr + 4;
        if (*fileName == '\0') return;
        uint fSize = 0;
        byte* fBuf = FAT16.ReadFile(fileName, &fSize);
        if (fBuf == null) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* e = "[!] cat: File not found on FAT16.\n\0") Terminal.Print(e);
            return;
        }
        if (fSize > 16384) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* e = "[!] File too large (>16KB). Refusing to print to prevent Terminal freeze.\n\0") Terminal.Print(e);
        } else {
            Terminal.SetColor(0x00FFFFFF);
            for(uint i = 0; i < fSize; i++) {
                char c = (char)fBuf[i];
                if (c == '\r') continue;
                if (IsPrintableChar_Pas((ushort)c) != 0) Terminal.DrawChar(c);
                else Terminal.DrawChar('.');
            }
            fixed (char* nl2 = "\n\0") Terminal.Print(nl2);
        }
        NekkoOS.Kernel.Heap.Free(fBuf);
    }

    private static void HandleRunOrDaemon(int id, char* appName, bool isDaemon, RegisterContext* ctx)
    {
        int callerThreadForRead = id;
        uint fileSize = 0; IO.EnableInterrupts();
        byte* rawData = FAT16.ReadFile(appName, &fileSize, callerThreadForRead);

        if (rawData != null) {
            if (rawData[0] != 'M' || rawData[1] != 'Z') {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] Kernel FATAL: Corrupted PE Header!\n\0") Terminal.Print(err);
                NekkoOS.Kernel.Heap.Free(rawData); ArchCtx.SetRet(ctx, 0); return;
            }

            Terminal.SetColor(0x00FFFF00);
            bool isJailed = (Scheduler.Threads[id].UID != 0 || Scheduler.Threads[id].GID != 0);
            if (isJailed) { Terminal.SetColor(0x00FF00FF); fixed (char* msg = "[!] ZERO TRUST: Untrusted App detected! Jailing in Phantom Sandbox...\n\0") Terminal.Print(msg); }

            PELoader.LoadAndRun(rawData, isDaemon, isJailed, false, appName, 1);

            if (isDaemon) { Terminal.SetColor(0x0000FF00); }
        }
        else {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] Kernel: Execute failed! File not found or OOM: \0") Terminal.Print(err);
            Terminal.Print(appName); fixed (char* nl = "\n\0") Terminal.Print(nl);
        }
    }

    private static void HandleLogout(int id, RegisterContext* ctx)
    {
        uint currentUid = Scheduler.Threads[id].UID;
        Terminal.SetColor(0x00FFFF00); fixed (char* msg = "\n[*] Saving session... Logging out...\n\0") Terminal.Print(msg);

        int callerThreadForLogout = id;
        uint fileSize = 0; IO.EnableInterrupts(); byte* rawData = null;
        fixed (char* logonFile = "syslogon.exe\0") fixed (char* dirRoot = "\\\0") {
            FAT16.Cd(dirRoot);
            rawData = FAT16.ReadFile(logonFile, &fileSize, callerThreadForLogout);
            if (rawData != null && rawData[0] == 'M' && rawData[1] == 'Z') {
                PELoader.LoadAndRun(rawData, false, false, true, logonFile);
            } else {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Cannot find syslogon.exe! System Halt!\n\0") Terminal.Print(err);
                if (rawData != null) NekkoOS.Kernel.Heap.Free(rawData);
                while(true) IO.Hlt();
            }
        }

        if (currentUid == 0) { Scheduler.TerminateCurrentTask(); }
        else {
            bool irq = Scheduler.AcquireSchedLockSafe();
            for (int i = 1; i < Scheduler.ThreadCount; i++) {
                if (i != id && Scheduler.Threads[i].Active == 1 && Scheduler.Threads[i].UID == currentUid) {
                    Scheduler.Threads[i].Active = 0; Scheduler.Threads[i].UID = 9999;
                }
            }
            Scheduler.ReleaseSchedLockSafe(irq);
            Scheduler.TerminateCurrentTask();
        }
    }
}