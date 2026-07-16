// =========================================================================
// NekkoOS - A 64-bit x86-64 Educational Operating System
// Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
// Licensed under the GNU General Public License v3.0 (GPLv3)
// =========================================================================

using System.Runtime.InteropServices;
namespace NekkoOS.Kernel;

// ==========================================================
// MODULE: CHÚA TỂ ĐA LÕI (LOCAL APIC)
// BẢN THIẾT QUÂN LUẬT: KHÔNG CACHE, TỐC ĐỘ ÁNH SÁNG, BỌC THÉP RÀO CHẮN!
// ==========================================================
public static unsafe class APIC
{
    // ==========================================================
    // KHAI BÁO RÀO CHẮN PHẦN CỨNG & COMPILER & HAL INTERFACE
    // ==========================================================
    [DllImport("*", EntryPoint = "Arch_CompilerFence")] public static extern void CompilerFence();
    [DllImport("*", EntryPoint = "Arch_LoadFence")] public static extern void LoadFence();
    [DllImport("*", EntryPoint = "Arch_StoreFence")] public static extern void StoreFence();
    [DllImport("*", EntryPoint = "Arch_FullFence")] public static extern void FullFence();

    [DllImport("*", EntryPoint = "HAL_SetLocalApicBase")] public static extern void SetLocalApicBase(ulong baseAddr);
    [DllImport("*", EntryPoint = "HAL_InitInterruptController")] public static extern void InitInterruptController();
    [DllImport("*", EntryPoint = "HAL_SendEOI")] public static extern void SendEoiHal(byte vector);
    [DllImport("*", EntryPoint = "HAL_SendIPI")] public static extern void SendIpiHal(uint targetCore, byte vector);
    [DllImport("*", EntryPoint = "HAL_BroadcastIPI")] public static extern void BroadcastIpiHal(byte vector);
    [DllImport("*", EntryPoint = "HAL_GetCoreId")] public static extern uint GetCoreIdHal();

    [DllImport("*", EntryPoint = "Arch_ReadTimestamp")] public static extern ulong Arch_ReadTimestamp();
    [DllImport("*", EntryPoint = "HAL_SetTimerFrequencies")] public static extern void SetTimerFrequenciesHal(ulong tsc, uint apicTicksPerMs);
    [DllImport("*", EntryPoint = "HAL_InitTimer")] public static extern void InitTimerHal();

    public static ulong LocalApicBaseVirt = 0;
    public static bool IsAwake = false;

    public static uint CalibratedTicksPerQuantum = 0;

    private const uint APIC_ID = 0x020;
    private const uint APIC_VERSION = 0x030;
    private const uint APIC_TPR = 0x080;   
    private const uint APIC_EOI = 0x0B0;   
    private const uint APIC_SVR = 0x0F0;   
    private const uint APIC_LVT_TIMER = 0x320; 
    private const uint APIC_TIMER_INIT_CNT = 0x380; 
    private const uint APIC_TIMER_CURR_CNT = 0x390; 
    private const uint APIC_TIMER_DIV = 0x3E0; 

    public static uint CoreCount = 1; 
    public static ulong IOApicBase = 0;
    public static bool isDebug = false;

    // ==========================================================
    // [BỌC THÉP 1] MMIO WRITE & READ
    // ==========================================================
    public static void Write(uint offset, uint value) 
    {
        // Kiểm tra xem LocalApicBaseVirt có được khởi tạo chưa
        if (LocalApicBaseVirt == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: APIC not initialized in Write!\n\0") Terminal.Print(err);
            return;
        }
        
        // Kiểm tra xem offset có nằm trong phạm vi hợp lệ không
        if (offset > 0x3FF) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid APIC write offset!\n\0") Terminal.Print(err);
            return;
        }

        CompilerFence(); // Báo LLVM: Không được đảo lệnh trước khi Ghi!
        *(uint*)(LocalApicBaseVirt + offset) = value;
        // Dùng FullFence (mfence) ở đây vì ghi vào APIC (như EOI hay Timer) 
        // đòi hỏi IC silicon phải cập nhật NGAY LẬP TỨC! Đéo cho phép Store Buffer ngâm hàng!
        FullFence(); 
    }

    public static uint Read(uint offset) 
    {
        // Kiểm tra xem LocalApicBaseVirt có được khởi tạo chưa
        if (LocalApicBaseVirt == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: APIC not initialized in Read!\n\0") Terminal.Print(err);
            return 0;
        }
        
        // Kiểm tra xem offset có nằm trong phạm vi hợp lệ không
        if (offset > 0x3FF) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid APIC read offset!\n\0") Terminal.Print(err);
            return 0;
        }

        CompilerFence(); // Báo LLVM: Phải đọc thẳng từ RAM/MMIO, cấm xài Cache thanh ghi!
        uint val = *(uint*)(LocalApicBaseVirt + offset);
        LoadFence();     // Ép CPU chờ lấy đủ dữ liệu từ APIC rồi mới chạy lệnh tiếp theo!
        return val;
    }

    public static void SendEOI()
    {
        if (IsAwake) SendEoiHal(0);
        else PIC.SendEOI();
    }

    public static void Init(ulong physAddress)
    {
        Terminal.SetColor(0x0000FFFF);
        fixed(char* m1 = "[+] Kernel APIC Driver: Awakening the Beast...\n\0") Terminal.Print(m1);

        // Kiểm tra xem physAddress có hợp lệ không
        if (physAddress == 0 || physAddress > 0xFFFFFFFF) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid APIC physical address!\n\0") Terminal.Print(err);
            return;
        }
        
        LocalApicBaseVirt = 0xFFFF800000000000;

        if (NekkoInt.isDebug) {
            fixed(char* dbg1 = "[DBG] APIC: LocalApicBaseVirt set\n\0") Serial.WriteString(dbg1);
        }

        if (VMM.PML4 != null) {
            VMM.MapPage(physAddress, LocalApicBaseVirt, 0x13, (ulong*)VMM.PML4);

            if (NekkoInt.isDebug) {
                fixed(char* dbg2 = "[DBG] APIC: Initial VMM.MapPage with kernel PML4 done\n\0") Serial.WriteString(dbg2);
            }
        }

        bool irqSched = Scheduler.AcquireSchedLockSafe();

        if (NekkoInt.isDebug) {
            fixed(char* dbg3 = "[DBG] APIC: Acquired scheduler lock\n\0") Serial.WriteString(dbg3);
        }

        // Kiểm tra xem ThreadCount có hợp lệ không
        if (Scheduler.ThreadCount < 1 || Scheduler.ThreadCount > 256) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid thread count in APIC Init!\n\0") Terminal.Print(err);
            Scheduler.ReleaseSchedLockSafe(irqSched);
            return;
        }

        if (NekkoInt.isDebug) {
            fixed(char* dbg4 = "[DBG] APIC: Starting per-thread mapping loop\n\0") Serial.WriteString(dbg4);
        }

        for (int i = 0; i < Scheduler.ThreadCount; i++)
        {
            // Kiểm tra xem i có nằm trong phạm vi hợp lệ không
            if (i < 0 || i >= 256) {
                Terminal.SetColor(0x00FF0000);
                fixed(char* err = "[!] FATAL: Invalid thread index in APIC Init!\n\0") Terminal.Print(err);
                Scheduler.ReleaseSchedLockSafe(irqSched);
                return;
            }

            // Validate per-thread PML4 before attempting to use it for mapping.
            if (Scheduler.Threads[i].Active != 0 && Scheduler.Threads[i].Pml4 != 0)
            {
                ulong pml4 = Scheduler.Threads[i].Pml4;
                // Ensure the stored PML4 value looks like a real physical/table pointer
                if (VMM.IsCanonical(pml4) && pml4 < PMM.TotalPages * 4096UL)
                {
                    if (NekkoInt.isDebug) {
                        fixed(char* dbgmap = "[DBG] APIC: Mapping per-thread PML4\n\0") Serial.WriteString(dbgmap);
                    }

                    VMM.MapPage(physAddress, LocalApicBaseVirt, 0x13, (ulong*)pml4);
                }
                else
                {
                    // Skip invalid PML4 entries instead of risking a crash
                    Terminal.SetColor(0x00FFFF00);
                    fixed(char* warn = "[WARN] Skipping invalid thread PML4 during APIC init\n\0") Terminal.Print(warn);
                }
            }
        }
        Scheduler.ReleaseSchedLockSafe(irqSched);
        if (NekkoInt.isDebug) {
            fixed(char* dbg5 = "[DBG] APIC: Released scheduler lock\n\0") Serial.WriteString(dbg5);
        }
        
        if (NekkoInt.isDebug) {
            fixed(char* dbg6 = "[DBG] APIC: Final VMM.MapPage (current PML4)\n\0") Serial.WriteString(dbg6);
        }
        
        VMM.MapPage(physAddress, LocalApicBaseVirt, 0x13);

        SetLocalApicBase(LocalApicBaseVirt);
        InitInterruptController();

        Write(APIC_TIMER_DIV, 0x03); 
        
        Write(APIC_LVT_TIMER, 0x10000 | 0xFF); 
        Write(APIC_TIMER_INIT_CNT, 0xFFFFFFFF); 

        IO.EnableInterrupts();

        // ==========================================================
        // [BỌC THÉP 2] CHỐNG LẶP VÔ HẠN KHI CALIBRATION (TRỊ -Ot)
        // ==========================================================
        ulong syncTick = PIT.GetTicksRealtime();

        if (syncTick == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PIT sync tick value!\n\0") Terminal.Print(err);
            return;
        }

        while(PIT.GetTicksRealtime() == syncTick) { 
            CompilerFence(); // Tát vỡ mặt LLVM: Bắt đọc lại PIT Ticks!
            IO.Hlt(); 
        }
        
        ulong startTicks = PIT.GetTicksRealtime();

        // Kiểm tra xem startTicks có hợp lệ không
        if (startTicks == 0) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PIT start tick value!\n\0") Terminal.Print(err);
            return;
        }

        ulong tscStart = Arch_ReadTimestamp();
        Write(APIC_TIMER_INIT_CNT, 0xFFFFFFFF);

        while(PIT.GetTicksRealtime() - startTicks < 10) {
            CompilerFence(); // Tát vỡ mặt LLVM lần 2!
            IO.Hlt();
        }

        ulong tscEnd = Arch_ReadTimestamp();
        uint endCount = Read(APIC_TIMER_CURR_CNT);
        // Kiểm tra xem endCount có hợp lệ không
        if (endCount > 0xFFFFFFFF) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid APIC timer end count!\n\0") Terminal.Print(err);
            return;
        }

        uint ticksIn40ms = 0xFFFFFFFF - endCount;

        // Kiểm tra xem ticksIn40ms có hợp lệ không
        if (ticksIn40ms > 0xFFFFFFFF) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid APIC ticks in 40ms calculation!\n\0") Terminal.Print(err);
            return;
        }
        
        uint ticksPerMs = ticksIn40ms / 40;

        // Kiểm tra xem ticksPerMs có hợp lệ không
        if (ticksPerMs == 0 || ticksPerMs > 1000000) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid APIC ticks per ms calculation!\n\0") Terminal.Print(err);
            return;
        }

        CalibratedTicksPerQuantum = ticksPerMs * 4;

        if (CalibratedTicksPerQuantum < 10000 || CalibratedTicksPerQuantum > 10000000) {
            CalibratedTicksPerQuantum = 60000;
        }

        ulong tscFreq = (tscEnd - tscStart) * 25;
        SetTimerFrequenciesHal(tscFreq, ticksPerMs);
        InitTimerHal();

        fixed(char* m2 = "[+] APIC Calibrated! CPU APIC Ticks per 1ms: \0") Terminal.Print(m2);
        Terminal.PrintDec(ticksPerMs);
        fixed(char* n = "\n\0") Terminal.Print(n);

        byte picMask = IO.In8(0x21);
        
        // Kiểm tra xem picMask có hợp lệ không
        if (picMask > 0xFF) {
            Terminal.SetColor(0x00FF0000);
            fixed(char* err = "[!] FATAL: Invalid PIC mask value!\n\0") Terminal.Print(err);
            return;
        }

        IO.Out8(0x21, (byte)(picMask | 0x01)); 

        IsAwake = true;

        Write(APIC_LVT_TIMER, 0x20000 | 32);
        Write(APIC_TIMER_INIT_CNT, CalibratedTicksPerQuantum);

        fixed(char* m3 = "[+] Multi-Core Timer Engaged at 250Hz! The PIT is Officially DEAD!\n\0") Terminal.Print(m3);
        Terminal.SetColor(0x00FFFFFF);
    }
}