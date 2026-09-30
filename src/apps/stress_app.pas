{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: stress_app - Ring-3 OS stability / stress harness.
  PORTED FROM: src/apps/stresstest.cs + src/apps/stresstest_asm.asm
               (both deleted once this unit is linked).

  WHY THE ORIGINAL NEEDED AN .asm OBJECT
  stresstest.cs AppMain was a one-line forwarder into stresstest_asm.asm.
  bflat's ILCompiler refuses to compile any method whose arithmetic needs
  ThrowOverflowException when ThrowHelpers is not recognised, and its error
  message buries the real cause. Hand-writing the loop in NASM sidestepped
  the compiler entirely. That workaround, and ThrowHelpers.cs with it, are
  both obsolete: FPC emits no overflow-check calls at all under the flags in
  compile_pascal.sh, so the throw helpers have nothing to satisfy. The loop
  below is ordinary Pascal and the only inline asm is the four deliberate
  fault injections, which cannot be written any other way.

  THE FAULT CASCADE IS DELIBERATE
  In the NASM, .trigger_fault fell through into .trigger_dbz, which fell
  through into .trigger_gpf, which fell through into .trigger_isr. There was
  no jump between them. One keystroke therefore walks the entire list, and a
  later keystroke starts partway down it. StageFault/StageDbz/StageGpf/
  StageIsr below are the same four labels and are chained the same way.

  GetThreadUID / GetThreadGID are called with the PID in RCX, exactly as the
  NASM did. app_api's wrappers for those two slots take no argument, which
  would lose the PID, so the slots are bound directly here.
  =========================================================================
}

unit stress_app;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}

{$ASMMODE Intel}   { the four fault injectors only }

interface

{ PE entry point. The loader looks for this symbol by name. }
procedure AppMain; cdecl; public name 'AppMain';

implementation

uses app_api, libc;

const
  { Counter layout shared by the master loop and the status line. }
  ST_FRAME = 0;
  ST_SENDS = 1;
  ST_RECVS = 2;
  ST_MEM   = 3;
  ST_SHM   = 4;
  ST_YLD   = 5;
  ST_SLP   = 6;
  ST_RST   = 7;
  ST_FLT   = 8;
  STAT_COUNT = 9;

  { Text frame limits, from UpdateDisplayCsharp. }
  FRAME_CAP = 500;
  FRAME_SIZE = 512;

  { Thread slots swept per frame. The NASM went to 64, not the 32 that
    GetProcessInfo is prepared for. }
  PID_SCAN = 64;

  { IPC receives attempted per frame. }
  RECV_PER_FRAME = 4;

  { xorshift32 seeds. Non-zero, or the PRNG collapses to zero forever. }
  PRNG_SEED = $00C0FFEE;

  { Keyboard backdrops. }
  CLEAR_COLOR   = $00110011;
  QUIT_COLOR    = $00111111;

  { Bare LF: Terminal_DrawCharUnsafe treats it as CR+LF. }
  LF = #10;

type
  { Only the first DWORD of ProcessInfo is ever read, and it is read for
    its position rather than its name - see the gate in the master loop. }
  PProcInfo = ^TProcInfo;
  TProcInfo = packed record
    ID:            Cardinal;
    UID:           Cardinal;
    GID:           Cardinal;
    Active:        Byte;
    IsJailed:      Byte;
    IsPhantomDead: Byte;
    HeapMemory:    QWord;
    Name:          array[0..15] of Byte;
    CpuTicks:      QWord;
    PhysPages:     Cardinal;
    VirtPages:     Cardinal;
  end;

var
  { Counters live at unit level so the status line and the master loop see
    the same storage without threading nine parameters through. }
  Stats: array[0..STAT_COUNT - 1] of Cardinal;

  { UI frame. The NASM put this on the stack; a static is equivalent and
    needs no manual frame teardown. }
  Frame: array[0..FRAME_SIZE - 1] of Word;
  FrameIdx: Integer = 0;

  { Destination for the shared-buffer syscall's second return value. }
  OutV: QWord = 0;

  { The NASM zeroed a second 8-byte slot here, next to OutV, on the
    invalid-syscall stage. Kept so the stack layout intent survives. }
  PokeSlot: QWord = 0;

  { ProcessInfo scratch. The NASM kept one on its own stack frame. }
  InfoBuf: TProcInfo;

  { IPC receive scratch. TMessage is 24 bytes; app_api's accessors own the
    layout, so the field is never needed. }
  MsgBuf: array[0..2] of QWord;

  { One-shot messages, widened once at startup. }
  MsgBye:   array[0..63] of Word;
  MsgFault: array[0..63] of Word;
  MsgDbz:   array[0..63] of Word;
  MsgGpf:   array[0..63] of Word;
  MsgIsr:   array[0..63] of Word;

{ ------------------------------------------------------------------ }
{ Fault injection                                                     }
{ ------------------------------------------------------------------ }

{ Write through a non-canonical-but-mapped-looking address to force a
  Ring-3 page fault. The address is the top of the lower half, well clear of
  anything a real mapping could own. }
procedure TriggerPageFault;
begin
  asm
    mov rax, $00007FFFFFFFF000
    mov byte [rax], $CC
  end;
end;

{ Integer divide by a zero divisor - exception vector 0. }
procedure TriggerDivideByZero;
begin
  asm
    xor eax, eax
    xor ecx, ecx
    div ecx
  end;
end;

{ LGDT is a privileged instruction; executing it from Ring 3 raises #GP. }
procedure TriggerGpf;
begin
  asm
    lgdt [rsp]
  end;
end;

{ Software interrupt through a vector the kernel installs a dummy handler
  for, exercising the IST/dummy-ISR path. }
procedure TriggerIsr;
begin
  asm
    int $82
  end;
end;

{ Replacement for ThrowHelpers.cs:CauseHalt. FPC generates no call to a
  throw helper under the flags in compile_pascal.sh, so nothing needs to
  consume this; it exists so the original behaviour - dereference null,
  then spin if the fault somehow did not take the thread down - is still
  available to call. }
procedure CauseHalt;
begin
  asm
    xor eax, eax
    mov byte [rax], 0
  end;
  while True do
    asm
      nop
    end;
end;

{ ------------------------------------------------------------------ }
{ Slot wrappers that app_api cannot express                             }
{ ------------------------------------------------------------------ }

{ app_api's App_GetThreadUID takes no parameter, but the delegate it was
  ported from is `delegate* unmanaged<uint, uint>` - the thread id goes in
  RCX (Syscall.cs ArchCtx.GetArg(ctx, 1)). Binding the slot directly keeps
  the id. }
function GetThreadUIDOf(tid: Cardinal): Cardinal;
type
  TFn = function(t: Cardinal): Cardinal; cdecl;
begin
  GetThreadUIDOf := TFn(AppApi_Slot(APP_SLOT_GET_THREAD_UID))(tid);
end;

function GetThreadGIDOf(tid: Cardinal): Cardinal;
type
  TFn = function(t: Cardinal): Cardinal; cdecl;
begin
  GetThreadGIDOf := TFn(AppApi_Slot(APP_SLOT_GET_THREAD_GID))(tid);
end;

{ ------------------------------------------------------------------ }
{ Text frame                                                          }
{ ------------------------------------------------------------------ }

procedure FillWide(dest: PWord; const s: AnsiString);
var
  i: Integer;
begin
  for i := 1 to Length(s) do
    dest[i - 1] := Word(Byte(s[i]));
  dest[Length(s)] := 0;
end;

procedure AppendChar(c: Word);
begin
  if FrameIdx < FRAME_CAP then
  begin
    Frame[FrameIdx] := c;
    Inc(FrameIdx);
  end;
end;

procedure AppendStr(const s: AnsiString);
var
  tmp: array[0..127] of Word;
begin
  FillWide(@tmp[0], s);
  StrAppend_Pas(@Frame[0], @tmp[0], @FrameIdx, FRAME_CAP);
end;

{ Eight hex digits, leading zeros included - the original AppendHex always
  emitted all eight. }
procedure AppendHex(v: Cardinal);
const
  Digits: array[0..15] of Word =
    (Ord('0'), Ord('1'), Ord('2'), Ord('3'), Ord('4'), Ord('5'), Ord('6'), Ord('7'),
     Ord('8'), Ord('9'), Ord('A'), Ord('B'), Ord('C'), Ord('D'), Ord('E'), Ord('F'));
var
  shift: Integer;
begin
  { FPC has no STEP on a for-to/downto loop, so this is spelled out. }
  shift := 28;
  while shift >= 0 do
  begin
    AppendChar(Digits[(v shr shift) and 15]);
    Dec(shift, 4);
  end;
end;

{ Build and show the whole status frame. Nine arguments, exactly as the
  NASM passed them: FPC's win64 cdecl puts the first four in RCX/RDX/R8/R9
  and the rest on the stack, which is the same machine code the NASM wrote
  by hand. }
procedure UpdateDisplay;
begin
  FrameIdx := 0;

  AppendStr('[STRESS TEST] Comprehensive OS Stability Test' + LF);
  AppendStr('[STRESS] ''q''=quit | ''f''=page fault | ''z''=div by zero | ''g''=GPF | ''i''=ISR test' + LF);

  AppendStr('[STATS] F=');        AppendHex(Stats[ST_FRAME]);
  AppendStr(' IPCS=');            AppendHex(Stats[ST_SENDS]);
  AppendStr(' IPCR=');            AppendHex(Stats[ST_RECVS]);
  AppendStr(' MEM=');             AppendHex(Stats[ST_MEM]);
  AppendStr(' SHM=');             AppendHex(Stats[ST_SHM]);
  AppendStr(LF + '[STATS] YLD='); AppendHex(Stats[ST_YLD]);
  AppendStr(' SLP=');             AppendHex(Stats[ST_SLP]);
  AppendStr(' RST=');             AppendHex(Stats[ST_RST]);
  AppendStr(' FLT=');             AppendHex(Stats[ST_FLT]);
  AppendStr(LF);

  AppendStr(LF + '[LEGEND] F=Frames | IPCS=IPC Sends | IPCR=IPC Receives | MEM=Memory Allocs' + LF);
  AppendStr('         SHM=Shared Mem | YLD=Yields | SLP=Sleeps | RST=Resets | FLT=Faults' + LF);

  { FrameIdx is capped at FRAME_CAP, so this stays in range. }
  Frame[FrameIdx] := 0;

  App_ResetCursor;
  App_Print(@Frame[0]);
end;

{ ------------------------------------------------------------------ }
{ The four cascade stages - one per NASM label                        }
{ ------------------------------------------------------------------ }

{ .trigger_fault. The fault counter is bumped only here, exactly as the NASM
  did - the other three stages never touched it. }
procedure StageFault;
begin
  App_Print(@MsgFault[0]);
  Inc(Stats[ST_FLT]);
  TriggerPageFault;
end;

{ .trigger_dbz }
procedure StageDbz;
begin
  App_Print(@MsgDbz[0]);
  TriggerDivideByZero;
end;

{ .trigger_gpf }
procedure StageGpf;
begin
  App_Print(@MsgGpf[0]);
  TriggerGpf;
end;

{ .trigger_isr }
procedure StageIsr;
begin
  App_Print(@MsgIsr[0]);
  TriggerIsr;
end;

{ ------------------------------------------------------------------ }
{ Master loop                                                         }
{ ------------------------------------------------------------------ }

var
  Tick: Cardinal = PRNG_SEED;
  Rand: Cardinal = PRNG_SEED;

function Xorshift32(x: Cardinal): Cardinal; inline;
begin
  x := x xor (x shl 13);
  x := x xor (x shr 17);
  x := x xor (x shl 5);
  Xorshift32 := x;
end;

{ The status line refreshes on the 16th frame and every 16th after that. }
procedure MaybeUpdateDisplay;
begin
  if (Stats[ST_FRAME] and 15) = 0 then
    UpdateDisplay;
end;

{ One pass of the sleep stage, which is where every key press lands. }
procedure SleepStage;
begin
  if (Tick and 7) = 0 then
  begin
    App_Sleep(1);
    Inc(Stats[ST_SLP]);
  end
  else
    App_Sleep(0);
end;

procedure TerminateTest;
begin
  App_Clear(QUIT_COLOR);
  App_Print(@MsgBye[0]);
  App_Exit;
  while True do App_WaitIPC;
end;

{ Dispatch one key. See the module header: the stages chain, they do not
  return to the key switch. }
procedure HandleKey(c: Word);
begin
  case Chr(c) of
    'q', 'Q':
      TerminateTest;

    'f', 'F':
      begin
        StageFault;
        StageDbz;
        StageGpf;
        StageIsr;
      end;

    'z', 'Z':
      begin
        StageDbz;
        StageGpf;
        StageIsr;
      end;

    'g', 'G':
      begin
        StageGpf;
        StageIsr;
      end;

    'i', 'I':
      StageIsr;
  end;
end;

{ ---- stage 1: process and IPC sweep over the thread table ---- }
procedure ProcessAndIpcStage;
var
  pid: Cardinal;
  gate: Cardinal;
  p: Pointer;
begin
  pid := 0;
  while pid < PID_SCAN do
  begin
    p := @InfoBuf;
    if App_GetProcessInfo(pid, p) = 1 then
    begin
      { THE NASM GATE. It loaded the first DWORD of ProcessInfo believing
        it was Active; the first field is actually ID. So this is really
        "stress PIDs 1 and 2", not "stress every running thread".
        Reproduced as-is - changing the field changes what the test covers. }
      gate := InfoBuf.ID;
      if (gate = 1) or (gate = 2) then
      begin
        if (Rand and 15) = 0 then
        begin
          App_SendIPC(pid, Rand and $FF, Rand);
          Inc(Stats[ST_SENDS]);
        end;

        { Reached whether or not the send above fired - the NASM had no
          jump around it. }
        if (Rand and 31) = 0 then
        begin
          GetThreadUIDOf(pid);
          GetThreadGIDOf(pid);
        end;
      end;
    end;

    Rand := Xorshift32(Rand);
    Inc(pid);
  end;
end;

{ ---- stage 2: drain whatever IPC is waiting ---- }
procedure IpcReceiveStage;
var
  k: Integer;
begin
  for k := 1 to RECV_PER_FRAME do
  begin
    App_ReceiveIPC(@MsgBuf[0]);
    Inc(Stats[ST_RECVS]);
  end;
end;

{ ---- stage 3: page allocation ---- }
procedure MemoryAllocStage;
var
  p: Pointer;
begin
  if (Tick and 255) = 0 then
  begin
    p := Pointer(App_AllocMem(1));
    if p <> nil then
    begin
      Inc(Stats[ST_MEM]);
      PByte(p)^ := Byte(Rand and $FF);
    end;
  end;
end;

{ ---- stage 4: shared-buffer mapping, then scribble over the head ---- }
procedure SharedBufferStage;
var
  v: QWord;
  vByte: PByte;
  k: Integer;
begin
  if (Tick and 127) = 0 then
  begin
    OutV := 0;
    v := App_CreateSharedBuffer(0, 1, OutV);
    if v <> 0 then
    begin
      Inc(Stats[ST_SHM]);
      vByte := PByte(Pointer(v));
      { The NASM filled bytes 0..15 downward from index 16. }
      for k := 16 downto 1 do
        vByte[k - 1] := Byte(Rand and $FF);
    end;
  end;
end;

{ ---- stage 5: hand the kernel pointers it must reject ---- }
procedure InvalidSyscallStage;
var
  nilPtr: Pointer;
begin
  if (Tick and 1023) = 0 then
  begin
    nilPtr := nil;
    App_ReceiveIPC(nilPtr);
    App_GetProcessInfo(0, nilPtr);
    PokeSlot := 0;
  end;
end;

{ ---- stage 6: cursor reset ---- }
procedure TerminalOpsStage;
begin
  if (Tick and 255) = 0 then
  begin
    App_ResetCursor;
    Inc(Stats[ST_RST]);
  end;
end;

{ ---- stage 7: voluntary yield ---- }
procedure YieldStage;
begin
  if (Tick and 127) = 0 then
  begin
    App_Yield;
    Inc(Stats[ST_YLD]);
  end;
end;

{ ------------------------------------------------------------------ }

procedure AppMain; cdecl;
var
  c: Word;
begin
  AppApi_Init;

  FillWide(@MsgBye[0],   '[STRESS] Test terminated' + LF);
  FillWide(@MsgFault[0], '[STRESS] Triggering Ring3 fault' + LF);
  FillWide(@MsgDbz[0],   '[STRESS] Triggering Ring3 Divide by Zero' + LF);
  FillWide(@MsgGpf[0],   '[STRESS] Triggering Ring3 GPF (General Protection Fault)' + LF);
  FillWide(@MsgIsr[0],   '[STRESS] Triggering Dummy ISR (int 0x82)' + LF);

  App_Clear(CLEAR_COLOR);

  while True do
  begin
    Inc(Stats[ST_FRAME]);

    Tick := Xorshift32(Tick);
    Rand := Xorshift32(Rand);

    ProcessAndIpcStage;
    IpcReceiveStage;
    MemoryAllocStage;
    SharedBufferStage;
    InvalidSyscallStage;
    TerminalOpsStage;
    YieldStage;
    MaybeUpdateDisplay;

    { Key poll. The C# declared the return as byte; the kernel puts a full
      char in RAX, so mask to 8 bits to keep the old comparison semantics. }
    c := App_GetChar and $FF;
    HandleKey(c);

    SleepStage;
  end;
end;

end.
