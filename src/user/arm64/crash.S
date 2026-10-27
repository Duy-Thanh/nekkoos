// A user program that must be contained: it reads kernel memory.
        .text
        .global _start
_start:
        ldr     x0, =0x40080000         // kernel image: not accessible from EL0
        ldr     x1, [x0]
1:      b       1b
