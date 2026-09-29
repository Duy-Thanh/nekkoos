{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: context - x86_64 interrupt/syscall stack frame layout.
  PORTED FROM: src/arch/x86_64/ContextLayout.cs (deleted).

  ARCH: x86_64 ONLY. The record below must match 1:1 the push order used by
  the ISR stubs in Hardware.asm and isr.pas:

      GP registers -> ErrorCode (pushed by the CPU for exceptions 8/13/14,
      faked as 0 by the syscall stub) -> Rip/Cs/Rflags/Rsp/Ss (CPU).

  Any reordering silently corrupts the saved context and turns a page fault
  into a jump into the middle of nowhere, so this layout is treated as an
  ABI and verified in review.

  Kernel-generic code (the syscall dispatcher) accesses registers by ROLE
  through the helpers below, never by field name, so porting to another
  architecture only requires rewriting this unit.
  =========================================================================
}

unit context;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}

interface

{ TRegContext is defined in the implementation section: exposing a record
  type in the interface makes FPC emit RTTI that lld cannot resolve
  (AGENTS.md §6.3). Callers pass and receive raw Pointer values and cast via
  the arch-local helpers below, so no other unit ever names the type. }

{ Syscall number: the libc stub places it in RAX before trapping. }
function Ctx_GetNumber(c: Pointer): QWord; inline;

{ Syscall arguments 0..4, read from RBX/RCX/RDX/R8/R9. }
function Ctx_GetArg(c: Pointer; i: Integer): QWord; inline;

{ Primary return value (RAX). }
procedure Ctx_SetRet(c: Pointer; v: QWord); inline;

{ Secondary return value (RBX) - syscall 101 returns a shared-memory
  address alongside its status code. }
procedure Ctx_SetRet2(c: Pointer; v: QWord); inline;

{ Direct register access for the scheduler and panic handler, which need to
  save/restore the full frame. Keep additions here minimal and arch-local. }
function Ctx_GetRsp(c: Pointer): QWord; inline;
procedure Ctx_SetRsp(c: Pointer; v: QWord); inline;
function Ctx_GetRip(c: Pointer): QWord; inline;
procedure Ctx_SetRip(c: Pointer; v: QWord); inline;
function Ctx_GetErrorCode(c: Pointer): QWord; inline;

implementation

type
  PRegContext = ^TRegContext;
  TRegContext = packed record
    R15: QWord; R14: QWord; R13: QWord; R12: QWord;
    R11: QWord; R10: QWord; R9:  QWord; R8:  QWord;
    Rdi: QWord; Rsi: QWord; Rbp: QWord; Rbx: QWord;
    Rdx: QWord; Rcx: QWord; Rax: QWord;

    { 8 bytes reserved by the CPU for exceptions that carry an error code. }
    ErrorCode: QWord;

    Rip: QWord; Cs: QWord; Rflags: QWord; Rsp: QWord; Ss: QWord;
  end;

function RC(c: Pointer): PRegContext; inline;
begin RC := PRegContext(c); end;


function Ctx_GetNumber(c: Pointer): QWord; inline;
begin
  Ctx_GetNumber := RC(c)^.Rax;
end;

function Ctx_GetArg(c: Pointer; i: Integer): QWord; inline;
begin
  case i of
    0: Ctx_GetArg := RC(c)^.Rbx;
    1: Ctx_GetArg := RC(c)^.Rcx;
    2: Ctx_GetArg := RC(c)^.Rdx;
    3: Ctx_GetArg := RC(c)^.R8;
    4: Ctx_GetArg := RC(c)^.R9;
  else
    Ctx_GetArg := 0;
  end;
end;

procedure Ctx_SetRet(c: Pointer; v: QWord); inline;
begin
  RC(c)^.Rax := v;
end;

procedure Ctx_SetRet2(c: Pointer; v: QWord); inline;
begin
  RC(c)^.Rbx := v;
end;

function Ctx_GetRsp(c: Pointer): QWord; inline;
begin
  Ctx_GetRsp := RC(c)^.Rsp;
end;

procedure Ctx_SetRsp(c: Pointer; v: QWord); inline;
begin
  RC(c)^.Rsp := v;
end;

function Ctx_GetRip(c: Pointer): QWord; inline;
begin
  Ctx_GetRip := RC(c)^.Rip;
end;

procedure Ctx_SetRip(c: Pointer; v: QWord); inline;
begin
  RC(c)^.Rip := v;
end;

function Ctx_GetErrorCode(c: Pointer): QWord; inline;
begin
  Ctx_GetErrorCode := RC(c)^.ErrorCode;
end;

end.
