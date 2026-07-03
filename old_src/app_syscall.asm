; Bắt buộc ép môi trường 64-bit cho an toàn tuyệt đối
; DEP
bits 64

; =========================================================================
; [FIX CHÍ MẠNG] BÁO CHO LINKER BIẾT ĐÂY LÀ PHÂN VÙNG CHỨA MÃ LỆNH (CODE)
; =========================================================================
section .text

global SyscallPrint
global SyscallExit 
global SyscallSendIPC
global SyscallAllocMem
global SyscallGrantPort
global AppOutByte
global AppInWord
global AppOutWord
global SyscallReceiveIPC
global SyscallGetSharedMem
global SyscallGetChar
global SyscallRunCmd
global SyscallGetThreadUID
global SyscallSetUID
global SyscallGetUID
global SyscallYield
global SyscallWaitIPC
global SyscallGetThreadGID
global SyscallSetGID
global AppInByte
global SyscallGetProcessInfo
global SyscallClear

global SyscallSleep
global SyscallGetUptime

global SyscallGetRsdp
global SyscallMapPhys

global SyscallReportHardware

global SyscallGetPIDByName

global AppOutDword

; ==========================================================
; [VŨ KHÍ MỚI] XUẤT KHẨU LỆNH RESET CURSOR CHO NEKKOTOP!
; ==========================================================
global SyscallResetCursor

; ==========================================================
; SYSCALL 399: RESET CURSOR (GỌI TỪ RING 3)
; C# gọi: void SyscallResetCursor()
; ==========================================================
SyscallResetCursor:
    mov rax, 399
    int 0x80
    ret

; C# gọi: void AppOutDword(ushort port, uint data)
; RCX = port, RDX = data
AppOutDword:
    mov eax, edx
    mov dx, cx
    out dx, eax
    ret

; C# gọi: int SyscallGetPIDByName(char* name)
; RCX = name pointer
SyscallGetPIDByName:
    mov rax, 14
    int 0x80
    ret

; C# gọi: ulong SyscallReportHardware(uint type, ulong physAddr)
; RCX = type, RDX = physAddr
SyscallReportHardware:
    mov rax, 13
    int 0x80
    ret

; C# gọi: ulong SyscallGetRsdp()
SyscallGetRsdp:
    mov rax, 11
    int 0x80
    ret

; C# gọi: ulong SyscallMapPhys(ulong physAddr, ulong numPages)
; RCX = physAddr, RDX = numPages
SyscallMapPhys:
    mov rax, 12
    int 0x80
    ret

; C# gọi: ulong SyscallGetUptime()
SyscallGetUptime:
    mov rax, 96 ; Tao chế thêm ID 96 cho lệnh này
    int 0x80
    ret

; ==========================================================
; SYSCALL 97: SLEEP (C# gọi: void SyscallSleep(ulong ms);)
; ==========================================================
SyscallSleep:
    mov rax, 97
    int 0x80
    ret

; ==========================================================
; SYSCALL 3: XÓA MÀN HÌNH (GỌI TỪ APP RING 3)
; C# gọi: void SyscallClear(uint color); -> RCX = color
; ==========================================================
SyscallClear:
    mov rax, 3
    int 0x80
    ret

; ==========================================================
; SYSCALL 10: LẤY THÔNG TIN PROCESS
; C# gọi: int SyscallGetProcessInfo(uint threadId, ProcessInfo* outInfo)
; RCX = threadId, RDX = outPtr
; ==========================================================
SyscallGetProcessInfo:
    mov rax, 10
    int 0x80
    ret

; ==========================================================
; THIẾT QUÂN LUẬT: BẢO VỆ THANH GHI (CALLEE-SAVED ABI)
; Nếu mượn RBX, RBP, RDI, RSI, R12-R15 -> BẮT BUỘC PUSH/POP
; Các thanh ghi RAX, RCX, RDX, R8, R9, R10, R11 dùng thoải mái.
; ==========================================================

; C# gọi: byte AppInByte(ushort port)
; RCX = port
AppInByte:
    mov dx, cx      
    xor rax, rax    
    in al, dx       
    ret             

; C# gọi: void SyscallPrint(char* msg)
; RCX = msg
SyscallPrint:
    mov rax, 1
    int 0x80
    ret

; C# gọi: void SyscallExit()
SyscallExit:
    mov rax, 0 
    int 0x80
    ret ; Về lý thuyết thì đéo bao giờ chạy đến lệnh này

; ==========================================================
; [BỌC THÉP HẠNG NẶNG] SYSCALL 5: GỬI TIN NHẮN IPC
; C# gọi: SyscallSendIPC(uint receiver, uint type, ulong payload)
; Tham số C# truyền vào: RCX = receiver, RDX = type, R8 = payload
; ==========================================================
SyscallSendIPC:
    ; Đéo mượn thanh ghi Callee-saved nào cả, truyền thẳng xuống Kernel!
    ; (Kernel của mày đang đọc từ ctx->Rcx, ctx->Rdx, ctx->R8, cực kỳ khớp!)
    mov rax, 5      
    int 0x80
    ret

; C# gọi: ulong SyscallAllocMem(ulong numberOfPages)
; RCX = numberOfPages
SyscallAllocMem:
    mov rax, 6      
    int 0x80        
    ret             

; C# gọi: void SyscallGrantPort(ushort port)
; RCX = port
SyscallGrantPort:
    mov rax, 7      
    int 0x80
    ret

; C# gọi: void AppOutByte(ushort port, byte data)
; RCX = port, RDX = data
AppOutByte:
    mov al, dl      
    mov dx, cx      
    out dx, al      
    ret

; C# gọi: ushort AppInWord(ushort port)
; RCX = port
AppInWord:
    mov dx, cx
    xor rax, rax
    in ax, dx       
    ret

; C# gọi: void AppOutWord(ushort port, ushort data)
; RCX = port, RDX = data
AppOutWord:
    mov ax, dx
    mov dx, cx
    out dx, ax
    ret

; C# gọi: int SyscallReceiveIPC(Message* outMsg)
; RCX = outMsg ptr
SyscallReceiveIPC:
    mov rax, 8
    int 0x80
    ret

; C# gọi: ulong SyscallGetSharedMem()
SyscallGetSharedMem:
    mov rax, 99
    int 0x80
    ret

; C# gọi: char SyscallGetChar()
SyscallGetChar:
    mov rax, 4
    int 0x80
    ret

; C# gọi: void SyscallRunCmd(char* cmdPtr)
; RCX = cmdPtr
SyscallRunCmd:
    mov rax, 88
    int 0x80
    ret

; ==========================================================
; [ĐÃ BỌC THÉP TỪ CHIỀU] CÁC SYSCALL THAO TÁC UID/GID
; ==========================================================

; C# gọi: uint SyscallGetThreadUID(int threadId)
; RCX = threadId
SyscallGetThreadUID:
    push rbx      ; Cất RBX
    mov rax, 90
    mov rbx, rcx  ; Đẩy tham số vào RBX cho Kernel đọc
    int 0x80
    pop rbx       ; Trả RBX
    ret

; C# gọi: int SyscallSetUID(uint targetUID)
; RCX = targetUID
SyscallSetUID:
    push rbx      
    mov rax, 91
    mov rbx, rcx  
    int 0x80
    pop rbx       
    ret

; C# gọi: uint SyscallGetUID()
SyscallGetUID:
    mov rax, 89
    int 0x80
    ret

; C# gọi: void SyscallYield()
SyscallYield:
    mov rax, 98
    int 0x80
    ret

; C# gọi: void SyscallWaitIPC()
SyscallWaitIPC:
    mov rax, 100
    int 0x80
    ret

; C# gọi: uint SyscallGetThreadGID(int threadId)
; RCX = threadId
SyscallGetThreadGID:
    push rbx      
    mov rax, 92
    mov rbx, rcx  
    int 0x80
    pop rbx       
    ret

; C# gọi: int SyscallSetGID(uint targetGID)
; RCX = targetGID
SyscallSetGID:
    push rbx      
    mov rax, 93
    mov rbx, rcx  
    int 0x80
    pop rbx       
    ret