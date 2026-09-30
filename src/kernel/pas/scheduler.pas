{
  =========================================================================
  NekkoOS — scheduler.pas

  Owns the scheduler state that used to live in the C# `static class Scheduler`
  (src/kernel/Thread.cs), and calls its services directly instead of through
  the raw function-pointer table that Sched_SetCallbacks_Pas used to install.
  That indirection existed only because the callees were C#; they are now
  Pascal units, so the dependency graph decides the binding:

    pmm, vmm, ipc, terminal, prng, gdt, apic, kstate, kstring, libc,
    scheduler_dispatch  ->  imported with `uses` (no unit imports this one)

  Two resources are still owned by C# and cannot be imported, so their handles
  are published into this unit instead of being called through a callback:

    * the IPC queue (IPC.queue / IPC.MAX_MESSAGES live in IPC.cs)
      -> Sched_SetIpcQueue, consumed by IPC_ClearMailbox via `uses ipc`
    * the idle-loop entry point (Program.KernelIdleLoop, a C# method with a
      managed body that also drives StrandScheduler and the daemons)
      -> Sched_SetIdleLoop, defaulting to Sched_IdleLoopProc

  CRITICAL: every type is declared in the implementation section. A record
  reachable from the interface makes FPC emit RTTI, which lld cannot resolve
  (AGENTS.md §2.4 / §6.3), so the interface speaks in Pointer. Verify with
  `objdump -t build/scheduler.o | grep -i rtti` — the count must be 0.
  =========================================================================
}
unit scheduler;

{$mode objfpc}
{$h+}
{$inline on}
{$TYPEINFO OFF}
{$PACKRECORDS 1}

interface

uses arch_interface;

const
  { Thread table and per-core arrays both hold 256 entries; the APIC window
    walker assumes the same bound. }
  SCHED_MAX_CORES   = 256;
  SCHED_MAX_THREADS = 256;

  { Priority 99 marks an idle task: pinned to its core and skipped by the
    VRuntime scan in scheduler_dispatch. }
  SCHED_IDLE_PRIORITY = 99;

  { 64 pages for the thread table (256 x 656 B needs 41), 4 for a stack.
    Stacks are counted in QWord slots: 2048 = 16 KiB. }
  SCHED_THREADS_PAGES = 64;
  SCHED_STACK_PAGES   = 4;
  SCHED_STACK_SLOTS   = 2048;

{ ── Scheduler state ────────────────────────────────────────────────────── }

{ Base of the thread table. Pointer, not TThread — the layout is private. }
function Sched_GetThreads: Pointer;
function Sched_GetThreadCount: Integer;
function Sched_IsReady: Boolean;
procedure Sched_SetReady(v: Boolean);
function Sched_GetForegroundTask: Integer;
procedure Sched_SetForegroundTask(v: Integer);
function Sched_GetCurrentThreadIds: PInteger;
function Sched_GetIdleThreadIds: PInteger;
function Sched_GetDyingThreadPerCore: PInteger;

{ System tick counter. The timer ISR is the only writer; it must use
  Sched_BumpSystemTicks so the increment stays atomic. }
function Sched_GetSystemTicks: QWord;
procedure Sched_SetSystemTicks(ticks: QWord);
function Sched_BumpSystemTicks(delta: QWord): QWord;

{ Id of the thread running on the calling core, 0 when it cannot be
  determined. Deliberately fail-safe: every caller indexes the thread table
  with the result. }
function Sched_GetCurrentThreadId: Integer;

{ ── Handles for state the C# side still owns ───────────────────────────── }

{ IPC.queue / IPC.MAX_MESSAGES. Until this is published, mailbox clearing
  falls back to the callback Sched_SetCallbacks_Pas may have installed. }
procedure Sched_SetIpcQueue(queue: Pointer; maxMessages: Integer);

{ Address of the routine entered when an idle task is first scheduled.
  Defaults to Sched_IdleLoopProc; Program.KernelIdleLoop is preferred once
  Sched_SetIdleLoop hands its address over. }
procedure Sched_SetIdleLoop(idleLoop: Pointer);
function Sched_GetIdleLoop: Pointer;

{ ── Thread.cs public API ───────────────────────────────────────────────── }

procedure Sched_Init;
procedure Sched_CreateIdleTaskForCore(coreId: Cardinal);

{ The yield ISR entry. Hardware.asm has `extern YieldHandler`, which C#
  Thread.cs still defines; exporting the same symbol from here as well would
  be a duplicate definition. Flip SCHED_OWN_YIELD_HANDLER at the commit that
  deletes Thread.cs to take the entry over. }
{$IFDEF SCHED_OWN_YIELD_HANDLER}
function Sched_YieldHandler(currentRsp: QWord): QWord; cdecl; public name 'YieldHandler';
{$ELSE}
function Sched_YieldHandler(currentRsp: QWord): QWord; cdecl; public name 'Sched_YieldHandler_Pas';
{$ENDIF}

function  Sched_SwitchTask(currentRsp: QWord): QWord;
function  Sched_GetFreeThreadSlot: Integer;
procedure Sched_CreateTask(entryPoint: QWord);

{ Returns the new thread id, or -1 when nothing was created. Callers that
  only need the side effect may ignore it (Thread.cs has both overloads). }
function  Sched_CreateUserTask(entryPoint, appPml4: QWord;
  isForeground, isJailed, forceRoot: Boolean; processName: PWord;
  imagePages: Cardinal; priority: Byte): Integer;

procedure Sched_TerminateTask(id: Integer);
procedure Sched_TerminateCurrentTask;

function  Sched_GetCS: Word;
function  Sched_GetSS: Word;
procedure Sched_Yield;
procedure Sched_SaveFPU(buffer: Pointer);
procedure Sched_RestoreFPU(buffer: Pointer);
function  Sched_GetRflags: QWord;
procedure Sched_LockScheduler;
procedure Sched_UnlockScheduler;

{ True when interrupts were enabled on entry, so the caller can restore them.
  Both wrap GlobalSchedLock from Hardware.asm — the same lock the C# side
  reached through Arch.LockScheduler. }
function  Sched_AcquireSchedLockSafe: Boolean;
procedure Sched_ReleaseSchedLockSafe(irqWasEnabled: Boolean);

{ ── Per-thread field accessors ────────────────────────────────────────────
  TThread stays private, so every other module reaches a field through these.
  All of them bounds-check the index and answer 0 / no-op when it is bad. }

function Sched_GetThreadActive(index: Integer): Byte;
procedure Sched_SetThreadActive(index: Integer; v: Byte);
function Sched_GetThreadJailed(index: Integer): Byte;
procedure Sched_SetThreadJailed(index: Integer; v: Byte);
function Sched_GetThreadPhantomDead(index: Integer): Byte;
procedure Sched_SetThreadPhantomDead(index: Integer; v: Byte);
function Sched_GetThreadUID(index: Integer): Cardinal;
procedure Sched_SetThreadUID(index: Integer; v: Cardinal);
function Sched_GetThreadGID(index: Integer): Cardinal;
procedure Sched_SetThreadGID(index: Integer; v: Cardinal);
function Sched_GetThreadParentId(index: Integer): Integer;
procedure Sched_SetThreadParentId(index: Integer; v: Integer);
function Sched_GetThreadCore(index: Integer): Integer;
procedure Sched_SetThreadCore(index: Integer; v: Integer);
function Sched_GetThreadRsp(index: Integer): QWord;
procedure Sched_SetThreadRsp(index: Integer; v: QWord);
function Sched_GetThreadKernelStackTop(index: Integer): QWord;
procedure Sched_SetThreadKernelStackTop(index: Integer; v: QWord);
function Sched_GetThreadHeapBase(index: Integer): QWord;
procedure Sched_SetThreadHeapBase(index: Integer; v: QWord);
function Sched_GetThreadName(index: Integer): PByte;
function Sched_GetThreadCpuTicks(index: Integer): QWord;
function Sched_GetThreadPhysPages(index: Integer): Cardinal;
procedure Sched_SetThreadPhysPages(index: Integer; v: Cardinal);
function Sched_GetThreadVirtPages(index: Integer): Cardinal;
procedure Sched_SetThreadVirtPages(index: Integer; v: Cardinal);
function Sched_GetThreadWakeUpTick(index: Integer): QWord;
procedure Sched_SetThreadWakeUpTick(index: Integer; v: QWord);
function Sched_GetThreadVRuntime(index: Integer): QWord;
procedure Sched_SetThreadVRuntime(index: Integer; v: QWord);
function Sched_BumpThreadVRuntime(index: Integer; delta: QWord): QWord;
function Sched_GetThreadPriority(index: Integer): Byte;
procedure Sched_SetThreadPriority(index: Integer; v: Byte);
function Sched_GetThreadTextColor(index: Integer): Cardinal;
procedure Sched_SetThreadTextColor(index: Integer; v: Cardinal);
function Sched_GetThreadFpuState(index: Integer): Pointer;

{ ── Legacy cdecl shims ────────────────────────────────────────────────────
  Thread.cs calls these; they are kept until it is deleted. Each one adapts
  the caller's explicit state into a TSchedState, runs the same core the
  state-owning API uses, and copies the mutated fields back. }

procedure Sched_SetCallbacks_Pas(
  pmmAllocContigFn, pmmAllocPageFn, pmmFreePageFn,
  getKernelRootFn, isCanonicalFn, destroyUserFn,
  mapPageFn, ipcClearBoxFn,
  termPrintFn, termSetColorFn, prngNextFn,
  getGdtTssRsp0Fn, getCoreTssRsp0Fn,
  apicReadFn, apicIsAwakeFn,
  getCurrentIdsFn, getIdleIdsFn, getDyingIdsFn,
  selectNextFn, getIdleLoopPtrFn,
  getCSFn, getSSFn, saveFpuFn, restoreFpuFn: Pointer
); cdecl;

procedure Sched_Init_Pas(
  out threadsOut: Pointer;
  out threadCountOut: Integer;
  out readyOut: Byte
); cdecl;

function Sched_GetFreeSlot_Pas(threads: Pointer; threadCount: Integer): Integer; cdecl;

{ Read a live thread's address-space root (physical PML4), or 0 when the
  index is out of range or the thread is inactive. The APIC uses this to map
  its MMIO window into every live address space. TThread's layout stays
  private to this unit, which is why the field is reached through an
  accessor instead of a shared struct. }
function Sched_GetThreadAddrSpace_Pas(index: Integer): QWord; cdecl;

procedure Sched_CreateIdleTask_Pas(
  coreId: Cardinal;
  threads: Pointer; var threadCount: Integer;
  currentThreadIds: PInteger; idleThreadIds: PInteger
); cdecl;

function Sched_SwitchTask_Pas(
  currentRsp: QWord;
  threads: Pointer;
  var threadCount: Integer;
  ready: Byte;
  systemTicks: QWord;
  var foregroundTask: Integer;
  currentThreadIds: PInteger;
  idleThreadIds: PInteger;
  dyingThreadIds: PInteger
): QWord; cdecl;

function Sched_CreateUserTask_Pas(
  entryPoint: QWord;
  appPml4: QWord;
  isForeground: Byte;
  isJailed: Byte;
  forceRoot: Byte;
  processName: PWord;
  imagePages: Cardinal;
  priority: Byte;
  threads: Pointer;
  var threadCount: Integer;
  currentThreadIds: PInteger;
  var foregroundTask: Integer
): Integer; cdecl;

procedure Sched_CreateTask_Pas(
  entryPoint: QWord;
  threads: Pointer;
  var threadCount: Integer
); cdecl;

procedure Sched_TerminateTask_Pas(
  id: Integer;
  threads: Pointer;
  threadCount: Integer;
  currentThreadIds: PInteger;
  var foregroundTask: Integer
); cdecl;

implementation

uses
  libc, kstring, prng, kstate, pmm, vmm, ipc, terminal, gdt, apic,
  scheduler_dispatch;

{ ── TThread — implementation only, no RTTI ──────────────────────────────── }
type
  TThread = packed record
    Rsp:            QWord;
    Active:         Byte;    { 0 dead, 1 runnable, 2 sleeping,
                               3 being created, 4 zombie }
    IsJailed:       Byte;
    IsPhantomDead:  Byte;
    Padding1:       Byte;
    ParentId:       Integer;
    ExecutingOnCore:Integer;
    PaddingNew:     Cardinal;
    PaddingAlign:   QWord;
    AppHeapBase:    QWord;
    KernelStackTop: QWord;
    AddrSpace:      QWord;   { [ARCH] address-space root (x86_64: PML4 phys) }
    UID:            Cardinal;
    GID:            Cardinal;
    SharedMemPhys:  QWord;
    SharedMemVirt:  QWord;
    Name:           array[0..15] of Byte;
    CpuTicks:       QWord;
    PhysPages:      Cardinal;
    VirtPages:      Cardinal;
    WakeUpTick:     QWord;
    VRuntime:       QWord;
    Priority:       Byte;
    TextColor:      Cardinal;
    Padding3:       array[0..10] of Byte;
    FpuState:       array[0..511] of Byte;
  end;
  PThread = ^TThread;

  { Legacy callback shapes, kept only for the two services C# still owns.
    FPC emits no RTTI for procedural types under TYPEINFO OFF. }
  TFnGetPtr      = function: Pointer; cdecl;
  TFnClearMailbox = procedure(tid: Cardinal); cdecl;

  { Everything Sched_* owns. Grouped in a record so the legacy cdecl shims can
    run the same code over caller-supplied state without touching the real one. }
  TSchedState = record
    Threads:         PThread;
    ThreadCount:     Integer;
    Ready:           Boolean;
    ForegroundTask:  Integer;
    CurrentIds:      PInteger;
    IdleIds:         PInteger;
    DyingIds:        PInteger;
    SystemTicks:     QWord;
  end;

{ ── Module state ────────────────────────────────────────────────────────── }

var
  St: TSchedState = (
    Threads: nil; ThreadCount: 0; Ready: False; ForegroundTask: -1;
    CurrentIds: nil; IdleIds: nil; DyingIds: nil; SystemTicks: 0);

  { Handles published by the C# side. See Sched_SetIpcQueue / Sched_SetIdleLoop. }
  IpcQueue:      Pointer = nil;
  IpcMaxMessages: Integer = 0;
  IdleLoopFn:    Pointer = nil;

  { Legacy fallbacks, installed by Sched_SetCallbacks_Pas. Consulted only when
    the corresponding handle above has not been published, so a C# caller that
    still registers its callbacks keeps working. }
  cb_IpcClearBox:  Pointer = nil;
  cb_GetIdleLoop:  Pointer = nil;

{ ── Diagnostics ─────────────────────────────────────────────────────────── }

procedure TermFatal(const msg: AnsiString); inline;
begin
  Terminal_SetColor_Pas($00FF0000);
  Terminal_Print_Pas(W(msg));
end;

procedure TermWarn(const msg: AnsiString); inline;
begin
  Terminal_SetColor_Pas($00FF00);
  Terminal_Print_Pas(W(msg));
end;

{ ── Small helpers ───────────────────────────────────────────────────────── }

{ Physical PML4 of the kernel address space. VMM.PML4 in the C# original. }
function KernelRoot: QWord; inline;
begin
  KernelRoot := QWord(Vmm_GetPml4);
end;

{ Physical-memory bound in bytes, used to reject bogus CR3 / stack values. }
function PhysLimit: QWord; inline;
begin
  PhysLimit := PMM_GetTotalPages * 4096;
end;

{ Raw APIC core id. Thread.cs applies its own range check where it matters. }
function ReadCoreId: Cardinal; inline;
begin
  if Apic_IsAwake then Result := Apic_Read($020) shr 24
  else Result := 0;
end;

{ Mirror the table into kstate so Sched_GetThreadAddrSpace_Pas and the APIC
  window walker (apic.pas) keep seeing a live thread table. }
procedure PublishState; inline;
begin
  kstate_Threads     := Pointer(St.Threads);
  kstate_ThreadCount := St.ThreadCount;
end;

{ Resolve a thread index to a record, or nil when it is out of range. }
function ThreadAt(index: Integer; out t: PThread): Boolean; inline;
begin
  Result := (St.Threads <> nil) and (index >= 0) and (index < St.ThreadCount);
  if Result then t := @St.Threads[index] else t := nil;
end;

{ ── Scheduler lock / yield primitives (Thread.cs statics) ───────────────── }

function Sched_GetCS: Word;
begin
  Sched_GetCS := Arch_GetCS;
end;

function Sched_GetSS: Word;
begin
  Sched_GetSS := Arch_GetSS;
end;

procedure Sched_Yield;
begin
  Arch_ForceYield;
end;

procedure Sched_SaveFPU(buffer: Pointer);
begin
  Arch_SaveFPU(buffer);
end;

procedure Sched_RestoreFPU(buffer: Pointer);
begin
  Arch_RestoreFPU(buffer);
end;

function Sched_GetRflags: QWord;
begin
  Sched_GetRflags := Arch_GetFlags;
end;

procedure Sched_LockScheduler;
begin
  Arch_LockScheduler;
end;

procedure Sched_UnlockScheduler;
begin
  Arch_UnlockScheduler;
end;

function Sched_AcquireSchedLockSafe: Boolean;
begin
  Result := (Arch_GetFlags and $200) <> 0;
  Arch_DisableInterrupts;
  Arch_LockScheduler;
end;

procedure Sched_ReleaseSchedLockSafe(irqWasEnabled: Boolean);
begin
  Arch_UnlockScheduler;
  if irqWasEnabled then Arch_EnableInterrupts;
end;

{ ── Default idle task body ────────────────────────────────────────────────
  Used only when nobody has published an idle-loop address. It is the
  KernelIdleLoop skeleton minus the parts that cannot exist here: the strand
  cycle and the ATA/FAT16 daemon handshake are still C#. An idle task runs
  only when nothing else is runnable, so halting until the next interrupt is
  enough to keep the timer ISR driving the scheduler. }
procedure Sched_IdleLoopProc; cdecl;
begin
  while True do
  begin
    Arch_EnableInterrupts;
    Arch_Halt;
    Arch_ForceYield;
  end;
end;

procedure Sched_SetIdleLoop(idleLoop: Pointer);
begin
  IdleLoopFn := idleLoop;
end;

function Sched_GetIdleLoop: Pointer;
begin
  if IdleLoopFn <> nil then
    Sched_GetIdleLoop := IdleLoopFn
  else if cb_GetIdleLoop <> nil then
    Sched_GetIdleLoop := TFnGetPtr(cb_GetIdleLoop)()
  else
    Sched_GetIdleLoop := Pointer(@Sched_IdleLoopProc);
end;

{ ── IPC mailbox clearing ────────────────────────────────────────────────── }

procedure Sched_SetIpcQueue(queue: Pointer; maxMessages: Integer);
begin
  IpcQueue      := queue;
  IpcMaxMessages := maxMessages;
end;

{ Mirrors IPC.ClearMailbox: with a published queue this is a direct call into
  ipc.pas; the legacy callback is the fallback for a caller that has not
  published one yet. }
procedure ClearMailbox(threadId: Cardinal);
begin
  if (IpcQueue <> nil) and (IpcMaxMessages > 0) then
    IPC_ClearMailbox(IpcQueue, IpcMaxMessages, threadId)
  else if cb_IpcClearBox <> nil then
    TFnClearMailbox(cb_IpcClearBox)(threadId)
  else
    TermFatal('[!] FATAL: IPC queue not initialized!'#13#10);
end;

{ ── Slot allocation ─────────────────────────────────────────────────────── }

{ Pure scan: the first inactive index, or threadCount when the table can still
  grow, or -1 when it is full. Does not mutate anything. }
function FindFreeSlot(t: PThread; threadCount: Integer): Integer;
var
  i: Integer;
begin
  if (t = nil) or (threadCount < 1) or (threadCount > SCHED_MAX_THREADS) then
  begin
    TermFatal('[!] FATAL: Invalid thread count in GetFreeThreadSlot!'#13#10);
    Result := -1;
    Exit;
  end;
  for i := 1 to threadCount - 1 do
    if t[i].Active = 0 then
    begin
      Result := i;
      Exit;
    end;
  if threadCount < SCHED_MAX_THREADS then Result := threadCount
  else Result := -1;
end;

function Sched_GetFreeThreadSlot: Integer;
begin
  Result := FindFreeSlot(St.Threads, St.ThreadCount);
  { Growing the table is part of the allocation, so publish straight away:
    the APIC walks kstate_ThreadCount without taking our lock. }
  if (Result >= 0) and (Result = St.ThreadCount) then
  begin
    Inc(St.ThreadCount);
    PublishState;
  end;
end;

{ ── Init ────────────────────────────────────────────────────────────────── }

procedure Sched_Init;
var
  i: Integer;
begin
  St.Threads := PThread(Pmm_AllocateContiguousPages(SCHED_THREADS_PAGES));
  if St.Threads = nil then
  begin
    TermFatal('[!] FATAL: Failed to allocate Threads memory!'#13#10);
    Exit;
  end;
  MemSet(St.Threads, 0, SCHED_THREADS_PAGES * 4096);

  St.CurrentIds := PInteger(Pmm_AllocatePage);
  if St.CurrentIds = nil then
  begin
    TermFatal('[!] FATAL: Failed to allocate CurrentThreadIds memory!'#13#10);
    Exit;
  end;
  St.IdleIds := PInteger(Pmm_AllocatePage);
  if St.IdleIds = nil then
  begin
    TermFatal('[!] FATAL: Failed to allocate IdleThreadIds memory!'#13#10);
    Pmm_FreePage(St.CurrentIds);
    Exit;
  end;
  St.DyingIds := PInteger(Pmm_AllocatePage);
  if St.DyingIds = nil then
  begin
    TermFatal('[!] FATAL: Failed to allocate DyingThreadPerCore memory!'#13#10);
    Pmm_FreePage(St.CurrentIds);
    Pmm_FreePage(St.IdleIds);
    Exit;
  end;

  { No thread may be mistaken for thread 0 just because the page read as zero. }
  for i := 0 to SCHED_MAX_CORES - 1 do
  begin
    St.CurrentIds[i] := -1;
    St.IdleIds[i]    := -1;
    St.DyingIds[i]   := -1;
  end;
  St.CurrentIds[0] := 0;
  St.IdleIds[0]    := 0;

  St.Threads[0].Active          := 1;
  St.Threads[0].KernelStackTop  := Gdt_GetTssRsp0;
  St.Threads[0].AddrSpace       := KernelRoot;
  St.Threads[0].UID             := 0;
  St.Threads[0].GID             := 0;
  St.Threads[0].TextColor       := $00FFFFFF;
  St.Threads[0].ParentId        := 0;
  St.Threads[0].ExecutingOnCore := 0;

  { [SCHEDULER RACE FIX] Thread 0 is the fallback task for core 0, so it must
    be flagged exactly like every other idle task. Leaving it at a normal
    priority lets another core's steal pass pick it, and two cores sharing one
    kernel stack destroys the whole context. }
  St.Threads[0].Priority := SCHED_IDLE_PRIORITY;

  St.Threads[0].Name[0] := Ord('K'); St.Threads[0].Name[1] := Ord('E');
  St.Threads[0].Name[2] := Ord('R'); St.Threads[0].Name[3] := Ord('N');
  St.Threads[0].Name[4] := Ord('E'); St.Threads[0].Name[5] := Ord('L');
  St.Threads[0].Name[6] := 0;

  Arch_SaveFPU(@St.Threads[0].FpuState[0]);

  St.ThreadCount := 1;
  St.Ready       := True;
  PublishState;

  Terminal_SetColor_Pas($0000FF00);
  Terminal_Print_Pas(W('[+] Multiverse Scheduler Initialized! Threads Isolated.'#13#10));
end;

{ ── Idle tasks ──────────────────────────────────────────────────────────── }

{ Shared by the state-owning entry point and the legacy shim. }
procedure CreateIdleTaskForCore(var s: TSchedState; coreId: Cardinal); forward;

procedure CreateIdleTaskForCore(var s: TSchedState; coreId: Cardinal);
var
  irq:        Boolean;
  id:         Integer;
  kStackBase: PQWord;
  kStackTop:  PQWord;
  rspValue:   QWord;
  idleAddr:   QWord;
  cs, ss:     Word;
  j:          Integer;
begin
  if coreId >= SCHED_MAX_CORES then
  begin
    TermFatal('[!] FATAL: Invalid core ID in CreateIdleTaskForCore!'#13#10);
    Exit;
  end;

  irq := Sched_AcquireSchedLockSafe;
  id := FindFreeSlot(s.Threads, s.ThreadCount);
  if (id >= 0) and (id = s.ThreadCount) then Inc(s.ThreadCount);
  if (id < 0) or (id >= s.ThreadCount) then
  begin
    TermFatal('[!] FATAL: Invalid thread ID in CreateIdleTaskForCore!'#13#10);
    Sched_ReleaseSchedLockSafe(irq);
    Exit;
  end;

  s.Threads[id].Active          := 1;
  s.Threads[id].Priority        := SCHED_IDLE_PRIORITY;
  s.Threads[id].ExecutingOnCore := Integer(coreId);
  s.Threads[id].Name[0] := Ord('I'); s.Threads[id].Name[1] := Ord('D');
  s.Threads[id].Name[2] := Ord('L'); s.Threads[id].Name[3] := Ord('E');

  kStackBase := PQWord(Pmm_AllocateContiguousPages(SCHED_STACK_PAGES));
  if kStackBase = nil then
  begin
    TermFatal('[!] FATAL: Failed to allocate kernel stack for idle task!'#13#10);
    Sched_ReleaseSchedLockSafe(irq);
    Exit;
  end;
  kStackTop := kStackBase + SCHED_STACK_SLOTS;
  s.Threads[id].KernelStackTop := QWord(kStackTop);

  { Defensive: the stack top has to be a plausible kernel address. }
  if (QWord(kStackTop) < $10000) or (QWord(kStackTop) >= PhysLimit) then
  begin
    TermFatal('[!] FATAL: Allocated kernel stack invalid in CreateIdleTaskForCore!'#13#10);
    { Preserved from Thread.cs, which frees only the first of the four pages. }
    Pmm_FreePage(kStackBase);
    Sched_ReleaseSchedLockSafe(irq);
    Exit;
  end;

  { [ALIGNMENT] The idle loop is entered by IRETQ, not by CALL, so RSP must
    be pushed 8 bytes off a 16-byte boundary to land on the 8 (mod 16) the
    compiled prologue assumes. A movaps as its first SSE op faults otherwise. }
  Dec(kStackTop); kStackTop^ := 0;
  rspValue := QWord(kStackTop);

  cs := Arch_GetCS;
  ss := Arch_GetSS;
  idleAddr := QWord(Sched_GetIdleLoop);

  Dec(kStackTop); kStackTop^ := ss;
  Dec(kStackTop); kStackTop^ := rspValue;
  Dec(kStackTop); kStackTop^ := $202;
  Dec(kStackTop); kStackTop^ := cs;
  if (idleAddr < 4096) or (not Vmm_IsCanonical(idleAddr)) then
  begin
    TermWarn('[WARN] KernelIdleLoop pointer invalid, using fallback'#13#10);
    Dec(kStackTop); kStackTop^ := QWord(Pointer(@Sched_IdleLoopProc));
  end
  else
  begin
    Dec(kStackTop); kStackTop^ := idleAddr;
  end;

  for j := 1 to 15 do
  begin
    Dec(kStackTop); kStackTop^ := 0;
  end;

  s.Threads[id].Rsp       := QWord(kStackTop);
  s.Threads[id].AddrSpace := KernelRoot;

  s.IdleIds[coreId] := id;
  Sched_ReleaseSchedLockSafe(irq);
end;

procedure Sched_CreateIdleTaskForCore(coreId: Cardinal);
begin
  CreateIdleTaskForCore(St, coreId);
  PublishState;
end;

{ ── Context switch ──────────────────────────────────────────────────────── }

function SwitchTask(var s: TSchedState; currentRsp: QWord): QWord;
var
  coreId:       Cardinal;
  current:      Integer;
  zombieId:     Integer;
  bestId:       Integer;
  i:            Integer;
  wokeAny:      Byte;
  zombiePml4:   QWord;
  weight:       QWord;
  nextRsp:      QWord;
  nextKStack:   QWord;
  nextPml4:     QWord;
  tss:          Pointer;
  selected:     Byte;
begin
  if not s.Ready then
  begin
    Result := currentRsp;
    Exit;
  end;
  { Ready implies Sched_Init completed, which is what allocates the per-core
    arrays. The legacy shim can be handed a state that never saw Init. }
  if (s.CurrentIds = nil) or (s.IdleIds = nil) or (s.DyingIds = nil) then
  begin
    Result := currentRsp;
    Exit;
  end;

  coreId := ReadCoreId;
  if coreId >= SCHED_MAX_CORES then
  begin
    TermFatal('[!] FATAL: Invalid core ID in SwitchTask!'#13#10);
    Result := currentRsp;
    Exit;
  end;

  { Reap the zombie this core parked, then sweep any others so simultaneous
    kills cannot leak an address space. Tearing an address space down walks and
    frees hundreds of pages, so the lock is dropped around it — the caller
    re-takes it before touching the table again. }
  if s.DyingIds[coreId] <> -1 then
  begin
    zombieId   := s.DyingIds[coreId];
    zombiePml4 := s.Threads[zombieId].AddrSpace;
    s.Threads[zombieId].Active := 0;
    s.DyingIds[coreId] := -1;
    if (zombiePml4 <> 0) and (zombiePml4 <> KernelRoot) then
    begin
      Arch_UnlockScheduler;
      Vmm_DestroyUserSpace(zombiePml4);
      Arch_LockScheduler;
    end;
  end;

  for i := 0 to s.ThreadCount - 1 do
  begin
    if s.Threads[i].Active = 4 then
    begin
      zombiePml4 := s.Threads[i].AddrSpace;
      s.Threads[i].Active := 0;
      if (zombiePml4 <> 0) and (zombiePml4 <> KernelRoot) then
      begin
        Arch_UnlockScheduler;
        Vmm_DestroyUserSpace(zombiePml4);
        Arch_LockScheduler;
      end;
    end;
  end;

  { An AP core starts with -1, so there may be no previous context to save.
    The index also has to be range-checked: this array is filled in by earlier
    switches, and a stale entry would otherwise be a wild access. }
  current := s.CurrentIds[coreId];
  if (current < 0) or (current >= s.ThreadCount) then current := -1;
  if (current <> -1) and (s.Threads[current].Active <> 0) then
  begin
    if s.Threads[current].Active = 4 then
    begin
      s.DyingIds[coreId] := current;
    end
    else
    begin
      Arch_SaveFPU(@s.Threads[current].FpuState[0]);
      if s.Threads[current].Active = 1 then
      begin
        Inc(s.Threads[current].CpuTicks);
        { Priority 99 marks an idle task; it gets no VRuntime credit. }
        if s.Threads[current].Priority <> SCHED_IDLE_PRIORITY then
        begin
          weight := QWord(s.Threads[current].Priority);
          if weight = 0 then weight := 1;
          Inc(s.Threads[current].VRuntime, weight);
        end;
      end;
      s.Threads[current].Rsp := currentRsp;
    end;
  end;
  if current <> -1 then s.Threads[current].ExecutingOnCore := -1;

  bestId   := -1;
  wokeAny  := 0;
  selected := SelectNextThread_Pas(Pointer(s.Threads), s.ThreadCount, coreId,
    s.SystemTicks, s.IdleIds[coreId], bestId, wokeAny);
  if selected = 0 then
  begin
    { Dispatcher refused; keep the core on the idle task. }
    bestId := s.IdleIds[coreId];
  end;
  { No idle task for this core yet, so there is nothing valid to run. Staying
    put is the only safe answer; indexing the table with -1 would not be. }
  if (bestId < 0) or (bestId >= s.ThreadCount) then
  begin
    Result := currentRsp;
    Exit;
  end;

  s.CurrentIds[coreId]             := bestId;
  s.Threads[bestId].ExecutingOnCore := Integer(coreId);

  nextRsp    := s.Threads[bestId].Rsp;
  nextKStack := s.Threads[bestId].KernelStackTop;
  nextPml4   := s.Threads[bestId].AddrSpace;

  { The TSS ring-0 stack must follow the thread we are switching to. Rsp0
    sits at byte offset 4 of the TSS (a 4-byte reserved field precedes it). }
  if nextKStack <> 0 then
  begin
    if coreId = 0 then tss := Gdt_GetTss
    else tss := Gdt_GetCoreTss(coreId);
    if tss <> nil then PQWord(PByte(tss) + 4)^ := nextKStack;
  end;

  if (nextPml4 = 0) or (not Vmm_IsCanonical(nextPml4)) or
     (nextPml4 >= PhysLimit) then
  begin
    nextPml4 := KernelRoot;
    s.Threads[bestId].AddrSpace := nextPml4;
  end;
  Arch_LoadPageTable(nextPml4);

  { No per-thread deferred mappings to process here. }

  Arch_RestoreFPU(@s.Threads[bestId].FpuState[0]);

  Result := nextRsp;
end;

function Sched_SwitchTask(currentRsp: QWord): QWord;
begin
  Arch_LockScheduler;
  Result := SwitchTask(St, currentRsp);
  Arch_UnlockScheduler;
end;

{ Implementation carries no public name: the interface declaration already has
  the one the IFDEF selects. }
function Sched_YieldHandler(currentRsp: QWord): QWord; cdecl;
begin
  Sched_YieldHandler := Sched_SwitchTask(currentRsp);
end;

{ ── Kernel tasks ────────────────────────────────────────────────────────── }

procedure CreateTask(var s: TSchedState; entryPoint: QWord);
var
  irq:         Boolean;
  id:          Integer;
  stackBase:   PQWord;
  stackTop:    PQWord;
  originalTop: QWord;
  cs, ss:      Word;
  epAddr:      QWord;
  i:           Integer;
begin
  irq := Sched_AcquireSchedLockSafe;
  id := FindFreeSlot(s.Threads, s.ThreadCount);
  if (id >= 0) and (id = s.ThreadCount) then Inc(s.ThreadCount);
  if id = -1 then
  begin
    Sched_ReleaseSchedLockSafe(irq);
    Exit;
  end;

  s.Threads[id].Active := 3;

  if s.Threads[id].KernelStackTop = 0 then
  begin
    { Allocate outside the lock: page zeroing under the scheduler lock is a
      prime source of cross-core stalls. }
    Sched_ReleaseSchedLockSafe(irq);
    stackBase := PQWord(Pmm_AllocateContiguousPages(SCHED_STACK_PAGES));
    irq := Sched_AcquireSchedLockSafe;
    if stackBase = nil then
    begin
      TermFatal('[!] FATAL: Failed to allocate kernel stack for task!'#13#10);
      s.Threads[id].Active := 0;
      Sched_ReleaseSchedLockSafe(irq);
      Exit;
    end;
    stackTop := stackBase + SCHED_STACK_SLOTS;
    s.Threads[id].KernelStackTop := QWord(stackTop);
  end
  else
  begin
    { [STACK MANAGEMENT] Recycled stacks are overwritten in place. MemSet on a
      live stack races with the other cores and corrupts them. }
    stackTop := PQWord(s.Threads[id].KernelStackTop);
  end;

  Dec(stackTop); stackTop^ := 0;
  originalTop := QWord(stackTop);

  cs := Arch_GetCS;
  ss := Arch_GetSS;

  Dec(stackTop); stackTop^ := ss;
  Dec(stackTop); stackTop^ := originalTop;
  Dec(stackTop); stackTop^ := $202;
  Dec(stackTop); stackTop^ := cs;

  epAddr := entryPoint;
  if (epAddr < 4096) or (not Vmm_IsCanonical(epAddr)) then
  begin
    TermWarn('[WARN] Invalid entryPoint in CreateTask, using KernelIdleLoop fallback'#13#10);
    Dec(stackTop); stackTop^ := QWord(Pointer(@Sched_IdleLoopProc));
  end
  else
  begin
    Dec(stackTop); stackTop^ := epAddr;
  end;

  for i := 1 to 15 do
  begin
    Dec(stackTop); stackTop^ := 0;
  end;

  s.Threads[id].Rsp             := QWord(stackTop);
  s.Threads[id].AddrSpace       := KernelRoot;
  s.Threads[id].ExecutingOnCore := -1;
  s.Threads[id].Active          := 1;

  Sched_ReleaseSchedLockSafe(irq);
end;

procedure Sched_CreateTask(entryPoint: QWord);
begin
  CreateTask(St, entryPoint);
  PublishState;
end;

function CreateUserTask(var s: TSchedState; entryPoint, appPml4: QWord;
  isForeground, isJailed, forceRoot: Boolean; processName: PWord;
  imagePages: Cardinal; priority: Byte): Integer;
var
  irq:           Boolean;
  id:            Integer;
  coreId:        Cardinal;
  currentParent: Integer;
  kStackBase:    PQWord;
  kStackTop:     PQWord;
  stackVirtBase: QWord;
  physPage:      QWord;
  appStackTop:   QWord;
  rflags:        QWord;
  i:             Integer;
begin
  Result := -1;
  if (entryPoint < 4096) or (not Vmm_IsCanonical(entryPoint)) then
  begin
    TermFatal('[!] Scheduler Blocked: Garbage PE EntryPoint! IPC/FAT16 Delivery Failed!'#13#10);
    Terminal_SetColor_Pas($00FFFFFF);
    Exit;
  end;
  if appPml4 = 0 then
  begin
    TermFatal('[!] FATAL: Invalid PML4 in CreateUserTask!'#13#10);
    Terminal_SetColor_Pas($00FFFFFF);
    Exit;
  end;

  irq := Sched_AcquireSchedLockSafe;
  id := FindFreeSlot(s.Threads, s.ThreadCount);
  if (id >= 0) and (id = s.ThreadCount) then Inc(s.ThreadCount);
  if id = -1 then
  begin
    Sched_ReleaseSchedLockSafe(irq);
    Exit;
  end;

  s.Threads[id].Active := 3;
  MemCopy(@s.Threads[id].FpuState[0], @s.Threads[0].FpuState[0], 512);

  coreId        := ReadCoreId;
  currentParent := s.CurrentIds[coreId];

  if s.Threads[id].KernelStackTop = 0 then
  begin
    Sched_ReleaseSchedLockSafe(irq);
    kStackBase := PQWord(Pmm_AllocateContiguousPages(SCHED_STACK_PAGES));
    irq := Sched_AcquireSchedLockSafe;
    if kStackBase = nil then
    begin
      TermFatal('[!] FATAL: Failed to allocate kernel stack for user task!'#13#10);
      Sched_ReleaseSchedLockSafe(irq);
      Exit;
    end;
    kStackTop := kStackBase + SCHED_STACK_SLOTS;
    s.Threads[id].KernelStackTop := QWord(kStackTop);
  end
  else
  begin
    { [STACK MANAGEMENT] Recycled stacks are overwritten in place. }
    kStackTop := PQWord(s.Threads[id].KernelStackTop);
  end;

  stackVirtBase := PRNG_Next_Range($0000600000000000, $0000700000000000) and (not QWord($FFF));

  { Map the ring-3 stack without the lock held, then take it again. }
  Sched_ReleaseSchedLockSafe(irq);
  for i := 0 to 3 do
  begin
    physPage := QWord(Pmm_AllocatePage);
    if physPage = 0 then
    begin
      TermFatal('[!] FATAL: Failed to allocate stack page in CreateUserTask!'#13#10);
      Exit;
    end;
    Vmm_MapPageIn(physPage, stackVirtBase + QWord(i * 4096), $07, Pointer(appPml4));
  end;
  irq := Sched_AcquireSchedLockSafe;

  appStackTop := stackVirtBase + $3FF8;

  rflags := $202;
  { IOPL=3 lets a root daemon reach IN/OUT through the vDSO without an IOPB. }
  if forceRoot or ((currentParent >= 0) and (s.Threads[currentParent].UID = 0)) then
    rflags := $3202;

  Dec(kStackTop); kStackTop^ := 0;
  Dec(kStackTop); kStackTop^ := $1B;
  Dec(kStackTop); kStackTop^ := appStackTop;
  Dec(kStackTop); kStackTop^ := rflags;
  Dec(kStackTop); kStackTop^ := $23;
  Dec(kStackTop); kStackTop^ := entryPoint;

  for i := 1 to 15 do
  begin
    Dec(kStackTop); kStackTop^ := 0;
  end;

  s.Threads[id].Rsp           := QWord(kStackTop);
  s.Threads[id].AddrSpace     := appPml4;
  s.Threads[id].IsJailed      := Byte(Ord(isJailed));
  s.Threads[id].IsPhantomDead := 0;
  s.Threads[id].CpuTicks      := 0;
  s.Threads[id].PhysPages     := 5 + imagePages;
  s.Threads[id].VirtPages     := 5 + imagePages;

  s.Threads[id].AppHeapBase :=
    PRNG_Next_Range($0000700000000000, $0000780000000000) and (not QWord($FFF));

  if forceRoot then
  begin
    s.Threads[id].UID := 0;
    s.Threads[id].GID := 0;
  end
  else if currentParent >= 0 then
  begin
    s.Threads[id].UID := s.Threads[currentParent].UID;
    s.Threads[id].GID := s.Threads[currentParent].GID;
  end;

  { Per-process text colour: a single global would let parallel threads on
    different cores overwrite each other's colour. }
  s.Threads[id].TextColor := $00FFFFFF;

  MemCopy(@s.Threads[id].FpuState[0], @s.Threads[0].FpuState[0], 512);

  if processName <> nil then
  begin
    i := 0;
    while (i < 15) and (processName[i] <> 0) do
    begin
      s.Threads[id].Name[i] := Byte(processName[i]);
      Inc(i);
    end;
    s.Threads[id].Name[i]   := 0;
    s.Threads[id].Name[15]  := 0;
  end
  else
  begin
    s.Threads[id].Name[0] := Ord('U'); s.Threads[id].Name[1] := Ord('N');
    s.Threads[id].Name[2] := Ord('K'); s.Threads[id].Name[3] := 0;
  end;

  s.Threads[id].ParentId        := currentParent;
  s.Threads[id].Priority        := priority;
  { currentParent is -1 on a core that has not claimed a thread yet; reading
    Threads[-1] would be a wild access, so leave VRuntime at zero. }
  if currentParent >= 0 then
    s.Threads[id].VRuntime := s.Threads[currentParent].VRuntime;
  s.Threads[id].ExecutingOnCore := -1;

  if isForeground then s.ForegroundTask := id;

  s.Threads[id].Active := 1;
  Result := id;

  Sched_ReleaseSchedLockSafe(irq);
end;

function Sched_CreateUserTask(entryPoint, appPml4: QWord;
  isForeground, isJailed, forceRoot: Boolean; processName: PWord;
  imagePages: Cardinal; priority: Byte): Integer;
begin
  Result := CreateUserTask(St, entryPoint, appPml4, isForeground, isJailed,
    forceRoot, processName, imagePages, priority);
  PublishState;
end;

{ ── Termination ─────────────────────────────────────────────────────────── }

procedure TerminateTask(var s: TSchedState; id: Integer);
var
  irq:        Boolean;
  coreId:     Cardinal;
  isSelf:     Boolean;
  dyingPml4:  QWord;
begin
  irq := Sched_AcquireSchedLockSafe;

  if (id <= 0) or (id >= s.ThreadCount) or (s.Threads[id].Active = 0) or
     (s.Threads[id].Priority = SCHED_IDLE_PRIORITY) then
  begin
    Sched_ReleaseSchedLockSafe(irq);
    Exit;
  end;

  coreId := ReadCoreId;

  { Never touch a stack another core is running on: wait for it to come home. }
  while (s.Threads[id].ExecutingOnCore <> -1) and
        (s.Threads[id].ExecutingOnCore <> Integer(coreId)) do
  begin
    Sched_ReleaseSchedLockSafe(irq);
    Arch_ForceYield;
    irq := Sched_AcquireSchedLockSafe;
  end;

  if s.ForegroundTask = id then
  begin
    s.ForegroundTask := s.Threads[id].ParentId;
    Terminal_SetColor_Pas($00FFFFFF);
  end;

  s.Threads[id].UID := 9999;
  s.Threads[id].GID := 9999;
  s.Threads[id].AppHeapBase := 0;
  ClearMailbox(Cardinal(id));

  { SharedMemPhys is already freed by Vmm_DestroyUserSpace walking the page
    tables; freeing it again here would be a double free. }
  s.Threads[id].SharedMemPhys := 0;
  s.Threads[id].SharedMemVirt := 0;

  isSelf    := (id = s.CurrentIds[coreId]);
  dyingPml4 := 0;

  if (s.Threads[id].AddrSpace <> 0) and (s.Threads[id].AddrSpace <> KernelRoot) then
  begin
    dyingPml4             := s.Threads[id].AddrSpace;
    s.Threads[id].AddrSpace := 0;
    if isSelf then Arch_LoadPageTable(KernelRoot);
  end;

  { Self keeps the zombie flag so nothing else touches its stack; anyone else
    is buried immediately, the record is already zeroed. }
  if isSelf then s.Threads[id].Active := 4
  else s.Threads[id].Active := 0;

  Sched_ReleaseSchedLockSafe(irq);

  if dyingPml4 <> 0 then
  begin
    { No preemption while physical pages are freed, matching the interrupt
      handler paths. }
    Arch_DisableInterrupts;
    Vmm_DestroyUserSpace(dyingPml4);
    Arch_EnableInterrupts;
  end;

  if isSelf then Arch_ForceYield;
end;

procedure Sched_TerminateTask(id: Integer);
begin
  TerminateTask(St, id);
end;

procedure Sched_TerminateCurrentTask;
begin
  TerminateTask(St, Sched_GetCurrentThreadId);
end;

{ ── State accessors ─────────────────────────────────────────────────────── }

function Sched_GetThreads: Pointer;
begin
  Sched_GetThreads := Pointer(St.Threads);
end;

function Sched_GetThreadCount: Integer;
begin
  Sched_GetThreadCount := St.ThreadCount;
end;

function Sched_IsReady: Boolean;
begin
  Sched_IsReady := St.Ready;
end;

procedure Sched_SetReady(v: Boolean);
begin
  St.Ready := v;
end;

function Sched_GetForegroundTask: Integer;
begin
  Sched_GetForegroundTask := St.ForegroundTask;
end;

procedure Sched_SetForegroundTask(v: Integer);
begin
  St.ForegroundTask := v;
end;

function Sched_GetCurrentThreadIds: PInteger;
begin
  Sched_GetCurrentThreadIds := St.CurrentIds;
end;

function Sched_GetIdleThreadIds: PInteger;
begin
  Sched_GetIdleThreadIds := St.IdleIds;
end;

function Sched_GetDyingThreadPerCore: PInteger;
begin
  Sched_GetDyingThreadPerCore := St.DyingIds;
end;

function Sched_GetSystemTicks: QWord;
begin
  Sched_GetSystemTicks := St.SystemTicks;
end;

procedure Sched_SetSystemTicks(ticks: QWord);
begin
  St.SystemTicks := ticks;
end;

function Sched_BumpSystemTicks(delta: QWord): QWord;
begin
  Sched_BumpSystemTicks := Arch_AtomicAdd64(St.SystemTicks, delta);
end;

function Sched_GetCurrentThreadId: Integer;
var
  coreId: Cardinal;
  tid:   Integer;
begin
  if St.CurrentIds = nil then
  begin
    Sched_GetCurrentThreadId := 0;
    Exit;
  end;
  if not Apic_IsAwake then
  begin
    Sched_GetCurrentThreadId := St.CurrentIds[0];
    Exit;
  end;

  coreId := ReadCoreId;
  if coreId >= SCHED_MAX_CORES then
  begin
    Sched_GetCurrentThreadId := 0;
    Exit;
  end;
  tid := St.CurrentIds[coreId];

  { [FIX CVE-2026-008] Every caller indexes the thread table with this, so an
    uninitialised or stale value must answer 0 rather than a wild pointer. }
  if (St.Threads = nil) or (tid < 0) or (tid >= St.ThreadCount) then
  begin
    Sched_GetCurrentThreadId := 0;
    Exit;
  end;
  Sched_GetCurrentThreadId := tid;
end;

{ ── Per-thread field accessors ──────────────────────────────────────────── }

function Sched_GetThreadActive(index: Integer): Byte;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.Active else Result := 0;
end;

procedure Sched_SetThreadActive(index: Integer; v: Byte);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.Active := v;
end;

function Sched_GetThreadJailed(index: Integer): Byte;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.IsJailed else Result := 0;
end;

procedure Sched_SetThreadJailed(index: Integer; v: Byte);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.IsJailed := v;
end;

function Sched_GetThreadPhantomDead(index: Integer): Byte;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.IsPhantomDead else Result := 0;
end;

procedure Sched_SetThreadPhantomDead(index: Integer; v: Byte);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.IsPhantomDead := v;
end;

function Sched_GetThreadUID(index: Integer): Cardinal;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.UID else Result := 0;
end;

procedure Sched_SetThreadUID(index: Integer; v: Cardinal);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.UID := v;
end;

function Sched_GetThreadGID(index: Integer): Cardinal;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.GID else Result := 0;
end;

procedure Sched_SetThreadGID(index: Integer; v: Cardinal);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.GID := v;
end;

function Sched_GetThreadParentId(index: Integer): Integer;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.ParentId else Result := -1;
end;

procedure Sched_SetThreadParentId(index: Integer; v: Integer);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.ParentId := v;
end;

function Sched_GetThreadCore(index: Integer): Integer;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.ExecutingOnCore else Result := -1;
end;

procedure Sched_SetThreadCore(index: Integer; v: Integer);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.ExecutingOnCore := v;
end;

function Sched_GetThreadRsp(index: Integer): QWord;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.Rsp else Result := 0;
end;

procedure Sched_SetThreadRsp(index: Integer; v: QWord);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.Rsp := v;
end;

function Sched_GetThreadKernelStackTop(index: Integer): QWord;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.KernelStackTop else Result := 0;
end;

procedure Sched_SetThreadKernelStackTop(index: Integer; v: QWord);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.KernelStackTop := v;
end;

function Sched_GetThreadHeapBase(index: Integer): QWord;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.AppHeapBase else Result := 0;
end;

procedure Sched_SetThreadHeapBase(index: Integer; v: QWord);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.AppHeapBase := v;
end;

function Sched_GetThreadName(index: Integer): PByte;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := @t^.Name[0] else Result := nil;
end;

function Sched_GetThreadCpuTicks(index: Integer): QWord;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.CpuTicks else Result := 0;
end;

function Sched_GetThreadPhysPages(index: Integer): Cardinal;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.PhysPages else Result := 0;
end;

procedure Sched_SetThreadPhysPages(index: Integer; v: Cardinal);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.PhysPages := v;
end;

function Sched_GetThreadVirtPages(index: Integer): Cardinal;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.VirtPages else Result := 0;
end;

procedure Sched_SetThreadVirtPages(index: Integer; v: Cardinal);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.VirtPages := v;
end;

function Sched_GetThreadWakeUpTick(index: Integer): QWord;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.WakeUpTick else Result := 0;
end;

procedure Sched_SetThreadWakeUpTick(index: Integer; v: QWord);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.WakeUpTick := v;
end;

function Sched_GetThreadVRuntime(index: Integer): QWord;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.VRuntime else Result := 0;
end;

procedure Sched_SetThreadVRuntime(index: Integer; v: QWord);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.VRuntime := v;
end;

function Sched_BumpThreadVRuntime(index: Integer; delta: QWord): QWord;
var t: PThread;
begin
  if ThreadAt(index, t) then
    Result := Arch_AtomicAdd64(t^.VRuntime, delta)
  else
    Result := 0;
end;

function Sched_GetThreadPriority(index: Integer): Byte;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.Priority else Result := 0;
end;

procedure Sched_SetThreadPriority(index: Integer; v: Byte);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.Priority := v;
end;

function Sched_GetThreadTextColor(index: Integer): Cardinal;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := t^.TextColor else Result := 0;
end;

procedure Sched_SetThreadTextColor(index: Integer; v: Cardinal);
var t: PThread;
begin
  if ThreadAt(index, t) then t^.TextColor := v;
end;

function Sched_GetThreadFpuState(index: Integer): Pointer;
var t: PThread;
begin
  if ThreadAt(index, t) then Result := @t^.FpuState[0] else Result := nil;
end;

{ ── Legacy cdecl shims ──────────────────────────────────────────────────── }

{ The 25 callees are now imported directly (see the unit header), so only two
  of the pointers still carry meaning: the IPC mailbox clear and the idle-loop
  entry, both of which are C#-owned resources. They are kept as fallbacks for
  a caller that registers them before the equivalent handle is published. The
  other 23 are accepted and ignored so the ABI stays byte-for-byte compatible. }
procedure Sched_SetCallbacks_Pas(
  pmmAllocContigFn, pmmAllocPageFn, pmmFreePageFn,
  getKernelRootFn, isCanonicalFn, destroyUserFn,
  mapPageFn, ipcClearBoxFn,
  termPrintFn, termSetColorFn, prngNextFn,
  getGdtTssRsp0Fn, getCoreTssRsp0Fn,
  apicReadFn, apicIsAwakeFn,
  getCurrentIdsFn, getIdleIdsFn, getDyingIdsFn,
  selectNextFn, getIdleLoopPtrFn,
  getCSFn, getSSFn, saveFpuFn, restoreFpuFn: Pointer
); cdecl; public name 'Sched_SetCallbacks_Pas';
begin
  cb_IpcClearBox := ipcClearBoxFn;
  cb_GetIdleLoop := getIdleLoopPtrFn;
  { pmmAllocContigFn, pmmAllocPageFn, pmmFreePageFn, getKernelRootFn,
    isCanonicalFn, destroyUserFn, mapPageFn, termPrintFn, termSetColorFn,
    prngNextFn, getGdtTssRsp0Fn, getCoreTssRsp0Fn, apicReadFn,
    apicIsAwakeFn, getCurrentIdsFn, getIdleIdsFn, getDyingIdsFn,
    selectNextFn, getCSFn, getSSFn, saveFpuFn, restoreFpuFn:
    superseded by direct pmm/vmm/terminal/prng/gdt/apic/scheduler_dispatch
    and arch_interface bindings. }
  if pmmAllocContigFn = nil then ;
  if getCurrentIdsFn = nil then ;
  if selectNextFn = nil then ;
end;

procedure Sched_Init_Pas(out threadsOut: Pointer; out threadCountOut: Integer;
  out readyOut: Byte); cdecl; public name 'Sched_Init_Pas';
begin
  Sched_Init;
  threadsOut     := Pointer(St.Threads);
  threadCountOut := St.ThreadCount;
  if St.Ready then readyOut := 1 else readyOut := 0;
end;

{ Historical behaviour: a pure query. The caller owns the increment, which is
  why the state-owning Sched_GetFreeThreadSlot grows the table itself instead. }
function Sched_GetFreeSlot_Pas(threads: Pointer; threadCount: Integer): Integer; cdecl;
  public name 'Sched_GetFreeSlot_Pas';
begin
  Sched_GetFreeSlot_Pas := FindFreeSlot(PThread(threads), threadCount);
end;

function Sched_GetThreadAddrSpace_Pas(index: Integer): QWord; cdecl;
  public name 'Sched_GetThreadAddrSpace_Pas';
var
  t: PThread;
begin
  Result := 0;
  if index < 0 then Exit;
  if (kstate_Threads = nil) or (index >= kstate_ThreadCount) then Exit;
  t := PThread(kstate_Threads);
  if t[index].Active = 0 then Exit;
  Result := t[index].AddrSpace;
end;

procedure Sched_CreateIdleTask_Pas(coreId: Cardinal; threads: Pointer;
  var threadCount: Integer; currentThreadIds: PInteger;
  idleThreadIds: PInteger); cdecl; public name 'Sched_CreateIdleTask_Pas';
var
  tmp: TSchedState;
begin
  tmp.Threads        := PThread(threads);
  tmp.ThreadCount    := threadCount;
  tmp.Ready          := St.Ready;
  tmp.ForegroundTask := St.ForegroundTask;
  tmp.CurrentIds     := currentThreadIds;
  tmp.IdleIds        := idleThreadIds;
  tmp.DyingIds       := St.DyingIds;
  tmp.SystemTicks    := St.SystemTicks;

  CreateIdleTaskForCore(tmp, coreId);

  threadCount := tmp.ThreadCount;
end;

function Sched_SwitchTask_Pas(currentRsp: QWord; threads: Pointer;
  var threadCount: Integer; ready: Byte; systemTicks: QWord;
  var foregroundTask: Integer; currentThreadIds, idleThreadIds,
  dyingThreadIds: PInteger): QWord; cdecl; public name 'Sched_SwitchTask_Pas';
var
  tmp: TSchedState;
begin
  tmp.Threads        := PThread(threads);
  tmp.ThreadCount    := threadCount;
  tmp.Ready          := ready <> 0;
  tmp.ForegroundTask := foregroundTask;
  tmp.CurrentIds     := currentThreadIds;
  tmp.IdleIds        := idleThreadIds;
  tmp.DyingIds       := dyingThreadIds;
  tmp.SystemTicks    := systemTicks;

  { The caller holds the scheduler lock around this shim, matching the C# side. }
  Sched_SwitchTask_Pas := SwitchTask(tmp, currentRsp);

  threadCount    := tmp.ThreadCount;
  foregroundTask := tmp.ForegroundTask;
end;

function Sched_CreateUserTask_Pas(entryPoint, appPml4: QWord;
  isForeground, isJailed, forceRoot: Byte; processName: PWord;
  imagePages: Cardinal; priority: Byte; threads: Pointer;
  var threadCount: Integer; currentThreadIds: PInteger;
  var foregroundTask: Integer): Integer; cdecl;
  public name 'Sched_CreateUserTask_Pas';
var
  tmp: TSchedState;
begin
  tmp.Threads        := PThread(threads);
  tmp.ThreadCount    := threadCount;
  tmp.Ready          := St.Ready;
  tmp.ForegroundTask := foregroundTask;
  tmp.CurrentIds     := currentThreadIds;
  tmp.IdleIds        := St.IdleIds;
  tmp.DyingIds       := St.DyingIds;
  tmp.SystemTicks    := St.SystemTicks;

  Sched_CreateUserTask_Pas := CreateUserTask(tmp, entryPoint, appPml4,
    isForeground <> 0, isJailed <> 0, forceRoot <> 0, processName,
    imagePages, priority);

  threadCount    := tmp.ThreadCount;
  foregroundTask := tmp.ForegroundTask;
end;

procedure Sched_CreateTask_Pas(entryPoint: QWord; threads: Pointer;
  var threadCount: Integer); cdecl; public name 'Sched_CreateTask_Pas';
var
  tmp: TSchedState;
begin
  tmp.Threads        := PThread(threads);
  tmp.ThreadCount    := threadCount;
  tmp.Ready          := St.Ready;
  tmp.ForegroundTask := St.ForegroundTask;
  tmp.CurrentIds     := St.CurrentIds;
  tmp.IdleIds        := St.IdleIds;
  tmp.DyingIds       := St.DyingIds;
  tmp.SystemTicks    := St.SystemTicks;

  CreateTask(tmp, entryPoint);

  threadCount := tmp.ThreadCount;
end;

procedure Sched_TerminateTask_Pas(id: Integer; threads: Pointer;
  threadCount: Integer; currentThreadIds: PInteger;
  var foregroundTask: Integer); cdecl; public name 'Sched_TerminateTask_Pas';
var
  tmp: TSchedState;
begin
  tmp.Threads        := PThread(threads);
  tmp.ThreadCount    := threadCount;
  tmp.Ready          := St.Ready;
  tmp.ForegroundTask := foregroundTask;
  tmp.CurrentIds     := currentThreadIds;
  tmp.IdleIds        := St.IdleIds;
  tmp.DyingIds       := St.DyingIds;
  tmp.SystemTicks    := St.SystemTicks;

  TerminateTask(tmp, id);

  foregroundTask := tmp.ForegroundTask;
end;

end.
