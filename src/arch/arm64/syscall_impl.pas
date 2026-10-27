{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: syscall_impl (ARM64) - the hardware-touching syscall bodies.

  Same interface as src/arch/x86_64/syscall_impl.pas. This platform has no
  keyboard driver, framebuffer or port I/O yet, so these report failure (0)
  instead of pretending; the generic dispatcher treats 0 as "refused".
  =========================================================================
}
unit syscall_impl;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Returns the RSP to resume on: either currentRsp, or another thread's after a
  context switch when no key was waiting. }
function Disp_KeyboardRead(threadId: Integer; isKing: Boolean; ctx: PQWord;
  currentRsp: QWord): QWord;

{ The functions below return a status code, NOT an RSP. }
function Disp_MapPhysicalMemory(threadId: Integer; isKing: Boolean; ctx: PQWord): QWord;
function Disp_HardwareReport(hwType: Cardinal; payload: QWord; isKing: Boolean): QWord;
function Disp_MapFramebuffer(threadId: Integer; isKing: Boolean; ctx: PQWord): QWord;
function Disp_FramebufferDims(ptrWidth, ptrHeight, ptrScanLine: PQWord): QWord;
function Disp_RedirectFramebuffer(newFb: QWord; w, h, sl: Cardinal; isKing: Boolean): QWord;
procedure Disp_GrantPortAccess(port: Word; threadId: Integer; isKing: Boolean);

implementation

uses arch_hal;

function Disp_KeyboardRead(threadId: Integer; isKing: Boolean; ctx: PQWord;
  currentRsp: QWord): QWord;
begin
  { No keyboard: "no key available", and the caller keeps running. }
  Ctx_SetRet(ctx, 0);
  Disp_KeyboardRead := currentRsp;
end;

function Disp_MapPhysicalMemory(threadId: Integer; isKing: Boolean; ctx: PQWord): QWord;
begin
  Ctx_SetRet(ctx, 0);
  Disp_MapPhysicalMemory := 0;
end;

function Disp_HardwareReport(hwType: Cardinal; payload: QWord; isKing: Boolean): QWord;
begin
  Disp_HardwareReport := 0;
end;

function Disp_MapFramebuffer(threadId: Integer; isKing: Boolean; ctx: PQWord): QWord;
begin
  Ctx_SetRet(ctx, 0);
  Disp_MapFramebuffer := 0;
end;

function Disp_FramebufferDims(ptrWidth, ptrHeight, ptrScanLine: PQWord): QWord;
begin
  Disp_FramebufferDims := 0;
end;

function Disp_RedirectFramebuffer(newFb: QWord; w, h, sl: Cardinal; isKing: Boolean): QWord;
begin
  Disp_RedirectFramebuffer := 0;
end;

procedure Disp_GrantPortAccess(port: Word; threadId: Integer; isKing: Boolean);
begin
  { There are no I/O ports on this architecture. }
end;

end.
