[bits 64]
; =======================================================
; NEKKO OS - GAME VẼ TRANH ETCH-A-SKETCH (USERLAND)
; =======================================================

    ; 1. XÓA MÀN HÌNH ĐEN THUI (Syscall 3)
    mov rax, 3
    mov rcx, 0x00111111 ; Đen xám Hacker
    int 0x80

    ; 2. IN HƯỚNG DẪN (Syscall 1)
    lea rcx, [rel msg]
    mov rax, 1
    int 0x80

    ; 3. KHỞI TẠO TỌA ĐỘ VẼ (Giữa màn hình)
    ; Dùng R12 và R13 vì chúng là thanh ghi Callee-saved, không bị Syscall làm hỏng
    mov r12, 640 ; X (Cứ giả sử màn hình mày ngang 1280)
    mov r13, 360 ; Y (Dọc 720)

.game_loop:
    ; --- VẼ 1 PIXEL MÀU XANH LÁ CÂY VÀO TỌA ĐỘ HIỆN TẠI (Syscall 2) ---
    mov rcx, r12
    mov rdx, r13
    mov r8, 0x0000FF00 ; Màu Xanh lá cây (Green)
    mov rax, 2
    int 0x80

    ; --- CHỜ NGƯỜI DÙNG BẤM PHÍM (Syscall 4) ---
    mov rax, 4
    int 0x80

    ; KẾT QUẢ TỪ KERNEL NẰM Ở RAX! (Cụ thể là ở AL - 8 bit cuối)
    cmp al, 'w'
    je .move_up
    cmp al, 's'
    je .move_down
    cmp al, 'a'
    je .move_left
    cmp al, 'd'
    je .move_right
    cmp al, 'q'
    je .exit_game

    ; Nếu bấm phím linh tinh, lặp lại từ đầu
    jmp .game_loop

; Các nhãn di chuyển (Cộng/Trừ tọa độ rồi nhảy về Loop để vẽ tiếp)
.move_up:    
    dec r13
    jmp .game_loop

.move_down:
    inc r13
    jmp .game_loop
.move_left:
    dec r12
    jmp .game_loop
.move_right: 
    inc r12
    jmp .game_loop

.exit_game:
    ; Gửi trả quyền lực tối cao lại cho Shell C#
    ret

; Dữ liệu chuỗi
msg: db "NEKKO OS MINI-GAME TICH HOP!", 10, "Dung [W,A,S,D] de ve, phim [Q] de thoat tro choi!", 10, 0