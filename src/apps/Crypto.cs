// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoApp;

// ==========================================================
// [VŨ KHÍ TỐI THƯỢNG] BAREMETAL SHA-256 CRYPTO ENGINE (RING 3)
// INTEROP: Logic thật đã port sang src/kerncrypto.pas (dùng chung với
// Kernel.exe qua src/KernCrypto.cs) - shim này chỉ gọi sang cùng một
// module Pascal để không phải copy-paste thuật toán ra 2 nơi nữa.
// ==========================================================
public static unsafe class SHA256
{
    [DllImport("*", EntryPoint = "SHA256_Compute_Pas")]
    private static extern void SHA256_Compute_Pas(byte* data, ulong length, byte* outputHash);

    public static void Compute(byte* data, ulong length, byte* outputHash)
    {
        SHA256_Compute_Pas(data, length, outputHash);
    }
}
