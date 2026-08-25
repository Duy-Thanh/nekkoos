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

// =========================================================================
// [ARCH ABI] Truy cập context theo VAI TRÒ thay vì tên thanh ghi - kernel
// generic (Syscall.cs...) CHỈ được gọi qua class này. Khi port sang kiến
// trúc khác (ARM64: số hiệu trong W8/X8, args X0-X4, ret X0), viết lại
// duy nhất mapping phía dưới cùng với layout frame mới ở trên.
// =========================================================================
public static unsafe class ArchCtx
{
    /// Số hiệu syscall (x86_64: đặt trong RAX bởi libc stub).
    public static ulong GetNumber(RegisterContext* c) => c->Rax;

    /// Đọc tham số thứ i (0-4) của syscall (x86_64: RBX,RCX,RDX,R8,R9).
    public static ulong GetArg(RegisterContext* c, int i)
    {
        if (i == 0) return c->Rbx;
        if (i == 1) return c->Rcx;
        if (i == 2) return c->Rdx;
        if (i == 3) return c->R8;
        if (i == 4) return c->R9;
        return 0;
    }

    /// Ghi giá trị trả về chính (x86_64: RAX).
    public static void SetRet(RegisterContext* c, ulong v) => c->Rax = v;

    /// Ghi giá trị trả về phụ (x86_64: RBX - vd syscall 101 trả thêm địa chỉ shared mem).
    public static void SetRet2(RegisterContext* c, ulong v) => c->Rbx = v;
}
