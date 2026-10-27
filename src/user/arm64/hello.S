// First ARM64 user program (EL0). Syscall ABI: number in x8, argument 1 in x1,
// result in x0 (see traps_arm64.pas).
        .text
        .global _start
_start:
        adr     x1, msg
        mov     x8, #1                  // SYS_PRINT (UTF-16 string)
        svc     #0

        mov     x8, #89                 // SYS_GETUID: this program runs as root
        svc     #0
        cbnz    x0, bad
        adr     x1, ok
        mov     x8, #1
        svc     #0

        mov     x8, #100                // SYS_YIELD, a few times
        mov     x9, #5
1:      svc     #0
        subs    x9, x9, #1
        b.ne    1b

        adr     x1, bye
        mov     x8, #1
        svc     #0
        mov     x8, #0                  // SYS_EXIT
        svc     #0
bad:
        adr     x1, badmsg
        mov     x8, #1
        svc     #0
        mov     x8, #0
        svc     #0
        .balign 2
msg:                                 // "arm64 EL0: hello from user mode\n" as UTF-16
        .hword 97, 114, 109, 54, 52, 32, 69, 76, 48, 58, 32, 104, 101, 108, 108, 111, 32, 102, 114, 111, 109, 32, 117, 115, 101, 114, 32, 109, 111, 100, 101, 10, 0
ok:                                 // "arm64 EL0: getuid syscall OK\n" as UTF-16
        .hword 97, 114, 109, 54, 52, 32, 69, 76, 48, 58, 32, 103, 101, 116, 117, 105, 100, 32, 115, 121, 115, 99, 97, 108, 108, 32, 79, 75, 10, 0
bye:                                 // "arm64 EL0: user program exiting\n" as UTF-16
        .hword 97, 114, 109, 54, 52, 32, 69, 76, 48, 58, 32, 117, 115, 101, 114, 32, 112, 114, 111, 103, 114, 97, 109, 32, 101, 120, 105, 116, 105, 110, 103, 10, 0
badmsg:                                 // "arm64 EL0: getuid syscall FAILED\n" as UTF-16
        .hword 97, 114, 109, 54, 52, 32, 69, 76, 48, 58, 32, 103, 101, 116, 117, 105, 100, 32, 115, 121, 115, 99, 97, 108, 108, 32, 70, 65, 73, 76, 69, 68, 10, 0
