// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

namespace NekkoOS.Kernel;

public static unsafe class IO
{
    [DllImport("*", EntryPoint = "Arch_WritePort8")] public static extern void Out8(ushort port, byte value);
    [DllImport("*", EntryPoint = "Arch_ReadPort8")]  public static extern byte In8(ushort port);
    [DllImport("*", EntryPoint = "Arch_EnableInterrupts")] public static extern void EnableInterrupts();
    // GỌI LỆNH HLT TỪ NASM VÀO ĐÂY!
    [DllImport("*", EntryPoint = "Arch_Halt")] public static extern void Hlt();
    [DllImport("*", EntryPoint = "Arch_WritePort16")]
    public static extern void Out16(ushort port, ushort value);

    [DllImport("*", EntryPoint = "Arch_ReadPort16")]
    public static extern ushort In16(ushort port);
    [DllImport("*", EntryPoint = "Arch_DisableInterrupts")] public static extern void DisableInterrupts();
    [DllImport("*", EntryPoint = "Arch_DisableInterrupts")] public static extern void Cli();
    [DllImport("*", EntryPoint = "Arch_EnableInterrupts")] public static extern void Sti();
    public static void Wait() => Out8(0x80, 0); 
}