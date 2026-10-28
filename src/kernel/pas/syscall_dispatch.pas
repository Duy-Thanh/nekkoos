{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: syscall_dispatch - the syscall switch.
  PORTED FROM: src/kernel/Syscall.cs.

  Entered from IsrSyscall (Hardware.asm) with the saved RSP; whatever this
  returns becomes the new RSP (`mov rsp, rax; iretq`).

  >>> THE RULE (AGENTS.md section 2.3, cost a triple fault twice) <<<
  A handler may return a *different* RSP only when it really switched
  threads, i.e. the value came from Sched_SwitchTask or Disp_KeyboardRead.
  Every other case must leave the function through the final
  `SyscallHandler := currentRsp`. The Disp_* helpers return success codes
  (0 or 1); using one as a return value reboots the machine.

  To make that hard to get wrong here, the case bodies never assign to the
  function result. `switched` is the only way out early, and it is set
  from Sched_SwitchTask / Disp_KeyboardRead alone.
  =========================================================================
}
unit syscall_dispatch;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

implementation

uses arch_interface, console, kstring, libc, pmm, scheduler, ipc, ipc_kernel,
  ata_kernel, fat16_kernel, kstate, syscall_security, syscall_impl, syscall_core, arch_hal,
  internal_shell, sudo_dispatch;

const
  PRIVILEGED_DEAD = QWord($DEAD);

var
  SyscallRet: QWord;

{ A pointer a ring-3 caller handed us must lie in user space and be mapped
  present+user in its own address space. }
function UserPtrOk(ptr: QWord): Boolean;
var
  tid: Integer;
begin
  UserPtrOk := False;
  if ptr < $1000 then Exit;
  tid := Sched_GetCurrentThreadId;
  if (tid < 0) or (tid >= Sched_GetThreadCount) then Exit;
  UserPtrOk := Hal_IsUserPageMapped(Sched_GetThreadAddrSpaceRaw(tid), ptr);
end;

{ Bytes of ProcessInfo as the user-space struct lays it out (packed, 55 bytes):
    0 ID u32 | 4 UID u32 | 8 GID u32 | 12 Active | 13 IsJailed | 14 IsPhantomDead
    15 HeapMemory u64 | 23 Name[16] | 39 CpuTicks u64 | 47 PhysPages u32 | 51 VirtPages u32 }
procedure FillProcessInfo(info: PByte; targetId: Cardinal; reveal: Boolean);
var
  t: Integer;
  name: PByte;
begin
  t := Integer(targetId);
  PCardinal(info + 0)^ := targetId;
  PCardinal(info + 4)^ := Sched_GetThreadUID(t);
  PCardinal(info + 8)^ := Sched_GetThreadGID(t);
  info[12] := Sched_GetThreadActive(t);
  info[13] := Sched_GetThreadJailed(t);
  info[14] := Sched_GetThreadPhantomDead(t);
  { The real heap base is only for root or the process itself: handing it to
    anyone helps locating the daemons running as root. }
  if reveal then PQWord(info + 15)^ := Sched_GetThreadHeapBase(t)
  else PQWord(info + 15)^ := 0;
  name := Sched_GetThreadName(t);
  if name <> nil then MemCopy(info + 23, name, 16);
  PQWord(info + 39)^ := Sched_GetThreadCpuTicks(t);
  PCardinal(info + 47)^ := Sched_GetThreadPhysPages(t);
  PCardinal(info + 51)^ := Sched_GetThreadVirtPages(t);
end;

function SyscallHandler(currentRsp: QWord): QWord; cdecl; public name 'SyscallHandler';
var
  ctx: PQWord;
  syscallId, currentTicks: QWord;
  id: Integer;
  isKing: Boolean;
  switched: Boolean;       { True once `switchedRsp` holds a real new RSP. }
  switchedRsp: QWord;
  irq: Boolean;
  receiverId, msgType, targetId: Cardinal;
  sendSuccess, isFat16Daemon: Boolean;
  outMsg: PByte;
  rType, rSender: Cardinal;
  rPayload: QWord;
  outPtr: QWord;
  i: Integer;
  foundId: Int64;
  targetName: PWord;
  pidArg: QWord;
  ticksToSleep: QWord;
  targetPid: Cardinal;
  numPages, targetVAddr, myVAddr: QWord;
  hwType: Cardinal;
begin
  { Syscall handling runs with interrupts off: a context switch in the middle
    of page-table edits would leave CR3 and the thread's address space
    disagreeing. Nor may it call Yield (INT 0x81): that would nest a ring-0
    interrupt frame inside the 5-word syscall frame and #GP on IRETQ. Blocking
    syscalls switch directly with Sched_SwitchTask instead. }
  switched := False;
  switchedRsp := currentRsp;

  if (currentRsp = 0) or (currentRsp < $1000) then
  begin
    SyscallHandler := currentRsp;
    Exit;
  end;

  ctx := PQWord(Pointer(currentRsp));
  syscallId := Ctx_GetNumber(ctx);
  id := Sched_GetCurrentThreadId;

  if (Sched_GetThreads = nil) or (id < 0) or (id >= Sched_GetThreadCount) then
  begin
    Ctx_SetRet(ctx, 0);
    SyscallHandler := currentRsp;
    Exit;
  end;

  isKing := Sched_GetThreadUID(id) = 0;

  { A jailed process that has been caught misbehaving still gets "answers",
    but nothing real: this is the phantom sandbox. }
  if (Sched_GetThreadJailed(id) = 1) and (Sched_GetThreadPhantomDead(id) = 1) then
  begin
    if syscallId = 0 then
    begin
      Sched_TerminateCurrentTask;
      SyscallHandler := currentRsp;
      Exit;
    end;
    if (syscallId = 6) or (syscallId = 99) then
    begin
      Ctx_SetRet(ctx, QWord($0000DEADBEEF0000) or QWord($0000FEEBDEAD0000));
      SyscallHandler := currentRsp;
      Exit;
    end;
    Ctx_SetRet(ctx, 1);
    SyscallHandler := Sched_SwitchTask(currentRsp);
    Exit;
  end;

  if Sched_GetThreadJailed(id) = 1 then
  begin
    if (syscallId = 7) or (syscallId = 91) or (syscallId = 93) then
    begin
      Sched_SetThreadPhantomDead(id, 1);
      Ctx_SetRet(ctx, 1);
      SyscallHandler := currentRsp;
      Exit;
    end;
    if (syscallId = 6) and (Ctx_GetArg(ctx, 1) > 256) then
    begin
      Sched_SetThreadPhantomDead(id, 1);
      Ctx_SetRet(ctx, QWord($0000DEADBEEF0000) and QWord($0000FEEBDEAD0000));
      SyscallHandler := currentRsp;
      Exit;
    end;
  end;

  currentTicks := Sched_GetSystemTicks;

  case syscallId of
    { 0: exit }
    0: Sched_TerminateCurrentTask;

    { 1: print a user string }
    1:
      begin
        if (Ctx_GetArg(ctx, 1) = 0) or (not UserPtrOk(Ctx_GetArg(ctx, 1))) then
          Ctx_SetRet(ctx, 0)
        else
          Ctx_SetRet(ctx, Disp_Print(id, PWord(Ctx_GetArg(ctx, 1))));
      end;

    { 2: draw pixel }
    2: Ctx_SetRet(ctx, Disp_DrawPixel(id, Ctx_GetArg(ctx, 1), Ctx_GetArg(ctx, 2), Ctx_GetArg(ctx, 3)));

    { 3: clear screen }
    3: Ctx_SetRet(ctx, Disp_ClearScreen(id, Ctx_GetArg(ctx, 1)));

    { 4: keyboard read. The ONE case whose helper returns a real RSP. }
    4:
      begin
        switchedRsp := Disp_KeyboardRead(id, isKing, ctx, currentRsp);
        switched := True;
      end;

    { 5: send IPC }
    5:
      begin
        receiverId := Cardinal(Ctx_GetArg(ctx, 1));
        msgType := Cardinal(Ctx_GetArg(ctx, 2));

        if (receiverId >= Cardinal(Sched_GetThreadCount)) or
           (Sched_GetThreadActive(Integer(receiverId)) = 0) then
          Ctx_SetRet(ctx, 0)
        else if (Sched_GetThreadJailed(id) = 1) and ((receiverId = 0) or (receiverId = 1)) then
        begin
          Sched_SetThreadPhantomDead(id, 1);
          Ctx_SetRet(ctx, 1);
        end
        else if (IsPrivilegedIpcType(msgType) <> 0) and (Sched_GetThreadUID(id) <> 0) then
          { Kill / shutdown / reboot messages are root-only; otherwise any user
            could tell the ACPI daemon to power the machine off. }
          Ctx_SetRet(ctx, 0)
        else
        begin
          isFat16Daemon := (Fat16K_GetTrustedThreadId >= 0) and (Fat16K_GetTrustedThreadId = id);
          { Raw sector access to the ATA daemon is for the FAT16 daemon alone.
            The daemon is identified by the thread id the kernel recorded when
            it spawned it, never by its (user-chosen) name. }
          if (Ata_GetDaemonId <> 0) and (receiverId = Ata_GetDaemonId) and (not isFat16Daemon) then
            Ctx_SetRet(ctx, 0)
          else
          begin
            sendSuccess := IpcK_Send(msgType, Cardinal(id), receiverId, Ctx_GetArg(ctx, 3));
            if sendSuccess then
            begin
              irq := Sched_AcquireSchedLockSafe;
              if Sched_GetThreadActive(Integer(receiverId)) = 2 then
                Sched_SetThreadActive(Integer(receiverId), 1);
              Sched_SetThreadVRuntime(Integer(receiverId), Sched_GetThreadVRuntime(id));
              Sched_ReleaseSchedLockSafe(irq);
              Ctx_SetRet(ctx, 1);
            end
            else
              Ctx_SetRet(ctx, 0);    { queue full: the caller retries }
          end;
        end;
      end;

    { 6: allocate heap pages }
    6: Ctx_SetRet(ctx, Disp_AllocateHeap(id, Ctx_GetArg(ctx, 1), isKing));

    { 7: grant an I/O port }
    7:
      begin
        Disp_GrantPortAccess(Word(Ctx_GetArg(ctx, 1)), id, isKing);
        Ctx_SetRet(ctx, 1);
      end;

    { 8: non-blocking receive into a user Message }
    8:
      begin
        if (Ctx_GetArg(ctx, 1) = 0) or (not UserPtrOk(Ctx_GetArg(ctx, 1))) then
          Ctx_SetRet(ctx, 0)
        else
        begin
          outMsg := PByte(Ctx_GetArg(ctx, 1));
          rType := 0; rSender := 0; rPayload := 0;
          if IpcK_ReceiveForRaw(Cardinal(id), rType, rSender, rPayload) then
          begin
            PCardinal(outMsg + 0)^ := rType;
            PCardinal(outMsg + 4)^ := rSender;
            PCardinal(outMsg + 8)^ := Cardinal(id);
            PQWord(outMsg + 16)^ := rPayload;
            Ctx_SetRet(ctx, 1);
          end
          else
            Ctx_SetRet(ctx, 0);
        end;
      end;

    { 10: process info }
    10:
      begin
        targetId := Cardinal(Ctx_GetArg(ctx, 1));
        outPtr := Ctx_GetArg(ctx, 2);
        if (not UserPtrOk(outPtr)) or (targetId >= Cardinal(Sched_GetThreadCount)) then
          Ctx_SetRet(ctx, 0)
        else
        begin
          irq := Sched_AcquireSchedLockSafe;
          FillProcessInfo(PByte(outPtr), targetId, isKing or (targetId = Cardinal(id)));
          Sched_ReleaseSchedLockSafe(irq);
          Ctx_SetRet(ctx, 1);
        end;
      end;

    { 11: ACPI RSDP }
    11: Ctx_SetRet(ctx, kstate_AcpiRsdp);

    { 12: map physical memory }
    12: Disp_MapPhysicalMemory(id, isKing, ctx);

    { 102: DMA buffer for a driver daemon; physical address in the second result }
    102: Disp_AllocDma(id, isKing, ctx);

    { 103: free pages of the caller's own memory }
    103: Disp_FreeMem(id, ctx);

    { 13: hardware report }
    13:
      begin
        hwType := Cardinal(Ctx_GetArg(ctx, 1));
        if not isKing then
        begin
          Sched_SetThreadPhantomDead(id, 1);
          Ctx_SetRet(ctx, 0);
        end
        else
          Ctx_SetRet(ctx, Disp_HardwareReport(hwType, Ctx_GetArg(ctx, 2), isKing));
      end;

    { 14: PID by name }
    14:
      begin
        if not UserPtrOk(Ctx_GetArg(ctx, 1)) then
          Ctx_SetRet(ctx, QWord(-1))
        else
        begin
          targetName := PWord(Ctx_GetArg(ctx, 1));
          foundId := -1;
          irq := Sched_AcquireSchedLockSafe;
          for i := 1 to Sched_GetThreadCount - 1 do
            if Sched_GetThreadActive(i) <> 0 then
              if StrEqWideBytes(targetName, Sched_GetThreadName(i)) <> 0 then
              begin
                foundId := i;
                Break;
              end;
          Sched_ReleaseSchedLockSafe(irq);
          Ctx_SetRet(ctx, QWord(foundId));
        end;
      end;

    { 50: map the framebuffer }
    50: Disp_MapFramebuffer(id, isKing, ctx);

    { 51: framebuffer geometry }
    51: Ctx_SetRet(ctx, Disp_FramebufferDims(PQWord(Ctx_GetArg(ctx, 1)),
          PQWord(Ctx_GetArg(ctx, 2)), PQWord(Ctx_GetArg(ctx, 3))));

    { 52: redirect terminal output }
    52:
      if not isKing then
      begin
        Sched_SetThreadPhantomDead(id, 1);
        Ctx_SetRet(ctx, 0);
      end
      else
        Ctx_SetRet(ctx, Disp_RedirectFramebuffer(Ctx_GetArg(ctx, 1), Cardinal(Ctx_GetArg(ctx, 2)),
          Cardinal(Ctx_GetArg(ctx, 3)), Cardinal(Ctx_GetArg(ctx, 4)), isKing));

    { 60 / 61: shared ATA hardware lock for ATA.EXE }
    60:
      begin
        Disp_AtaLockAcquire;
        Ctx_SetRet(ctx, 1);
      end;
    61:
      begin
        Disp_AtaLockRelease;
        Ctx_SetRet(ctx, 1);
      end;

    { 88: kernel builtin shell }
    88: InternalShell_Dispatch(id, currentTicks, isKing, ctx);

    { 89: my UID }
    89: Ctx_SetRet(ctx, Sched_GetThreadUID(id));

    { 90: UID of a thread }
    90:
      begin
        pidArg := Ctx_GetArg(ctx, 0);
        if Cardinal(pidArg) < Cardinal(Sched_GetThreadCount) then
          Ctx_SetRet(ctx, Sched_GetThreadUID(Integer(Cardinal(pidArg))))
        else
          Ctx_SetRet(ctx, 9999);
      end;

    { 91: set UID (traps untrusted callers) }
    91: Ctx_SetRet(ctx, Disp_SetUID(id, Cardinal(Ctx_GetArg(ctx, 0))));

    { 92: GID of a thread }
    92:
      begin
        pidArg := Ctx_GetArg(ctx, 0);
        if Cardinal(pidArg) < Cardinal(Sched_GetThreadCount) then
          Ctx_SetRet(ctx, Sched_GetThreadGID(Integer(Cardinal(pidArg))))
        else
          Ctx_SetRet(ctx, 9999);
      end;

    { 93: set GID }
    93: Ctx_SetRet(ctx, Disp_SetGID(id, Cardinal(Ctx_GetArg(ctx, 0))));

    { 94: sudo }
    94: Sudo_Handle(id, ctx);

    { 96: RTC seconds }
    96: Ctx_SetRet(ctx, Hal_WallClockSeconds);

    { 97: sleep }
    97:
      begin
        ticksToSleep := MsToTicks(Ctx_GetArg(ctx, 1));
        irq := Sched_AcquireSchedLockSafe;
        Sched_SetThreadWakeUpTick(id, currentTicks + ticksToSleep);
        Sched_SetThreadActive(id, 2);
        Sched_ReleaseSchedLockSafe(irq);
        Ctx_SetRet(ctx, 1);
        switchedRsp := Sched_SwitchTask(currentRsp);
        switched := True;
      end;

    { 98: yield }
    98:
      begin
        irq := Sched_AcquireSchedLockSafe;
        { Push VRuntime out so this thread is not picked straight back. }
        Sched_BumpThreadVRuntime(id, 1000);
        Sched_ReleaseSchedLockSafe(irq);
        Ctx_SetRet(ctx, 1);
        switchedRsp := Sched_SwitchTask(currentRsp);
        switched := True;
      end;

    { 99: global shared memory window }
    99: Ctx_SetRet(ctx, Disp_GlobalSharedMemory(id));

    { 100: wait for an IPC message (sleeps two ticks if none) }
    100:
      begin
        irq := Sched_AcquireSchedLockSafe;
        if IpcK_HasMessageFor(Cardinal(id)) then
        begin
          Sched_ReleaseSchedLockSafe(irq);
          Ctx_SetRet(ctx, 1);
        end
        else
        begin
          Sched_SetThreadActive(id, 2);
          Sched_SetThreadWakeUpTick(id, currentTicks + 2);
          Sched_ReleaseSchedLockSafe(irq);
          Ctx_SetRet(ctx, 1);
          switchedRsp := Sched_SwitchTask(currentRsp);
          switched := True;
        end;
      end;

    { 101: shared-memory pipeline to another process; the second result,
      the address in the target's space, comes back in RBX. }
    101:
      begin
        targetPid := Cardinal(Ctx_GetArg(ctx, 1));
        numPages := Ctx_GetArg(ctx, 2);
        targetVAddr := 0;
        myVAddr := Disp_SharedMemoryPipeline(id, Integer(targetPid), numPages, @targetVAddr);
        if myVAddr = 0 then
        begin
          Ctx_SetRet(ctx, 0);
          Ctx_SetRet2(ctx, 0);
        end
        else
        begin
          Ctx_SetRet(ctx, myVAddr);
          Ctx_SetRet2(ctx, targetVAddr);
        end;
      end;

    { 399: reset the text cursor }
    399:
      begin
        Disp_ResetCursor;
        Ctx_SetRet(ctx, 1);
      end;
  else
    begin
      Con_SetColor($00FF0000);
      Con_Print(W('[!] Invalid call! Error Code: '));
      Con_PrintDec(syscallId);
      Con_Print(W(#13#10));
    end;
  end;

  if switched then SyscallHandler := switchedRsp
  else SyscallHandler := currentRsp;
end;

end.
