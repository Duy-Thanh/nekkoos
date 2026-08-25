// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
// MODULE: ContextLayout - x86_64 interrupt/syscall stack frame layout
// ARCH: x86_64 ONLY. Khi port sang kiến trúc khác, thay thế file này bằng
// layout frame tương ứng (xem ARCHITECTURE.md §5) - kernel generic không
// được định nghĩa layout thanh ghi ở bất kỳ đâu khác.
//
// Layout khớp 1:1 với thứ tự push trong ISR stub (src/arch/x86_64/ISR.cs
// và Hardware.asm): GP registers -> ErrorCode (CPU đẩy cho exception
// 8/13/14, ISR syscall đẩy 0 giả) -> RIP/Cs/Rflags/Rsp/Ss do CPU push.
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

[StructLayout(LayoutKind.Sequential, Pack = 1)]
public struct RegisterContext
{
    public ulong R15; public ulong R14; public ulong R13; public ulong R12;
    public ulong R11; public ulong R10; public ulong R9;  public ulong R8;
    public ulong Rdi; public ulong Rsi; public ulong Rbp; public ulong Rbx;
    public ulong Rdx; public ulong Rcx; public ulong Rax;

    public ulong ErrorCode; // <-- HẤP THỤ 8 BYTES CỦA CPU CHO EXCEPTION CÓ MÃ LỖI

    public ulong Rip; public ulong Cs;  public ulong Rflags;
    public ulong Rsp; public ulong Ss;
}
