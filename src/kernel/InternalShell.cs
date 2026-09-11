// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
// MODULE: InternalShell - syscall 88 dispatcher (Kernel builtin shell).
// SHIM: Command parser in src/kernel/pas/internal_shell.pas.
// C# executes the parsed actions (FAT16, PELoader, etc.).
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

public static unsafe class InternalShell
{
    // Command action enum (matches Pascal TShellAction)
    public enum ShellAction : byte
    {
        None = 0,
        Clear = 1,
        Help = 2,
        Mem = 3,
        Uptime = 4,
        Pci = 5,
        Date = 6,
        PowerOff = 7,
        Reboot = 8,
        Uname = 9,
        Cat = 10,
        Run = 11,
        Daemon = 12,
        Logout = 13,
        Unknown = 255
    }

    // [PASCAL PORT] Parse command string into action + argument (output via pointers)
    [DllImport("*", EntryPoint = "InternalShell_ParseCommand_Pas")]
    private static extern byte InternalShell_ParseCommand_Pas(char* cmdStr, byte* outAction, ushort* outArg, ushort* outArgLen);

    // [PASCAL PORT] IsPrintableChar for cat builtin
    [DllImport("*", EntryPoint = "IsPrintableChar_Pas")]
    private static extern byte IsPrintableChar_Pas(ushort c);

    // [PASCAL PORT] User pointer validation
    [DllImport("*", EntryPoint = "IsValidUserPtr_Pas")]
    private static extern byte IsValidUserPtr_Pas(int threadId, ulong virtAddr, ulong pml4Phys, ulong totalPages);

    private static bool IsValidUserPtr(ulong ptr)
    {
        if (ptr < 0x1000 || ptr > 0x00007FFFFFFFFFFF) return false;
        int tid = Scheduler.CurrentThreadId;
        if (tid < 0 || tid >= Scheduler.ThreadCount) return false;
        ulong pml4Phys = Scheduler.Threads[tid].AddrSpace;
        return IsValidUserPtr_Pas(tid, ptr, pml4Phys, PMM.TotalPages * 4096) != 0;
    }

    public static ulong Dispatch(int id, ulong currentTicks, bool isKing, RegisterContext* ctx)
    {
        if (ArchCtx.GetArg(ctx, 1) == 0 || !IsValidUserPtr(ArchCtx.GetArg(ctx, 1)))
        {
            ArchCtx.SetRet(ctx, 0);
            return 0;
        }
        char* cmdStr = (char*)ArchCtx.GetArg(ctx, 1);
        ulong targetFb = ArchCtx.GetArg(ctx, 2);

        byte action = 0;
        ushort argLen = 0;
        ushort* argPtr = stackalloc ushort[256];
        if (InternalShell_ParseCommand_Pas(cmdStr, &action, argPtr, &argLen) == 0)
            {
                ArchCtx.SetRet(ctx, 0);
                return 0;
            }

            switch ((ShellAction)action)
            {
                case ShellAction.Clear:
                    Terminal.Clear(0x00111111);
                    break;
                case ShellAction.Help:
                    fixed (char* msg = "NekkoOS Microkernel\nCommands: clear, help, mem, uptime, pci, date, uname, run, daemon, ls, cat, cd, write\n\0") Terminal.Print(msg);
                    break;
                case ShellAction.Mem:
                    fixed (char* msg = "Free memory:\t\t\0") Terminal.Print(msg);
                    Terminal.PrintHex(PMM.FreePages * 4096 / (1024 * 1024));
                    fixed (char* msg2 = " MB\n\0") Terminal.Print(msg2);
                    break;
                case ShellAction.Uptime:
                    ulong totalSeconds = currentTicks / 1000;
                    ulong ms = currentTicks % 1000;
                    fixed (char* msg = "System Uptime: \0") Terminal.Print(msg);
                    Terminal.PrintHex(totalSeconds);
                    fixed (char* msg2 = " seconds, \0") Terminal.Print(msg2);
                    Terminal.PrintHex(ms);
                    fixed (char* msg3 = " ms\n\n\0") Terminal.Print(msg3);
                    break;
                case ShellAction.Pci:
                    PCI.ScanBus();
                    break;
                case ShellAction.Date:
                    RTC.PrintCurrentTime();
                    break;
                case ShellAction.PowerOff:
                    if (isKing) Power.Shutdown();
                    else { Terminal.SetColor(0x00FF0000); fixed(char* e = "[!] Permission Denied: Only Root can shutdown the system!\n\0") Terminal.Print(e); }
                    break;
                case ShellAction.Reboot:
                    if (isKing) Power.Reboot();
                    else { Terminal.SetColor(0x00FF0000); fixed(char* e = "[!] Permission Denied: Only Root can reboot the system!\n\0") Terminal.Print(e); }
                    break;
                case ShellAction.Uname:
                    fixed (char* buildDate = "NekkoOS Microkernel x86_64\n\0") Terminal.Print(buildDate);
                    break;
                case ShellAction.Cat:
                    HandleCat(argPtr, argLen);
                    break;
                case ShellAction.Run:
                case ShellAction.Daemon:
                    bool isDaemon = (ShellAction)action == ShellAction.Daemon;
                    if (!isKing && isDaemon)
                    {
                        Terminal.SetColor(0x00FF0000);
                        fixed(char* e = "[!] Permission Denied: Only Root can spawn Daemons!\n\0") Terminal.Print(e);
                        Terminal.SetColor(0x00FFFFFF);
                        ArchCtx.SetRet(ctx, 0);
                        return 0;
                    }
                    HandleRunOrDaemon(id, argPtr, argLen, isDaemon, ctx);
                    break;
                case ShellAction.Logout:
                    HandleLogout(id, ctx);
                    break;
                case ShellAction.Unknown:
                default:
                    Terminal.SetColor(0x00FF0000);
                    fixed (char* msg = "Kernel: Unknown Command or handled by Ring 3: \0") Terminal.Print(msg);
                    PrintArg(argPtr, argLen);
                    fixed (char* nl = "\n\0") Terminal.Print(nl);
                    break;
            }

        Terminal.SetColor(0x00FFFFFF);
        ArchCtx.SetRet(ctx, 1);
        return 0;
    }

    private static void HandleCat(ushort* arg, ushort argLen)
    {
        char* fileName = (char*)arg;
        if (argLen == 0 || fileName[0] == '\0') return;
        uint fSize = 0;
        byte* fBuf = FAT16.ReadFile(fileName, &fSize);
        if (fBuf == null)
        {
            Terminal.SetColor(0x00FF0000);
            fixed(char* e = "[!] cat: File not found on FAT16.\n\0") Terminal.Print(e);
            return;
        }
        if (fSize > 16384)
        {
            Terminal.SetColor(0x00FF0000);
            fixed(char* e = "[!] File too large (>16KB). Refusing to print to prevent Terminal freeze.\n\0") Terminal.Print(e);
        }
        else
        {
            Terminal.SetColor(0x00FFFFFF);
            for (uint i = 0; i < fSize; i++)
            {
                char c = (char)fBuf[i];
                if (c == '\r') continue;
                if (IsPrintableChar_Pas((ushort)c) != 0) Terminal.DrawChar(c);
                else Terminal.DrawChar('.');
            }
            fixed (char* nl2 = "\n\0") Terminal.Print(nl2);
        }
        NekkoOS.Kernel.Heap.Free(fBuf);
    }

    private static void HandleRunOrDaemon(int id, ushort* arg, ushort argLen, bool isDaemon, RegisterContext* ctx)
    {
        char* appName = (char*)arg;
        if (argLen == 0 || appName[0] == '\0')
        {
            ArchCtx.SetRet(ctx, 0);
            return;
        }

        int callerThreadForRead = id;
        uint fileSize = 0;
        IO.EnableInterrupts();
        byte* rawData = FAT16.ReadFile(appName, &fileSize, callerThreadForRead);

        if (rawData != null)
        {
            if (rawData[0] != 'M' || rawData[1] != 'Z')
            {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] Kernel FATAL: Corrupted PE Header!\n\0") Terminal.Print(err);
                NekkoOS.Kernel.Heap.Free(rawData);
                ArchCtx.SetRet(ctx, 0);
                return;
            }

            Terminal.SetColor(0x00FFFF00);
            bool isJailed = (Scheduler.Threads[id].UID != 0 || Scheduler.Threads[id].GID != 0);
            if (isJailed)
            {
                Terminal.SetColor(0x00FF00FF);
                fixed (char* msg = "[!] ZERO TRUST: Untrusted App detected! Jailing in Phantom Sandbox...\n\0") Terminal.Print(msg);
            }

            PELoader.LoadAndRun(rawData, isDaemon, isJailed, false, appName, 1);

            if (isDaemon) Terminal.SetColor(0x0000FF00);
        }
        else
        {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] Kernel: Execute failed! File not found or OOM: \0") Terminal.Print(err);
            Terminal.Print(appName);
            fixed (char* nl = "\n\0") Terminal.Print(nl);
        }
    }

    private static void HandleLogout(int id, RegisterContext* ctx)
    {
        uint currentUid = Scheduler.Threads[id].UID;
        Terminal.SetColor(0x00FFFF00);
        fixed (char* msg = "\n[*] Saving session... Logging out...\n\0") Terminal.Print(msg);

        int callerThreadForLogout = id;
        uint fileSize = 0;
        IO.EnableInterrupts();
        byte* rawData = null;
        fixed (char* logonFile = "syslogon.exe\0") fixed (char* dirRoot = "\\\0") fixed (char* dirEtc = "ETC\0") fixed (char* passwdFile = "PASSWD\0")
        {
            FAT16.Cd(dirRoot);
            FAT16.Cd(dirEtc, 0);
            rawData = FAT16.ReadFile(passwdFile, &fileSize, callerThreadForLogout);
            FAT16.Cd(dirRoot);
            if (rawData != null && rawData[0] == 'M' && rawData[1] == 'Z')
            {
                PELoader.LoadAndRun(rawData, false, false, true, logonFile);
            }
            else
            {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: Cannot find syslogon.exe! System Halt!\n\0") Terminal.Print(err);
                if (rawData != null) NekkoOS.Kernel.Heap.Free(rawData);
                while (true) IO.Hlt();
            }
        }

        if (currentUid == 0)
        {
            Scheduler.TerminateCurrentTask();
        }
        else
        {
            bool irq = Scheduler.AcquireSchedLockSafe();
            for (int i = 1; i < Scheduler.ThreadCount; i++)
            {
                if (i != id && Scheduler.Threads[i].Active == 1 && Scheduler.Threads[i].UID == currentUid)
                {
                    Scheduler.Threads[i].Active = 0;
                    Scheduler.Threads[i].UID = 9999;
                }
            }
            Scheduler.ReleaseSchedLockSafe(irq);
            Scheduler.TerminateCurrentTask();
        }
    }

    private static void PrintArg(ushort* arg, ushort len)
    {
        for (ushort i = 0; i < len; i++)
        {
            char c = (char)arg[i];
            if (c == '\0') break;
            Terminal.DrawChar(c);
        }
    }
}