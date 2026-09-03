// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
// MODULE: ARM64SyscallImpl - SKELETON implementation cho ARM64.
//
// Tất cả syscall I/O-specific trả về lỗi: "Syscall này không hỗ trợ
// trên kiến trúc này". Khi port thật sự sang ARM64, mỗi method sẽ được
// implement dựa trên:
//   - Keyboard: ARM Generic Interrupt Controller (GIC) + PS/2 hoặc USB
//   - Physical memory mapping: TTBR0/TTBR1 + 4-level page tables
//   - Framebuffer: Simple Framebuffer (EDK2) hoặc DisplayLink
//   - Hardware reporting: GIC distributor + redistributor
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

public sealed class ARM64SyscallImpl : IArcSyscall
{
    public ulong DispatchKeyboardRead(int threadId, bool isKing, RegisterContext* ctx, ulong currentRsp)
    {
        ArchCtx.SetRet(ctx, unchecked((ulong)-1));
        return unchecked((ulong)-1);
    }

    public ulong DispatchMapPhysicalMemory(int threadId, bool isKing, RegisterContext* ctx)
    {
        ArchCtx.SetRet(ctx, unchecked((ulong)-1));
        return unchecked((ulong)-1);
    }

    public ulong DispatchHardwareReport(uint hwType, ulong payload, bool isKing)
    {
        return unchecked((ulong)-1);
    }

    public ulong DispatchMapFramebuffer(int threadId, bool isKing, RegisterContext* ctx)
    {
        ArchCtx.SetRet(ctx, unchecked((ulong)-1));
        return unchecked((ulong)-1);
    }

    public ulong DispatchFramebufferDims(ulong* ptrWidth, ulong* ptrHeight, ulong* ptrScanLine)
    {
        return unchecked((ulong)-1);
    }

    public ulong DispatchRedirectFramebuffer(ulong newFb, uint w, uint h, uint sl, bool isKing)
    {
        return unchecked((ulong)-1);
    }

    public void DispatchGrantPortAccess(ushort port, int threadId, bool isKing)
    {
    }

    public ulong DispatchAllocateHeap(int threadId, ulong numPages, bool isKing)
    {
        return unchecked((ulong)-1);
    }

    public ulong DispatchSharedMemoryPipeline(int callerId, int targetPid, ulong numPages, ulong* outTargetVAddr)
    {
        return unchecked((ulong)-1);
    }

    public ulong DispatchPrint(int threadId, char* str)
    {
        return unchecked((ulong)-1);
    }

    public ulong DispatchDrawPixel(int threadId, ulong x, ulong y, ulong color)
    {
        return unchecked((ulong)-1);
    }

    public ulong DispatchClearScreen(int threadId, ulong color)
    {
        return unchecked((ulong)-1);
    }

    public void DispatchAtaLockAcquire()
    {
    }

    public void DispatchAtaLockRelease()
    {
    }

    public void DispatchResetCursor()
    {
    }
}