{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: syscall_impl - the x86_64 specific syscall bodies.
  PORTED FROM: src/arch/x86_64/SyscallImpl.cs and ContextLayout.cs.

  Syscalls that touch paging, the framebuffer, I/O ports or the keyboard
  mailbox live here so the generic dispatcher stays architecture-neutral.

  CONTRACT THAT HAS ALREADY CAUSED A TRIPLE FAULT (AGENTS.md section 2.3):
  IsrSyscall does `mov rsp, rax; iretq` with whatever the dispatcher returns.
  Only Disp_KeyboardRead returns a real RSP. Every other Disp_* returns a
  success/failure code and the dispatcher must discard it and fall through to
  `return currentRsp`; returning it instead sets RSP to 0 or 1.
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

uses syscall_core, arch_interface, console, ata_kernel, gdt, input_drv, ipc_kernel, kstate,
  pmm, scheduler, syscall_security, terminal, vmm, apic, arch_hal;

const
  PHYS_MASK = QWord($000FFFFFFFFFF000);
  PAGE      = 4096;

  { IPC mailbox record, see ipc_kernel.pas. }
  MSG_SIZE        = 24;
  MSG_OFF_TYPE    = 0;
  MSG_OFF_SENDER  = 4;
  MSG_OFF_LOCKED  = 12;
  MSG_OFF_PAYLOAD = 16;

{ ── Shared helpers ───────────────────────────────────────────────────────── }

function PhysLimit: QWord; inline;
begin
  PhysLimit := Pmm_GetTotalPages * PAGE;
end;

{ A page-table root that is plausible: non-zero, canonical, inside RAM. }
function RootOk(pml4: QWord): Boolean; inline;
begin
  RootOk := (pml4 <> 0) and (pml4 < PhysLimit) and Vmm_IsCanonical(pml4);
end;

function CurrentRoot: QWord; inline;
begin
  CurrentRoot := Vmm_ReadCr3 and PHYS_MASK;
end;

{ ── Syscall 4: keyboard ──────────────────────────────────────────────────── }

function Disp_KeyboardRead(threadId: Integer; isKing: Boolean; ctx: PQWord;
  currentRsp: QWord): QWord;
var
  fg, i: Integer;
  fgValid, allowed, found: Boolean;
  c: Word;
  q: PByte;
  m: PByte;
  irq: Boolean;
begin
  found := False;
  c := 0;

  fg := Sched_GetForegroundTask;
  fgValid := (fg >= 0) and (fg < Sched_GetThreadCount) and (Sched_GetThreadActive(fg) <> 0);
  allowed := (not fgValid) or (fg = threadId);

  q := PByte(IpcK_GetQueue);
  if allowed and (q <> nil) then
  begin
    for i := 0 to IpcK_GetMax - 1 do
    begin
      m := q + i * MSG_SIZE;
      if (PCardinal(m + MSG_OFF_TYPE)^ = 1) and (PCardinal(m + MSG_OFF_SENDER)^ = 33) then
      begin
        { Claim the slot atomically; the ISR may be filling its neighbours. }
        if Arch_AtomicExchange(PCardinal(m + MSG_OFF_LOCKED)^, 1) = 0 then
        begin
          if (PCardinal(m + MSG_OFF_TYPE)^ = 1) and (PCardinal(m + MSG_OFF_SENDER)^ = 33) then
          begin
            c := Kbd_ProcessScanCode(Byte(PQWord(m + MSG_OFF_PAYLOAD)^));
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

{ ── Syscall 12: map physical memory ──────────────────────────────────────── }

{ ── Syscall 13: hardware report ──────────────────────────────────────────── }

function Disp_HardwareReport(hwType: Cardinal; payload: QWord; isKing: Boolean): QWord;
begin
  Disp_HardwareReport := 0;
  if not isKing then Exit;
  case hwType of
    1: begin Apic_Init(payload); Disp_HardwareReport := 1; end;
    2: begin Apic_SetCoreCount(Cardinal(payload)); Disp_HardwareReport := 1; end;
    3: begin Apic_SetIoApicBase(payload); Disp_HardwareReport := 1; end;
  end;
end;

{ ── Syscalls 50-52: framebuffer ──────────────────────────────────────────── }

function Disp_MapFramebuffer(threadId: Integer; isKing: Boolean; ctx: PQWord): QWord;
var
  fbPhys, fbSize, vAddr, numPages, pml4, currentPml4, p: QWord;
  irq: Boolean;
begin
  Disp_MapFramebuffer := 0;
  if not isKing then
  begin
    Sched_SetThreadPhantomDead(threadId, 1);
    Ctx_SetRet(ctx, 0);
    Exit;
  end;

  fbPhys := Con_GetBootFbBase;
  fbSize := QWord(Con_GetScanLine) * Con_GetHeight * 4;

  vAddr := Sched_GetThreadHeapBase(threadId);
  numPages := (fbSize + 4095) div 4096;
  pml4 := Sched_GetThreadAddrSpaceRaw(threadId);

  if not RootOk(pml4) then begin Ctx_SetRet(ctx, 0); Exit; end;

  irq := Sched_AcquireSchedLockSafe;
  currentPml4 := CurrentRoot;
  if pml4 <> currentPml4 then
  begin
    Sched_ReleaseSchedLockSafe(irq);
    Ctx_SetRet(ctx, 0);
    Exit;
  end;

  for p := 0 to numPages - 1 do
    Vmm_MapPageIn(fbPhys + p * PAGE, vAddr + p * PAGE, $07, Pointer(currentPml4));

  Sched_SetThreadHeapBase(threadId, Sched_GetThreadHeapBase(threadId) + numPages * PAGE + PAGE);
  Sched_SetThreadVirtPages(threadId, Sched_GetThreadVirtPages(threadId) + Cardinal(numPages));
  Sched_ReleaseSchedLockSafe(irq);

  Ctx_SetRet(ctx, vAddr);
  Disp_MapFramebuffer := 1;
end;

function Disp_FramebufferDims(ptrWidth, ptrHeight, ptrScanLine: PQWord): QWord;
begin
  if (ptrWidth <> nil) and IsValidUserPtr(QWord(ptrWidth)) then ptrWidth^ := Con_GetWidth;
  if (ptrHeight <> nil) and IsValidUserPtr(QWord(ptrHeight)) then ptrHeight^ := Con_GetHeight;
  if (ptrScanLine <> nil) and IsValidUserPtr(QWord(ptrScanLine)) then ptrScanLine^ := Con_GetScanLine;
  Disp_FramebufferDims := 1;
end;

function Disp_RedirectFramebuffer(newFb: QWord; w, h, sl: Cardinal; isKing: Boolean): QWord;
begin
  Disp_RedirectFramebuffer := 0;
  if not isKing then Exit;
  if IsValidUserPtr(newFb) then
  begin
    Con_RedirectOutput(PCardinal(Pointer(newFb)), w, h, sl);
    Disp_RedirectFramebuffer := 1;
  end;
end;

{ ── I/O ports, IDs, memory ───────────────────────────────────────────────── }

procedure Disp_GrantPortAccess(port: Word; threadId: Integer; isKing: Boolean);
begin
  if not isKing then
  begin
    Sched_SetThreadPhantomDead(threadId, 1);
    Exit;
  end;
  Gdt_SetCoreCount(Apic_GetCoreCount);
  Gdt_GrantPortAccess(port);
end;

end.
