// NekkoOS ARM64 hardware primitives: the Arch_* contract of arch_interface.pas.
// AAPCS64 matches FPC's cdecl on aarch64: args x0..x7, result x0.
// x86-only primitives (port I/O, GDT/IDT/TSS, ISR entry getters) exist only so
// the arch_interface wrappers link; they stop the CPU if ever called.
        .text
        .macro FN name
        .global \name
        .type \name, %function
\name:
        .endm

FN Arch_WriteMmio32
        str     w1, [x0]
        ret
FN Arch_ReadMmio32
        ldr     w0, [x0]
        ret
FN Arch_ReadVolatile64
        ldr     x0, [x0]
        ret

FN Arch_EnableInterrupts
        msr     daifclr, #2
        ret
FN Arch_DisableInterrupts
        msr     daifset, #2
        ret
FN Arch_InterruptsEnabled
        mrs     x0, daif
        ubfx    x0, x0, #7, #1          // I bit
        eor     x0, x0, #1
        ret
FN Arch_GetFlags
        mrs     x0, daif
        ret
FN Arch_Halt
        wfi
        ret

FN Arch_ReadTimestamp
        isb
        mrs     x0, cntpct_el0
        ret
FN Arch_ReadCounterFrequency
        mrs     x0, cntfrq_el0
        ret
FN Arch_ReadCpuId
        mrs     x0, mpidr_el1
        ret

FN Arch_CompilerFence
        ret
FN Arch_StoreFence
        dmb     ishst
        ret
FN Arch_LoadFence
        dmb     ishld
        ret
FN Arch_FullFence
        dmb     ish
        ret

// Cardinal Arch_AtomicExchange(Cardinal *p, Cardinal v)
FN Arch_AtomicExchange
1:      ldaxr   w2, [x0]
        stlxr   w3, w1, [x0]
        cbnz    w3, 1b
        mov     w0, w2
        ret
// QWord Arch_AtomicAdd64(QWord *p, QWord d)  -> returns the previous value
FN Arch_AtomicAdd64
1:      ldaxr   x2, [x0]
        add     x3, x2, x1
        stlxr   w4, x3, [x0]
        cbnz    w4, 1b
        mov     x0, x2
        ret
// Cardinal Arch_CmpXchg(Cardinal *p, Cardinal expected, Cardinal new) -> previous
FN Arch_CmpXchg
1:      ldaxr   w3, [x0]
        cmp     w3, w1
        b.ne    2f
        stlxr   w4, w2, [x0]
        cbnz    w4, 1b
2:      mov     w0, w3
        ret

FN Arch_SpinlockAcquire
        mov     w2, #1
1:      ldaxr   w1, [x0]
        cbnz    w1, 1b
        stxr    w3, w2, [x0]
        cbnz    w3, 1b
        ret
FN Arch_SpinlockRelease
        stlr    wzr, [x0]
        ret

// ---- x86-only or not yet written: stop the CPU rather than return garbage ----
Arch_Unsupported:
1:      wfe
        b       1b
        .global Arch_EnableNX
Arch_EnableNX:
        b       Arch_Unsupported
        .global Arch_GetCS
Arch_GetCS:
        b       Arch_Unsupported
        .global Arch_GetFaultAddress
Arch_GetFaultAddress:
        b       Arch_Unsupported
        .global Arch_GetIDTR
Arch_GetIDTR:
        b       Arch_Unsupported
        .global Arch_GetIsrDiv0
Arch_GetIsrDiv0:
        b       Arch_Unsupported
        .global Arch_GetIsrGPF
Arch_GetIsrGPF:
        b       Arch_Unsupported
        .global Arch_GetIsrKeyboard
Arch_GetIsrKeyboard:
        b       Arch_Unsupported
        .global Arch_GetIsrMouse
Arch_GetIsrMouse:
        b       Arch_Unsupported
        .global Arch_GetIsrPageFault
Arch_GetIsrPageFault:
        b       Arch_Unsupported
        .global Arch_GetIsrSyscall
Arch_GetIsrSyscall:
        b       Arch_Unsupported
        .global Arch_GetIsrTimer
Arch_GetIsrTimer:
        b       Arch_Unsupported
        .global Arch_GetIsrYield
Arch_GetIsrYield:
        b       Arch_Unsupported
        .global Arch_GetSS
Arch_GetSS:
        b       Arch_Unsupported
        .global Arch_IoWait
Arch_IoWait:
        b       Arch_Unsupported
        .global Arch_LoadGDT
Arch_LoadGDT:
        b       Arch_Unsupported
        .global Arch_LoadIDT
Arch_LoadIDT:
        b       Arch_Unsupported
        .global Arch_LoadTSS
Arch_LoadTSS:
        b       Arch_Unsupported
        .global Arch_ReadPort16
Arch_ReadPort16:
        b       Arch_Unsupported
        .global Arch_ReadPort32
Arch_ReadPort32:
        b       Arch_Unsupported
        .global Arch_ReadPort8
Arch_ReadPort8:
        b       Arch_Unsupported
        .global Arch_WritePort16
Arch_WritePort16:
        b       Arch_Unsupported
        .global Arch_WritePort32
Arch_WritePort32:
        b       Arch_Unsupported
        .global Arch_WritePort8
Arch_WritePort8:
        b       Arch_Unsupported

// FPC emits a call to this where x86 relies on the divide trap (AArch64 UDIV by
// zero silently yields 0). Treat it as a fatal kernel bug: say so and stop.
        .global FPC_DIVBYZERO
FPC_DIVBYZERO:
        ldr     x1, =0x09000000
        adr     x2, 3f
1:      ldrb    w3, [x2], #1
        cbz     w3, 2f
        strb    w3, [x1]
        b       1b
2:      wfe
        b       2b
3:      .asciz  "\r\narm64: FATAL integer division by zero\r\n"
        .balign 4


// ---------------------------------------------------------------------------
// Exceptions. VBAR_EL1 table: 16 entries of 0x80 bytes. Only "current EL, SPx"
// IRQ (offset 0x280) is a normal event; everything else is a fatal fault that
// reports ESR/ELR/FAR to Arm64Fault (Pascal) and never returns.
// ---------------------------------------------------------------------------
        // Full trap frame, 288 bytes: x0..x30 at 0..240, SP_EL0 at 248, ELR at 256,
        // SPSR at 264. A context switch is "resume on another thread's frame".
        .macro SAVE_FRAME
        sub     sp, sp, #288
        stp     x0,  x1,  [sp, #0]
        stp     x2,  x3,  [sp, #16]
        stp     x4,  x5,  [sp, #32]
        stp     x6,  x7,  [sp, #48]
        stp     x8,  x9,  [sp, #64]
        stp     x10, x11, [sp, #80]
        stp     x12, x13, [sp, #96]
        stp     x14, x15, [sp, #112]
        stp     x16, x17, [sp, #128]
        stp     x18, x19, [sp, #144]
        stp     x20, x21, [sp, #160]
        stp     x22, x23, [sp, #176]
        stp     x24, x25, [sp, #192]
        stp     x26, x27, [sp, #208]
        stp     x28, x29, [sp, #224]
        str     x30,      [sp, #240]
        mrs     x1, sp_el0
        mrs     x2, elr_el1
        mrs     x3, spsr_el1
        str     x1, [sp, #248]
        stp     x2, x3, [sp, #256]
        .endm
        // x0 = frame to resume.
        .macro RESUME_FRAME
        mov     sp, x0
        ldr     x1, [sp, #248]
        ldp     x2, x3, [sp, #256]
        msr     sp_el0, x1
        msr     elr_el1, x2
        msr     spsr_el1, x3
        ldp     x0,  x1,  [sp, #0]
        ldp     x2,  x3,  [sp, #16]
        ldp     x4,  x5,  [sp, #32]
        ldp     x6,  x7,  [sp, #48]
        ldp     x8,  x9,  [sp, #64]
        ldp     x10, x11, [sp, #80]
        ldp     x12, x13, [sp, #96]
        ldp     x14, x15, [sp, #112]
        ldp     x16, x17, [sp, #128]
        ldp     x18, x19, [sp, #144]
        ldp     x20, x21, [sp, #160]
        ldp     x22, x23, [sp, #176]
        ldp     x24, x25, [sp, #192]
        ldp     x26, x27, [sp, #208]
        ldp     x28, x29, [sp, #224]
        ldr     x30,      [sp, #240]
        add     sp, sp, #288
        eret
        .endm

        .macro FAULT_ENTRY
        mrs     x0, esr_el1
        mrs     x1, elr_el1
        mrs     x2, far_el1
        bl      Arm64Fault
        b       .
        .endm

        .balign 2048
vector_table:
        .rept 4                         // current EL, SP0
        .balign 128
        FAULT_ENTRY
        .endr
        .balign 128                     // current EL, SPx: synchronous (svc = yield)
        b       sync_handler
        .balign 128                     // IRQ
        b       irq_handler
        .balign 128                     // FIQ
        FAULT_ENTRY
        .balign 128                     // SError
        FAULT_ENTRY
        // Lower EL using AArch64: synchronous (svc = syscall, aborts), IRQ, FIQ, SError.
        .balign 128
        b       sync_handler
        .balign 128
        b       irq_handler
        .balign 128
        FAULT_ENTRY
        .balign 128
        FAULT_ENTRY
        .rept 4                         // lower EL using AArch32: unsupported
        .balign 128
        FAULT_ENTRY
        .endr

// Handlers live outside the 128-byte vector slots: a slot is too small for a
// full frame save + restore, and overflowing it silently corrupts the next one.
sync_handler:
        SAVE_FRAME
        mov     x0, sp
        bl      Arm64Sync
        RESUME_FRAME
irq_handler:
        SAVE_FRAME
        mov     x0, sp
        bl      Arm64Irq
        RESUME_FRAME

        .global Arch_InstallVectors
Arch_InstallVectors:
        adr     x0, vector_table
        msr     vbar_el1, x0
        isb
        ret

// Generic timer (EL1 physical): program a one-shot of `ticks` counter ticks and
// enable it; Arch_TimerStop disables it.
        .global Arch_TimerProgram
Arch_TimerProgram:
        msr     cntp_tval_el0, x0
        mov     x1, #1
        msr     cntp_ctl_el0, x1
        isb
        ret
// Re-arm from the previous deadline instead of from "now", so interrupt latency
// does not accumulate as drift: the tick rate stays exact on average.
        .global Arch_TimerRearm
Arch_TimerRearm:
        mrs     x1, cntp_cval_el0
        add     x1, x1, x0
        msr     cntp_cval_el0, x1
        isb
        ret
        .global Arch_TimerStop
Arch_TimerStop:
        msr     cntp_ctl_el0, xzr
        isb
        ret

// ---------------------------------------------------------------------------
// MMU (4 KiB granule, TTBR0 only). Arch_EnableMmu turns it on with the given
// root and attribute/control register values; the caller built the tables.
// ---------------------------------------------------------------------------
        .global Arch_EnableMmu
Arch_EnableMmu:
        msr     mair_el1, x1
        msr     tcr_el1, x2
        msr     ttbr0_el1, x0
        isb
        tlbi    vmalle1
        dsb     nsh
        isb
        mrs     x3, sctlr_el1
        mov     x4, #((1 << 0) | (1 << 2) | (1 << 12))   // M, C, I
        orr     x3, x3, x4
        msr     sctlr_el1, x3
        isb
        ret
        .global Arch_LoadPageTable
Arch_LoadPageTable:
        msr     ttbr0_el1, x0
        isb
        tlbi    vmalle1is
        dsb     ish
        isb
        ret
        .global Arch_ReadPageTable
Arch_ReadPageTable:
        mrs     x0, ttbr0_el1
        and     x0, x0, #0x0000FFFFFFFFF000
        ret
        .global Arch_FlushTLB
Arch_FlushTLB:
        tlbi    vmalle1is
        dsb     ish
        isb
        ret

// Voluntary yield: a supervisor call into the synchronous vector, which the
// scheduler answers by resuming another thread.
        .global Arch_ForceYield
Arch_ForceYield:
        svc     #0
        ret

// Scheduler lock: one global word shared by all cores.
        .global Arch_LockScheduler
Arch_LockScheduler:
        adr     x0, sched_lock
        mov     w2, #1
1:      ldaxr   w1, [x0]
        cbnz    w1, 1b
        stxr    w3, w2, [x0]
        cbnz    w3, 1b
        ret
        .global Arch_UnlockScheduler
Arch_UnlockScheduler:
        adr     x0, sched_lock
        stlr    wzr, [x0]
        ret

// FPU/SIMD state: v0..v31 (512 bytes). FPCR/FPSR keep their boot values.
        .global Arch_SaveFPU
Arch_SaveFPU:
        stp     q0,  q1,  [x0, #0]
        stp     q2,  q3,  [x0, #32]
        stp     q4,  q5,  [x0, #64]
        stp     q6,  q7,  [x0, #96]
        stp     q8,  q9,  [x0, #128]
        stp     q10, q11, [x0, #160]
        stp     q12, q13, [x0, #192]
        stp     q14, q15, [x0, #224]
        stp     q16, q17, [x0, #256]
        stp     q18, q19, [x0, #288]
        stp     q20, q21, [x0, #320]
        stp     q22, q23, [x0, #352]
        stp     q24, q25, [x0, #384]
        stp     q26, q27, [x0, #416]
        stp     q28, q29, [x0, #448]
        stp     q30, q31, [x0, #480]
        ret
        .global Arch_RestoreFPU
Arch_RestoreFPU:
        ldp     q0,  q1,  [x0, #0]
        ldp     q2,  q3,  [x0, #32]
        ldp     q4,  q5,  [x0, #64]
        ldp     q6,  q7,  [x0, #96]
        ldp     q8,  q9,  [x0, #128]
        ldp     q10, q11, [x0, #160]
        ldp     q12, q13, [x0, #192]
        ldp     q14, q15, [x0, #224]
        ldp     q16, q17, [x0, #256]
        ldp     q18, q19, [x0, #288]
        ldp     q20, q21, [x0, #320]
        ldp     q22, q23, [x0, #352]
        ldp     q24, q25, [x0, #384]
        ldp     q26, q27, [x0, #416]
        ldp     q28, q29, [x0, #448]
        ldp     q30, q31, [x0, #480]
        ret

        .data
        .balign 4
sched_lock:
        .word 0
        .text

        .global Arch_ReadEsr
Arch_ReadEsr:
        mrs     x0, esr_el1
        ret
        .global Arch_ReadFar
Arch_ReadFar:
        mrs     x0, far_el1
        ret

// No hardware RNG on the QEMU cortex-a72 model: report 0 bytes produced so the
// PRNG seeds from the counter instead.
        .global HAL_GetHardwareRandom
HAL_GetHardwareRandom:
        mov     x0, #0
        ret

// Arch_SyncCode(addr, len): make code written through the data cache visible to
// instruction fetch, one cache line (64 bytes is the safe minimum) at a time.
        .global Arch_SyncCode
Arch_SyncCode:
        add     x1, x0, x1
        and     x0, x0, #~63
1:      dc      cvau, x0
        add     x0, x0, #64
        cmp     x0, x1
        b.lo    1b
        dsb     ish
        ic      iallu
        dsb     ish
        isb
        ret
