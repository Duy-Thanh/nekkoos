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

    public void DispatchGrantPortAccess(ushort port, int threadId, bool isKing)
    {
        if (!isKing) { Scheduler.Threads[threadId].IsPhantomDead = 1; return; }
        GDT.GrantPortAccess(port);
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