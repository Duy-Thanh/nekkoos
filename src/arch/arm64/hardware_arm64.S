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
        .global Arch_FlushTLB
Arch_FlushTLB:
        b       Arch_Unsupported
        .global Arch_ForceYield
Arch_ForceYield:
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
        .global Arch_LoadPageTable
Arch_LoadPageTable:
        b       Arch_Unsupported
        .global Arch_LoadTSS
Arch_LoadTSS:
        b       Arch_Unsupported
        .global Arch_LockScheduler
Arch_LockScheduler:
        b       Arch_Unsupported
        .global Arch_ReadPageTable
Arch_ReadPageTable:
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
        .global Arch_RestoreFPU
Arch_RestoreFPU:
        b       Arch_Unsupported
        .global Arch_SaveFPU
Arch_SaveFPU:
        b       Arch_Unsupported
        .global Arch_UnlockScheduler
Arch_UnlockScheduler:
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
