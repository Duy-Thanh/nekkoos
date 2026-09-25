{
  =========================================================================
  NekkoOS — scheduler.pas
  Full port of Thread.cs Scheduler class.
  CRITICAL: All types declared in implementation only to avoid RTTI.
  AGENTS.md §2.4: Built-in types only in cdecl signatures.
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

{ All exported functions use Pointer for thread array (avoids RTTI on TThread).
  C# side casts Thread* → Pointer when calling. }

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

uses libc, prng;

{ ── TThread record — implementation only, no RTTI ──────────────────────── }
type
  TThread = packed record
    Rsp:            QWord;
    Active:         Byte;
    IsJailed:       Byte;
    IsPhantomDead:  Byte;
    Padding1:       Byte;
    ParentId:       Integer;
    ExecutingOnCore:Integer;
    PaddingNew:     Cardinal;
    PaddingAlign:   QWord;
    AppHeapBase:    QWord;
    KernelStackTop: QWord;
    AddrSpace:      QWord;
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

{ ── Callback variables — Pointer type, no RTTI ──────────────────────────── }
var
  cb_PmmAllocContig: Pointer = nil;
  cb_PmmAllocPage:   Pointer = nil;
  cb_PmmFreePage:    Pointer = nil;
  cb_GetKernelRoot:  Pointer = nil;
  cb_IsCanonical:    Pointer = nil;
  cb_DestroyUser:    Pointer = nil;
  cb_MapPage:        Pointer = nil;
  cb_IpcClearBox:    Pointer = nil;
  cb_TermPrint:      Pointer = nil;
  cb_TermSetColor:   Pointer = nil;
  cb_PrngNext:       Pointer = nil;
  cb_GetGdtTssRsp0:  Pointer = nil;
  cb_GetCoreTssRsp0: Pointer = nil;
  cb_ApicRead:       Pointer = nil;
  cb_ApicIsAwake:    Pointer = nil;
  cb_GetCurrentIds:  Pointer = nil;
  cb_GetIdleIds:     Pointer = nil;
  cb_GetDyingIds:    Pointer = nil;
  cb_SelectNext:     Pointer = nil;
  cb_GetIdleLoopPtr: Pointer = nil;
  cb_GetCS:          Pointer = nil;
  cb_GetSS:          Pointer = nil;
  cb_SaveFPU:        Pointer = nil;
  cb_RestoreFPU:     Pointer = nil;

{ ── Typed call helpers (cast at call site, no type alias defined) ────────── }

function  CallAllocContig(pages: QWord): Pointer; inline;
type TFn = function(p: QWord): Pointer; cdecl;
begin Result := TFn(cb_PmmAllocContig)(pages); end;

function  CallAllocPage: Pointer; inline;
type TFn = function: Pointer; cdecl;
begin Result := TFn(cb_PmmAllocPage)(); end;

procedure CallFreePage(p: Pointer); inline;
type TFn = procedure(p: Pointer); cdecl;
begin TFn(cb_PmmFreePage)(p); end;

function  CallGetKernelRoot: QWord; inline;
type TFn = function: QWord; cdecl;
begin Result := TFn(cb_GetKernelRoot)(); end;

procedure CallDestroyUser(pml4: QWord); inline;
type TFn = procedure(pml4: QWord); cdecl;
begin TFn(cb_DestroyUser)(pml4); end;

procedure CallMapPage(phys, virt, flags: QWord; pml4: PQWord); inline;
type TFn = procedure(phys, virt, flags: QWord; pml4: PQWord); cdecl;
begin TFn(cb_MapPage)(phys, virt, flags, pml4); end;

procedure CallIpcClearBox(tid: Cardinal); inline;
type TFn = procedure(tid: Cardinal); cdecl;
begin TFn(cb_IpcClearBox)(tid); end;

procedure CallTermPrint(str: PWord); inline;
type TFn = procedure(str: PWord); cdecl;
begin TFn(cb_TermPrint)(str); end;

procedure CallTermSetColor(color: Cardinal); inline;
type TFn = procedure(color: Cardinal); cdecl;
begin TFn(cb_TermSetColor)(color); end;

function  CallPrngNext(lo, hi: QWord): QWord; inline;
type TFn = function(lo, hi: QWord): QWord; cdecl;
begin Result := TFn(cb_PrngNext)(lo, hi); end;

function  CallGetGdtTssRsp0: PQWord; inline;
type TFn = function: PQWord; cdecl;
begin Result := TFn(cb_GetGdtTssRsp0)(); end;

function  CallGetCoreTssRsp0(coreId: Cardinal): PQWord; inline;
type TFn = function(coreId: Cardinal): PQWord; cdecl;
begin Result := TFn(cb_GetCoreTssRsp0)(coreId); end;

function  CallApicRead(reg: Cardinal): Cardinal; inline;
type TFn = function(reg: Cardinal): Cardinal; cdecl;
begin Result := TFn(cb_ApicRead)(reg); end;

function  CallApicIsAwake: Byte; inline;
type TFn = function: Byte; cdecl;
begin Result := TFn(cb_ApicIsAwake)(); end;

function  CallGetCurrentIds: PInteger; inline;
type TFn = function: PInteger; cdecl;
begin Result := TFn(cb_GetCurrentIds)(); end;

function  CallGetIdleIds: PInteger; inline;
type TFn = function: PInteger; cdecl;
begin Result := TFn(cb_GetIdleIds)(); end;

function  CallGetDyingIds: PInteger; inline;
type TFn = function: PInteger; cdecl;
begin Result := TFn(cb_GetDyingIds)(); end;

function  CallGetIdleLoopPtr: Pointer; inline;
type TFn = function: Pointer; cdecl;
begin Result := TFn(cb_GetIdleLoopPtr)(); end;

function  CallGetCS: Word; inline;
type TFn = function: Word; cdecl;
begin Result := TFn(cb_GetCS)(); end;

function  CallGetSS: Word; inline;
type TFn = function: Word; cdecl;
begin Result := TFn(cb_GetSS)(); end;

procedure CallSaveFPU(buf: Pointer); inline;
type TFn = procedure(buf: Pointer); cdecl;
begin TFn(cb_SaveFPU)(buf); end;

procedure CallRestoreFPU(buf: Pointer); inline;
type TFn = procedure(buf: Pointer); cdecl;
begin TFn(cb_RestoreFPU)(buf); end;

procedure CallSelectNext(threads: PThread; threadCount: Integer; coreId: Cardinal;
  ticks: QWord; idleId: Integer; out bestId: Integer; out wokeAny: Byte); inline;
type TFn = function(threads: PThread; threadCount: Integer; coreId: Cardinal;
  ticks: QWord; idleId: Integer; out bestId: Integer; out wokeAny: Byte): Byte; cdecl;
begin TFn(cb_SelectNext)(threads, threadCount, coreId, ticks, idleId, bestId, wokeAny); end;

{ ── Sched_SetCallbacks_Pas ──────────────────────────────────────────────── }
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
  cb_PmmAllocContig := pmmAllocContigFn;
  cb_PmmAllocPage   := pmmAllocPageFn;
  cb_PmmFreePage    := pmmFreePageFn;
  cb_GetKernelRoot  := getKernelRootFn;
  cb_IsCanonical    := isCanonicalFn;
  cb_DestroyUser    := destroyUserFn;
  cb_MapPage        := mapPageFn;
  cb_IpcClearBox    := ipcClearBoxFn;
  cb_TermPrint      := termPrintFn;
  cb_TermSetColor   := termSetColorFn;
  cb_PrngNext       := prngNextFn;
  cb_GetGdtTssRsp0  := getGdtTssRsp0Fn;
  cb_GetCoreTssRsp0 := getCoreTssRsp0Fn;
  cb_ApicRead       := apicReadFn;
  cb_ApicIsAwake    := apicIsAwakeFn;
  cb_GetCurrentIds  := getCurrentIdsFn;
  cb_GetIdleIds     := getIdleIdsFn;
  cb_GetDyingIds    := getDyingIdsFn;
  cb_SelectNext     := selectNextFn;
  cb_GetIdleLoopPtr := getIdleLoopPtrFn;
  cb_GetCS          := getCSFn;
  cb_GetSS          := getSSFn;
  cb_SaveFPU        := saveFpuFn;
  cb_RestoreFPU     := restoreFpuFn;
end;

{ ── WPrint helper ───────────────────────────────────────────────────────── }
procedure WPrint(msg: PChar);
var buf: array[0..127] of Word; i: Integer;
begin
  i := 0;
  while (msg[i] <> #0) and (i < 127) do begin buf[i] := Ord(msg[i]); Inc(i); end;
  buf[i] := 0;
  CallTermPrint(@buf[0]);
end;

{ ── GetCoreId ───────────────────────────────────────────────────────────── }
function GetCoreId: Cardinal; inline;
begin
  if CallApicIsAwake() <> 0 then
    Result := CallApicRead($020) shr 24
  else
    Result := 0;
  if Result >= 256 then Result := 0;
end;

function IsCanonicalAddr(addr: QWord): Boolean; inline;
begin
  Result := (addr shr 47 = 0) or (addr shr 47 = $1FFFF);
end;

{ ── Sched_Init_Pas ──────────────────────────────────────────────────────── }
procedure Sched_Init_Pas(out threadsOut: Pointer; out threadCountOut: Integer; out readyOut: Byte); cdecl;
  public name 'Sched_Init_Pas';
var
  threads:    PThread;
  currentIds: PInteger;
  idleIds:    PInteger;
  dyingIds:   PInteger;
  gdtTssRsp0: PQWord;
  i: Integer;
  name: PByte;
begin
  threadsOut     := nil;
  threadCountOut := 0;
  readyOut       := 0;

  threads := PThread(CallAllocContig(64));
  if threads = nil then begin
    CallTermSetColor($00FF0000);
    WPrint('[!] FATAL: Failed to allocate Threads memory!'#10);
    Exit;
  end;
  MemSet(threads, 0, 64 * 4096);

  currentIds := PInteger(CallAllocPage());
  if currentIds = nil then begin
    CallTermSetColor($00FF0000);
    WPrint('[!] FATAL: Failed to allocate CurrentThreadIds!'#10);
    Exit;
  end;
  idleIds := PInteger(CallAllocPage());
  if idleIds = nil then begin
    CallTermSetColor($00FF0000);
    WPrint('[!] FATAL: Failed to allocate IdleThreadIds!'#10);
    CallFreePage(currentIds);
    Exit;
  end;
  dyingIds := PInteger(CallAllocPage());
  if dyingIds = nil then begin
    CallTermSetColor($00FF0000);
    WPrint('[!] FATAL: Failed to allocate DyingThreadPerCore!'#10);
    CallFreePage(currentIds); CallFreePage(idleIds);
    Exit;
  end;

  for i := 0 to 255 do begin currentIds[i] := -1; idleIds[i] := -1; end;
  currentIds[0] := 0; idleIds[0] := 0;
  for i := 0 to 255 do dyingIds[i] := -1;

  gdtTssRsp0 := CallGetGdtTssRsp0();
  threads[0].Active          := 1;
  if gdtTssRsp0 <> nil then
    threads[0].KernelStackTop := gdtTssRsp0^
  else
    threads[0].KernelStackTop := 0;
  threads[0].AddrSpace       := CallGetKernelRoot();
  threads[0].UID             := 0; threads[0].GID := 0;
  threads[0].TextColor       := $00FFFFFF;
  threads[0].ParentId        := 0;
  threads[0].ExecutingOnCore := 0;
  threads[0].Priority        := 99;

  name := @threads[0].Name[0];
  name[0]:=Ord('K'); name[1]:=Ord('E'); name[2]:=Ord('R');
  name[3]:=Ord('N'); name[4]:=Ord('E'); name[5]:=Ord('L'); name[6]:=0;

  CallSaveFPU(@threads[0].FpuState[0]);

  threadsOut     := threads;
  threadCountOut := 1;
  readyOut       := 1;

  CallTermSetColor($0000FF00);
  WPrint('[+] Multiverse Scheduler Initialized! Threads Isolated.'#10);
end;

{ ── Sched_GetFreeSlot_Pas ───────────────────────────────────────────────── }
function Sched_GetFreeSlot_Pas(threads: Pointer; threadCount: Integer): Integer; cdecl;
  public name 'Sched_GetFreeSlot_Pas';
var
  t: PThread;
  i: Integer;
begin
  t := PThread(threads);
  if (threadCount < 1) or (threadCount > 256) then begin
    CallTermSetColor($00FF0000);
    WPrint('[!] FATAL: Invalid thread count in GetFreeSlot!'#10);
    Result := -1; Exit;
  end;
  for i := 1 to threadCount - 1 do
    if t[i].Active = 0 then begin Result := i; Exit; end;
  if threadCount < 256 then Result := threadCount
  else Result := -1;
end;

{ ── Sched_CreateIdleTask_Pas ────────────────────────────────────────────── }
procedure Sched_CreateIdleTask_Pas(coreId: Cardinal;
  threads: Pointer; var threadCount: Integer;
  currentThreadIds: PInteger; idleThreadIds: PInteger); cdecl;
  public name 'Sched_CreateIdleTask_Pas';
var
  t:          PThread;
  id:         Integer;
  kStackBase: PQWord;
  kStackTop:  PQWord;
  rspValue:   QWord;
  idleAddr:   QWord;
  cs, ss:     Word;
  j: Integer;
begin
  t := PThread(threads);
  if coreId >= 256 then begin
    CallTermSetColor($00FF0000);
    WPrint('[!] FATAL: Invalid core ID in CreateIdleTask!'#10);
    Exit;
  end;

  id := Sched_GetFreeSlot_Pas(threads, threadCount);
  if (id < 0) or (id > threadCount) then begin
    CallTermSetColor($00FF0000);
    WPrint('[!] FATAL: Invalid thread ID in CreateIdleTask!'#10);
    Exit;
  end;
  if id = threadCount then Inc(threadCount);

  t[id].Active          := 1;
  t[id].Priority        := 99;
  t[id].ExecutingOnCore := Integer(coreId);
  t[id].Name[0]         := Ord('I'); t[id].Name[1] := Ord('D');
  t[id].Name[2]         := Ord('L'); t[id].Name[3] := Ord('E');
  t[id].Name[4]         := 0;

  kStackBase := PQWord(CallAllocContig(4));
  if kStackBase = nil then begin
    CallTermSetColor($00FF0000);
    WPrint('[!] FATAL: Failed to alloc idle task stack!'#10);
    Exit;
  end;
  kStackTop := kStackBase + 2048;
  t[id].KernelStackTop := QWord(kStackTop);

  if (QWord(kStackTop) < $10000) or (not IsCanonicalAddr(QWord(kStackTop))) then begin
    CallTermSetColor($00FF0000);
    WPrint('[!] FATAL: Idle task stack invalid!'#10);
    CallFreePage(kStackBase);
    Exit;
  end;

  Dec(kStackTop); kStackTop^ := 0;
  rspValue := QWord(kStackTop);

  cs      := CallGetCS();
  ss      := CallGetSS();
  idleAddr := QWord(CallGetIdleLoopPtr());

  Dec(kStackTop); kStackTop^ := ss;
  Dec(kStackTop); kStackTop^ := rspValue;
  Dec(kStackTop); kStackTop^ := $202;
  Dec(kStackTop); kStackTop^ := cs;
  Dec(kStackTop); kStackTop^ := idleAddr;

  for j := 0 to 14 do begin Dec(kStackTop); kStackTop^ := 0; end;

  t[id].Rsp       := QWord(kStackTop);
  t[id].AddrSpace := CallGetKernelRoot();

  idleThreadIds[coreId] := id;
end;

{ ── Sched_CreateTask_Pas ────────────────────────────────────────────────── }
procedure Sched_CreateTask_Pas(entryPoint: QWord; threads: Pointer; var threadCount: Integer); cdecl;
  public name 'Sched_CreateTask_Pas';
var
  t:           PThread;
  id:          Integer;
  stackBase:   PQWord;
  stackTop:    PQWord;
  originalTop: QWord;
  cs, ss:      Word;
  i: Integer;
begin
  t  := PThread(threads);
  id := Sched_GetFreeSlot_Pas(threads, threadCount);
  if id = -1 then Exit;
  if id = threadCount then Inc(threadCount);

  t[id].Active := 3;

  if t[id].KernelStackTop = 0 then begin
    stackBase := PQWord(CallAllocContig(4));
    if stackBase = nil then begin
      CallTermSetColor($00FF0000);
      WPrint('[!] FATAL: Failed to alloc kernel stack for task!'#10);
      t[id].Active := 0;
      Exit;
    end;
    stackTop := stackBase + 2048;
    t[id].KernelStackTop := QWord(stackTop);
  end
  else stackTop := PQWord(t[id].KernelStackTop);

  Dec(stackTop); stackTop^ := 0;
  originalTop := QWord(stackTop);

  cs := CallGetCS(); ss := CallGetSS();

  Dec(stackTop); stackTop^ := ss;
  Dec(stackTop); stackTop^ := originalTop;
  Dec(stackTop); stackTop^ := $202;
  Dec(stackTop); stackTop^ := cs;
  Dec(stackTop);
  if (entryPoint >= 4096) and IsCanonicalAddr(entryPoint) then
    stackTop^ := entryPoint
  else
    stackTop^ := QWord(CallGetIdleLoopPtr());

  for i := 0 to 14 do begin Dec(stackTop); stackTop^ := 0; end;

  t[id].Rsp              := QWord(stackTop);
  t[id].AddrSpace        := CallGetKernelRoot();
  t[id].ExecutingOnCore  := -1;
  t[id].Active           := 1;
end;

{ ── Sched_CreateUserTask_Pas ────────────────────────────────────────────── }
function Sched_CreateUserTask_Pas(
  entryPoint, appPml4: QWord;
  isForeground, isJailed, forceRoot: Byte;
  processName: PWord;
  imagePages: Cardinal;
  priority: Byte;
  threads: Pointer;
  var threadCount: Integer;
  currentThreadIds: PInteger;
  var foregroundTask: Integer
): Integer; cdecl; public name 'Sched_CreateUserTask_Pas';
var
  t:             PThread;
  id:            Integer;
  coreId:        Cardinal;
  currentParent: Integer;
  kStackBase:    PQWord;
  kStackTop:     PQWord;
  stackVirtBase: QWord;
  physPage:      QWord;
  appStackTop:   QWord;
  rflags:        QWord;
  minHeap, maxHeap: QWord;
  i: Integer;
begin
  Result := -1;
  t := PThread(threads);

  if (entryPoint < 4096) or (not IsCanonicalAddr(entryPoint)) then begin
    CallTermSetColor($00FF0000);
    WPrint('[!] Scheduler Blocked: Garbage PE EntryPoint!'#10);
    CallTermSetColor($00FFFFFF);
    Exit;
  end;
  if appPml4 = 0 then begin
    CallTermSetColor($00FF0000);
    WPrint('[!] FATAL: Invalid PML4 in CreateUserTask!'#10);
    CallTermSetColor($00FFFFFF);
    Exit;
  end;

  id := Sched_GetFreeSlot_Pas(threads, threadCount);
  if id = -1 then Exit;
  if id = threadCount then Inc(threadCount);

  t[id].Active := 3;
  MemCopy(@t[id].FpuState[0], @t[0].FpuState[0], 512);

  coreId        := GetCoreId();
  currentParent := currentThreadIds[coreId];

  if t[id].KernelStackTop = 0 then begin
    kStackBase := PQWord(CallAllocContig(4));
    if kStackBase = nil then begin
      CallTermSetColor($00FF0000);
      WPrint('[!] FATAL: Failed to alloc kernel stack for user task!'#10);
      Exit;
    end;
    kStackTop := kStackBase + 2048;
    t[id].KernelStackTop := QWord(kStackTop);
  end
  else kStackTop := PQWord(t[id].KernelStackTop);

  stackVirtBase := CallPrngNext($0000600000000000, $0000700000000000) and (not QWord($FFF));

  for i := 0 to 3 do begin
    physPage := QWord(CallAllocPage());
    if physPage = 0 then begin
      CallTermSetColor($00FF0000);
      WPrint('[!] FATAL: Failed to alloc user stack page!'#10);
      Exit;
    end;
    CallMapPage(physPage, stackVirtBase + QWord(i * 4096), $07, PQWord(appPml4));
  end;

  appStackTop := stackVirtBase + $3FF8;

  if (forceRoot <> 0) or ((currentParent >= 0) and (t[currentParent].UID = 0)) then
    rflags := $3202
  else
    rflags := $202;

  Dec(kStackTop); kStackTop^ := 0;
  Dec(kStackTop); kStackTop^ := $1B;
  Dec(kStackTop); kStackTop^ := appStackTop;
  Dec(kStackTop); kStackTop^ := rflags;
  Dec(kStackTop); kStackTop^ := $23;
  Dec(kStackTop); kStackTop^ := entryPoint;

  for i := 0 to 14 do begin Dec(kStackTop); kStackTop^ := 0; end;

  t[id].Rsp           := QWord(kStackTop);
  t[id].AddrSpace     := appPml4;
  t[id].IsJailed      := isJailed;
  t[id].IsPhantomDead := 0;
  t[id].CpuTicks      := 0;
  t[id].PhysPages     := 5 + imagePages;
  t[id].VirtPages     := 5 + imagePages;

  minHeap := $0000700000000000; maxHeap := $0000780000000000;
  t[id].AppHeapBase := CallPrngNext(minHeap, maxHeap) and (not QWord($FFF));

  if forceRoot <> 0 then begin t[id].UID := 0; t[id].GID := 0; end
  else if currentParent >= 0 then begin
    t[id].UID := t[currentParent].UID;
    t[id].GID := t[currentParent].GID;
  end;

  t[id].TextColor := $00FFFFFF;
  MemCopy(@t[id].FpuState[0], @t[0].FpuState[0], 512);

  if processName <> nil then begin
    i := 0;
    while (i < 15) and (processName[i] <> 0) do begin
      t[id].Name[i] := Byte(processName[i]); Inc(i);
    end;
    t[id].Name[i] := 0; t[id].Name[15] := 0;
  end
  else begin
    t[id].Name[0]:=Ord('U'); t[id].Name[1]:=Ord('N');
    t[id].Name[2]:=Ord('K'); t[id].Name[3]:=0;
  end;

  t[id].ParentId        := currentParent;
  t[id].Priority        := priority;
  if currentParent >= 0 then
    t[id].VRuntime := t[currentParent].VRuntime;
  t[id].ExecutingOnCore := -1;

  if isForeground <> 0 then foregroundTask := id;

  t[id].Active := 1;
  Result := id;
end;

{ ── Sched_SwitchTask_Pas ────────────────────────────────────────────────── }
function Sched_SwitchTask_Pas(
  currentRsp: QWord;
  threads: Pointer;
  var threadCount: Integer;
  ready: Byte;
  systemTicks: QWord;
  var foregroundTask: Integer;
  currentThreadIds, idleThreadIds, dyingThreadIds: PInteger
): QWord; cdecl; public name 'Sched_SwitchTask_Pas';
var
  t:         PThread;
  coreId:    Cardinal;
  current:   Integer;
  zombieId:  Integer;
  zombiePml4:QWord;
  weight:    QWord;
  bestId:    Integer;
  wokeAny:   Byte;
  nextRsp, nextKStack, nextPml4: QWord;
  tssRsp0:   PQWord;
  i: Integer;
begin
  if ready = 0 then begin Result := currentRsp; Exit; end;
  t := PThread(threads);

  coreId := GetCoreId();

  if dyingThreadIds[coreId] <> -1 then begin
    zombieId   := dyingThreadIds[coreId];
    zombiePml4 := t[zombieId].AddrSpace;
    t[zombieId].Active       := 0;
    dyingThreadIds[coreId]   := -1;
    if (zombiePml4 <> 0) and (zombiePml4 <> CallGetKernelRoot()) then begin
      Arch_UnlockScheduler();
      CallDestroyUser(zombiePml4);
      Arch_LockScheduler();
    end;
  end;

  for i := 0 to threadCount - 1 do begin
    if t[i].Active = 4 then begin
      zombiePml4 := t[i].AddrSpace;
      t[i].Active := 0;
      if (zombiePml4 <> 0) and (zombiePml4 <> CallGetKernelRoot()) then begin
        Arch_UnlockScheduler();
        CallDestroyUser(zombiePml4);
        Arch_LockScheduler();
      end;
    end;
  end;

  current := currentThreadIds[coreId];

  if (current <> -1) and (t[current].Active <> 0) then begin
    if t[current].Active = 4 then
      dyingThreadIds[coreId] := current
    else begin
      CallSaveFPU(@t[current].FpuState[0]);
      if t[current].Active = 1 then begin
        Inc(t[current].CpuTicks);
        if t[current].Priority <> 99 then begin
          weight := QWord(t[current].Priority);
          if weight = 0 then weight := 1;
          Inc(t[current].VRuntime, weight);
        end;
      end;
      t[current].Rsp := currentRsp;
    end;
  end;

  if current <> -1 then t[current].ExecutingOnCore := -1;

  bestId  := -1;
  wokeAny := 0;
  CallSelectNext(t, threadCount, coreId, systemTicks,
    idleThreadIds[coreId], bestId, wokeAny);

  currentThreadIds[coreId]         := bestId;
  t[bestId].ExecutingOnCore        := Integer(coreId);

  nextRsp    := t[bestId].Rsp;
  nextKStack := t[bestId].KernelStackTop;
  nextPml4   := t[bestId].AddrSpace;

  if nextKStack <> 0 then begin
    if coreId = 0 then begin
      tssRsp0 := CallGetGdtTssRsp0();
      if tssRsp0 <> nil then tssRsp0^ := nextKStack;
    end
    else begin
      tssRsp0 := CallGetCoreTssRsp0(coreId);
      if tssRsp0 <> nil then tssRsp0^ := nextKStack;
    end;
  end;

  if (nextPml4 = 0) or (not IsCanonicalAddr(nextPml4)) then begin
    nextPml4 := CallGetKernelRoot();
    t[bestId].AddrSpace := nextPml4;
  end;
  Arch_LoadPageTable(nextPml4);
  CallRestoreFPU(@t[bestId].FpuState[0]);

  Result := nextRsp;
end;

{ ── Sched_TerminateTask_Pas ──────────────────────────────────────────────── }
procedure Sched_TerminateTask_Pas(
  id: Integer; threads: Pointer; threadCount: Integer;
  currentThreadIds: PInteger; var foregroundTask: Integer
); cdecl; public name 'Sched_TerminateTask_Pas';
var
  t:         PThread;
  coreId:    Cardinal;
  isSelf:    Boolean;
  dyingPml4: QWord;
begin
  t := PThread(threads);
  if (id <= 0) or (id >= threadCount) or
     (t[id].Active = 0) or (t[id].Priority = 99) then Exit;

  coreId := GetCoreId();

  while (t[id].ExecutingOnCore <> -1) and
        (t[id].ExecutingOnCore <> Integer(coreId)) do begin
    Arch_UnlockScheduler();
    Arch_ForceYield();
    Arch_LockScheduler();
  end;

  if foregroundTask = id then begin
    foregroundTask := t[id].ParentId;
    CallTermSetColor($00FFFFFF);
  end;

  t[id].UID := 9999; t[id].GID := 9999; t[id].AppHeapBase := 0;
  CallIpcClearBox(Cardinal(id));
  t[id].SharedMemPhys := 0; t[id].SharedMemVirt := 0;

  isSelf    := (id = currentThreadIds[coreId]);
  dyingPml4 := 0;

  if (t[id].AddrSpace <> 0) and (t[id].AddrSpace <> CallGetKernelRoot()) then begin
    dyingPml4       := t[id].AddrSpace;
    t[id].AddrSpace := 0;
    if isSelf then Arch_LoadPageTable(CallGetKernelRoot());
  end;

  if isSelf then t[id].Active := 4
  else t[id].Active := 0;

  Arch_UnlockScheduler();

  if dyingPml4 <> 0 then begin
    Arch_DisableInterrupts();
    CallDestroyUser(dyingPml4);
    Arch_EnableInterrupts();
  end;

  if isSelf then Arch_ForceYield();
end;

end.
