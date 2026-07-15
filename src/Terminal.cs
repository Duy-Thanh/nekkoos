// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
// SHIM: All render logic delegated to src/terminal.pas (Terminal_*_Pas).
// C# keeps: ScreenLock (needs IO.Cli/APIC), Init (bootInfo struct),
//           EnableShadowBuffer (PMM), per-thread color callbacks,
//           public fields fb/width/height/scanLine for Syscall.cs compat.
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

public static unsafe class Terminal
{
    [DllImport("*", EntryPoint = "GetRflags")] public static extern ulong GetRflags();

    // ==========================================================
    // INTEROP: Pascal render engine
    // ==========================================================
    [DllImport("*", EntryPoint = "Terminal_SetFB_Pas")]
    private static extern void Terminal_SetFB_Pas(uint* fb, uint width, uint height, uint scanLine);

    [DllImport("*", EntryPoint = "Terminal_SetBackbuffer_Pas")]
    private static extern void Terminal_SetBackbuffer_Pas(uint* buf);

    [DllImport("*", EntryPoint = "Terminal_SetCallbacks_Pas")]
    private static extern void Terminal_SetCallbacks_Pas(void* serialWriteChar, void* getColor, void* setColor);

    [DllImport("*", EntryPoint = "Terminal_SetColor_Pas")]
    public static extern void SetColor(uint fg);

    [DllImport("*", EntryPoint = "Terminal_Clear_Pas")]
    private static extern void Terminal_Clear_Pas(uint color);

    [DllImport("*", EntryPoint = "Terminal_DrawChar_Pas")]
    private static extern void Terminal_DrawChar_Pas(ushort c);

    [DllImport("*", EntryPoint = "Terminal_Print_Pas")]
    private static extern void Terminal_Print_Pas(char* str);

    [DllImport("*", EntryPoint = "Terminal_PrintHex_Pas")]
    private static extern void Terminal_PrintHex_Pas(ulong val);

    [DllImport("*", EntryPoint = "Terminal_PrintDec_Pas")]
    private static extern void Terminal_PrintDec_Pas(ulong val);

    [DllImport("*", EntryPoint = "Terminal_PrintObfuscated_Pas")]
    public static extern void PrintObfuscated(byte* encryptedBytes, int length);

    [DllImport("*", EntryPoint = "Terminal_SyncRect_Pas")]
    public static extern void SyncRect(uint startX, uint startY, uint w, uint h);

    [DllImport("*", EntryPoint = "Terminal_GetCursor_Pas")]
    private static extern void Terminal_GetCursor_Pas(out uint x, out uint y);

    [DllImport("*", EntryPoint = "Terminal_SetCursor_Pas")]
    private static extern void Terminal_SetCursor_Pas(uint x, uint y);

    // ==========================================================
    // Public state — shadow copies kept for Syscall.cs compat
    // ==========================================================
    public static uint* fb;
    public static uint  width;
    public static uint  height;
    public static uint  scanLine;
    public static uint* backbuffer; // null until EnableShadowBuffer

    public const int CHAR_WIDTH  = 8 * 2;
    public const int CHAR_HEIGHT = 8 * 2;

    public static uint CursorX {
        get { Terminal_GetCursor_Pas(out uint x, out _); return x; }
        set { Terminal_GetCursor_Pas(out _, out uint y); Terminal_SetCursor_Pas(value, y); }
    }
    public static uint CursorY {
        get { Terminal_GetCursor_Pas(out _, out uint y); return y; }
        set { Terminal_GetCursor_Pas(out uint x, out _); Terminal_SetCursor_Pas(x, value); }
    }

    // DrawCharUnsafe — used by Syscall.cs (already inside ScreenLock)
    public static void DrawCharUnsafe(char c) => Terminal_DrawChar_Pas((ushort)c);

    // Unsafe variants for code that already holds ScreenLock (e.g., SMP.cs)
    public static void PrintUnsafe(char* str) => Terminal_Print_Pas(str);
    public static void PrintHexUnsafe(ulong val) => Terminal_PrintHex_Pas(val);
    public static void PrintDecUnsafe(ulong val) => Terminal_PrintDec_Pas(val);

    public static void DrawChar(char c) {
        bool irq = ScreenLock.AcquireSafe();
        Terminal_DrawChar_Pas((ushort)c);
        ScreenLock.ReleaseSafe(irq);
    }

    public static void Print(char* str) {
        bool irq = ScreenLock.AcquireSafe();
        Terminal_Print_Pas(str);
        ScreenLock.ReleaseSafe(irq);
    }

    public static void PrintHex(ulong val) {
        bool irq = ScreenLock.AcquireSafe();
        Terminal_PrintHex_Pas(val);
        ScreenLock.ReleaseSafe(irq);
    }

    public static void PrintDec(ulong val) {
        bool irq = ScreenLock.AcquireSafe();
        Terminal_PrintDec_Pas(val);
        ScreenLock.ReleaseSafe(irq);
    }

    public static void Clear(uint color) {
        bool irq = ScreenLock.AcquireSafe();
        Terminal_Clear_Pas(color);
        ScreenLock.ReleaseSafe(irq);
    }

    // RedirectOutput — used by Syscall.cs syscall 5
    public static void RedirectOutput(uint* newFb, uint newWidth, uint newHeight, uint newScanLine) {
        bool irq = ScreenLock.AcquireSafe();
        if (newFb == null || newWidth == 0 || newHeight == 0 || newScanLine == 0
            || ((ulong)newFb & 0x7) != 0) { ScreenLock.ReleaseSafe(irq); return; }
        fb = newFb; width = newWidth; height = newHeight; scanLine = newScanLine;
        backbuffer = null;
        Terminal_SetFB_Pas(newFb, newWidth, newHeight, newScanLine);
        Terminal_SetBackbuffer_Pas(null);
        Terminal_Clear_Pas(0x00000000);
        ScreenLock.ReleaseSafe(irq);
    }

    // ==========================================================
    // Per-thread color callbacks (passed to Pascal at Init)
    // ==========================================================
    private static uint bootColor = 0x00FFFFFF;

    [UnmanagedCallersOnly(EntryPoint = "TermCbGetColor")]
    public static uint CbGetColor() {
        if (!Scheduler.Ready || Scheduler.CurrentThreadIds == null) return bootColor;
        int cur = Scheduler.CurrentThreadId;
        if (cur < 0 || cur >= Scheduler.ThreadCount) return bootColor;
        return Scheduler.Threads[cur].TextColor;
    }

    [UnmanagedCallersOnly(EntryPoint = "TermCbSetColor")]
    public static void CbSetColor(uint color) {
        if (!Scheduler.Ready || Scheduler.CurrentThreadIds == null) { bootColor = color; return; }
        int cur = Scheduler.CurrentThreadId;
        if (cur < 0 || cur >= Scheduler.ThreadCount) { bootColor = color; return; }
        Scheduler.Threads[cur].TextColor = color;
    }

    [UnmanagedCallersOnly(EntryPoint = "TermCbSerialWriteChar")]
    public static void CbSerialWriteChar(byte c) {
        Serial.WriteChar((char)c);
    }

    // ==========================================================
    // Init — called from Kernel.cs with UEFI bootInfo
    // ==========================================================
    public static void Init(NekkoBootInfo* bootInfo) {
        fb       = (uint*)bootInfo->FrameBufferBase;
        width    = bootInfo->HorizontalResolution;
        height   = bootInfo->VerticalResolution;
        scanLine = bootInfo->PixelsPerScanLine;
        backbuffer = null;

        Terminal_SetFB_Pas(fb, width, height, scanLine);

        Terminal_SetCallbacks_Pas(
            (void*)(delegate* unmanaged<byte, void>)&CbSerialWriteChar,
            (void*)(delegate* unmanaged<uint>)&CbGetColor,
            (void*)(delegate* unmanaged<uint, void>)&CbSetColor);

        Terminal_Clear_Pas(0x00111111);
    }

    // ==========================================================
    // EnableShadowBuffer — allocates via PMM, kept in C#
    // ==========================================================
    public static void EnableShadowBuffer() {
        bool irq = ScreenLock.AcquireSafe();
        ulong bufferBytes = (ulong)scanLine * (ulong)height * 4UL;
        ulong numPages = (bufferBytes + 4095UL) / 4096UL;
        uint* bb = (uint*)PMM.AllocateContiguousPages(numPages);
        if (bb == null) {
            ScreenLock.ReleaseSafe(irq);
            SetColor(0x00FF0000);
            fixed (char* err = "[!] Terminal: Out of Contiguous RAM! Shadow Buffer failed!\n\0") Print(err);
            return;
        }
        LibC.MemCpy((byte*)bb, (byte*)fb, (uint)bufferBytes);
        backbuffer = bb;
        Terminal_SetBackbuffer_Pas(bb);
        ScreenLock.ReleaseSafe(irq);
        SetColor(0x0000FF00);
        fixed (char* msg = "[+] Terminal Shadow Buffer Activated!\n\0") Print(msg);
    }

    // ==========================================================
    // ScreenLock — reentrant per-core spinlock (needs APIC/IO)
    // ==========================================================
    public static class ScreenLock
    {
        private static Spinlock rawLock = new Spinlock();

        // Simple irq-safe spinlock: disable interrupts on this core, then spin.
        // No per-core reentrant tracking — callers must not nest AcquireSafe.
        // (Syscall handler already has IF=0 from INT gate; timer handler does not
        //  touch terminal directly, so no nesting occurs in practice.)
        public static bool AcquireSafe() {
            bool irq = (GetRflags() & 0x200) != 0;
            IO.Cli();          // disable interrupts on this core first
            rawLock.Acquire(); // then spin until we own the lock
            return irq;
        }

        public static void ReleaseSafe(bool irq) {
            rawLock.Release();
            if (irq) IO.EnableInterrupts();
        }

        public static void Acquire() { AcquireSafe(); }
        public static void Release() { ReleaseSafe(false); }
    }
}
