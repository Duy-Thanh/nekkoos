// User programs linked into the kernel image until a filesystem exists.
        .section .rodata
        .balign 16
        .global user_hello_start, user_hello_end, user_crash_start, user_crash_end
user_hello_start:
        .incbin "build/arm64/hello.elf"
user_hello_end:
        .balign 16
user_crash_start:
        .incbin "build/arm64/crash.elf"
user_crash_end:
