{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: syscall_impl (ARM64) - the hardware-touching syscall bodies.

  Same interface as src/arch/x86_64/syscall_impl.pas. This platform has no
  framebuffer or port I/O; keyboard input comes from the serial UART, so these report failure (0)
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
function Disp_HardwareReport(hwType: Cardinal; payload: QWord; isKing: Boolean): QWord;
function Disp_MapFramebuffer(threadId: Integer; isKing: Boolean; ctx: PQWord): QWord;
function Disp_FramebufferDims(ptrWidth, ptrHeight, ptrScanLine: PQWord): QWord;
function Disp_RedirectFramebuffer(newFb: QWord; w, h, sl: Cardinal; isKing: Boolean): QWord;
procedure Disp_GrantPortAccess(port: Word; threadId: Integer; isKing: Boolean);

implementation

uses arch_interface, arch_hal, ipc_kernel, scheduler;

function Disp_KeyboardRead(threadId: Integer; isKing: Boolean; ctx: PQWord;
  currentRsp: QWord): QWord;
const
  MSG_SIZE = 24;  MSG_OFF_TYPE = 0;  MSG_OFF_SENDER = 4;  MSG_OFF_LOCKED = 12;
  MSG_OFF_PAYLOAD = 16;
  KBD_SENDER = 34;                    { the UART interrupt, see traps_arm64 }
var
  fg, i: Integer;
  fgValid, allowed, found: Boolean;
  c: Word;
  q, m: PByte;
  irq: Boolean;
begin
  { Same algorithm as x86 (only the foreground task may read, the message is
    claimed atomically), but the payload is already a character. }
  found := False;
  c := 0;
  fg := Sched_GetForegroundTask;
  fgValid := (fg >= 0) and (fg < Sched_GetThreadCount) and (Sched_GetThreadActive(fg) <> 0);
  allowed := (not fgValid) or (fg = threadId);

  q := PByte(IpcK_GetQueue);
  if allowed and (q <> nil) then
    for i := 0 to IpcK_GetMax - 1 do
    begin
      m := q + i * MSG_SIZE;
      if (PCardinal(m + MSG_OFF_TYPE)^ = 1) and (PCardinal(m + MSG_OFF_SENDER)^ = KBD_SENDER) and
         (Arch_AtomicExchange(PCardinal(m + MSG_OFF_LOCKED)^, 1) = 0) then
      begin
        if (PCardinal(m + MSG_OFF_TYPE)^ = 1) and (PCardinal(m + MSG_OFF_SENDER)^ = KBD_SENDER) then
        begin
          c := Word(PQWord(m + MSG_OFF_PAYLOAD)^);
          Arch_StoreFence;
          PCardinal(m + MSG_OFF_TYPE)^ := 0;
          Arch_StoreFence;
          PCardinal(m + MSG_OFF_LOCKED)^ := 0;
          found := True;
          Break;
        end;
        PCardinal(m + MSG_OFF_LOCKED)^ := 0;
      end;
    end;

  if found then
  begin
    Ctx_SetRet(ctx, c);
    Disp_KeyboardRead := currentRsp;
    Exit;
  end;

  { Nothing to read: sleep one tick and let someone else run. }
  irq := Sched_AcquireSchedLockSafe;
  Sched_SetThreadWakeUpTick(threadId, Sched_GetSystemTicks + 1);
  Sched_SetThreadActive(threadId, 2);
  Sched_ReleaseSchedLockSafe(irq);
  Ctx_SetRet(ctx, 0);
  Disp_KeyboardRead := Sched_SwitchTask(currentRsp);
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
