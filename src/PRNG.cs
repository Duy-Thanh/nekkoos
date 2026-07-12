// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
using System.Runtime.InteropServices;

namespace NekkoOS.Kernel.Utilities;

public static unsafe class PRNG
{
    [DllImport("*", EntryPoint = "ReadTSC")] 
    public static extern ulong ReadTSC();

    private static ulong state = 0;

    // ==========================================================
    // [SYNCHRONIZATION] Spinlock to protect seed state
    // Ensures multi-core safety by preventing concurrent access to seed state
    // ==========================================================
    private static Spinlock PrngLock = new Spinlock();

    public static void Init()
    {
        state = ReadTSC();

        // Kiểm tra xem ReadTSC có trả về giá trị hợp lệ không
        if (state == 0) {
            state = 0x1337CAFE8BADBEEFUL; // Sử dụng giá trị mặc định nếu TSC = 0
        }

        state ^= PIT.Ticks << 16;

        state = (state ^ (state >> 30)) * 0xbf58476d1ce4e5b9UL;
        state = (state ^ (state >> 27)) * 0x94d049bb133111ebUL;

        // ==========================================================
        // [XORSHIFT RULE] Seed state must never be 0
        // If state is 0, initialize it to a default non-zero value
        // ==========================================================
        if (state == 0) state = 0x1337CAFE8BADBEEFUL; 
    }

    public static ulong Next()
    {
        // ==========================================================
        // [SYNCHRONIZATION] Lock seed state during generation
        // ==========================================================
        bool irq = PrngLock.AcquireSafe();

        // Guard against early calls to Next() before Init() has executed
        if (state == 0) {
            ulong tsc = ReadTSC();
            // Kiểm tra xem ReadTSC có trả về giá trị hợp lệ không
            if (tsc == 0) {
                Terminal.SetColor(0x00FF0000);
                fixed (char* err = "[!] FATAL: TSC returned zero in PRNG!\n\0") Terminal.Print(err);
                PrngLock.ReleaseSafe(irq);
                return 0; // Trả về giá trị mặc định
            }
            state = tsc | 1; 
        }

        state ^= state >> 12;
        state ^= state << 25;
        state ^= state >> 27;
        
        ulong result = state * 0x2545F4914F6CDD1DUL;

        PrngLock.ReleaseSafe(irq); // Release spinlock

        return result;
    }

    public static ulong Next(ulong min, ulong max)
    {
        if (min >= max) return min; // Guard: check parameter boundaries

        // ==========================================================
        // [SAFETY] Prevent integer overflow that can lead to division by zero
        // ==========================================================
        ulong range = max - min;

        // ==========================================================
        // [COMPILER LIMITATION] Use raw hex instead of ulong.MaxValue
        // Baremetal target lacks standard System.UInt64 metadata
        // ==========================================================
        if (range == 0xFFFFFFFFFFFFFFFFUL) return Next(); 
        
        range += 1; 
        
        return min + (Next() % range);
    }
}