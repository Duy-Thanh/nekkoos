// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
// MODULE: X86SyscallImpl - x86_64 implementation của IArcSyscall interface.
// Chứa các syscall I/O-specific cho kiến trúc x86_64: keyboard polling,
// physical memory mapping, framebuffer management, hardware reporting.
//
// Logic được di chuyển từ Syscall.cs case 4/12/13/50/51/52 (refactor #7).
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

public sealed unsafe class X86SyscallImpl : IArcSyscall
{
    [DllImport("*", EntryPoint = "IsValidUserPtr_Pas")]
    private static extern byte IsValidUserPtr_Pas(int threadId, ulong virtAddr, ulong pml4Phys, ulong totalPages);

    private static byte IsValidUserPtr(ulong ptr)
    {
        int tid = Scheduler.CurrentThreadId;
        if (tid < 0 || tid >= Scheduler.ThreadCount) return 0;
        ulong pml4Phys = Scheduler.Threads[tid].AddrSpace;
        return IsValidUserPtr_Pas(tid, ptr, pml4Phys, PMM.TotalPages);
    }
    // [SYSCALL 4]: Keyboard read (I/O-specific)
    // Được xử lý trực tiếp trên x86_64 thông qua IPC messages từ Keyboard ISR.
    public ulong DispatchKeyboardRead(int threadId, bool isKing, RegisterContext* ctx, ulong currentRsp)
    {
        bool found = false;
        char c = '\0';

        int fgTask = Scheduler.ForegroundTask;
        bool fgValid = fgTask >= 0 && fgTask < Scheduler.ThreadCount && Scheduler.Threads[fgTask].Active != 0;
        bool allowedToConsume = !fgValid || fgTask == threadId;

        if (allowedToConsume)
        {
            for (int i = 0; i < IPC.MAX_MESSAGES; i++)
            {
                if (IPC.queue[i].Type == 1 && IPC.queue[i].Sender == 33)
                {
                    if (IPC.AtomicExchange(ref IPC.queue[i].IsLocked, 1) == 0)
                    {
                        if (IPC.queue[i].Type == 1 && IPC.queue[i].Sender == 33)
                        {
                            c = KeyboardDriver.ProcessScanCode((byte)IPC.queue[i].Payload);
                            IPC.StoreFence();
                            IPC.queue[i].Type = 0;
                            IPC.StoreFence();
                            IPC.queue[i].IsLocked = 0;
                            found = true;
                            break;
                        }
                        IPC.queue[i].IsLocked = 0;
                    }
                }
            }
        }

        if (found)
        {
            if (c != '\0') { ArchCtx.SetRet(ctx, (ulong)c); } else { ArchCtx.SetRet(ctx, 0); }
            return 1;
        }

        bool irq = Scheduler.AcquireSchedLockSafe();
        Scheduler.Threads[threadId].WakeUpTick = Scheduler.SystemTicks + 1;
        Scheduler.Threads[threadId].Active = 2;
        Scheduler.ReleaseSchedLockSafe(irq);

        ArchCtx.SetRet(ctx, 0);
        return Scheduler.SwitchTask(currentRsp);
    }

    // [SYSCALL 12]: Map physical memory (I/O-specific - paging hardware)
    // Yêu cầu root privilege để ánh xạ physical memory.
    public ulong DispatchMapPhysicalMemory(int threadId, bool isKing, RegisterContext* ctx)
    {
        if (!isKing) { Scheduler.Threads[threadId].IsPhantomDead = 1; ArchCtx.SetRet(ctx, 0); return 0; }
        ulong physAddr = ArchCtx.GetArg(ctx, 1); ulong numPages = ArchCtx.GetArg(ctx, 2);
        if (numPages == 0 || numPages > 256) { ArchCtx.SetRet(ctx, 0); return 0; }

        bool irq = Scheduler.AcquireSchedLockSafe();

        ulong alignedPhys = physAddr & ~0xFFFUL; ulong offset = physAddr & 0xFFFUL;
        ulong virtAddr = Scheduler.Threads[threadId].AppHeapBase;

        ulong* threadPml4 = (ulong*)Scheduler.Threads[threadId].AddrSpace;
        if (threadPml4 == null || (ulong)threadPml4 == 0 || (ulong)threadPml4 >= PMM.TotalPages * 4096UL || !Mem.IsCanonical((ulong)threadPml4)) { Scheduler.ReleaseSchedLockSafe(irq); ArchCtx.SetRet(ctx, 0); return 0; }
        ulong* currentPml4 = (ulong*)(Arch.ReadPageTable() & 0x000FFFFFFFFFF000UL);
        if ((ulong*)threadPml4 != currentPml4) { Scheduler.ReleaseSchedLockSafe(irq); ArchCtx.SetRet(ctx, 0); return 0; }
        for(ulong p = 0; p < numPages; p++) { Mem.MapPage(alignedPhys + (p * 4096), virtAddr + (p * 4096), 0x07, currentPml4); }
        Mem.MapPage(0, virtAddr + (numPages * 4096), 0x04, currentPml4);

        Scheduler.Threads[threadId].AppHeapBase += (numPages * 4096) + 4096;
        Scheduler.ReleaseSchedLockSafe(irq);

        ArchCtx.SetRet(ctx, virtAddr + offset);
        return 1;
    }

    // [SYSCALL 13]: Hardware reporting (I/O-specific - APIC/MADT)
    public ulong DispatchHardwareReport(uint hwType, ulong payload, bool isKing)
    {
        if (!isKing) return 0;
        if (hwType == 1) { APIC.Init(payload); return 1; }
        else if (hwType == 2) { APIC.CoreCount = (uint)payload; return 1; }
        else if (hwType == 3) { APIC.IOApicBase = payload; return 1; }
        else return 0;
    }

    // [SYSCALL 50]: Map framebuffer (I/O-specific - FB hardware)
    public ulong DispatchMapFramebuffer(int threadId, bool isKing, RegisterContext* ctx)
    {
        if (!isKing) { Scheduler.Threads[threadId].IsPhantomDead = 1; ArchCtx.SetRet(ctx, 0); return 0; }

        ulong fbPhys = Program.GlobalBootInfo->FrameBufferBase;
        ulong fbSize = (ulong)(Terminal.scanLine * Terminal.height * 4);

        ulong vAddr = Scheduler.Threads[threadId].AppHeapBase;
        ulong numPages = (fbSize + 4095) / 4096;
        ulong pml4 = Scheduler.Threads[threadId].AddrSpace;

        if (pml4 == 0 || pml4 >= PMM.TotalPages * 4096UL || !Mem.IsCanonical(pml4)) { ArchCtx.SetRet(ctx, 0); return 0; }

        bool irq = Scheduler.AcquireSchedLockSafe();
        ulong* currentPml4 = (ulong*)(Arch.ReadPageTable() & 0x000FFFFFFFFFF000UL);
        if ((ulong*)pml4 != currentPml4) { Scheduler.ReleaseSchedLockSafe(irq); ArchCtx.SetRet(ctx, 0); return 0; }
        for(ulong p = 0; p < numPages; p++)
        {
            Mem.MapPage(fbPhys + (p * 4096), vAddr + (p * 4096), 0x07, currentPml4);
        }

        Scheduler.Threads[threadId].AppHeapBase += (numPages * 4096) + 4096;
        Scheduler.Threads[threadId].VirtPages += (uint)numPages;

        Scheduler.ReleaseSchedLockSafe(irq);

        ArchCtx.SetRet(ctx, vAddr);
        return 1;
    }

    // [SYSCALL 51]: Get framebuffer dimensions (I/O-specific)
    public ulong DispatchFramebufferDims(ulong* ptrWidth, ulong* ptrHeight, ulong* ptrScanLine)
    {
        if (ptrWidth != null && IsValidUserPtr((ulong)ptrWidth) != 0) *ptrWidth = Terminal.width;
        if (ptrHeight != null && IsValidUserPtr((ulong)ptrHeight) != 0) *ptrHeight = Terminal.height;
        if (ptrScanLine != null && IsValidUserPtr((ulong)ptrScanLine) != 0) *ptrScanLine = Terminal.scanLine;

        return 1;
    }

    // [SYSCALL 52]: Redirect framebuffer output (I/O-specific)
    public ulong DispatchRedirectFramebuffer(ulong newFb, uint w, uint h, uint sl, bool isKing)
    {
        if (!isKing) return 0;
        if (IsValidUserPtr(newFb) != 0)
        {
            Terminal.RedirectOutput((uint*)newFb, w, h, sl);
            return 1;
        }
        else return 0;
    }

    public ulong DispatchPrint(int threadId, char* str)
    {
        // [MITIGATION CVE-2026-003] TOCTOU hardening
        bool irq = Terminal.ScreenLock.AcquireSafe();
        int maxPrint = 8192;
        int charsSinceLastCheck = 0;
        const int CHECK_INTERVAL = 256;

        while (*str != '\0' && maxPrint > 0)
        {
            if (charsSinceLastCheck >= CHECK_INTERVAL)
            {
                if (IsValidUserPtr((ulong)str) == 0) break;
                charsSinceLastCheck = 0;
            }
            Terminal.DrawCharUnsafe(*str);
            str++;
            maxPrint--;
            charsSinceLastCheck++;
        }

        Terminal.ScreenLock.ReleaseSafe(irq);
        return 1;
    }

    public ulong DispatchDrawPixel(int threadId, ulong x, ulong y, ulong color)
    {
        int fgTaskDraw = Scheduler.ForegroundTask;
        bool fgValidDraw = fgTaskDraw >= 0 && fgTaskDraw < Scheduler.ThreadCount && Scheduler.Threads[fgTaskDraw].Active != 0;
        if (fgValidDraw && fgTaskDraw != threadId) return 0;

        uint ux = (uint)x; uint uy = (uint)y; uint ucolor = (uint)color;
        if (ux >= Terminal.width || uy >= Terminal.height) return 0;
        Terminal.fb[uy * Terminal.scanLine + ux] = ucolor;
        return 1;
    }

    public ulong DispatchClearScreen(int threadId, ulong color)
    {
        int fgTaskClear = Scheduler.ForegroundTask;
        bool fgValidClear = fgTaskClear >= 0 && fgTaskClear < Scheduler.ThreadCount && Scheduler.Threads[fgTaskClear].Active != 0;
        if (fgValidClear && fgTaskClear != threadId) return 0;
        Terminal.Clear((uint)color);
        return 1;
    }

    public void DispatchGrantPortAccess(ushort port, int threadId, bool isKing)
    {
        if (!isKing) { Scheduler.Threads[threadId].IsPhantomDead = 1; return; }
        GDT.GrantPortAccess(port);
    }

    public ulong DispatchGlobalSharedMemory(int threadId, ulong* inOutGlobalPhys)
    {
        bool irq = Scheduler.AcquireSchedLockSafe();
        ulong globalPhys = *inOutGlobalPhys;

        if (globalPhys == 0) {
            ulong allocPhys = (ulong)PMM.AllocateContiguousPages(5);
            if (allocPhys != 0) {
                globalPhys = allocPhys;
                *inOutGlobalPhys = allocPhys;
            } else {
                Scheduler.ReleaseSchedLockSafe(irq);
                return 0;
            }
        }

        if (Scheduler.Threads[threadId].SharedMemPhys == 0) {
            ulong allocPage = (ulong)PMM.AllocatePage();
            if (allocPage == 0) {
                Scheduler.ReleaseSchedLockSafe(irq);
                return 0;
            }

            Scheduler.Threads[threadId].SharedMemPhys = allocPage;
            Scheduler.Threads[threadId].PhysPages += 1;
            Scheduler.Threads[threadId].VirtPages += 5;
            Scheduler.Threads[threadId].SharedMemVirt = Scheduler.Threads[threadId].AppHeapBase;

            ulong* threadPml4 = (ulong*)Scheduler.Threads[threadId].AddrSpace;
            if (threadPml4 == null || (ulong)threadPml4 == 0 || (ulong)threadPml4 >= PMM.TotalPages * 4096UL || !Mem.IsCanonical((ulong)threadPml4))
            { Scheduler.ReleaseSchedLockSafe(irq); return 0; }
            if (globalPhys == 0 || globalPhys >= PMM.TotalPages * 4096UL)
            { Scheduler.ReleaseSchedLockSafe(irq); return 0; }
            ulong* currentPml4 = (ulong*)(Arch.ReadPageTable() & 0x000FFFFFFFFFF000UL);
            if ((ulong*)threadPml4 != currentPml4) { Scheduler.ReleaseSchedLockSafe(irq); return 0; }
            Mem.MapPage(allocPage, Scheduler.Threads[threadId].SharedMemVirt, 0x07, currentPml4);
            for (ulong p = 1; p < 5; p++) {
                ulong cand = globalPhys + (p * 4096);
                if (cand >= PMM.TotalPages * 4096UL) break;
                Mem.MapPage(cand, Scheduler.Threads[threadId].SharedMemVirt + (p * 4096), 0x07, currentPml4);
            }

            Scheduler.Threads[threadId].AppHeapBase += (4096 * 5);
        }

        ulong resultVirt = Scheduler.Threads[threadId].SharedMemVirt;
        Scheduler.ReleaseSchedLockSafe(irq);
        return resultVirt;
    }

    public ulong DispatchAllocateHeap(int threadId, ulong numPages, bool isKing)
    {
        if (numPages == 0) return Scheduler.Threads[threadId].AppHeapBase;
        if (!isKing && numPages > 256) { Scheduler.Threads[threadId].IsPhantomDead = 1; return 0; }
        if (numPages > 1024) return 0;

        bool irq = Scheduler.AcquireSchedLockSafe();

        ulong physAddr = (ulong)PMM.AllocateContiguousPages(numPages);
        if (physAddr == 0) { Scheduler.ReleaseSchedLockSafe(irq); return 0; }

        ulong virtAddr = Scheduler.Threads[threadId].AppHeapBase;

        ulong* threadPml4 = (ulong*)Scheduler.Threads[threadId].AddrSpace;
        if (threadPml4 == null || (ulong)threadPml4 == 0 || (ulong)threadPml4 >= PMM.TotalPages * 4096UL || !Mem.IsCanonical((ulong)threadPml4))
        { Scheduler.ReleaseSchedLockSafe(irq); return 0; }
        ulong* currentPml4 = (ulong*)(Arch.ReadPageTable() & 0x000FFFFFFFFFF000UL);
        if ((ulong*)threadPml4 != currentPml4) { Scheduler.ReleaseSchedLockSafe(irq); return 0; }
        for(ulong p = 0; p < numPages; p++) { Mem.MapPage(physAddr + (p * 4096), virtAddr + (p * 4096), 0x07, currentPml4); }
        Mem.MapPage(0, virtAddr + (numPages * 4096), 0x04, currentPml4);

        Scheduler.Threads[threadId].PhysPages += (uint)numPages;
        Scheduler.Threads[threadId].VirtPages += (uint)numPages + 1;
        Scheduler.Threads[threadId].AppHeapBase += (numPages * 4096) + 4096;

        Scheduler.ReleaseSchedLockSafe(irq);
        return virtAddr;
    }

    public ulong DispatchSharedMemoryPipeline(int callerId, int targetPid, ulong numPages, ulong* outTargetVAddr)
    {
        if ((uint)targetPid >= Scheduler.ThreadCount || Scheduler.Threads[targetPid].Active == 0) return 0;
        if (numPages == 0 || numPages > 4096) return 0;

        bool irq = Scheduler.AcquireSchedLockSafe();

        ulong myVAddr = Scheduler.Threads[callerId].AppHeapBase;
        ulong targetVAddr = Scheduler.Threads[targetPid].AppHeapBase;
        ulong targetPml4 = Scheduler.Threads[targetPid].AddrSpace;
        ulong* myPml4 = (ulong*)Scheduler.Threads[callerId].AddrSpace;
        if (myPml4 == null || (ulong)myPml4 == 0 || (ulong)myPml4 >= PMM.TotalPages * 4096UL || !Mem.IsCanonical((ulong)myPml4))
        { Scheduler.ReleaseSchedLockSafe(irq); return 0; }
        if (targetPml4 == 0 || targetPml4 >= PMM.TotalPages * 4096UL || !Mem.IsCanonical(targetPml4))
        { Scheduler.ReleaseSchedLockSafe(irq); return 0; }

        ulong physAddr = (ulong)PMM.AllocateContiguousPages(numPages);
        if (physAddr == 0) { Scheduler.ReleaseSchedLockSafe(irq); return 0; }

        ulong* currentPml4 = (ulong*)(Arch.ReadPageTable() & 0x000FFFFFFFFFF000UL);
        if ((ulong*)myPml4 != currentPml4) { Scheduler.ReleaseSchedLockSafe(irq); return 0; }
        for(ulong p = 0; p < numPages; p++)
        {
            Mem.MapPage(physAddr + (p * 4096), myVAddr + (p * 4096), 0x07, currentPml4);
            if ((ulong*)targetPml4 == currentPml4) {
                Mem.MapPage(physAddr + (p * 4096), targetVAddr + (p * 4096), 0x07, (ulong*)targetPml4);
            }
        }

        Scheduler.Threads[callerId].PhysPages += (uint)numPages;
        Scheduler.Threads[callerId].VirtPages += (uint)numPages;
        Scheduler.Threads[callerId].AppHeapBase += (numPages * 4096);

        Scheduler.Threads[targetPid].VirtPages += (uint)numPages;
        Scheduler.Threads[targetPid].AppHeapBase += (numPages * 4096);

        Scheduler.ReleaseSchedLockSafe(irq);

        ulong* currentPml4_after = (ulong*)(Arch.ReadPageTable() & 0x000FFFFFFFFFF000UL);
        if ((ulong*)myPml4 == currentPml4_after) {
            Arch.LoadPageTable((ulong)myPml4);
        } else {
            return 0;
        }

        *outTargetVAddr = targetVAddr;
        return myVAddr;
    }

    public void DispatchAtaLockAcquire()
    {
        Driver.ATA.AtaHardwareLock.Acquire();
    }

    public void DispatchAtaLockRelease()
    {
        Driver.ATA.AtaHardwareLock.Release();
    }

    public void DispatchResetCursor()
    {
        bool irq = Terminal.ScreenLock.AcquireSafe();
        Terminal.CursorX = 0;
        Terminal.CursorY = 0;
        Terminal.ScreenLock.ReleaseSafe(irq);
    }
}