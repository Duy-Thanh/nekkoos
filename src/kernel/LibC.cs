// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;
namespace NekkoOS.Kernel.Lib;

// ==========================================================
// MODULE: THƯ VIỆN CHUẨN LÕI (LIBC ZERO - BẢN BỌC THÉP TỐI CAO)
// ==========================================================
public static unsafe class LibC
{
    // ==========================================================
    // KHAI BÁO RÀO CHẮN TRÌNH BIÊN DỊCH
    // ==========================================================
    public static void CompilerFence() => Arch.CompilerFence();

    public static ulong HardwareTscOffset = 0;
    public static ulong RtcInterruptHandler_Ptr = 0;

    // ==========================================================
    // INTEROP: Gọi sang implementation bằng Pascal
    // ==========================================================
    [DllImport("*", EntryPoint = "MemSet_Pas")]
    private static extern void MemSet_Pas(byte* ptr, byte value, uint count);

    [DllImport("*", EntryPoint = "MemCopy_Pas")]
    private static extern void MemCopy_Pas(void* dest, void* src, uint count);

    [DllImport("*", EntryPoint = "MemCmp_Pas")]
    public static extern int MemCmp(void* ptr1, void* ptr2, uint count);

    [DllImport("*", EntryPoint = "StrCmp_Pas")]
    private static extern byte StrCmp_Pas(char* str1, char* str2);

    [DllImport("*", EntryPoint = "StrStartsWith_Pas")]
    private static extern byte StrStartsWith_Pas(char* str, char* prefix);

    [DllImport("*", EntryPoint = "FormatFATName_Pas")]
    private static extern void FormatFATName_Pas(char* input, byte* output);

    public static void MemCpy(void* dest, void* src, uint count)
    {
        // Kiểm tra xem dest và src có null không
        if (dest == null || src == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in MemCpy!\n\0") Terminal.Print(err);
            return;
        }

        // Kiểm tra xem count có hợp lệ không
        if (count == 0) return;
        if (count > 0x10000000) { // Giới hạn 256MB
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: MemCpy size too large!\n\0") Terminal.Print(err);
            return;
        }

        // Gọi sang Pascal!
        MemCopy_Pas(dest, src, count);
    }

    public static void MemSet(byte* ptr, byte value, uint count)
    {
        // Kiểm tra xem ptr có null không
        if (ptr == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in MemSet!\n\0") Terminal.Print(err);
            return;
        }

        // Kiểm tra xem count có hợp lệ không
        if (count == 0) return;
        if (count > 0x10000000) { // Giới hạn 256MB
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: MemSet size too large!\n\0") Terminal.Print(err);
            return;
        }

        // Gọi sang Pascal!
        MemSet_Pas(ptr, value, count);
    }

    public static bool StrCmp(char* str1, char* str2)
    {
        if (str1 == null || str2 == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in StrCmp!\n\0") Terminal.Print(err);
            return false;
        }

        return StrCmp_Pas(str1, str2) != 0;
    }

    public static bool StrStartsWith(char* str, char* prefix)
    {
        if (str == null || prefix == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in StrStartsWith!\n\0") Terminal.Print(err);
            return false;
        }

        return StrStartsWith_Pas(str, prefix) != 0;
    }

    public static void FormatFATName(char* input, byte* output)
    {
        if (input == null || output == null) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: Null pointer in FormatFATName!\n\0") Terminal.Print(err);
            return;
        }

        FormatFATName_Pas(input, output);
    }

    // [ARCH MOVE] CheckHardwareError đã chuyển sang src/arch/x86_64/HardwareChecks.cs
}