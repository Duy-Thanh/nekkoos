; =========================================================================
; NekkoOS - A 64-bit x86-64 Educational Operating System
; Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
; Licensed under the GNU General Public License v3.0 (GPLv3)
; =========================================================================
bits 16
org 0x8000

cli
cld
xor ax, ax
mov ds, ax
mov es, ax
mov ss, ax

; ==========================================================
; [SAFETY] Set up temporary 16-bit stack
; ==========================================================
mov sp, 0x8000

; 1. Enable protected mode
lgdt [gdt32_desc]
mov eax, cr0
or al, 1
mov cr0, eax
jmp 0x08:protected_mode

bits 32
protected_mode:
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; ==========================================================
    ; 2. [CPU FEATURES] Enable PAE and SSE (OSFXSR)
    ; ==========================================================
    ; Kiểm tra PAE
    mov eax, 1
    cpuid
    test edx, 1 << 6
    jz .error_pae
    
    ; Kiểm tra SSE
    test edx, 1 << 25
    jz .error_sse
    
    ; Kiểm tra Long Mode
    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29
    jz .error_long_mode

    mov eax, cr4
    or eax, 0x20        ; Bit 5 = PAE
    or eax, 0x600       ; Bit 9 = OSFXSR, Bit 10 = OSXMMEXCPT
    mov cr4, eax

    ; ==========================================================
    ; [COPROCESSOR] Initialize Floating-Point Unit (FPU)
    ; ==========================================================
    mov eax, cr0
    and eax, 0xFFFFFFFB ; Clear EM (Emulation) flag
    or eax, 0x22        ; Set MP (Monitor Coprocessor) and NE (Numeric Error) flags
    mov cr0, eax

    clts                ; Clear Task Switched flag
    fninit              ; Initialize FPU

    ; Kiểm tra xem FPU có được khởi tạo thành công không
    fnstsw ax
    test ax, 0x4C00      ; Kiểm tra các lỗi FPU
    jnz .error_fpu

    ; 3. Load PML4 (page tables) from IPC
    ; ==========================================================
    ; [PAGING] Load 32-bit CR3 initially, then switch to 64-bit
    ; PMM may allocate PML4 above 4GB (0x100000000+) on systems with >2GB RAM.
    ; In 32-bit Protected Mode, CR3 only supports 32-bit physical addresses.
    ; We load the lower 32 bits here, then reload the full 64-bit value once in Long Mode.
    ; ==========================================================
    mov eax, dword [0x8F00]
    mov cr3, eax

    ; ==========================================================
    ; 4. [QUẢ BOM HẠT NHÂN] ENABLE EFER.LME VÀ EFER.NXE !!!
    ; ==========================================================
    mov ecx, 0xC0000080
    rdmsr
    or eax, 0x00000900  ; Bit 8 = LME (Long Mode), Bit 11 = NXE (No-Execute)
    wrmsr

    ; Kiểm tra xem việc ghi vào EFER có thành công không
    rdmsr
    and eax, 0x00000900
    cmp eax, 0x00000900
    jne .error_efer

    ; 5. Enable Paging (64-bit)
    mov eax, cr0
    or eax, 0x80000000
    mov cr0, eax

    ; 6. Load GDT 64-bit
    lgdt [gdt64_desc]
    jmp 0x08:long_mode

.error_fpu:
    ; Xử lý lỗi FPU không được khởi tạo thành công
    cli
    hlt
    jmp .error_fpu

.error_efer:
    ; Xử lý lỗi EFER không được ghi thành công
    cli
    hlt
    jmp .error_efer

.error_pae:
    ; Xử lý lỗi PAE không được hỗ trợ
    cli
    hlt
    jmp .error_pae

.error_sse:
    ; Xử lý lỗi SSE không được hỗ trợ
    cli
    hlt
    jmp .error_sse

.error_long_mode:
    ; Xử lý lỗi Long Mode không được hỗ trợ
    cli
    hlt
    jmp .error_long_mode

bits 64
long_mode:
    ; Kiểm tra xem đã vào Long Mode thành công chưa
    mov eax, 0x80000001
    cpuid
    test edx, 1 << 29
    jz .error_long_mode
    
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov ss, ax

    ; ==========================================================
    ; [SEGMENTS] Clear FS/GS segment registers
    ; Ensures C# compiler/runtime does not trigger GPF when referencing these registers
    ; ==========================================================
    xor ax, ax
    mov fs, ax
    mov gs, ax

    ; ==========================================================
    ; [PAGING] Load full 64-bit CR3 register
    ; Reload CR3 with the full 64-bit PML4 address now that we are in Long Mode.
    ; This corrects the truncated address loaded during 32-bit Protected Mode.
    ; ==========================================================
    mov rax, qword [abs 0x8F00]
    mov cr3, rax

    ; 7. LẤY STACK TỪ HÒM THƯ (0x8F10)
    mov rsp, qword [abs 0x8F10]

    ; If stack mailbox is zero, halt to avoid NULL-stack GPF
    test rsp, rsp
    je .halt

    ; ==========================================================
    ; [SYNCHRONIZATION] Acknowledge stack retrieval
    ; ==========================================================
    mov qword [abs 0x8F10], 0

    ; ==========================================================
    ; [BARRIER] Hardware store fence
    ; Forces CPU to flush the Store Buffer immediately to ensure the
    ; BSP core detects the mailbox state update.
    ; ==========================================================
    ; ==========================================================
    sfence

    xor rbp, rbp

    ; 8. Run C# code!
    mov rax, qword [abs 0x8F08]
    
    ; ==========================================================
    ; [BỌC THÉP 2 - LOAD FENCE] CHỐNG ĐỌC MÙ (SPECULATIVE EXECUTION)!
    ; Ép CPU phải nạp xong xuôi địa chỉ hàm C# vào RAX rồi mới 
    ; được phép nhảy, cấm cầm đèn chạy trước ô tô nổ GPF!
    ; ==========================================================
    lfence

    ; Protect against null entry pointer
    test rax, rax
    je .halt

    call rax

.error_long_mode:
    ; Xử lý lỗi không vào được Long Mode
    cli
    hlt
    jmp .error_long_mode

.halt:
    cli
    hlt
    jmp .halt

; --- DATA (CÁC BẢNG GDT) ---
align 16
gdt32:
    dq 0
    dq 0x00cf9a000000ffff ; 32-bit Code
    dq 0x00cf92000000ffff ; 32-bit Data
gdt32_desc:
    dw $ - gdt32 - 1
    dd gdt32

align 16
gdt64:
    dq 0
    dq 0x0020980000000000 ; 64-bit Code
    dq 0x0000920000000000 ; 64-bit Data
gdt64_desc:
    dw $ - gdt64 - 1
    dd gdt64