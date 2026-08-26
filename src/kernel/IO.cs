// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

namespace NekkoOS.Kernel;

public static unsafe class IO
{
    public static void Out8(ushort port, byte value) => Arch.WritePort8(port, value);
    public static byte In8(ushort port) => Arch.ReadPort8(port);
    public static void EnableInterrupts() => Arch.EnableInterrupts();
    // GỌI LỆNH HLT TỪ NASM VÀO ĐÂY!
    public static void Hlt() => Arch.Halt();
    public static void Out16(ushort port, ushort value) => Arch.WritePort16(port, value);

    public static ushort In16(ushort port) => Arch.ReadPort16(port);
    public static void DisableInterrupts() => Arch.DisableInterrupts();
    public static void Cli() => Arch.DisableInterrupts();
    public static void Sti() => Arch.EnableInterrupts();
    public static void Wait() => Out8(0x80, 0); 
}