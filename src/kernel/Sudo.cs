// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
// MODULE: Sudo - syscall 94 dispatcher (elevate-one-command).
// Extracted from Syscall.cs to keep that file small. This module handles
// password verification, sudoers lookup, and temporary privilege
// elevation for the caller's thread.
// =========================================================================

using System.Runtime.InteropServices;
using NekkoOS.Kernel.Crypto;

namespace NekkoOS.Kernel;

public static unsafe class Sudo
{
    [DllImport("*", EntryPoint = "IsValidUserPtr_Pas")]
    private static extern byte IsValidUserPtr_Pas(int threadId, ulong virtAddr, ulong pml4Phys, ulong totalPages);

    [DllImport("*", EntryPoint = "ParsePasswdLine_Pas")]
    private static extern uint ParsePasswdLine_Pas(char* linePtr, char* userOut, uint userCap, char* saltOut, uint saltCap, char* hashOut, uint hashCap, char* uidOut, uint uidCap);

    [DllImport("*", EntryPoint = "SudoersContains_Pas")]
    private static extern byte SudoersContains_Pas(byte* buf, uint bufLen, char* user);

    [DllImport("*", EntryPoint = "Atoi_Pas")]
    private static extern uint Atoi_Pas(char* str);

    [DllImport("*", EntryPoint = "StrCpyLimited_Pas")]
    private static extern uint StrCpyLimited_Pas(char* dest, char* src, uint cap);

    [DllImport("*", EntryPoint = "StrStartsWith_Pas")]
    private static extern byte StrStartsWith_Pas(char* s, char* prefix);

    [DllImport("*", EntryPoint = "StrCmp_Pas")]
    private static extern byte StrCmp_Pas(char* s1, char* s2);

    [DllImport("*", EntryPoint = "SplitTwoArgs_Pas")]
    private static extern byte SplitTwoArgs_Pas(char* rest, char* outFirst, int firstCap, char* outSecond, int secondCap);

    [DllImport("*", EntryPoint = "OctalStrToUInt_Pas")]
    private static extern uint OctalStrToUInt_Pas(char* str);

    [DllImport("*", EntryPoint = "IsPrintableChar_Pas")]
    private static extern byte IsPrintableChar_Pas(ushort c);

    public static int Dispatch(int id, RegisterContext* ctx)
    {
        if (ArchCtx.GetArg(ctx, 1) == 0 || IsValidUserPtr_Pas(id, ArchCtx.GetArg(ctx, 1), Scheduler.Threads[id].AddrSpace, PMM.TotalPages) == 0
            || ArchCtx.GetArg(ctx, 2) == 0 || IsValidUserPtr_Pas(id, ArchCtx.GetArg(ctx, 2), Scheduler.Threads[id].AddrSpace, PMM.TotalPages) == 0)
        { ArchCtx.SetRet(ctx, 0); return 0; }
        char* appName = (char*)ArchCtx.GetArg(ctx, 1);
        char* inputPass = (char*)ArchCtx.GetArg(ctx, 2);

        byte* sudoWriteContent = (ArchCtx.GetArg(ctx, 3) != 0 && IsValidUserPtr_Pas(id, ArchCtx.GetArg(ctx, 3), Scheduler.Threads[id].AddrSpace, PMM.TotalPages) != 0) ? (byte*)ArchCtx.GetArg(ctx, 3) : null;
        uint sudoWriteContentLen = (uint)ArchCtx.GetArg(ctx, 4);

        int callerThreadForSudo = id;
        uint callerUidForSudo = Scheduler.Threads[id].UID;
        *(uint*)0x8000UL = 1;
        IO.EnableInterrupts();

        char* lineUser = stackalloc char[32];
        char* lineSalt = stackalloc char[64];
        char* lineHash = stackalloc char[80];
        char* lineUID = stackalloc char[16];
        byte* saltBytes = stackalloc byte[32];
        byte* hashInputBuf = stackalloc byte[32 + 32];
        byte* computedHash = stackalloc byte[32];
        char* computedHashHex = stackalloc char[80];
        char* matchedUser = stackalloc char[32];

        int ret = 0;
        bool foundAccount = false;
        fixed (char* dirEtc = "ETC\0") fixed (char* dirRoot = "\\\0") fixed (char* passFileName = "PASSWD\0") {
            FAT16.Cd(dirRoot, 0); FAT16.Cd(dirEtc, 0);
            uint passSize = 0;
            byte* passBuf = FAT16.ReadFile(passFileName, &passSize, 0);
            FAT16.Cd(dirRoot, 0);
            *(uint*)0x8000UL = 2;

            if (passBuf != null && passSize > 0) {
                int i = 0;
                while (i < (int)passSize) {
                    ParsePasswdLine_Pas((char*)&passBuf[i], lineUser, 32, lineSalt, 64, lineHash, 80, lineUID, 16);
                    while (i < (int)passSize && passBuf[i] != '\n' && passBuf[i] != '\r') i++;
                    while (i < (int)passSize && (passBuf[i] == '\n' || passBuf[i] == '\r')) i++;

                    uint lineUidVal = Atoi_Pas(lineUID);

                    if (lineUser[0] != '\0' && lineUidVal == callerUidForSudo) {
                        *(uint*)0x8000UL = 3;
                        StrCpyLimited_Pas(matchedUser, lineUser, 32);

                        int saltLen = KernHexUtil.HexToBytes(lineSalt, saltBytes, 32);
                        int passLen = 0; while (inputPass[passLen] != '\0') passLen++;
                        *(uint*)0x8000UL = 4;
                        int hashInputLen = 0;
                        for (int k = 0; k < saltLen; k++) hashInputBuf[hashInputLen++] = saltBytes[k];
                        for (int k = 0; k < passLen; k++) hashInputBuf[hashInputLen++] = (byte)inputPass[k];

                        SHA256.Compute(hashInputBuf, (ulong)hashInputLen, computedHash);
                        KernHexUtil.BytesToHex(computedHash, 32, computedHashHex);

                        foundAccount = true;
                        bool passOk = KernHexUtil.ConstantTimeEq(computedHashHex, lineHash, 64);
                        *(uint*)0x8000UL = (uint)(5 | (passOk ? 0x100 : 0));

                        KernHexUtil.ZeroMemChar(lineSalt, 64); KernHexUtil.ZeroMemChar(lineHash, 80);
                        KernHexUtil.ZeroMemByte(saltBytes, 32); KernHexUtil.ZeroMemByte(hashInputBuf, 64);
                        KernHexUtil.ZeroMemByte(computedHash, 32); KernHexUtil.ZeroMemChar(computedHashHex, 80);

                        if (!passOk) {
                            NekkoOS.Kernel.Heap.Free(passBuf);
                            *(uint*)0x8000UL = 6;
                            ret = 0; goto cleanup;
                        }

                        bool inSudoers = false;
                        *(uint*)0x8000UL = 7;
                        fixed (char* sudoersFile = "SUDOERS\0") {
                            FAT16.Cd(dirEtc, 0);
                            uint sudoSize = 0;
                            byte* sudoBuf = FAT16.ReadFile(sudoersFile, &sudoSize, 0);
                            FAT16.Cd(dirRoot, 0);
                            if (sudoBuf != null && sudoSize > 0) {
                                inSudoers = SudoersContains_Pas(sudoBuf, sudoSize, matchedUser) != 0;
                                NekkoOS.Kernel.Heap.Free(sudoBuf);
                            }
                        }

                        if (!inSudoers) { NekkoOS.Kernel.Heap.Free(passBuf); ret = 2; goto cleanup; }

                        fixed (char* vCat = "cat \0") fixed (char* vRm = "rm \0")
                        fixed (char* vMkdir = "mkdir \0") fixed (char* vRmdir = "rmdir \0")
                        fixed (char* vChmod = "chmod \0") fixed (char* vChown = "chown \0")
                        fixed (char* vLs = "ls\0") fixed (char* vLl = "ll\0") fixed (char* vCd = "cd \0")
                        fixed (char* vWrite = "write \0")
                        {
                            bool isBuiltin = StrStartsWith_Pas(appName, vCat) != 0 || StrStartsWith_Pas(appName, vRm) != 0 ||
                                              StrStartsWith_Pas(appName, vMkdir) != 0 || StrStartsWith_Pas(appName, vRmdir) != 0 ||
                                              StrStartsWith_Pas(appName, vChmod) != 0 || StrStartsWith_Pas(appName, vChown) != 0 ||
                                              StrCmp_Pas(appName, vLs) != 0 || StrCmp_Pas(appName, vLl) != 0 ||
                                              StrStartsWith_Pas(appName, vCd) != 0 || StrStartsWith_Pas(appName, vWrite) != 0;
                            if (isBuiltin) {
                                *(uint*)0x8000UL = 9;
                                uint sudoOrigUid = Scheduler.Threads[id].UID;
                                uint sudoOrigGid = Scheduler.Threads[id].GID;
                                Scheduler.Threads[id].UID = 0; Scheduler.Threads[id].GID = 0;

                                HandleBuiltin(id, callerThreadForSudo, appName, vCat, vRm, vMkdir, vRmdir, vChmod, vChown, vLs, vLl, vCd, vWrite, sudoWriteContent, sudoWriteContentLen);

                                Scheduler.Threads[id].UID = sudoOrigUid; Scheduler.Threads[id].GID = sudoOrigGid;
                                Terminal.SetColor(0x00FFFFFF);
                                *(uint*)0x8000UL = 12;
                                NekkoOS.Kernel.Heap.Free(passBuf);
                                *(uint*)0x8000UL = 13;
                                ret = 1; goto cleanup;
                            }
                        }

                        uint appFileSize = 0;
                        byte* rawData = FAT16.ReadFile(appName, &appFileSize, callerThreadForSudo);
                        if (rawData == null || rawData[0] != 'M' || rawData[1] != 'Z') {
                            if (rawData != null) NekkoOS.Kernel.Heap.Free(rawData);
                            NekkoOS.Kernel.Heap.Free(passBuf); ret = 3; goto cleanup;
                        }

                        PELoader.LoadAndRun(rawData, false, false, true, appName, 1);
                        NekkoOS.Kernel.Heap.Free(passBuf);
                        ret = 1; goto cleanup;
                    }
                }
                if (!foundAccount) { NekkoOS.Kernel.Heap.Free(passBuf); ret = 0; }
            } else { ret = 0; }
        }
    cleanup:
        ArchCtx.SetRet(ctx, (ulong)ret);
        return 0;
    }

    private static void HandleBuiltin(int id, int callerThreadForSudo, char* appName,
        char* vCat, char* vRm, char* vMkdir, char* vRmdir, char* vChmod, char* vChown,
        char* vLs, char* vLl, char* vCd, char* vWrite,
        byte* sudoWriteContent, uint sudoWriteContentLen)
    {
        if (StrCmp_Pas(appName, vLs) != 0 || StrCmp_Pas(appName, vLl) != 0) {
            char* listBuf = stackalloc char[2048];
            *(uint*)0x8000UL = 10;
            bool listOk = FAT16.ListDir(listBuf, 2048, callerThreadForSudo);
            *(uint*)0x8000UL = 11;
            if (listOk) {
                Terminal.SetColor(0x00FFFFFF);
                Terminal.Print(listBuf);
            } else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] sudo ls: Failed to list directory.\n\0") Terminal.Print(e); }
        }
        else if (StrStartsWith_Pas(appName, vCd) != 0) {
            char* p = appName + 3;
            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo cd <path>\n\0") Terminal.Print(e); }
            else { FAT16.Cd(p, callerThreadForSudo); }
        }
        else if (StrStartsWith_Pas(appName, vWrite) != 0) {
            char* p = appName + 6;
            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo write <path>\n\0") Terminal.Print(e); }
            else if (sudoWriteContent == null) {
                Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] sudo write: No content buffer provided.\n\0") Terminal.Print(e);
            }
            else {
                int wr = FAT16.WriteFileRelay(p, sudoWriteContent, sudoWriteContentLen, callerThreadForSudo);
                if (wr == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] File written successfully!\n\0") Terminal.Print(ok); }
                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Failed! Disk Full, Access Denied or File is a Directory!\n\0") Terminal.Print(e); }
            }
        }
        else if (StrStartsWith_Pas(appName, vCat) != 0) {
            char* p = appName + 4;
            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo cat <path>\n\0") Terminal.Print(e); }
            else {
                uint catSize = 0;
                byte* catBuf = FAT16.ReadFile(p, &catSize, callerThreadForSudo);
                if (catBuf != null) {
                    if (catSize > 16384) { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] File too large (>16KB). Refusing to print to prevent Terminal freeze.\n\0") Terminal.Print(e); }
                    else {
                        Terminal.SetColor(0x00FFFFFF);
                        for (uint k = 0; k < catSize; k++) {
                            char c = (char)catBuf[k];
                            if (c == '\r') continue;
                            if (IsPrintableChar_Pas((ushort)c) != 0) Terminal.DrawChar(c);
                            else Terminal.DrawChar('.');
                        }
                        fixed (char* nl2 = "\n\0") Terminal.Print(nl2);
                    }
                    NekkoOS.Kernel.Heap.Free(catBuf);
                } else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] sudo cat: File not found or Access Denied.\n\0") Terminal.Print(e); }
            }
        }
        else if (StrStartsWith_Pas(appName, vMkdir) != 0) {
            char* p = appName + 6;
            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo mkdir <path>\n\0") Terminal.Print(e); }
            else {
                int r = FAT16.MakeDir(p, callerThreadForSudo);
                if (r == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] Directory Created Successfully!\n\0") Terminal.Print(ok); }
                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Failed! Directory already exists or Disk Full.\n\0") Terminal.Print(e); }
            }
        }
        else if (StrStartsWith_Pas(appName, vRm) != 0) {
            char* p = appName + 3;
            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo rm <path>\n\0") Terminal.Print(e); }
            else {
                int r = FAT16.RemoveFile(p, callerThreadForSudo);
                if (r == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] File Removed and Clusters Recycled!\n\0") Terminal.Print(ok); }
                else if (r == 2) { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Cannot use RM on a Directory!\n\0") Terminal.Print(e); }
                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] File Not Found.\n\0") Terminal.Print(e); }
            }
        }
        else if (StrStartsWith_Pas(appName, vRmdir) != 0) {
            char* p = appName + 6;
            if (*p == '\0') { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo rmdir <path>\n\0") Terminal.Print(e); }
            else {
                int r = FAT16.RemoveDir(p, callerThreadForSudo);
                if (r == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] Directory and ALL its contents obliterated recursively!\n\0") Terminal.Print(ok); }
                else if (r == 2) { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Target is a File. Use 'sudo rm' instead.\n\0") Terminal.Print(e); }
                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Directory Not Found.\n\0") Terminal.Print(e); }
            }
        }
        else if (StrStartsWith_Pas(appName, vChmod) != 0) {
            char* rest = appName + 6;
            char* modeStr = stackalloc char[16]; char* path = stackalloc char[256];
            if (SplitTwoArgs_Pas(rest, modeStr, 16, path, 256) == 0) { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo chmod <mode> <path>\n\0") Terminal.Print(e); }
            else {
                uint mode = OctalStrToUInt_Pas(modeStr);
                int r = FAT16.Chmod(path, mode, callerThreadForSudo);
                if (r == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] Permissions Changed Successfully!\n\0") Terminal.Print(ok); }
                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Failed! Not Found.\n\0") Terminal.Print(e); }
            }
        }
        else if (StrStartsWith_Pas(appName, vChown) != 0) {
            char* rest = appName + 6;
            char* ownerStr = stackalloc char[32]; char* path = stackalloc char[256];
            if (SplitTwoArgs_Pas(rest, ownerStr, 32, path, 256) == 0) { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Usage: sudo chown <uid>:<gid> <path>\n\0") Terminal.Print(e); }
            else {
                int r = FAT16.Chown(path, ownerStr, callerThreadForSudo);
                if (r == 1) { Terminal.SetColor(0x0000FF00); fixed (char* ok = "[+] Ownership Changed Successfully!\n\0") Terminal.Print(ok); }
                else { Terminal.SetColor(0x00FF0000); fixed (char* e = "[!] Failed! Not Found.\n\0") Terminal.Print(e); }
            }
        }
    }
}