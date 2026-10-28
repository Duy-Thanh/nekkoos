// Driver-daemon prerequisite: map a virtio-mmio slot with SYS_MAPPHYS (12) and
// read its magic register from EL0. Runs as root (the loader spawns it so).
        .text
        .global _start
_start:
        ldr     x1, =0x0A000000         // virtio-mmio slot 0 (physical)
        mov     x2, #1                  // one page
        mov     x8, #12                 // SYS_MAPPHYS
        svc     #0
        cbz     x0, bad
        ldr     w3, [x0]                // MagicValue register
        ldr     w4, =0x74726976         // "virt"
        cmp     w3, w4
        b.ne    bad
        adr     x1, ok
        b       out
bad:    adr     x1, badmsg
out:    mov     x8, #1
        svc     #0
        mov     x8, #0
        svc     #0
        .balign 2
ok:                                 // "arm64 EL0: mapphys MMIO read OK\n" as UTF-16
        .hword 97, 114, 109, 54, 52, 32, 69, 76, 48, 58, 32, 109, 97, 112, 112, 104, 121, 115, 32, 77, 77, 73, 79, 32, 114, 101, 97, 100, 32, 79, 75, 10, 0
badmsg:                                 // "arm64 EL0: mapphys MMIO read FAILED\n" as UTF-16
        .hword 97, 114, 109, 54, 52, 32, 69, 76, 48, 58, 32, 109, 97, 112, 112, 104, 121, 115, 32, 77, 77, 73, 79, 32, 114, 101, 97, 100, 32, 70, 65, 73, 76, 69, 68, 10, 0
