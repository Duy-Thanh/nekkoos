// NekkoOS ARM64 entry. QEMU "virt" -kernel enters here at EL1 with the MMU off.
        .section .text.boot, "ax"
        .global _start
_start:
        mrs     x0, mpidr_el1
        and     x0, x0, #0xff
        cbnz    x0, 2f                  // secondary cores park until PSCI bring-up exists

        ldr     x0, =__stack_top
        mov     sp, x0

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
