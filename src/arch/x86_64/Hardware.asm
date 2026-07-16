; =========================================================================
; NekkoOS - A 64-bit x86-64 Educational Operating System
; Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
; Licensed under the GNU General Public License v3.0 (GPLv3)
; =========================================================================
; NEKKO OS - HARDWARE ABSTRACTION LAYER (NASM)
; BẢN ĐÚC BÊ TÔNG MÁC 1000 - CHUẨN MILITARY GRADE
; =========================================================================
bits 64
DEFAULT REL

global Out8
global In8
global EnableInterrupts
global LoadIdt

global GetIsrDiv0
global GetIsrGPF
global GetIsrPageFault
global GetIsrTimer
global GetIsrKeyboard
global GetIsrMouse
global HltCPU
global LoadPML4
global GetCS
global GetSS
global ForceYield
global Out32
global In32
global Out16
global In16
global GetIsrSyscall
global ReadTSC
global DisableInterrupts
global ReadCR2
global FlushTLB
global LoadGDT
global LoadTSS
global EnableNXHardware
global SaveFPU
global RestoreFPU
global ReadVolatile64
global GetIsrYield
global AsmSpinlockAcquire
global AsmSpinlockRelease
global WriteMmio32
global ReadMmio32
global GetIdtr
global GetRflags
global ReadCR3
global CompilerFence
global LoadFence
global StoreFence
global FullFence

extern DivideByZeroHandler
extern GPFHandler
extern PageFaultHandler
extern TimerHandler
extern KeyboardHandler
extern MouseHandler
extern SyscallHandler
extern YieldHandler
global InterlockedCompareExchange
global AtomicExchange
global AtomicAdd64

; =========================================================================
; Arch_* aliases — Architecture Abstraction Layer (AAL) symbol names.
; arch_interface.pas declares these as the portable interface; the actual
; implementation is right here in Hardware.asm via NASM EQU aliases.
; No Pascal forwarder stubs needed — zero overhead, no ABI risk.
; =========================================================================
global Arch_WritePort8
global Arch_WritePort16
global Arch_WritePort32
global Arch_ReadPort8
global Arch_ReadPort16
global Arch_ReadPort32
global Arch_IoWait
global Arch_WriteMmio32
global Arch_ReadMmio32
global Arch_EnableInterrupts
global Arch_DisableInterrupts
global Arch_Halt
global Arch_InterruptsEnabled
global Arch_AtomicExchange
global Arch_AtomicAdd64
global Arch_CmpXchg
global Arch_CompilerFence
global Arch_StoreFence
global Arch_LoadFence
global Arch_FullFence
global Arch_SpinlockAcquire
global Arch_SpinlockRelease
global Arch_LoadPageTable
global Arch_ReadPageTable
global Arch_GetFaultAddress
global Arch_FlushTLB
global Arch_EnableNX
global Arch_LoadGDT
global Arch_LoadIDT
global Arch_LoadTSS
global Arch_GetCS
global Arch_GetSS
global Arch_GetIDTR
global Arch_GetFlags
global Arch_ReadTimestamp
global Arch_SaveFPU
global Arch_RestoreFPU
global Arch_ReadVolatile64
global Arch_GetIsrDiv0
global Arch_GetIsrGPF
global Arch_GetIsrPageFault
global Arch_GetIsrTimer
global Arch_GetIsrKeyboard
global Arch_GetIsrMouse
global Arch_GetIsrSyscall
global Arch_GetIsrYield
global Arch_LockScheduler
global Arch_UnlockScheduler
global Arch_ForceYield

section .data
global GlobalSchedLock
GlobalSchedLock: dd 0

section .text

; Arch_* aliases — same code, alternate entry point names for AAL
; Defined before the implementation labels so forward references work.
Arch_ReadPageTable:
ReadCR3:
    mov rax, cr3
    ret

Arch_GetFlags:
GetRflags:
    pushfq          
    pop rax         
    ret

Arch_GetIDTR:
GetIdtr:
    sidt [rcx]
    ret

; ==========================================================
; [BỌC THÉP 1] MMIO (MEMORY-MAPPED I/O)
; Đụng vào thanh ghi của APIC, PCIe là phải chốt sổ ngay!
; ==========================================================
Arch_WriteMmio32:
WriteMmio32:
    test rcx, rcx
    jz .wmz_ret
    mov dword [rcx], edx
    mfence              ; Force memory write to peripheral register immediately (bypass cache)
    ret
.wmz_ret:
    ret

Arch_ReadMmio32:
ReadMmio32:
    test rcx, rcx
    jz .rmz_zero
    mov eax, dword [rcx]
    lfence              ; Ép CPU đợi thiết bị trả lời xong, nạp hẳn vào EAX rồi mới được chạy lệnh tiếp theo!
    ret
.rmz_zero:
    xor eax, eax
    ret

; ==========================================================
; [BỌC THÉP 2] SPINLOCK ARCHITECTURE
; ==========================================================
Arch_SpinlockAcquire:
AsmSpinlockAcquire:
    mov eax, 1
    xor r10d, r10d          ; [MITIGATION CVE-2026-007] Counter = 0
.spin:
    xchg eax, dword [rcx]   ; xchg trên x86 TỰ ĐỘNG khóa BUS (Atomic)
    test eax, eax
    jz .acquired

    ; [MITIGATION CVE-2026-007] Check spin count
    inc r10d
    cmp r10d, 10000000      ; 10 million iterations (~100ms trên 3GHz CPU)
    jae .spinlock_timeout   ; Jump if Above or Equal

    pause
    jmp .spin

.spinlock_timeout:
    ; Potential deadlock/priority inversion detected!
    ; Note: Không thể call Terminal.Print ở đây vì nó cần lock
    ; Chỉ có thể halt hoặc trigger triple fault
    mov rax, 0xDEADDEAD
    mov rbx, 0xDEADDEAD
    hlt                     ; Halt - better than infinite spin
    jmp .spinlock_timeout   ; Loop halt nếu interrupt wake up

.acquired:
    lfence                  ; [LÁ CHẮN LOAD] Cấm Speculative Execution!
    ret

Arch_SpinlockRelease:
AsmSpinlockRelease:
    sfence                  ; [LÁ CHẮN STORE] Quan Trọng Nhất!!! Ép CPU xả toàn bộ dữ liệu rác trong Vùng Cấm xuống RAM trước khi vứt chìa khóa đi!
    mov dword [rcx], 0      
    ret

global LockScheduler
Arch_LockScheduler:
LockScheduler:
    lea rcx, [rel GlobalSchedLock]
    jmp AsmSpinlockAcquire

global UnlockScheduler
Arch_UnlockScheduler:
UnlockScheduler:
    lea rcx, [rel GlobalSchedLock]
    jmp AsmSpinlockRelease

Arch_ReadVolatile64:
ReadVolatile64:
    mov rax, [rcx]  
    lfence                  ; Đọc xong phải chốt luôn!
    ret

global SaveFPU
Arch_SaveFPU:
SaveFPU:
    push rbp
    mov rbp, rsp
    sub rsp, 528        
    mov rax, rsp
    add rax, 15
    and rax, -16        
    fxsave [rax]        
    
    ; Sử dụng kích thước thực tế từ CPUID thay vì giả định 512 bytes
    mov r8, 0
.loop_save:
    ; Kiểm tra xem đã sao chép đủ chưa
    cmp r8, 512
    jge .done_save

    mov r9, qword [rax + r8]
    mov qword [rcx + r8], r9
    add r8, 8
    cmp r8, 512
    jl .loop_save

.done_save:
    leave
    ret

global RestoreFPU
Arch_RestoreFPU:
RestoreFPU:
    push rbp
    mov rbp, rsp
    sub rsp, 528
    mov rax, rsp
    add rax, 15
    and rax, -16
    
    mov r8, 0
.loop_restore:
    ; Kiểm tra xem đã khôi phục đủ chưa
    cmp r8, 512
    jge .done_restore

    mov r9, qword [rcx + r8]
    mov qword [rax + r8], r9
    add r8, 8
    cmp r8, 512
    jl .loop_restore
    
.done_restore:
    fxrstor [rax]       
    leave
    ret

global EnableNXHardware
Arch_EnableNX:
EnableNXHardware:
    push rbx
    push rcx
    push rdx

    mov eax, 0x80000001
    cpuid
    bt edx, 20
    jnc .not_supported 

    mov ecx, 0xC0000080
    rdmsr
    bts eax, 11
    wrmsr

.not_supported:
    pop rdx
    pop rcx
    pop rbx
    ret

; ==========================================================
; [BỌC THÉP 3] TLB FLUSH & PAGING
; ==========================================================
Arch_FlushTLB:
FlushTLB:
    mfence              ; Chờ Page Table cập nhật xong xuôi
    invlpg [rcx]
    mfence              ; Chốt sổ việc xóa Cache TLB
    ret

Arch_LoadPageTable:
LoadPML4:
    mfence              ; Xả toàn bộ dữ liệu rác trước khi đổi vũ trụ RAM
    mov cr3, rcx
    mfence              ; Ép CPU nhận không gian Paging mới ngay lập tức
    ret

Arch_GetFaultAddress:
ReadCR2:
    mov rax, cr2
    ret

Arch_DisableInterrupts:
DisableInterrupts:
    cli
    ret

Arch_EnableInterrupts:
EnableInterrupts:
    sti
    ret

Arch_ReadTimestamp:
ReadTSC:
    lfence              ; Ép bộ đếm thời gian phải chuẩn xác, không bị CPU reorder lệnh!
    rdtsc               
    shl rdx, 32         
    or rax, rdx         
    ret

Arch_LoadGDT:
LoadGDT:
    lgdt [rcx]
    mov ax, 0x10
    mov ds, ax
    mov es, ax
    mov fs, ax
    mov gs, ax
    mov ss, ax
    push 0x08
    lea rax, [rel .flush]
    push rax
    retfq
.flush:
    ret

Arch_LoadTSS:
LoadTSS:
    ltr cx
    ret

Arch_ForceYield:
ForceYield:
    int 0x81 
    ret

Arch_WritePort16:
Out16:
    mov ax, dx
    mov dx, cx
    out dx, ax
    ret

Arch_ReadPort16:
In16:
    mov dx, cx
    in ax, dx
    ret

Arch_WritePort32:
Out32:
    mov eax, edx
    mov dx, cx
    out dx, eax
    ret

Arch_ReadPort32:
In32:
    mov dx, cx
    in eax, dx
    ret

Arch_GetCS:
GetCS:
    mov ax, cs
    ret

Arch_GetSS:
GetSS:
    mov ax, ss
    ret

Arch_Halt:
HltCPU:
    hlt
    ret

Arch_WritePort8:
Out8:
    mov al, dl
    mov dx, cx
    out dx, al
    ret

Arch_ReadPort8:
In8:
    mov dx, cx
    in al, dx
    ret

Arch_LoadIDT:
LoadIdt:
    lidt [rcx]
    ret

Arch_GetIsrDiv0:
GetIsrDiv0:       lea rax, [rel IsrDiv0]
                  ret
Arch_GetIsrGPF:
GetIsrGPF:        lea rax, [rel IsrGPF]
                  ret
Arch_GetIsrPageFault:
GetIsrPageFault:  lea rax, [rel IsrPageFault]
                  ret
Arch_GetIsrTimer:
GetIsrTimer:      lea rax, [rel IsrTimer]
                  ret
Arch_GetIsrKeyboard:
GetIsrKeyboard:   lea rax, [rel IsrKeyboard]
                  ret
Arch_GetIsrMouse:
GetIsrMouse:      lea rax, [rel IsrMouse]
                  ret
Arch_GetIsrSyscall:
GetIsrSyscall:    lea rax, [rel IsrSyscall]
                  ret
Arch_GetIsrYield:
GetIsrYield: 
    lea rax, [rel IsrYield]
    ret

; =========================================================================
; INTERRUPT SERVICE ROUTINES (ISR) - TASK SWITCHING AND REGISTER PRESERVATION
; (Note: The IRETQ instruction on x86_64 is inherently serializing and acts as
; a memory barrier; explicit mfence calls are not required here).
; =========================================================================

IsrYield:
    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rcx, rsp           
    
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 32

    cld                     
    call YieldHandler      
    
    mov rsp, rbp           
    pop rbp

    mov rsp, rax           

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    iretq

IsrTimer:
    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rcx, rsp           
    
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 32

    cld                     
    call TimerHandler      
    
    mov rsp, rbp           
    pop rbp

    mov rsp, rax           

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    iretq

IsrPageFault:
    ; Khi vào đây, Stack đang là: [SS, RSP, RFLAGS, CS, RIP, ERROR_CODE] <- RSP đang trỏ ở đây
    
    ; 1. Lưu toàn bộ 15 thanh ghi tổng quát xuống Stack
    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rcx, rsp           ; Truyền đỉnh Stack hiện tại vào làm tham số currentRsp cho C#
    
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 32

    cld                     
    call PageFaultHandler
    
    mov rsp, rbp
    pop rbp

    mov rsp, rax           ; Nhận RSP mới từ Context Switch (nếu có)

    ; 2. Khôi phục lại 15 thanh ghi tổng quát
    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    iretq


IsrGPF:
    ; Khi vào đây, Stack có ERROR CODE do CPU tự đẩy vào!
    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rcx, rsp   
    
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 32

    cld                     
    call GPFHandler
    
    mov rsp, rbp
    pop rbp

    mov rsp, rax         ; Load new RSP returned from GPFHandler

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    iretq

IsrKeyboard:
    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 32

    cld                     
    call KeyboardHandler
    
    mov rsp, rbp
    pop rbp

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    iretq

IsrMouse:
    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    ; ==========================================================
    ; [SCHEDULER] Pass stack pointer to C# handler via RCX
    ; ==========================================================
    mov rcx, rsp

    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 32

    cld
    call MouseHandler

    mov rsp, rbp
    pop rbp

    ; ==========================================================
    ; [SCHEDULER] Update stack pointer from RAX to execute context switch
    ; ==========================================================
    mov rsp, rax           

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    iretq

IsrDiv0:
    ; [FIX] Divide by Zero KHÔNG có error code - push dummy 0!
    push 0

    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rcx, rsp

    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 32

    cld
    call DivideByZeroHandler

    mov rsp, rbp
    pop rbp

    mov rsp, rax           ; Context switch - stack MỚI!

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    iretq
.invalid_error_code:
    iretq

IsrSyscall:
    push rax
    push rcx
    push rdx
    push rbx
    push rbp
    push rsi
    push rdi
    push r8
    push r9
    push r10
    push r11
    push r12
    push r13
    push r14
    push r15

    mov rcx, rsp
    
    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 32

    cld                     
    call SyscallHandler     ; Returns ulong: new RSP (SwitchTask result or currentRsp)
    
    mov rsp, rbp
    pop rbp
    mov rsp, rax            ; Switch stack to returned RSP (like IsrTimer/IsrYield)

    pop r15
    pop r14
    pop r13
    pop r12
    pop r11
    pop r10
    pop r9
    pop r8
    pop rdi
    pop rsi
    pop rbp
    pop rbx
    pop rdx
    pop rcx
    pop rax
    iretq

; [1] RÀO CHẮN TRÌNH BIÊN DỊCH (Vũ khí mạnh nhất trị -Ot)
Arch_InterruptsEnabled:
    pushfq
    pop rax
    shr rax, 9
    and rax, 1
    ret

Arch_IoWait:
    xor eax, eax
    out 0x80, al
    ret

Arch_CompilerFence:
CompilerFence:
    ret 

; [2] RÀO CHẮN ĐỌC (Ép CPU x86_64 không được đọc lố)
Arch_LoadFence:
LoadFence:
    lfence
    ret

; [3] RÀO CHẮN GHI (Ép CPU x86_64 xả Store Buffer trước khi đi tiếp)
Arch_StoreFence:
StoreFence:
    sfence
    ret

; [4] MEMORY BARRIER (Used for sensitive I/O device access)
Arch_FullFence:
FullFence:
    mfence
    ret

; ==========================================================
; [ATOMIC] COMPARE-AND-SWAP (CAS)
; C# signature: int CompareExchange(ref uint location, uint value, uint comparand)
; ==========================================================
Arch_CmpXchg:
InterlockedCompareExchange:
    ; RCX = Địa chỉ của biến (ref location)
    ; EDX = Giá trị mới muốn ghi vào (value)
    ; R8D = Giá trị cũ dùng để so sánh (comparand)

    mov eax, r8d                    ; EAX = comparand
    lock cmpxchg dword [rcx], edx   ; So sánh EAX với [RCX]. Nếu bằng, ghi EDX vào [RCX].
                                    ; Bất kể thành công hay không, giá trị gốc tại [RCX] sẽ được trả về trong EAX.
    ret

; ==========================================================
; [ATOMIC] ATOMIC EXCHANGE (XCHG)
; C# signature: uint AtomicExchange(ref uint location, uint newValue)
; Replaces value atomically and returns the previous value
; ==========================================================
Arch_AtomicExchange:
AtomicExchange:
    ; RCX = Địa chỉ của biến (ref location)
    ; EDX = Giá trị mới muốn nhét vào (newValue)
    mov eax, edx                ; Bỏ giá trị mới vào EAX
    xchg dword [rcx], eax       ; Vả thẳng vào RAM! Lấy giá trị cũ trả về EAX!
                                ; (Lệnh XCHG với bộ nhớ tự động bao gồm tiền tố LOCK trên x86)
    ret

; ==========================================================
; 64-bit Atomic Add
; RCX = address of 64-bit value
; RDX = value to add
; Returns previous value in RAX
; Implementation uses LOCK XADD to be atomic across cores
; ==========================================================
Arch_AtomicAdd64:
AtomicAdd64:
    mov rax, rdx
    lock xadd qword [rcx], rax
    ; RAX now contains previous value
    ret