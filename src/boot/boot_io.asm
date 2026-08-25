; =========================================================================
; NekkoOS - A 64-bit x86-64 Educational Operating System
; Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
; Licensed under the GNU General Public License v3.0 (GPLv3)
; =========================================================================

; =========================================================================
; NEKKO OS - BOOTLOADER I/O PORT AL
; Chỉ chứa đúng 2 hàm Out8 và In8 cho cổng Serial. Cấm nhét thêm rác!
; =========================================================================
bits 64

global Out8
global In8

section .text

Out8:
    mov al, dl
    mov dx, cx
    out dx, al
    ret

In8:
    mov dx, cx
    in al, dx
    ret