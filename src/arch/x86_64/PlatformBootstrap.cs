// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================
// MODULE: PlatformBootstrap - wiring phần cứng ISA-legacy của x86_64.
// ARCH: x86_64 ONLY.
//
// Kernel generic (Kernel.cs) KHÔNG được nhắc tên driver legacy (Serial/
// PIT/PS/2) hay hook ISR cứng - mọi thứ tập trung ở đây để khi port sang
// kiến trúc khác chỉ cần thay thế đúng 1 file này (thay PS/2 bằng UART
// PL011/USB, thay PIT bằng arch timer... - xem ARCHITECTURE.md §5).
// Thứ tự gọi từ KernelMain phải giữ nguyên: EarlySerial() -> ... ->
// HookPs2IsrGates() (sau IDT ready) -> InitLegacyTimer() (sau scheduler).
// =========================================================================

using System.Runtime.InteropServices;

namespace NekkoOS.Kernel;

public static unsafe class PlatformBootstrap
{
    [DllImport("*", EntryPoint = "Arch_GetIsrKeyboard")] static extern void* GetIsrKeyboard();
    [DllImport("*", EntryPoint = "Arch_GetIsrMouse")] static extern void* GetIsrMouse();

    /// COM1 sớm cho debug log - phải chạy trước mọi print debug kernel.
    public static void EarlySerial() => Serial.Init();

    /// Hook 2 gate PS/2 vào IDT: IRQ1 keyboard = vector 33, IRQ12 mouse = vector 44.
    public static void HookPs2IsrGates()
    {
        IDTManager.SetGate(33, GetIsrKeyboard());
        IDTManager.SetGate(44, GetIsrMouse());
    }

    /// Legacy PIT (i8253/8254) làm nguồn tick scheduler trước khi APIC timer tiếp quản.
    public static void InitLegacyTimer(uint targetFrequencyHz) => PIT.Init(targetFrequencyHz);

    /// Xả sạch output buffer 8042 (bỏ qua phím gõ rác trong lúc boot).
    public static void DrainPs2Buffers()
    {
        while ((IO.In8(0x64) & 1) != 0) {
            LibC.CompilerFence();
            IO.In8(0x60);
        }
    }
}
