// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel.Crypto;

// ==========================================================
// [VŨ KHÍ TỐI THƯỢNG] BAREMETAL SHA-256 CRYPTO ENGINE (RING 3)
// INTEROP: Logic thật đã port sang src/kerncrypto.pas - giữ nguyên API
// public bên dưới để các module gọi (Syscall.cs, ...) không cần sửa gì.
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

// ==========================================================
// [SUDO] Hex/ConstantTimeEq cho kernel - bản sao logic y hệt
// src/Login.cs (HexToBytes/BytesToHex/ConstantTimeEq) vì Kernel.exe
// build riêng, không link chung với SysLogon.exe (userland).
// INTEROP: Logic thật đã port sang src/kerncrypto.pas.
// ==========================================================
public static unsafe class KernHexUtil
{
    [DllImport("*", EntryPoint = "HexToBytes_Pas")]
    private static extern int HexToBytes_Pas(char* hex, byte* outBytes, int maxOutBytes);

    [DllImport("*", EntryPoint = "BytesToHex_Pas")]
    private static extern void BytesToHex_Pas(byte* bytes, int len, char* outHex);

    [DllImport("*", EntryPoint = "ConstantTimeEq_Pas")]
    private static extern byte ConstantTimeEq_Pas(char* a, char* b, int maxLen);

    [DllImport("*", EntryPoint = "ZeroMemChar_Pas")]
    private static extern void ZeroMemChar_Pas(char* buf, int len);

    [DllImport("*", EntryPoint = "ZeroMemByte_Pas")]
    private static extern void ZeroMemByte_Pas(byte* buf, int len);

    public static int HexToBytes(char* hex, byte* outBytes, int maxOutBytes)
    {
        return HexToBytes_Pas(hex, outBytes, maxOutBytes);
    }

    public static void BytesToHex(byte* bytes, int len, char* outHex)
    {
        BytesToHex_Pas(bytes, len, outHex);
    }

    public static bool ConstantTimeEq(char* a, char* b, int maxLen)
    {
        return ConstantTimeEq_Pas(a, b, maxLen) != 0;
    }

    public static void ZeroMemChar(char* buf, int len)
    {
        ZeroMemChar_Pas(buf, len);
    }

    public static void ZeroMemByte(byte* buf, int len)
    {
        ZeroMemByte_Pas(buf, len);
    }
}
