{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: CPU - x86_64 Architecture Specific Implementation (Pascal)
  PURPOSE: Low-level x86_64 assembly instructions and features
  =========================================================================
}

unit cpu;

{$mode objfpc}
{$h+}
{$asmmode intel} // Sử dụng cú pháp Intel Assembly chuẩn!

interface

function Arch_ReadTimestamp: QWord; cdecl; public name 'Arch_ReadTimestamp';
procedure Arch_Pause; cdecl; public name 'Arch_Pause';
function Arch_AtomicCompareExchange(var target: Cardinal; newVal: Cardinal; expectedVal: Cardinal): Cardinal; cdecl; public name 'Arch_AtomicCompareExchange';
procedure Arch_AtomicExchange(var target: Cardinal; value: Cardinal); cdecl; public name 'Arch_AtomicExchange';

implementation

{ ReadTSC for x86_64 }
function Arch_ReadTimestamp: QWord; cdecl;
var
  resultVal: QWord;
begin
  asm
    rdtsc
    shl rdx, 32
    or rax, rdx
    mov resultVal, rax
  end;
  Arch_ReadTimestamp := resultVal;
end;

{ PAUSE instruction for spinlocks }
procedure Arch_Pause; cdecl;
begin
  asm
    pause
  end;
end;

{ Atomic Compare-and-Swap using x86 LOCK CMPXCHG with explicit 32-bit sizes }
function Arch_AtomicCompareExchange(var target: Cardinal; newVal: Cardinal; expectedVal: Cardinal): Cardinal; cdecl;
var
  resultVal: Cardinal;
begin
  asm
    mov rdi, target          // RDI = pointer to target
    mov eax, expectedVal     // EAX = expected value (must be in EAX/RAX for cmpxchg)
    mov edx, newVal          // EDX = new value
    lock cmpxchg dword ptr [rdi], edx // Thực hiện so sánh nguyên tử (32-bit dword)
    mov resultVal, eax       // EAX sẽ chứa giá trị cũ sau khi cmpxchg
  end;
  Arch_AtomicCompareExchange := resultVal;
end;

{ Atomic Exchange using x86 XCHG (XCHG is implicitly locked on x86) }
procedure Arch_AtomicExchange(var target: Cardinal; value: Cardinal); cdecl;
begin
  asm
    mov rdi, target          // RDI = pointer to target
    mov eax, value           // EAX = value to exchange
    xchg dword ptr [rdi], eax // Thực hiện đổi chỗ nguyên tử (32-bit dword)
  end;
end;

end.