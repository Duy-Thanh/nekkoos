// User programs linked into the kernel image until a filesystem exists.
        .section .rodata
        .balign 16
        .global user_hello_start, user_hello_end, user_crash_start, user_crash_end
        .global user_mmio_start, user_mmio_end
user_hello_start:
        .incbin "build/arm64/hello.elf"
user_hello_end:
        .balign 16
user_crash_start:
        .incbin "build/arm64/crash.elf"
user_crash_end:
        .balign 16
user_mmio_start:
        .incbin "build/arm64/mmio.elf"
user_mmio_end:
        .balign 16
        .global user_vblk_start, user_vblk_end, user_blktest_start, user_blktest_end
user_vblk_start:
        .incbin "build/arm64/vblk.elf"
user_vblk_end:
        .balign 16
user_blktest_start:
        .incbin "build/arm64/blktest.elf"
user_blktest_end:
        .balign 16
        .global user_snoop_start, user_snoop_end
user_snoop_start:
        .incbin "build/arm64/snoop.elf"
user_snoop_end:
