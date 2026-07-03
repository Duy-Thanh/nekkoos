bits 16
org 0x8000

cli
cld
xor ax, ax
mov ds, ax
mov es, ax
mov ss, ax

; ==========================================================
; [FIX CHÍ MẠNG 3] CẮM CỌC STACK 16-BIT CHỐNG NGẮT NMI!
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
    ; 2. [FIX CHÍ MẠNG] BẬT PAE VÀ SSE (OSFXSR) TRỌN GÓI!
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
    ; [FIX CHÍ MẠNG 2] KHỞI TẠO BỘ ĐỒNG XỬ LÝ (FPU) CHUẨN MỰC!
    ; ==========================================================
    mov eax, cr0
    and eax, 0xFFFFFFFB ; Xóa cờ EM (Emulation)
    or eax, 0x22        ; Bật cờ MP (Monitor Coproc) VÀ NE (Numeric Error)
    mov cr0, eax
    
    clts                ; Xóa cờ Task Switched
    fninit              ; Rửa sạch FPU tinh khiết 100%!

    ; Kiểm tra xem FPU có được khởi tạo thành công không
    fnstsw ax
    test ax, 0x4C00      ; Kiểm tra các lỗi FPU
    jnz .error_fpu

    ; 3. Load PML4 (page tables) from IPC
    ; ==========================================================
    ; [FIX CHÍ MẠNG VŨ TRỤ] LOAD CR3 32-BIT TRƯỚC, RỒI SỬA LẠI 64-BIT!
    ; PMM có thể cấp PML4 trên 4GB (0x100000000+) khi QEMU dùng RAM > 2GB.
    ; Trong Protected Mode, CR3 chỉ chứa được 32 bit (tối đa 4GB).
    ; => Nạp phần THẤP trước, rồi khi vào Long Mode sẽ nạp đầy đủ 64 bit!
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
    ; [FIX CHÍ MẠNG VŨ TRỤ] DỌN SẠCH CACHE RÁC TỪ REAL MODE!
    ; Trình biên dịch C# đụng vào FS/GS sẽ ĐÉO bị GPF nữa!
    ; ==========================================================
    xor ax, ax
    mov fs, ax
    mov gs, ax

    ; ==========================================================
    ; [FIX CHÍ MẠNG NHẤT VŨ TRỤ] NẠP LẠI CR3 ĐẦY ĐỦ 64-BIT!
    ; Ở Protected Mode, CR3 chỉ nhận được 32 bit thấp.
    ; Nếu PML4 nằm trên 4GB (ví dụ 0x100001000), thì CR3 cũ
    ; chỉ chứa 0x00001000 → BẢN ĐỒ BỘ NHỚ SAI HOÀN TOÀN!
    ; Giờ đã ở Long Mode, nạp lại 64-bit đầy đủ để sửa chữa!
    ; ==========================================================
    mov rax, qword [0x8F00]
    mov cr3, rax

    ; 7. LẤY STACK TỪ HÒM THƯ (0x8F10)
    mov rsp, qword [0x8F10]

    ; If stack mailbox is zero, halt to avoid NULL-stack GPF
    test rsp, rsp
    je .halt

    ; ==========================================================
    ; [VŨ KHÍ MỚI] GIAO THỨC ACK (BÁO NHẬN HÀNG)
    ; ==========================================================
    mov qword [0x8F10], 0 
    
    ; ==========================================================
    ; [BỌC THÉP 1 - STORE FENCE] DAO MỔ TRÂU CỦA PHẦN CỨNG!
    ; Ép CPU xả Store Buffer ngay lập tức! Số 0 phải hiện hình 
    ; trên RAM ĐỂ LÕI 0 THẤY ĐƯỢC NGAY TỨC KHẮC!
    ; ==========================================================
    sfence 

    xor rbp, rbp

    ; 8. Run C# code!
    mov rax, qword [0x8F08]
    
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