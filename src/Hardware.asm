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

section .data
global GlobalSchedLock
GlobalSchedLock: dd 0

section .text

ReadCR3:
    mov rax, cr3
    ret

GetRflags:
    pushfq          
    pop rax         
    ret

GetIdtr:
    sidt [rcx]
    ret

; ==========================================================
; [BỌC THÉP 1] MMIO (MEMORY-MAPPED I/O)
; Đụng vào thanh ghi của APIC, PCIe là phải chốt sổ ngay!
; ==========================================================
WriteMmio32:
    test rcx, rcx
    jz .wmz_ret
    mov dword [rcx], edx
    mfence              ; Ép CPU phóng lệnh Ghi thẳng ra thiết bị ngoại vi, đéo được ngâm trong Cache!
    ret
.wmz_ret:
    ret

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
AsmSpinlockAcquire:
    mov eax, 1              
.spin:
    xchg eax, dword [rcx]   ; xchg trên x86 TỰ ĐỘNG khóa BUS (Atomic)
    test eax, eax           
    jz .acquired            
    pause                   
    jmp .spin               
.acquired:
    lfence                  ; [LÁ CHẮN LOAD] Cấm Speculative Execution! Đéo cho phép CPU "đoán trước" mà chạy lén vào Vùng Cấm khi chưa cầm chắc chìa khóa!
    ret

AsmSpinlockRelease:
    sfence                  ; [LÁ CHẮN STORE] Quan Trọng Nhất!!! Ép CPU xả toàn bộ dữ liệu rác trong Vùng Cấm xuống RAM trước khi vứt chìa khóa đi!
    mov dword [rcx], 0      
    ret

global LockScheduler
LockScheduler:
    lea rcx, [rel GlobalSchedLock]
    jmp AsmSpinlockAcquire

global UnlockScheduler
UnlockScheduler:
    lea rcx, [rel GlobalSchedLock]
    jmp AsmSpinlockRelease

ReadVolatile64:
    mov rax, [rcx]  
    lfence                  ; Đọc xong phải chốt luôn!
    ret

global SaveFPU
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
FlushTLB:
    mfence              ; Chờ Page Table cập nhật xong xuôi
    invlpg [rcx]
    mfence              ; Chốt sổ việc xóa Cache TLB
    ret

LoadPML4:
    mfence              ; Xả toàn bộ dữ liệu rác trước khi đổi vũ trụ RAM
    mov cr3, rcx
    mfence              ; Ép CPU nhận không gian Paging mới ngay lập tức
    ret

ReadCR2:
    mov rax, cr2
    ret

DisableInterrupts:
    cli
    ret

EnableInterrupts:
    sti
    ret

ReadTSC:
    lfence              ; Ép bộ đếm thời gian phải chuẩn xác, không bị CPU reorder lệnh!
    rdtsc               
    shl rdx, 32         
    or rax, rdx         
    ret

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

LoadTSS:
    ltr cx
    ret

ForceYield:
    int 0x81 
    ret

Out16:
    mov ax, dx
    mov dx, cx
    out dx, ax
    ret

In16:
    mov dx, cx
    in ax, dx
    ret

Out32:
    mov eax, edx
    mov dx, cx
    out dx, eax
    ret

In32:
    mov dx, cx
    in eax, dx
    ret

GetCS:
    mov ax, cs
    ret

GetSS:
    mov ax, ss
    ret

HltCPU:
    hlt
    ret

Out8:
    mov al, dl
    mov dx, cx
    out dx, al
    ret

In8:
    mov dx, cx
    in al, dx
    ret

LoadIdt:
    lidt [rcx]
    ret

GetIsrDiv0:       lea rax, [rel IsrDiv0]
                  ret
GetIsrGPF:        lea rax, [rel IsrGPF]
                  ret
GetIsrPageFault:  lea rax, [rel IsrPageFault]
                  ret
GetIsrTimer:      lea rax, [rel IsrTimer]
                  ret
GetIsrKeyboard:   lea rax, [rel IsrKeyboard]
                  ret
GetIsrMouse:      lea rax, [rel IsrMouse]
                  ret
GetIsrSyscall:    lea rax, [rel IsrSyscall]
                  ret
GetIsrYield: 
    lea rax, [rel IsrYield]
    ret

; =========================================================================
; CÁC ISR CHUYỂN LUỒNG VÀ KHÔNG ĐỔI LUỒNG
; (Giữ nguyên vì lệnh IRETQ trên x86_64 vốn dĩ đã là một Serializing Instruction - 
; nó tự động hoạt động như một cái Rào Chắn Tuyệt Đối rồi, đéo cần thêm mfence!)
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

    ; 3. [TỬ HUYỆT ĐƯỢC VÁ] DỌN DẸP ERROR CODE TRƯỚC KHI IRETQ!
    ; Lúc này RSP đang trỏ thẳng vào ERROR CODE, ta phải bước qua nó để tới RIP!
    add rsp, 8             
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

    mov rsp, rax         ; Nhận RSP xịn từ GPFHandler bọc thép tao với mày vừa sửa

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

    ; 4. [TỬ HUYỆT ĐƯỢC VÁ] TRẢ TỰ DO CHO STACK, ĐÁ PHĂNG ERROR CODE!
    add rsp, 8            
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
    ; [FIX CHÍ MẠNG 1] CHUYỀN CON TRỎ STACK VÀO RCX CHO THẰNG C#!
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
    ; [FIX CHÍ MẠNG 2] NHẬN STACK MỚI TỪ RAX ĐỂ THỰC THI CONTEXT SWITCH!
    ; Đéo có dòng này thì Scheduler của mày vứt đi!
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
    add rsp, 8               ; Lấy error code từ stack

    ; Kiểm tra tính hợp lệ của error code
    mov r10d, [rsp-8]         ; Lấy error code
    test r10d, r10d           ; Kiểm tra error code có hợp lệ không
    js .invalid_error_code    ; Error code âm -> không hợp lệ

.valid_error_code:
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
    ; [FIX CHÍ MẠNG] CHUYỀN CON TRỎ STACK VÀO RCX CHO C#!
    ; DivideByZeroHandler giờ trả về RSP mới qua RAX (context switch)!
    ; ==========================================================
    mov rcx, rsp

    push rbp
    mov rbp, rsp
    and rsp, -16
    sub rsp, 32

    cld                     
    call DivideByZeroHandler
    
    mov rsp, rbp
    pop rbp

    mov rsp, rax           ; NHẬN STACK MỚI TỪ CONTEXT SWITCH!

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
    call SyscallHandler
    
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

; [1] RÀO CHẮN TRÌNH BIÊN DỊCH (Vũ khí mạnh nhất trị -Ot)
CompilerFence:
    ret 

; [2] RÀO CHẮN ĐỌC (Ép CPU x86_64 không được đọc lố)
LoadFence:
    lfence
    ret

; [3] RÀO CHẮN GHI (Ép CPU x86_64 xả Store Buffer trước khi đi tiếp)
StoreFence:
    sfence
    ret

; [4] RÀO CHẮN TUYỆT ĐỐI (Dao mổ trâu - Chỉ dùng khi đụng chạm I/O Device nhạy cảm)
FullFence:
    mfence
    ret

; ==========================================================
; [VŨ KHÍ NGUYÊN TỬ] COMPARE-AND-SWAP (CAS)
; Hàm C# sẽ là: int CompareExchange(ref uint location, uint value, uint comparand)
; ==========================================================
InterlockedCompareExchange:
    ; RCX = Địa chỉ của biến (ref location)
    ; EDX = Giá trị mới muốn ghi vào (value)
    ; R8D = Giá trị cũ dùng để so sánh (comparand)
    
    mov eax, r8d                    ; EAX = comparand
    lock cmpxchg dword [rcx], edx   ; So sánh EAX với [RCX]. Nếu bằng, ghi EDX vào [RCX].
                                    ; Bất kể thành công hay không, giá trị gốc tại [RCX] sẽ được trả về trong EAX.
    ret

; ==========================================================
; [VŨ KHÍ TỐI THƯỢNG] ATOMIC EXCHANGE (XCHG)
; Hàm C# sẽ là: uint AtomicExchange(ref uint location, uint newValue)
; Đéo cần Compare! Đổi thẳng và lấy giá trị cũ về để tự xét xử!
; ==========================================================
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
AtomicAdd64:
    mov rax, rdx
    lock xadd qword [rcx], rax
    ; RAX now contains previous value
    ret