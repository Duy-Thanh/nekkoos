{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: syscall_core - architecture-independent syscall bodies.

  Everything here is policy over generic kernel services (scheduler, pmm,
  console, ata lock). Address spaces are reached only through arch_hal, so
  this unit does not change when another architecture is added. The parts
  that touch hardware directly stay in the architecture's syscall_impl.
  The Disp_* functions return a status code, NOT an RSP (AGENTS.md 2.3).
  =========================================================================
}
unit syscall_core;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Does the running thread own this user address? }
function IsValidUserPtr(ptr: QWord): Boolean;
function Disp_Print(threadId: Integer; str: PWord): QWord;
function Disp_DrawPixel(threadId: Integer; x, y, color: QWord): QWord;
function Disp_ClearScreen(threadId: Integer; color: QWord): QWord;
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

uses console, ata_kernel, libc, pmm, scheduler, kstate, syscall_security, terminal, arch_hal;

const
  PAGE = HAL_PAGE_SIZE;

function PhysLimit: QWord; inline;
begin
  PhysLimit := Pmm_GetTotalPages * PAGE;
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
    if Hal_AddressSpaceValid(pml4) then
      Hal_MapPageIn(kstate_MpuTrapPage_Phys, Sched_GetThreadSharedMemVirt(threadId),
        HAL_MAP_USER_RO, pml4);
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
    if not Hal_AddressSpaceValid(threadPml4) then begin Sched_ReleaseSchedLockSafe(irq); Exit; end;
    if (globalPhys = 0) or (globalPhys >= PhysLimit) then
    begin
      Sched_ReleaseSchedLockSafe(irq);
      Exit;
    end;
    currentPml4 := Hal_CurrentAddressSpace;
    if threadPml4 <> currentPml4 then begin Sched_ReleaseSchedLockSafe(irq); Exit; end;

    { Page 0 is private to the thread; pages 1-4 are the shared window. }
    Hal_MapPageIn(allocPage, virt, HAL_MAP_USER_RW, currentPml4);
    for p := 1 to 4 do
    begin
      cand := globalPhys + p * PAGE;
      if cand >= PhysLimit then Break;
      Hal_MapPageIn(cand, virt + p * PAGE, HAL_MAP_USER_RW, currentPml4);
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
  currentPml4 := Hal_CurrentAddressSpace;
  if (not Hal_AddressSpaceValid(threadPml4)) or (threadPml4 <> currentPml4) then
  begin
    Sched_ReleaseSchedLockSafe(irq);
    Exit;
  end;

  for p := 0 to numPages - 1 do
    Hal_MapPageIn(physAddr + p * PAGE, virtAddr + p * PAGE, HAL_MAP_USER_RW, currentPml4);
  Hal_MapPageIn(0, virtAddr + numPages * PAGE, HAL_MAP_USER_GUARD, currentPml4);

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

  if (not Hal_AddressSpaceValid(myPml4)) or (not Hal_AddressSpaceValid(targetPml4)) then
  begin
    Sched_ReleaseSchedLockSafe(irq);
    Exit;
  end;

  physAddr := QWord(Pmm_AllocateContiguousPages(numPages));
  if physAddr = 0 then begin Sched_ReleaseSchedLockSafe(irq); Exit; end;

  currentPml4 := Hal_CurrentAddressSpace;
  if myPml4 <> currentPml4 then begin Sched_ReleaseSchedLockSafe(irq); Exit; end;

  for p := 0 to numPages - 1 do
  begin
    Hal_MapPageIn(physAddr + p * PAGE, myVAddr + p * PAGE, HAL_MAP_USER_RW, currentPml4);
    { The target is only mapped now if it happens to be the loaded space;
      otherwise the daemon maps it lazily. }
    if targetPml4 = currentPml4 then
      Hal_MapPageIn(physAddr + p * PAGE, targetVAddr + p * PAGE, HAL_MAP_USER_RW, targetPml4);
  end;

  Sched_SetThreadPhysPages(callerId, Sched_GetThreadPhysPages(callerId) + Cardinal(numPages));
  Sched_SetThreadVirtPages(callerId, Sched_GetThreadVirtPages(callerId) + Cardinal(numPages));
  Sched_SetThreadHeapBase(callerId, Sched_GetThreadHeapBase(callerId) + numPages * PAGE);

  Sched_SetThreadVirtPages(targetPid, Sched_GetThreadVirtPages(targetPid) + Cardinal(numPages));
  Sched_SetThreadHeapBase(targetPid, Sched_GetThreadHeapBase(targetPid) + numPages * PAGE);

  Sched_ReleaseSchedLockSafe(irq);

  { If the loaded space changed under us, the mappings went to the wrong one. }
  if myPml4 = Hal_CurrentAddressSpace then
    Hal_ActivateAddressSpace(myPml4)
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
