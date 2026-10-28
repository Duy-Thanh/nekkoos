// An ordinary program (not the trusted filesystem thread) tries to send a raw
// sector request to the disk daemon; the kernel must refuse it (syscall 5).
        .text
        .global _start
_start:
        mov     x19, #50               // give the daemon time to hand-shake
1:      mov     x8, #100                // SYS_YIELD
        svc     #0
        subs    x19, x19, #1
        b.ne    1b
        adr     x1, vblk
        mov     x8, #14                 // SYS_PIDBYNAME
        svc     #0
        cmp     x0, #0
        b.le    nodaemon
        mov     x1, x0                  // receiver = disk daemon
        mov     x2, #10                 // IPC_ATA_READ
        mov     x3, #0                  // LBA 0
        mov     x8, #5                  // SYS_SENDIPC
        svc     #0
        cbnz    x0, allowed
        adr     x1, refused
        b       out
allowed: adr    x1, accepted
        b       out
nodaemon: adr   x1, missing
out:    mov     x8, #1
        svc     #0
        mov     x8, #0
        svc     #0
        .balign 2
vblk:   .hword 65, 84, 65, 46, 69, 88, 69, 0     // ATA.EXE
refused:                                 // "snoop: raw disk request refused by the kernel OK\n" as UTF-16
        .hword 115, 110, 111, 111, 112, 58, 32, 114, 97, 119, 32, 100, 105, 115, 107, 32, 114, 101, 113, 117, 101, 115, 116, 32, 114, 101, 102, 117, 115, 101, 100, 32, 98, 121, 32, 116, 104, 101, 32, 107, 101, 114, 110, 101, 108, 32, 79, 75, 10, 0
accepted:                                 // "snoop: raw disk request ACCEPTED (policy broken)\n" as UTF-16
        .hword 115, 110, 111, 111, 112, 58, 32, 114, 97, 119, 32, 100, 105, 115, 107, 32, 114, 101, 113, 117, 101, 115, 116, 32, 65, 67, 67, 69, 80, 84, 69, 68, 32, 40, 112, 111, 108, 105, 99, 121, 32, 98, 114, 111, 107, 101, 110, 41, 10, 0
missing:                                 // "snoop: disk daemon not found\n" as UTF-16
        .hword 115, 110, 111, 111, 112, 58, 32, 100, 105, 115, 107, 32, 100, 97, 101, 109, 111, 110, 32, 110, 111, 116, 32, 102, 111, 117, 110, 100, 10, 0
