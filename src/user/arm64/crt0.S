// ARM64 user-space runtime: entry point, the syscall trampoline used by
// uapi.pas, and the few compiler helpers FPC emits calls to.
// Syscall ABI (traps_arm64.pas): number in x8, argument i in x_i (1-based as
// in the x86 dispatcher), results in x0 and x1. All other registers survive.
        .text
        .global _start
_start:
        bl      AppMain
        mov     x8, #0                  // SYS_EXIT if AppMain ever returns
        svc     #0
1:      b       1b

// QWord uapi_sys(n, a1, a2, a3, a4)
        .global uapi_sys
uapi_sys:
        mov     x8, x0
        svc     #0
        ret

// QWord uapi_sys2(n, a1, a2, a3, out2: PQWord): second result stored at out2
        .global uapi_sys2
uapi_sys2:
        mov     x8, x0
        mov     x9, x4
        svc     #0
        cbz     x9, 1f
        str     x1, [x9]
1:      ret

// Full barrier, for ordering memory shared with a DMA device.
        .global uapi_fence
uapi_fence:
        dmb     sy
        ret

// FPC calls this where AArch64 division by zero would silently give 0.
        .global FPC_DIVBYZERO
FPC_DIVBYZERO:
        mov     x8, #0
        svc     #0

// FPC's Move(): memmove(dest = x1, src = x0, count = x2).
        .global FPC_MOVE
FPC_MOVE:
        cbz     x2, 3f
        cmp     x1, x0
        b.ls    1f
        add     x3, x0, x2
        cmp     x1, x3
        b.hs    1f
2:      sub     x2, x2, #1
        ldrb    w3, [x0, x2]
        strb    w3, [x1, x2]
        cbnz    x2, 2b
        ret
1:      ldrb    w3, [x0], #1
        strb    w3, [x1], #1
        subs    x2, x2, #1
        b.ne    1b
3:      ret

// QWord uapi_sys0(n, a0): for syscalls that read their argument from x0.
        .global uapi_sys0
uapi_sys0:
        mov     x8, x0
        mov     x0, x1
        svc     #0
        ret
