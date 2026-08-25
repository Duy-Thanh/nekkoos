// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

// ==========================================================
// MODULE: PIT / GLOBAL TIMER MANAGER
// ĐÃ PHỤC SINH: LÀM TRỤ CỘT THỜI GIAN CHO CẢ HỆ THỐNG!
// ==========================================================
public static unsafe class PIT
{
    [DllImport("*", EntryPoint = "HAL_GetTickCount")]
    public static extern ulong GetTickCountHal();

    [DllImport("*", EntryPoint = "HAL_IncrementTicks")]
    public static extern void IncrementTicksHal();

    // Biến đếm nhịp đập toàn cục. Trỏ thẳng vào HAL!
    public static ulong Ticks => GetTickCountHal();

    // Tần số hệ thống (Mặc định 250Hz - Chuẩn Linux Server/Desktop)
    public static uint CurrentFreq = 250;

    private const uint PIT_BASE_FREQ = 1193182;
    private const ushort PIT_CMD_PORT = 0x43;
    private const ushort PIT_DATA_PORT_0 = 0x40;

    // Vũ khí xuyên Cache
    public static ulong GetTicksRealtime()
    {
        return Ticks;
    }

    public static void Init(uint frequency)
    {
        if (frequency == 0) frequency = 250; 
        if (frequency > PIT_BASE_FREQ) frequency = PIT_BASE_FREQ; 

        // Kiểm tra xem tần số có nằm trong phạm vi hợp lệ không
        if (frequency < 1 || frequency > 10000) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: PIT frequency out of range!\n\0") Terminal.Print(err);
            return;
        }
        
        CurrentFreq = frequency; 

        uint divisor = PIT_BASE_FREQ / frequency;
        if (divisor > 65535) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: PIT divisor too large!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem divisor có hợp lệ không
        if (divisor == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: PIT divisor cannot be zero!\n\0") Terminal.Print(err);
            return;
        }

        IO.Cli();
        IO.Out8(PIT_CMD_PORT, 0x34); // Mode 2: Chống Jitter
        IO.Wait(); 
        IO.Out8(PIT_DATA_PORT_0, (byte)(divisor & 0xFF));
        IO.Wait();
        IO.Out8(PIT_DATA_PORT_0, (byte)((divisor >> 8) & 0xFF));
        IO.Wait();
        IO.Sti();
    }

    // ==========================================================
    // [BỘ CHUYỂN ĐỔI MA THUẬT] Tự động scale theo Tần số APIC/PIT
    // ==========================================================
    public static ulong MsToTicks(ulong ms)
    {
        if (ms == 0) return 0;
    
        // Kiểm tra xem phép nhân có gây ra tràn số không
        if (ms > 0xFFFFFFFFFFFF / (ulong)CurrentFreq) {
            Terminal.SetColor(0x00FF0000);
            fixed (char* err = "[!] FATAL: PIT multiplication overflow!\n\0") Terminal.Print(err);
            return 0xFFFFFFFFFFFF;
        }

        ulong ticks = (ms * CurrentFreq) / 1000;
        if (ticks == 0 && ms > 0) ticks = 1; 
        return ticks;
    }

    public static void Sleep(ulong ms)
    {
        ulong targetTicks = GetTicksRealtime() + MsToTicks(ms);
        while (GetTicksRealtime() < targetTicks)
        {
            Scheduler.Yield(); 
        }
    }
}