; =========================================================================
; NekkoOS - A 64-bit x86-64 Educational Operating System
; Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
; Licensed under the GNU General Public License v3.0 (GPLv3)
; =========================================================================

;
; This file contains fixes for this bullshit (compiler bug):
;
; Error: AggregateException_ctor_DefaultMessage (Code generation failed for method '[stresstest]NekkoApp.StressTest.AppMain()')
; System.AggregateException: AggregateException_ctor_DefaultMessage (Code generation failed for method '[stresstest]NekkoApp.StressTest.AppMain()')
; ---> ILCompiler.CodeGenerationFailedException: Code generation failed for method '[stresstest]NekkoApp.StressTest.AppMain()'
; ---> System.InvalidOperationException: Expected method 'ThrowOverflowException' not found on type '[zerolib]Internal.Runtime.CompilerHelpers.ThrowHelpers'
;   at Internal.IL.HelperExtensions.GetKnownMethod(TypeDesc, String, MethodSignature) + 0x64
;   at ILCompiler.JitHelper.GetEntryPoint(TypeSystemContext, ReadyToRunHelper, String&, MethodDesc&) + 0x324
;   at ILCompiler.ILScanner.HelperCache.CreateValueFromKey(ReadyToRunHelper) + 0x40
;   at Internal.TypeSystem.LockFreeReaderHashtable`2.CreateValueAndEnsureValueIsInTable(TKey) + 0x14
;   at Internal.IL.ILImporter.ImportBinaryOperation(ILOpcode) + 0x727
;   at Internal.IL.ILImporter.ImportBasicBlock(ILImporter.BasicBlock) + 0x2a7
;   at Internal.IL.ILImporter.ImportBasicBlocks() + 0x59
;   at Internal.IL.ILImporter.Import() + 0x447
;   at ILCompiler.ILScanner.CompileSingleMethod(ScannedMethodNode) + 0x53
;   Exception_EndOfInnerExceptionStack
;   at ILCompiler.ILScanner.CompileSingleMethod(ScannedMethodNode) + 0x104
;   at System.Threading.Tasks.Parallel.<>c__DisplayClass19_0`2.<ForWorker>b__1(RangeWorker&, Int64, Boolean&) + 0x282
;--- End of stack trace from previous location ---
;   at System.Threading.Tasks.Parallel.<>c__DisplayClass19_0`2.<ForWorker>b__1(RangeWorker&, Int64, Boolean&) + 0x37f
;   at System.Threading.Tasks.TaskReplicator.Replica.Execute() + 0x65
;   Exception_EndOfInnerExceptionStack
;   at System.Threading.Tasks.TaskReplicator.Run[TState](TaskReplicator.ReplicatableUserAction`1, ParallelOptions, Boolean) + 0x155
;   at System.Threading.Tasks.Parallel.ForWorker[TLocal,TInt](TInt, TInt, ParallelOptions, Action`1, Action`2, Func`4, Func`1, Action`1) + 0x208
;--- End of stack trace from previous location ---
;   at System.Threading.Tasks.Parallel.ThrowSingleCancellationExceptionOrOtherException(ICollection, CancellationToken, Exception) + 0x31
;   at System.Threading.Tasks.Parallel.ForWorker[TLocal,TInt](TInt, TInt, ParallelOptions, Action`1, Action`2, Func`4, Func`1, Action`1) + 0x33c
;   at System.Threading.Tasks.Parallel.ForEachWorker[TSource,TLocal](IEnumerable`1, ParallelOptions, Action`1, Action`2, Action`3, Func`4, Func`5, Func`1, Action`1) + 0x112
;   at System.Threading.Tasks.Parallel.ForEach[TSource](IEnumerable`1, ParallelOptions, Action`1) + 0x49
;   at ILCompiler.ILScanner.CompileMultiThreaded(List`1) + 0x16a
;   at ILCompiler.ILScanner.ComputeDependencyNodeDependencies(List`1) + 0x164
;   at ILCompiler.DependencyAnalysisFramework.DependencyAnalyzer`2.ComputeMarkedNodes() + 0x9f
;   at ILCompiler.ILScanner.ILCompiler.IILScanner.Scan() + 0x565
;   at BuildCommand.Handle(ParseResult) + 0x2a64
;   at System.CommandLine.Invocation.InvocationPipeline.<>c__DisplayClass4_0.<<BuildInvocationChain>b__0>d.MoveNext() + 0xdb
;--- End of stack trace from previous location ---
;   at System.CommandLine.Builder.CommandLineBuilderExtensions.<>c__DisplayClass17_0.<<UseParseErrorReporting>b__0>d.MoveNext() + 0x58
;--- End of stack trace from previous location ---
;   at System.CommandLine.Builder.CommandLineBuilderExtensions.<>c__DisplayClass12_0.<<UseHelp>b__0>d.MoveNext() + 0x51
;--- End of stack trace from previous location ---
;   at System.CommandLine.Builder.CommandLineBuilderExtensions.<>c__DisplayClass23_0.<<UseVersionOption>b__0>d.MoveNext() + 0x59
;--- End of stack trace from previous location ---
;   at System.CommandLine.Invocation.InvocationPipeline.<Invoke>g__FullInvocationChain|3_0(InvocationContext) + 0x86
;   at Program.Main(String[] args) + 0x227
;
; You can see? bflat constantly complains about the lack of overflow exception handling. 
; This damn thing has been tormenting us right from the kernel writing stage!
;
; To shut this stubbornly conservative compiler up forever, we need force. 
; Writing assembly code is the most powerful thing we can do.
;
; Damn bflat, I'm going to switch this entire operating system to Pascal
; or something else soon. 
;
; Damn it! This goddamn compiler hasn't been updated in ages...
;

bits 64
section .text

global AppMainAsm
extern InitAPI
extern SyscallClear
extern SyscallPrint
extern SyscallGetProcessInfo
extern SyscallSendIPC
extern SyscallGetThreadUID
extern SyscallGetThreadGID
extern SyscallReceiveIPC
extern SyscallAllocMem
extern SyscallCreateSharedBuffer
extern SyscallResetCursor
extern SyscallYield
extern SyscallGetChar
extern SyscallExit
extern SyscallWaitIPC
extern SyscallSleep
extern UpdateDisplayCsharp

section .data
    bye db "[STRESS] Test terminated", 10, 0
    fault_msg db "[STRESS] Triggering Ring3 fault", 10, 0
    dbz_msg db "[STRESS] Triggering Ring3 Divide by Zero", 10, 0
    gpf_msg db "[STRESS] Triggering Ring3 GPF (General Protection Fault)", 10, 0
    isr_msg db "[STRESS] Triggering Dummy ISR (int 0x82)", 10, 0
    nl db 10, 0

section .text
align 16
AppMainAsm:
    ; Setup Stack Frame chuẩn x64 (Allocating shadow space + local variables)
    push rbp
    mov rbp, rsp
    sub rsp, 832            ; Cấp phát đủ lớn cho ProcessInfo, Message, outV, scratch buffer và UI frame buffer

    ; Định nghĩa vị trí biến trên Stack (Local Variables)
    ; rbp - 4  : tick (uint)
    ; rbp - 8  : rand (uint)
    ; rbp - 12 : pid  (uint)
    ; rbp - 16 : loop counter i (uint)
    ; rbp - 20 : frame counter
    ; rbp - 24 : IPC sends
    ; rbp - 28 : IPC receives
    ; rbp - 32 : memory allocations
    ; rbp - 36 : shared buffer grants
    ; rbp - 40 : yields
    ; rbp - 44 : sleep(1) calls
    ; rbp - 48 : cursor resets
    ; rbp - 52 : fault injections
    ; rbp - 112: ProcessInfo info
    ; rbp - 144: Message msg[1]
    ; rbp - 168: ulong outV[1]
    ; rbp - 192: scratch area
    ; rbp - 704: UI frame buffer (512 bytes)

    call InitAPI

    mov ecx, 0x00110011
    call SyscallClear

    ; Initialize tick và rand = 0xC0FFEE
    mov dword [rbp - 4], 0xC0FFEE
    mov dword [rbp - 8], 0xC0FFEE
    mov dword [rbp - 20], 0
    mov dword [rbp - 24], 0
    mov dword [rbp - 28], 0
    mov dword [rbp - 32], 0
    mov dword [rbp - 36], 0
    mov dword [rbp - 40], 0
    mov dword [rbp - 44], 0
    mov dword [rbp - 48], 0
    mov dword [rbp - 52], 0
    mov qword [rbp - 168], 0

.master_loop:
    inc dword [rbp - 20]

    ; --- PRNG Xorshift32 cho TICK ---
    mov eax, [rbp - 4]
    mov edx, eax
    shl edx, 13
    xor eax, edx
    mov edx, eax
    shr edx, 17
    xor eax, edx
    mov edx, eax
    shl edx, 5
    xor eax, edx
    mov [rbp - 4], eax      ; Lưu lại tick

    ; --- PRNG Xorshift32 cho RAND ---
    mov eax, [rbp - 8]
    mov edx, eax
    shl edx, 13
    xor eax, edx
    mov edx, eax
    shr edx, 17
    xor eax, edx
    mov edx, eax
    shl edx, 5
    xor eax, edx
    mov [rbp - 8], eax      ; Lưu lại rand

    ; --- 1. PROCESS & IPC STRESS ---
    mov dword [rbp - 12], 0 ; pid = 0
.pid_loop:
    cmp dword [rbp - 12], 64
    jae .ipc_receive_stage

    ; SyscallGetProcessInfo(pid, &info)
    mov ecx, [rbp - 12]
    lea rdx, [rbp - 112]
    call SyscallGetProcessInfo
    cmp eax, 1
    jne .pid_loop_next

    ; Kiểm tra info.Active == 1 hoặc 2 (Giả định Active nằm ở 4 bytes đầu của ProcessInfo)
    mov eax, [rbp - 112]
    cmp eax, 1
    je .ipc_stress_trigger
    cmp eax, 2
    jne .pid_loop_next

.ipc_stress_trigger:
    ; if ((rand & 15u) == 0u)
    mov eax, [rbp - 8]
    and eax, 15
    jnz .thread_info_trigger
    
    ; SyscallSendIPC(pid, (byte)(rand & 0xFFu), (ulong)rand)
    mov ecx, [rbp - 12]
    mov edx, [rbp - 8]
    and edx, 0xFF
    mov r8, [rbp - 8]       ; rand (ulong)
    call SyscallSendIPC
    inc dword [rbp - 24]

.thread_info_trigger:
    ; if ((rand & 31u) == 0u)
    mov eax, [rbp - 8]
    and eax, 31
    jnz .pid_loop_next
    
    mov ecx, [rbp - 12]
    call SyscallGetThreadUID
    mov ecx, [rbp - 12]
    call SyscallGetThreadGID

.pid_loop_next:
    ; Xorshift rand cuối loop pid
    mov eax, [rbp - 8]
    mov edx, eax
    shl edx, 13
    xor eax, edx
    mov edx, eax
    shr edx, 17
    xor eax, edx
    mov edx, eax
    shl edx, 5
    xor eax, edx
    mov [rbp - 8], eax

    inc dword [rbp - 12]    ; pid++
    jmp .pid_loop

    ; --- 2. IPC RECEIVE ---
.ipc_receive_stage:
    mov dword [rbp - 16], 0 ; i = 0
.ipc_recv_loop:
    cmp dword [rbp - 16], 4
    jae .mem_alloc_stage
    lea rcx, [rbp - 144]    ; &msg
    call SyscallReceiveIPC
    inc dword [rbp - 28]
    inc dword [rbp - 16]
    jmp .ipc_recv_loop

    ; --- 3. MEMORY ALLOCATION ---
.mem_alloc_stage:
    mov eax, [rbp - 4]      ; tick
    and eax, 255
    jnz .shared_buffer_stage
    
    mov rcx, 1
    call SyscallAllocMem
    test rax, rax
    jz .shared_buffer_stage
    inc dword [rbp - 32]
    mov edx, [rbp - 8]      ; rand
    and dl, 0xFF
    mov [rax], dl           ; p[0] = (byte)(rand & 0xFFu)

    ; --- 4. SHARED BUFFER ---
.shared_buffer_stage:
    mov eax, [rbp - 4]      ; tick
    and eax, 127
    jnz .invalid_syscall_stage
    
    mov qword [rbp - 168], 0 ; outV[0] = 0
    xor ecx, ecx            ; 0u
    mov rdx, 1              ; 1UL
    lea r8, [rbp - 168]     ; outV
    call SyscallCreateSharedBuffer
    test rax, rax
    jz .invalid_syscall_stage
    inc dword [rbp - 36]
    
    ; Gán nhanh 16 bytes bằng giá trị rand
    mov edx, [rbp - 8]
    and dl, 0xFF
    mov ecx, 16
.pb_loop:
    mov [rax + rcx - 1], dl
    dec ecx
    jnz .pb_loop

    ; --- 5. INVALID SYSCALL STRESS ---
.invalid_syscall_stage:
    mov eax, [rbp - 4]
    and eax, 1023
    jnz .terminal_ops_stage
    
    xor rcx, rcx            ; (Message*)0
    call SyscallReceiveIPC
    xor ecx, ecx
    xor rdx, rdx            ; (ProcessInfo*)0
    call SyscallGetProcessInfo

    ; Also poke shared buffer state harder by touching the returned pointer window
    mov qword [rbp - 160], 0

    ; --- 6. TERMINAL OPS ---
.terminal_ops_stage:
    mov eax, [rbp - 4]
    and eax, 255
    jnz .yield_stage
    call SyscallResetCursor
    inc dword [rbp - 48]

    ; --- 7. YIELD ---
.yield_stage:
    mov eax, [rbp - 4]
    and eax, 127
    jnz .status_report_stage
    call SyscallYield
    inc dword [rbp - 40]

    ; --- 8. STATUS REPORT ---
.status_report_stage:
    mov eax, [rbp - 20]
    and eax, 15
    jnz .user_input_stage

    ; Prepare stack arguments (5th to 9th arguments) for Windows x64 calling convention
    ; [rsp + 32]: shm [rbp - 36]
    mov eax, [rbp - 36]
    mov [rsp + 32], rax
    ; [rsp + 40]: yld [rbp - 40]
    mov eax, [rbp - 40]
    mov [rsp + 40], rax
    ; [rsp + 48]: slp [rbp - 44]
    mov eax, [rbp - 44]
    mov [rsp + 48], rax
    ; [rsp + 56]: rst [rbp - 48]
    mov eax, [rbp - 48]
    mov [rsp + 56], rax
    ; [rsp + 64]: flt [rbp - 52]
    mov eax, [rbp - 52]
    mov [rsp + 64], rax

    ; Prepare register arguments (1st to 4th arguments)
    mov ecx, [rbp - 20]     ; frame
    mov edx, [rbp - 24]     ; sends
    mov r8d, [rbp - 28]     ; recvs
    mov r9d, [rbp - 32]     ; mem

    call UpdateDisplayCsharp

    ; --- 9. USER INPUT ---
.user_input_stage:
    call SyscallGetChar
    cmp al, 'q'
    je .terminate_test
    cmp al, 'Q'
    je .terminate_test
    cmp al, 'f'
    je .trigger_fault
    cmp al, 'F'
    je .trigger_fault
    cmp al, 'z'
    je .trigger_dbz
    cmp al, 'Z'
    je .trigger_dbz
    cmp al, 'g'
    je .trigger_gpf
    cmp al, 'G'
    je .trigger_gpf
    cmp al, 'i'
    je .trigger_isr
    cmp al, 'I'
    je .trigger_isr
    jmp .sleep_stage

.terminate_test:
    mov ecx, 0x00111111
    call SyscallClear
    lea rcx, [rel bye]
    call SyscallPrint
    call SyscallExit
.wait_ipc_dead:
    call SyscallWaitIPC
    jmp .wait_ipc_dead

.trigger_fault:
    lea rcx, [rel fault_msg]
    call SyscallPrint
    inc dword [rbp - 52]
    mov rax, 0x00007FFFFFFFF000
    mov byte [rax], 0xCC    ; Trấn lột phân trang Ring 3 luôn!

.trigger_dbz:
    lea rcx, [rel dbz_msg]
    call SyscallPrint
    xor eax, eax
    xor ecx, ecx
    div ecx                 ; Divide by zero! (Exception 0x00)

.trigger_gpf:
    lea rcx, [rel gpf_msg]
    call SyscallPrint
    ; Trigger GPF: Execute privileged instruction from Ring 3
    lgdt [rsp]              ; Load GDT from stack - privileged instruction! (GPF 0x0D)

.trigger_isr:
    lea rcx, [rel isr_msg]
    call SyscallPrint
    ; Trigger software interrupt to test dummy ISR
    int 0x82                ; Software interrupt vector 0x82

.sleep_stage:
    mov eax, [rbp - 4]
    and eax, 7
    jnz .sleep_zero
    mov ecx, 1
    call SyscallSleep
    inc dword [rbp - 44]
    jmp .master_loop_end
.sleep_zero:
    xor ecx, ecx
    call SyscallSleep

.master_loop_end:
    jmp .master_loop

    ; Clean up frame (Thực ra loop vô tận nhưng viết cho chuẩn)
    mov rsp, rbp
    pop rbp
    ret

WriteHex8:
    push rbx
    mov ebx, eax
    mov ecx, 8
.hex_loop:
    mov eax, ebx
    shr eax, 28
    and eax, 15
    cmp eax, 9
    jbe .digit
    add eax, 55
    jmp .store
.digit:
    add eax, 48
.store:
    mov byte [rdi], al
    inc rdi
    shl ebx, 4
    dec ecx
    jnz .hex_loop
    pop rbx
    ret