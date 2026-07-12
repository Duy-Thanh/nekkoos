// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

namespace NekkoOS.Kernel;

public static unsafe class IO
{
    [DllImport("*", EntryPoint = "Out8")] public static extern void Out8(ushort port, byte value);
    [DllImport("*", EntryPoint = "In8")]  public static extern byte In8(ushort port);
    [DllImport("*", EntryPoint = "EnableInterrupts")] public static extern void EnableInterrupts();
    // GỌI LỆNH HLT TỪ NASM VÀO ĐÂY!
    [DllImport("*", EntryPoint = "HltCPU")] public static extern void Hlt();
    [DllImport("*", EntryPoint = "Out16")]
    public static extern void Out16(ushort port, ushort value);

    [DllImport("*", EntryPoint = "In16")]
    public static extern ushort In16(ushort port);
    [DllImport("*", EntryPoint = "DisableInterrupts")] public static extern void DisableInterrupts();
    [DllImport("*", EntryPoint = "DisableInterrupts")] public static extern void Cli();
    [DllImport("*", EntryPoint = "EnableInterrupts")] public static extern void Sti();
    public static void Wait() => Out8(0x80, 0); 
}