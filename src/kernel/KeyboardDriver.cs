// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel.Driver;

// ==========================================================
// MODULE: DRIVER BÀN PHÍM (USER-SPACE LOGIC)
// BẢN ĐÃ BỌC THÉP CHỐNG CỜ TỐI ƯU CỦA COMPILER!
// ==========================================================
public static class KeyboardDriver
{
    // ==========================================================
    // KHAI BÁO RÀO CHẮN TRÌNH BIÊN DỊCH
    // ==========================================================
    [DllImport("*", EntryPoint = "Arch_CompilerFence")] public static extern void CompilerFence();

    public static bool LeftShift = false;
    public static bool RightShift = false;
    public static bool CapsLock = false;

    public static char ProcessScanCode(byte sc)
    {
        bool isBreak = (sc & 0x80) != 0; // Cờ nhả phím
        byte makeCode = (byte)(sc & 0x7F); // Lấy mã gốc

        // Xử lý các phím trạng thái (Modifier Keys)
        if (makeCode == 0x2A) { LeftShift = !isBreak; return '\0'; }
        if (makeCode == 0x36) { RightShift = !isBreak; return '\0'; }
        if (makeCode == 0x3A && !isBreak) { CapsLock = !CapsLock; return '\0'; } // Bấm CapsLock để bật/tắt

        // Đéo quan tâm đến các phím nhả khác
        if (isBreak) return '\0'; 

        bool shift = LeftShift || RightShift;
        bool upper = CapsLock ^ shift; // XOR Logic: Caps bật + Shift bấm = Viết thường!

        switch (makeCode)
        {
            // Dãy số và ký tự đặc biệt
            case 0x29: return shift ? '~' : '`';
            case 0x02: return shift ? '!' : '1';
            case 0x03: return shift ? '@' : '2';
            case 0x04: return shift ? '#' : '3';
            case 0x05: return shift ? '$' : '4';
            case 0x06: return shift ? '%' : '5';
            case 0x07: return shift ? '^' : '6';
            case 0x08: return shift ? '&' : '7';
            case 0x09: return shift ? '*' : '8';
            case 0x0A: return shift ? '(' : '9';
            case 0x0B: return shift ? ')' : '0';
            case 0x0C: return shift ? '_' : '-';
            case 0x0D: return shift ? '+' : '=';
            case 0x0E: return '\b'; // Backspace
            case 0x0F: return '\t'; // Tab

            // Chữ cái (Chịu ảnh hưởng của CapsLock và Shift)
            case 0x10: return upper ? 'Q' : 'q';
            case 0x11: return upper ? 'W' : 'w';
            case 0x12: return upper ? 'E' : 'e';
            case 0x13: return upper ? 'R' : 'r';
            case 0x14: return upper ? 'T' : 't';
            case 0x15: return upper ? 'Y' : 'y';
            case 0x16: return upper ? 'U' : 'u';
            case 0x17: return upper ? 'I' : 'i';
            case 0x18: return upper ? 'O' : 'o';
            case 0x19: return upper ? 'P' : 'p';
            case 0x1A: return shift ? '{' : '[';
            case 0x1B: return shift ? '}' : ']';
            case 0x1C: return '\n'; // Enter

            case 0x1E: return upper ? 'A' : 'a';
            case 0x1F: return upper ? 'S' : 's';
            case 0x20: return upper ? 'D' : 'd';
            case 0x21: return upper ? 'F' : 'f';
            case 0x22: return upper ? 'G' : 'g';
            case 0x23: return upper ? 'H' : 'h';
            case 0x24: return upper ? 'J' : 'j';
            case 0x25: return upper ? 'K' : 'k';
            case 0x26: return upper ? 'L' : 'l';
            case 0x27: return shift ? ':' : ';';
            case 0x28: return shift ? '"' : '\'';

            case 0x2B: return shift ? '|' : '\\';
            case 0x2C: return upper ? 'Z' : 'z';
            case 0x2D: return upper ? 'X' : 'x';
            case 0x2E: return upper ? 'C' : 'c';
            case 0x2F: return upper ? 'V' : 'v';
            case 0x30: return upper ? 'B' : 'b';
            case 0x31: return upper ? 'N' : 'n';
            case 0x32: return upper ? 'M' : 'm';
            case 0x33: return shift ? '<' : ',';
            case 0x34: return shift ? '>' : '.';
            case 0x35: return shift ? '?' : '/';
            case 0x39: return ' '; // Space

            default: return '\0';
        }
    }

    // ==========================================================
    // [VŨ KHÍ KERNEL] POLLING KEYBOARD (HỎI VÒNG PHẦN CỨNG TRỰC TIẾP)
    // Dùng cho màn hình DRM, Kernel Panic, hoặc khi Scheduler chưa chạy!
    // ==========================================================
    public static char PollChar()
    {
        // ==========================================================
        // [BỌC THÉP TRỊ CỜ -Ot] Ép LLVM đọc lại giá trị cổng 0x64 liên tục!
        // ==========================================================
        while ((IO.In8(0x64) & 1) == 0) 
        { 
            CompilerFence(); // KHÓA MÕM TRÌNH BIÊN DỊCH!
            IO.In8(0x80);    // Câu giờ 1 microsecond phần cứng
        }
        
        byte scancode = IO.In8(0x60); 
        return ProcessScanCode(scancode);
    }
}