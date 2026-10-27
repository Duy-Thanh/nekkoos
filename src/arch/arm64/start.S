// NekkoOS ARM64 entry. QEMU "virt" -kernel enters here at EL1 with the MMU off.
        .section .text.boot, "ax"
        .global _start
_start:
        b       1f                      // arm64 Image header (Documentation/arm64/booting)
        .word   0
        .quad   0x80000                 // text_offset from the start of RAM
        .quad   __image_size
        .quad   0                       // flags: little-endian, 4K pages
        .quad   0, 0, 0
        .word   0x644d5241              // "ARM\x64"
        .word   0
1:
        mov     x19, x0                 // QEMU passes the device tree address in x0
        mrs     x0, mpidr_el1
        and     x0, x0, #0xff
        cbnz    x0, 2f                  // secondary cores park until PSCI bring-up exists

        ldr     x0, =__stack_top
        mov     sp, x0
        adr     x1, Arm64_DtbPhys
        str     x19, [x1]

        // Let EL1 use FP/SIMD (compiled code may spill with it).
        mrs     x0, cpacr_el1
        orr     x0, x0, #(3 << 20)
        msr     cpacr_el1, x0
        isb

        // Clear .bss
        ldr     x0, =__bss_start
        ldr     x1, =__bss_end
1:      cmp     x0, x1
        b.hs    3f
        str     xzr, [x0], #8
        b       1b
3:      bl      Arm64Main
2:      wfe
        b       2b

        .data
        .balign 8
        .global Arm64_DtbPhys
Arm64_DtbPhys:
        .quad 0
