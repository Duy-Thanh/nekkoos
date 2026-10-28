// Lives only on the FAT16 disk: the kernel reads it through FAT16.EXE and
// ATA.EXE (virtio) and starts it with the ELF loader.
        .text
        .global _start
_start:
        adr     x1, msg
        mov     x8, #1
        svc     #0
        mov     x8, #0
        svc     #0
        .balign 2
msg:                                 // "arm64 EL0: DISKAPP.ELF loaded from the FAT16 disk\n" as UTF-16
        .hword 97, 114, 109, 54, 52, 32, 69, 76, 48, 58, 32, 68, 73, 83, 75, 65, 80, 80, 46, 69, 76, 70, 32, 108, 111, 97, 100, 101, 100, 32, 102, 114, 111, 109, 32, 116, 104, 101, 32, 70, 65, 84, 49, 54, 32, 100, 105, 115, 107, 10, 0
