{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: SchedulerDispatch - VRuntime thread selection (Pascal Implementation)
  PURPOSE: Pure scheduling logic — finds the runnable thread with the
           lowest VRuntime for the given core. Also wakes sleeping threads
           whose WakeUpTick has expired.

           Ported from Thread.cs SwitchTask() scheduling decision block
           (the VRuntime scan + sleep wakeup logic). Kernel infrastructure
           (locks, FPU save/restore, page table load, TSS update) stays
           in the C# shim.

           Thread struct offsets defined in fpc_runtime.pas (THREAD_*).
  =========================================================================
}

unit scheduler_dispatch;

{$mode objfpc}
{$h+}
{$inline on}

interface

uses fpc_runtime;

{ [SCHED] Scans thread table for runnable threads and selects the one
  with minimum VRuntime on the given core. Also wakes sleeping threads
  whose WakeUpTick <= currentTicks.

  Inputs:
    threads       — base pointer of Thread array (Pack=1 struct)
    threadCount   — number of entries in the thread array
    coreId        — current CPU core ID
    currentTicks  — Scheduler.SystemTicks value
    idleId        — idle thread ID for this core (fallback)
  Outputs:
    outBestId     — selected thread ID to run
    outWokeAny    — 1 if any sleeping thread was woken, 0 otherwise

  Returns: 1 = success }

function SelectNextThread_Pas(threads: Pointer; threadCount: Int32;
  coreId: UInt32; currentTicks: UInt64; idleId: Int32;
  out outBestId: Int32; out outWokeAny: Byte): Byte; cdecl; public name 'SelectNextThread_Pas';

implementation

function SelectNextThread_Pas(threads: Pointer; threadCount: Int32;
  coreId: UInt32; currentTicks: UInt64; idleId: Int32;
  out outBestId: Int32; out outWokeAny: Byte): Byte; cdecl;
var
  threadBase: UInt64;
  i: Int32;
  active: Byte;
  execCore: Int32;
  priority: Byte;
  vRuntime: UInt64;
  wakeTick: UInt64;
  minVRuntime: UInt64;
  bestId: Int32;
  wokeAny: Byte;
  sysMinVRuntime: UInt64;
begin
  outBestId := idleId;
  outWokeAny := 0;
  SelectNextThread_Pas := 0;

  if threads = nil then
    Exit;

  threadBase := UInt64(threads);
  minVRuntime := High(UInt64);
  bestId := -1;
  wokeAny := 0;
  sysMinVRuntime := High(UInt64);

  { Phase 1: Wake up sleeping threads whose WakeUpTick expired }
  for i := 0 to threadCount - 1 do
  begin
    active := PByte(threadBase + UInt64(i) * THREAD_SIZE + THREAD_ACTIVE_OFFSET)^;
    if active = 2 then
    begin
      wakeTick := PUInt64(threadBase + UInt64(i) * THREAD_SIZE + THREAD_WAKEUP_TICK_OFFSET)^;
      if currentTicks >= wakeTick then
      begin
        { Change Active from Sleep(2) to Runnable(1) }
        PByte(threadBase + UInt64(i) * THREAD_SIZE + THREAD_ACTIVE_OFFSET)^ := 1;
        wokeAny := 1;
      end;
    end;
  end;

  { Phase 2: Find minimum VRuntime among runnable, non-idle threads }
  for i := 0 to threadCount - 1 do
  begin
    active := PByte(threadBase + UInt64(i) * THREAD_SIZE + THREAD_ACTIVE_OFFSET)^;
    execCore := PInt32(threadBase + UInt64(i) * THREAD_SIZE + THREAD_EXEC_CORE_OFFSET)^;
    priority := PByte(threadBase + UInt64(i) * THREAD_SIZE + THREAD_PRIORITY_OFFSET)^;

    { Runnable (Active==1), not on another core, not idle (Priority!=99) }
    if (active = 1) and (execCore = -1) and (priority <> 99) then
    begin
      vRuntime := PUInt64(threadBase + UInt64(i) * THREAD_SIZE + THREAD_VRUNTIME_OFFSET)^;
      if vRuntime < sysMinVRuntime then
        sysMinVRuntime := vRuntime;
    end;
  end;

  { Phase 3: Select the runnable thread with the lowest VRuntime }
  for i := 0 to threadCount - 1 do
  begin
    active := PByte(threadBase + UInt64(i) * THREAD_SIZE + THREAD_ACTIVE_OFFSET)^;
    execCore := PInt32(threadBase + UInt64(i) * THREAD_SIZE + THREAD_EXEC_CORE_OFFSET)^;
    priority := PByte(threadBase + UInt64(i) * THREAD_SIZE + THREAD_PRIORITY_OFFSET)^;

    if (active = 1) and (execCore = -1) and (priority <> 99) then
    begin
      vRuntime := PUInt64(threadBase + UInt64(i) * THREAD_SIZE + THREAD_VRUNTIME_OFFSET)^;
      if vRuntime < minVRuntime then
      begin
        minVRuntime := vRuntime;
        bestId := i;
      end;
    end;
  end;

  { Fallback to idle thread if no runnable thread found }
  if bestId = -1 then
    bestId := idleId;

  outBestId := bestId;
  outWokeAny := wokeAny;
  SelectNextThread_Pas := 1;
end;

end.
