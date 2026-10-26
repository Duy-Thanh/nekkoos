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

// [PASCAL PORT] Drawing lives in terminal.pas; the locked front end, the
// per-thread colour hooks and the shadow buffer live in console.pas. This class
// forwards, and exposes the framebuffer description as properties.
public static unsafe class Terminal
{
    public static ulong GetRflags() => Arch.GetFlags();

    [DllImport("*", EntryPoint = "Terminal_SetColor_Pas")] public static extern void SetColor(uint fg);
    [DllImport("*", EntryPoint = "Terminal_DrawChar_Pas")] private static extern void Terminal_DrawChar_Pas(ushort c);
    [DllImport("*", EntryPoint = "Terminal_Print_Pas")] private static extern void Terminal_Print_Pas(char* str);
    [DllImport("*", EntryPoint = "Terminal_PrintHex_Pas")] private static extern void Terminal_PrintHex_Pas(ulong val);
    [DllImport("*", EntryPoint = "Terminal_PrintDec_Pas")] private static extern void Terminal_PrintDec_Pas(ulong val);
    [DllImport("*", EntryPoint = "Terminal_PrintObfuscated_Pas")] public static extern void PrintObfuscated(byte* encryptedBytes, int length);
    [DllImport("*", EntryPoint = "Terminal_SyncRect_Pas")] public static extern void SyncRect(uint startX, uint startY, uint w, uint h);
    [DllImport("*", EntryPoint = "Terminal_GetCursor_Pas")] private static extern void Terminal_GetCursor_Pas(out uint x, out uint y);
    [DllImport("*", EntryPoint = "Terminal_SetCursor_Pas")] private static extern void Terminal_SetCursor_Pas(uint x, uint y);

    [DllImport("*", EntryPoint = "Con_Init_Pas")] private static extern void Init_Pas(ulong fbBase, uint w, uint h, uint scan);
    [DllImport("*", EntryPoint = "Con_EnableShadowBuffer_Pas")] private static extern void EnableShadowBuffer_Pas();
    [DllImport("*", EntryPoint = "Con_RedirectOutput_Pas")] private static extern void RedirectOutput_Pas(uint* newFb, uint w, uint h, uint scan);
    [DllImport("*", EntryPoint = "Con_ScreenLockAcquire_Pas")] private static extern byte ScreenLockAcquire_Pas();
    [DllImport("*", EntryPoint = "Con_ScreenLockRelease_Pas")] private static extern void ScreenLockRelease_Pas(byte irq);
    [DllImport("*", EntryPoint = "Con_Print_Pas")] private static extern void ConPrint_Pas(char* str);
    [DllImport("*", EntryPoint = "Con_PrintHex_Pas")] private static extern void ConPrintHex_Pas(ulong val);
    [DllImport("*", EntryPoint = "Con_PrintDec_Pas")] private static extern void ConPrintDec_Pas(ulong val);
    [DllImport("*", EntryPoint = "Con_DrawChar_Pas")] private static extern void ConDrawChar_Pas(ushort c);
    [DllImport("*", EntryPoint = "Con_Clear_Pas")] private static extern void ConClear_Pas(uint color);
    [DllImport("*", EntryPoint = "Con_GetFb_Pas")] private static extern uint* GetFb_Pas();
    [DllImport("*", EntryPoint = "Con_GetWidth_Pas")] private static extern uint GetWidth_Pas();
    [DllImport("*", EntryPoint = "Con_GetHeight_Pas")] private static extern uint GetHeight_Pas();
    [DllImport("*", EntryPoint = "Con_GetScanLine_Pas")] private static extern uint GetScanLine_Pas();
    [DllImport("*", EntryPoint = "Con_GetBackbuffer_Pas")] private static extern uint* GetBackbuffer_Pas();
    [DllImport("*", EntryPoint = "Con_SetBackbuffer_Pas")] private static extern void SetBackbuffer_Pas(uint* buf);

    public static uint* fb => GetFb_Pas();
    public static uint width => GetWidth_Pas();
    public static uint height => GetHeight_Pas();
    public static uint scanLine => GetScanLine_Pas();
    public static uint* backbuffer { get => GetBackbuffer_Pas(); set => SetBackbuffer_Pas(value); }

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

    public static void DrawCharUnsafe(char c) => Terminal_DrawChar_Pas((ushort)c);
    public static void PrintUnsafe(char* str) => Terminal_Print_Pas(str);
    public static void PrintHexUnsafe(ulong val) => Terminal_PrintHex_Pas(val);
    public static void PrintDecUnsafe(ulong val) => Terminal_PrintDec_Pas(val);

    public static void DrawChar(char c) => ConDrawChar_Pas((ushort)c);
    public static void Print(char* str) => ConPrint_Pas(str);
    public static void PrintHex(ulong val) => ConPrintHex_Pas(val);
    public static void PrintDec(ulong val) => ConPrintDec_Pas(val);
    public static void Clear(uint color) => ConClear_Pas(color);
    public static void RedirectOutput(uint* newFb, uint newWidth, uint newHeight, uint newScanLine) => RedirectOutput_Pas(newFb, newWidth, newHeight, newScanLine);

    public static void Init(NekkoBootInfo* bootInfo)
        => Init_Pas(bootInfo->FrameBufferBase, bootInfo->HorizontalResolution, bootInfo->VerticalResolution, bootInfo->PixelsPerScanLine);

    public static void EnableShadowBuffer() => EnableShadowBuffer_Pas();

    public static class ScreenLock
    {
        public static bool AcquireSafe() => ScreenLockAcquire_Pas() != 0;
        public static void ReleaseSafe(bool irq) => ScreenLockRelease_Pas((byte)(irq ? 1 : 0));
        public static void Acquire() { AcquireSafe(); }
        public static void Release() { ReleaseSafe(false); }
    }
}
