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

{ ── Register frame access (x86_64: args RBX, RCX, RDX, R8, R9; return RAX,
     second return RBX) ── }
function  Ctx_GetNumber(ctx: PQWord): QWord;
function  Ctx_GetArg(ctx: PQWord; i: Integer): QWord;
procedure Ctx_SetRet(ctx: PQWord; v: QWord);
procedure Ctx_SetRet2(ctx: PQWord; v: QWord);

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
function Disp_Print(threadId: Integer; str: PWord): QWord;
function Disp_DrawPixel(threadId: Integer; x, y, color: QWord): QWord;
function Disp_ClearScreen(threadId: Integer; color: QWord): QWord;
procedure Disp_GrantPortAccess(port: Word; threadId: Integer; isKing: Boolean);
function Disp_SetUID(threadId: Integer; targetUID: Cardinal): QWord;
function Disp_SetGID(threadId: Integer; targetGID: Cardinal): QWord;
function Disp_GlobalSharedMemory(threadId: Integer): QWord;
function Disp_AllocateHeap(threadId: Integer; numPages: QWord; isKing: Boolean): QWord;
function Disp_SharedMemoryPipeline(callerId, targetPid: Integer; numPages: QWord;
  outTargetVAddr: PQWord): QWord;
procedure Disp_AtaLockAcquire;
procedure Disp_AtaLockRelease;
procedure Disp_ResetCursor;

implementation

uses arch_interface, console, ata_kernel, gdt, input_drv, ipc_kernel, kstate,
  pmm, scheduler, syscall_security, terminal, vmm, apic;

const
  { RegisterContext slots (u64 each) counted from the saved RSP. }
  CTX_R9  = 6;
  CTX_R8  = 7;
  CTX_RBX = 11;
  CTX_RDX = 12;
  CTX_RCX = 13;
  CTX_RAX = 14;

  PHYS_MASK = QWord($000FFFFFFFFFF000);
  PAGE      = 4096;

  { IPC mailbox record, see ipc_kernel.pas. }
  MSG_SIZE        = 24;
  MSG_OFF_TYPE    = 0;
  MSG_OFF_SENDER  = 4;
  MSG_OFF_LOCKED  = 12;
  MSG_OFF_PAYLOAD = 16;

function Ctx_GetNumber(ctx: PQWord): QWord;
begin
  Ctx_GetNumber := ctx[CTX_RAX];
end;

function Ctx_GetArg(ctx: PQWord; i: Integer): QWord;
begin
  case i of
    0: Ctx_GetArg := ctx[CTX_RBX];
    1: Ctx_GetArg := ctx[CTX_RCX];
    2: Ctx_GetArg := ctx[CTX_RDX];
    3: Ctx_GetArg := ctx[CTX_R8];
    4: Ctx_GetArg := ctx[CTX_R9];
  else
    Ctx_GetArg := 0;
  end;
end;

procedure Ctx_SetRet(ctx: PQWord; v: QWord);
begin
  ctx[CTX_RAX] := v;
end;

procedure Ctx_SetRet2(ctx: PQWord; v: QWord);
begin
  ctx[CTX_RBX] := v;
end;

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

function IsValidUserPtr(ptr: QWord): Boolean;
var
  tid: Integer;
begin
  IsValidUserPtr := False;
  tid := Sched_GetCurrentThreadId;
  if (tid < 0) or (tid >= Sched_GetThreadCount) then Exit;
  IsValidUserPtr := IsValidUserPtr_Pas(tid, ptr, Sched_GetThreadAddrSpaceRaw(tid),
    Pmm_GetTotalPages) <> 0;
end;

{ True when `threadId` may draw/clear: the foreground task, or nobody is. }
function MayUseScreen(threadId: Integer): Boolean;
var
  fg: Integer;
begin
  fg := Sched_GetForegroundTask;
  MayUseScreen := not ((fg >= 0) and (fg < Sched_GetThreadCount) and
    (Sched_GetThreadActive(fg) <> 0) and (fg <> threadId));
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

function Disp_MapPhysicalMemory(threadId: Integer; isKing: Boolean; ctx: PQWord): QWord;
var
  physAddr, numPages, alignedPhys, offset, virtAddr, threadPml4, currentPml4, p: QWord;
  irq: Boolean;
begin
  Disp_MapPhysicalMemory := 0;
  if not isKing then
  begin
    Sched_SetThreadPhantomDead(threadId, 1);
    Ctx_SetRet(ctx, 0);
    Exit;
  end;

  physAddr := Ctx_GetArg(ctx, 1);
  numPages := Ctx_GetArg(ctx, 2);
  if (numPages = 0) or (numPages > 256) then begin Ctx_SetRet(ctx, 0); Exit; end;

  irq := Sched_AcquireSchedLockSafe;

  alignedPhys := physAddr and (not QWord($FFF));
  offset := physAddr and $FFF;
  virtAddr := Sched_GetThreadHeapBase(threadId);

  threadPml4 := Sched_GetThreadAddrSpaceRaw(threadId);
  currentPml4 := CurrentRoot;
  if (not RootOk(threadPml4)) or (threadPml4 <> currentPml4) then
  begin
    Sched_ReleaseSchedLockSafe(irq);
    Ctx_SetRet(ctx, 0);
    Exit;
  end;

  for p := 0 to numPages - 1 do
    Vmm_MapPageIn(alignedPhys + p * PAGE, virtAddr + p * PAGE, $07, Pointer(currentPml4));
  { Guard page after the window. }
  Vmm_MapPageIn(0, virtAddr + numPages * PAGE, $04, Pointer(currentPml4));

  Sched_SetThreadHeapBase(threadId, Sched_GetThreadHeapBase(threadId) + numPages * PAGE + PAGE);
  Sched_ReleaseSchedLockSafe(irq);

  Ctx_SetRet(ctx, virtAddr + offset);
  Disp_MapPhysicalMemory := 1;
end;

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

{ ── Console I/O ──────────────────────────────────────────────────────────── }

function Disp_Print(threadId: Integer; str: PWord): QWord;
const
  MAX_PRINT = 8192;
  CHECK_INTERVAL = 256;
var
  irq: Boolean;
  left, sinceCheck: Integer;
begin
  { Re-validate the user pointer as it advances: the string can be unmapped by
    another thread of the same process mid-print (TOCTOU, CVE-2026-003). }
  irq := Con_ScreenLockAcquire;
  left := MAX_PRINT;
  sinceCheck := 0;

  while (str^ <> 0) and (left > 0) do
  begin
    if sinceCheck >= CHECK_INTERVAL then
    begin
      if not IsValidUserPtr(QWord(str)) then Break;
      sinceCheck := 0;
    end;
    Terminal_DrawChar_Pas(str^);
    Inc(str);
    Dec(left);
    Inc(sinceCheck);
  end;

  Con_ScreenLockRelease(irq);
  Disp_Print := 1;
end;

function Disp_DrawPixel(threadId: Integer; x, y, color: QWord): QWord;
var
  ux, uy: Cardinal;
  fb: PCardinal;
begin
  Disp_DrawPixel := 0;
  if not MayUseScreen(threadId) then Exit;

  ux := Cardinal(x);
  uy := Cardinal(y);
  if (ux >= Con_GetWidth) or (uy >= Con_GetHeight) then Exit;

  fb := Con_GetFb;
  fb[uy * Con_GetScanLine + ux] := Cardinal(color);
  Disp_DrawPixel := 1;
end;

function Disp_ClearScreen(threadId: Integer; color: QWord): QWord;
begin
  Disp_ClearScreen := 0;
  if not MayUseScreen(threadId) then Exit;
  Con_Clear(Cardinal(color));
  Disp_ClearScreen := 1;
end;

procedure Disp_ResetCursor;
var
  irq: Boolean;
begin
  irq := Con_ScreenLockAcquire;
  Terminal_SetCursor_Pas(0, 0);
  Con_ScreenLockRelease(irq);
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

{ Make sure the MPU trap page exists and is mapped over the thread's shared
  window, so the next access from a now-untrusted thread faults. }
procedure ArmTrapPage(threadId: Integer);
var
  pml4: QWord;
begin
  if kstate_MpuTrapPage_Phys = 0 then kstate_MpuTrapPage_Phys := QWord(Pmm_AllocatePage);
  if Sched_GetThreadSharedMemVirt(threadId) <> 0 then
  begin
    pml4 := Sched_GetThreadAddrSpaceRaw(threadId);
    if RootOk(pml4) then
      Vmm_MapPageIn(kstate_MpuTrapPage_Phys, Sched_GetThreadSharedMemVirt(threadId),
        $05, Pointer(pml4));
  end;
end;

function Disp_SetUID(threadId: Integer; targetUID: Cardinal): QWord;
var
  cur: Cardinal;
begin
  cur := Sched_GetThreadUID(threadId);
  if (cur = 0) or (targetUID = cur) then
  begin
    Sched_SetThreadUID(threadId, targetUID);
    Disp_SetUID := 1;
    Exit;
  end;
  ArmTrapPage(threadId);
  Disp_SetUID := 0;
end;

function Disp_SetGID(threadId: Integer; targetGID: Cardinal): QWord;
var
  cur: Cardinal;
begin
  cur := Sched_GetThreadGID(threadId);
  if (cur = 0) or (Sched_GetThreadUID(threadId) = 0) or (targetGID = cur) then
  begin
    Sched_SetThreadGID(threadId, targetGID);
    Disp_SetGID := 1;
    Exit;
  end;
  ArmTrapPage(threadId);
  Disp_SetGID := 0;
end;

function Disp_GlobalSharedMemory(threadId: Integer): QWord;
var
  irq: Boolean;
  globalPhys, allocPhys, allocPage, threadPml4, currentPml4, cand, p, virt: QWord;
begin
  Disp_GlobalSharedMemory := 0;
  irq := Sched_AcquireSchedLockSafe;
  globalPhys := kstate_SharedRAM_Phys;

  if globalPhys = 0 then
  begin
    allocPhys := QWord(Pmm_AllocateContiguousPages(5));
    if allocPhys = 0 then begin Sched_ReleaseSchedLockSafe(irq); Exit; end;
    globalPhys := allocPhys;
    kstate_SharedRAM_Phys := allocPhys;
  end;

  if Sched_GetThreadSharedMemPhys(threadId) = 0 then
  begin
    allocPage := QWord(Pmm_AllocatePage);
    if allocPage = 0 then begin Sched_ReleaseSchedLockSafe(irq); Exit; end;

    Sched_SetThreadSharedMemPhys(threadId, allocPage);
    Sched_SetThreadPhysPages(threadId, Sched_GetThreadPhysPages(threadId) + 1);
    Sched_SetThreadVirtPages(threadId, Sched_GetThreadVirtPages(threadId) + 5);
    virt := Sched_GetThreadHeapBase(threadId);
    Sched_SetThreadSharedMemVirt(threadId, virt);

    threadPml4 := Sched_GetThreadAddrSpaceRaw(threadId);
    if not RootOk(threadPml4) then begin Sched_ReleaseSchedLockSafe(irq); Exit; end;
    if (globalPhys = 0) or (globalPhys >= PhysLimit) then
    begin
      Sched_ReleaseSchedLockSafe(irq);
      Exit;
    end;
    currentPml4 := CurrentRoot;
    if threadPml4 <> currentPml4 then begin Sched_ReleaseSchedLockSafe(irq); Exit; end;

    { Page 0 is private to the thread; pages 1-4 are the shared window. }
    Vmm_MapPageIn(allocPage, virt, $07, Pointer(currentPml4));
    for p := 1 to 4 do
    begin
      cand := globalPhys + p * PAGE;
      if cand >= PhysLimit then Break;
      Vmm_MapPageIn(cand, virt + p * PAGE, $07, Pointer(currentPml4));
    end;

    Sched_SetThreadHeapBase(threadId, Sched_GetThreadHeapBase(threadId) + PAGE * 5);
  end;

  Disp_GlobalSharedMemory := Sched_GetThreadSharedMemVirt(threadId);
  Sched_ReleaseSchedLockSafe(irq);
end;

function Disp_AllocateHeap(threadId: Integer; numPages: QWord; isKing: Boolean): QWord;
var
  irq: Boolean;
  physAddr, virtAddr, threadPml4, currentPml4, p: QWord;
begin
  Disp_AllocateHeap := 0;
  if numPages = 0 then
  begin
    Disp_AllocateHeap := Sched_GetThreadHeapBase(threadId);
    Exit;
  end;
  if (not isKing) and (numPages > 256) then
  begin
    Sched_SetThreadPhantomDead(threadId, 1);
    Exit;
  end;
  if numPages > 1024 then Exit;

  irq := Sched_AcquireSchedLockSafe;

  physAddr := QWord(Pmm_AllocateContiguousPages(numPages));
  if physAddr = 0 then begin Sched_ReleaseSchedLockSafe(irq); Exit; end;

  virtAddr := Sched_GetThreadHeapBase(threadId);

  threadPml4 := Sched_GetThreadAddrSpaceRaw(threadId);
  currentPml4 := CurrentRoot;
  if (not RootOk(threadPml4)) or (threadPml4 <> currentPml4) then
  begin
    Sched_ReleaseSchedLockSafe(irq);
    Exit;
  end;

  for p := 0 to numPages - 1 do
    Vmm_MapPageIn(physAddr + p * PAGE, virtAddr + p * PAGE, $07, Pointer(currentPml4));
  Vmm_MapPageIn(0, virtAddr + numPages * PAGE, $04, Pointer(currentPml4));

  Sched_SetThreadPhysPages(threadId, Sched_GetThreadPhysPages(threadId) + Cardinal(numPages));
  Sched_SetThreadVirtPages(threadId, Sched_GetThreadVirtPages(threadId) + Cardinal(numPages) + 1);
  Sched_SetThreadHeapBase(threadId, Sched_GetThreadHeapBase(threadId) + numPages * PAGE + PAGE);

  Sched_ReleaseSchedLockSafe(irq);
  Disp_AllocateHeap := virtAddr;
end;

function Disp_SharedMemoryPipeline(callerId, targetPid: Integer; numPages: QWord;
  outTargetVAddr: PQWord): QWord;
var
  irq: Boolean;
  myVAddr, targetVAddr, targetPml4, myPml4, physAddr, currentPml4, p: QWord;
begin
  Disp_SharedMemoryPipeline := 0;
  if (targetPid < 0) or (targetPid >= Sched_GetThreadCount) or
     (Sched_GetThreadActive(targetPid) = 0) then Exit;
  if (numPages = 0) or (numPages > 4096) then Exit;

  irq := Sched_AcquireSchedLockSafe;

  myVAddr := Sched_GetThreadHeapBase(callerId);
  targetVAddr := Sched_GetThreadHeapBase(targetPid);
  targetPml4 := Sched_GetThreadAddrSpaceRaw(targetPid);
  myPml4 := Sched_GetThreadAddrSpaceRaw(callerId);

  if (not RootOk(myPml4)) or (not RootOk(targetPml4)) then
  begin
    Sched_ReleaseSchedLockSafe(irq);
    Exit;
  end;

  physAddr := QWord(Pmm_AllocateContiguousPages(numPages));
  if physAddr = 0 then begin Sched_ReleaseSchedLockSafe(irq); Exit; end;

  currentPml4 := CurrentRoot;
  if myPml4 <> currentPml4 then begin Sched_ReleaseSchedLockSafe(irq); Exit; end;

  for p := 0 to numPages - 1 do
  begin
    Vmm_MapPageIn(physAddr + p * PAGE, myVAddr + p * PAGE, $07, Pointer(currentPml4));
    { The target is only mapped now if it happens to be the loaded space;
      otherwise the daemon maps it lazily. }
    if targetPml4 = currentPml4 then
      Vmm_MapPageIn(physAddr + p * PAGE, targetVAddr + p * PAGE, $07, Pointer(targetPml4));
  end;

  Sched_SetThreadPhysPages(callerId, Sched_GetThreadPhysPages(callerId) + Cardinal(numPages));
  Sched_SetThreadVirtPages(callerId, Sched_GetThreadVirtPages(callerId) + Cardinal(numPages));
  Sched_SetThreadHeapBase(callerId, Sched_GetThreadHeapBase(callerId) + numPages * PAGE);

  Sched_SetThreadVirtPages(targetPid, Sched_GetThreadVirtPages(targetPid) + Cardinal(numPages));
  Sched_SetThreadHeapBase(targetPid, Sched_GetThreadHeapBase(targetPid) + numPages * PAGE);

  Sched_ReleaseSchedLockSafe(irq);

  { If the loaded space changed under us, the mappings went to the wrong one. }
  if myPml4 = CurrentRoot then
    Arch_LoadPageTable(myPml4)
  else
    Exit;

  outTargetVAddr^ := targetVAddr;
  Disp_SharedMemoryPipeline := myVAddr;
end;

procedure Disp_AtaLockAcquire;
begin
  Ata_HwLockAcquire;
end;

procedure Disp_AtaLockRelease;
begin
  Ata_HwLockRelease;
end;

end.
