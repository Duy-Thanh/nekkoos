{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: isr - runtime ISR trampoline builder.
  PORTED FROM: src/arch/x86_64/ISR.cs (deleted).

  x86_64 ONLY.

  WHAT THIS DOES
  The CPU enters an interrupt through a fixed, statically known stub in
  Hardware.asm. That stub pushes registers and calls SyscallHandler. But
  several CPU exceptions (divide error, general protection fault) arrive
  WITHOUT an error code on the stack, while others (page fault, GPF with
  table) push one. A single handler cannot consume both shapes.

  This module therefore generates a small trampoline in RAM per exception
  kind. The trampoline normalises the frame - pushing a dummy zero for the
  no-error-code case - so the handler always sees the layout declared in
  context.pas, then calls the C-compatible handler with a pointer to the
  saved frame in RCX.

  The emitted byte sequences are an ABI with Hardware.asm and with
  context.pas. They were verified byte-for-byte against the C# original;
  do not "tidy" the ordering.
  =========================================================================
}

unit isr;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Build a trampoline for an exception the CPU delivers WITHOUT an error
  code. Pushes a dummy 0 first so the frame matches the error-code form.
  Returns nil if the stub page could not be allocated. }
function Isr_CreateWrapperWithoutErrorCode(handler: Pointer): Pointer;

{ Build a trampoline for an exception the CPU delivers WITH an error code
  already on the stack. }
function Isr_CreateWrapper(handler: Pointer): Pointer;

implementation

uses pmm, vmm, arch_interface;

procedure Arch_StoreFence; cdecl; external name 'Arch_StoreFence';

{ Bit flags for a user-accessible identity mapping of the stub page. }
const
  MAP_USER_WRITABLE = QWord($03);

var
  { Emission cursor. Only one trampoline is built at a time during boot, so
    a single cursor in this unit is sufficient. }
  stub: PByte = nil;
  i: Integer = 0;

procedure Emit(b: Byte); inline;
begin
  stub[i] := b;
  Inc(i);
end;

{ Write an 8-byte value at an ARBITRARY byte offset. The trampoline has no
  alignment guarantee where this lands, so it must not be indexed as a
  QWord array. }
procedure EmitQword(v: QWord); inline;
var
  b: QWord;
begin
  b := v;
  Emit(Byte(b and $FF));
  Emit(Byte((b shr 8) and $FF));
  Emit(Byte((b shr 16) and $FF));
  Emit(Byte((b shr 24) and $FF));
  Emit(Byte((b shr 32) and $FF));
  Emit(Byte((b shr 40) and $FF));
  Emit(Byte((b shr 48) and $FF));
  Emit(Byte((b shr 56) and $FF));
end;

{ Allocate a page, identity-map it so the CPU can fetch from it, and point
  the emitter at it. Returns False on failure. }
function BeginStub: Boolean;
var
  stubPhys: QWord;
begin
  stub := PByte(Pmm_AllocatePage);
  if stub = nil then
  begin
    BeginStub := False;
    Exit;
  end;

  stubPhys := QWord(stub);
  Vmm_MapPage(stubPhys, stubPhys, MAP_USER_WRITABLE);

  i := 0;
  BeginStub := True;
end;

procedure EndStub; inline;
begin
  { The CPU executes these bytes; make sure they are out of the store
    buffer before the gate is published. }
  Arch_StoreFence;
end;

{ Shared tail of both trampolines, starting from the point where the frame
  has been saved into rbp and the handler address is about to be loaded. }
procedure EmitCallAndReturn; inline;
begin
  { mov rsp, rbp }
  Emit($48); Emit($89); Emit($EC);
  Emit($5D);                                { pop rbp }

  { Restore the saved scratch registers, in exact reverse of push order. }
  Emit($41); Emit($5B);                      { pop r11 }
  Emit($41); Emit($5A);                      { pop r10 }
  Emit($41); Emit($59);                      { pop r9 }
  Emit($41); Emit($58);                      { pop r8 }
  Emit($5B);                                { pop rbx }
  Emit($5A);                                { pop rdx }
  Emit($59);                                { pop rcx }
  Emit($58);                                { pop rax }
end;

{ Push the caller's scratch registers, frame the call, align the stack and
  hand the frame pointer to the handler in RCX (first argument). }
procedure EmitPrologue; inline;
begin
  Emit($50);                                { push rax }
  Emit($51);                                { push rcx }
  Emit($52);                                { push rdx }
  Emit($53);                                { push rbx }
  Emit($41); Emit($50);                     { push r8 }
  Emit($41); Emit($51);                     { push r9 }
  Emit($41); Emit($52);                     { push r10 }
  Emit($41); Emit($53);                     { push r11 }

  Emit($55);                                { push rbp }
  Emit($48); Emit($89); Emit($E5);          { mov rbp, rsp }

  { 16-byte alignment for the System V ABI, plus 32 bytes of shadow space. }
  Emit($48); Emit($83); Emit($E4); Emit($F0);   { and rsp, -16 }
  Emit($48); Emit($83); Emit($EC); Emit($20);   { sub rsp, 0x20 }

  Emit($FC);                                { cld }

  Emit($48); Emit($89); Emit($E9);          { mov rcx, rbp }
end;

{ mov rax, <handler> ; call rax }
procedure EmitCall(handler: Pointer); inline;
begin
  Emit($48); Emit($B8);                     { mov rax, imm64 }
  EmitQword(QWord(handler));
  Emit($FF); Emit($D0);                     { call rax }
end;

function Isr_CreateWrapperWithoutErrorCode(handler: Pointer): Pointer;
begin
  if not BeginStub then
  begin
    Isr_CreateWrapperWithoutErrorCode := nil;
    Exit;
  end;

  { Normalise: fake the missing error code so the handler can treat both
    exception shapes identically. }
  Emit($6A); Emit($00);                      { push 0 }

  EmitPrologue;
  EmitCall(handler);
  EmitCallAndReturn;

  { Discard the dummy error code we pushed, then return from the
    interrupt. The CPU still pops the real frame it saved. }
  Emit($48); Emit($83); Emit($C4); Emit($08);   { add rsp, 8 }
  Emit($48); Emit($CF);                          { iretq }

  EndStub;
  Isr_CreateWrapperWithoutErrorCode := Pointer(stub);
end;

function Isr_CreateWrapper(handler: Pointer): Pointer;
begin
  if not BeginStub then
  begin
    Isr_CreateWrapper := nil;
    Exit;
  end;

  { The CPU already pushed a real error code, so the frame needs no fixup. }
  EmitPrologue;
  EmitCall(handler);
  EmitCallAndReturn;

  Emit($48); Emit($CF);                      { iretq }

  EndStub;
  Isr_CreateWrapper := Pointer(stub);
end;

end.
