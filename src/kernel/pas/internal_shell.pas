{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: InternalShell - Syscall 88 Command Parser
  PURPOSE: Parses kernel builtin commands and returns action enum.
           C# shim executes the actions (FAT16, PELoader, etc.).
  =========================================================================
}
unit internal_shell;

{$mode objfpc}
{$h+}
{$inline on}
{$TYPEINFO OFF}
{$PACKRECORDS C}

interface

uses libc;

  { Parsed command result - use simple types, no record }
  { Action: Byte; Arg: PWord; ArgLen: Word }

{ Initialize - no-op for now }
procedure InternalShell_SetSchedulerState(threads: Pointer; threadCount: Integer;
  currentThreadIdPtr: PInteger; foregroundTaskPtr: PInteger; systemTicksPtr: PQWord); cdecl;
  public name 'InternalShell_SetSchedulerState';

{ Parse command string into action + argument }
function InternalShell_ParseCommand_Pas(cmdStr: PWord; outAction: PByte; outArg: PWord; outArgLen: PWord): Byte; cdecl;
  public name 'InternalShell_ParseCommand_Pas';

{ Execute the command in the NUL-terminated user string at ctx arg 1 (syscall 88).
  Sets the syscall return (1 handled, 0 refused) and returns 0; the dispatcher
  must ignore the value (it is not an RSP). }
function InternalShell_Dispatch(id: Integer; currentTicks: QWord; isKing: Boolean;
  ctx: PQWord): QWord;

implementation

uses arch_interface, console, kstring, heap, pmm, scheduler, syscall_security,
  syscall_impl, syscall_core, arch_hal, fat16_kernel, pe_loader, power, pci, terminal;

{ TShellAction lives here, not in the interface: an enum reachable from the
  interface makes FPC emit RTTI that lld cannot resolve (AGENTS.md §6.3b).
  It is private to this unit; callers receive the action as a Byte. }
type
  { Command action types returned by parser }
  TShellAction = (
    SA_NONE = 0,
    SA_CLEAR = 1,
    SA_HELP = 2,
    SA_MEM = 3,
    SA_UPTIME = 4,
    SA_PCI = 5,
    SA_DATE = 6,
    SA_POWEROFF = 7,
    SA_REBOOT = 8,
    SA_UNAME = 9,
    SA_CAT = 10,
    SA_RUN = 11,
    SA_DAEMON = 12,
    SA_LOGOUT = 13,
    SA_UNKNOWN = 255
  );

{ Initialize - no-op }
procedure InternalShell_SetSchedulerState(threads: Pointer; threadCount: Integer;
  currentThreadIdPtr: PInteger; foregroundTaskPtr: PInteger; systemTicksPtr: PQWord); cdecl;
begin
  { State no longer needed in parser }
end;

{ Compare wide string against fixed wide string }
function StrCmpWide(s1, s2: PWord): Boolean; inline;
var
  i: Integer;
begin
  StrCmpWide := False;
  if (s1 = nil) or (s2 = nil) then Exit;
  i := 0;
  while (s1[i] <> 0) and (s2[i] <> 0) do
  begin
    if s1[i] <> s2[i] then Exit;
    Inc(i);
  end;
  StrCmpWide := (s1[i] = 0) and (s2[i] = 0);
end;

{ Check if wide string starts with prefix }
function StrStartsWithWide(str, prefix: PWord): Boolean; inline;
var
  i: Integer;
begin
  StrStartsWithWide := False;
  if (str = nil) or (prefix = nil) then Exit;
  i := 0;
  while prefix[i] <> 0 do
  begin
    if str[i] <> prefix[i] then Exit;
    Inc(i);
  end;
  StrStartsWithWide := True;
end;

{ Copy wide string argument }
procedure CopyWideArg(src: PWord; dest: PWord; var destLen: Word; maxLen: Word); inline;
var
  i: Word;
begin
  destLen := 0;
  if src = nil then Exit;
  i := 0;
  while (src[i] <> 0) and (i < maxLen) do
  begin
    dest[i] := src[i];
    Inc(i);
  end;
  destLen := i;
end;

{ Builtin command strings (wide char) }
const
  CMD_CLEAR    : array[0..5] of Word = (Ord('c'), Ord('l'), Ord('e'), Ord('a'), Ord('r'), 0);
  CMD_HELP     : array[0..4] of Word = (Ord('h'), Ord('e'), Ord('l'), Ord('p'), 0);
  CMD_MEM      : array[0..3] of Word = (Ord('m'), Ord('e'), Ord('m'), 0);
  CMD_UPTIME   : array[0..5] of Word = (Ord('u'), Ord('p'), Ord('t'), Ord('i'), Ord('m'), Ord('e'));
  CMD_PCI      : array[0..3] of Word = (Ord('p'), Ord('c'), Ord('i'), 0);
  CMD_DATE     : array[0..4] of Word = (Ord('d'), Ord('a'), Ord('t'), Ord('e'), 0);
  CMD_UNAME    : array[0..5] of Word = (Ord('u'), Ord('n'), Ord('a'), Ord('m'), Ord('e'), 0);
  CMD_RUN      : array[0..4] of Word = (Ord('r'), Ord('u'), Ord('n'), Ord(' '), 0);
  CMD_DAEMON   : array[0..6] of Word = (Ord('d'), Ord('a'), Ord('e'), Ord('m'), Ord('o'), Ord('n'), Ord(' '));
  CMD_POWEROFF : array[0..8] of Word = (Ord('s'), Ord('h'), Ord('u'), Ord('t'), Ord('d'), Ord('o'), Ord('w'), Ord('n'), 0);
  CMD_LOGOUT   : array[0..6] of Word = (Ord('l'), Ord('o'), Ord('g'), Ord('o'), Ord('u'), Ord('t'), 0);
  CMD_REBOOT   : array[0..6] of Word = (Ord('r'), Ord('e'), Ord('b'), Ord('o'), Ord('o'), Ord('t'), 0);
  CMD_CAT      : array[0..4] of Word = (Ord('c'), Ord('a'), Ord('t'), Ord(' '), 0);

{ Parse command string - outputs via pointer parameters to avoid record RTTI }
function InternalShell_ParseCommand_Pas(cmdStr: PWord; outAction: PByte; outArg: PWord; outArgLen: PWord): Byte; cdecl;
var
  action: TShellAction;
  argLen: Word;
begin
  InternalShell_ParseCommand_Pas := 0;
  if (cmdStr = nil) or (outAction = nil) or (outArg = nil) or (outArgLen = nil) then Exit;

  argLen := 0;
  action := SA_NONE;

  if StrCmpWide(cmdStr, @CMD_CLEAR) then
  begin
    action := SA_CLEAR;
  end
  else if StrCmpWide(cmdStr, @CMD_HELP) then
  begin
    action := SA_HELP;
  end
  else if StrCmpWide(cmdStr, @CMD_MEM) then
  begin
    action := SA_MEM;
  end
  else if StrCmpWide(cmdStr, @CMD_UPTIME) then
  begin
    action := SA_UPTIME;
  end
  else if StrCmpWide(cmdStr, @CMD_PCI) then
  begin
    action := SA_PCI;
  end
  else if StrCmpWide(cmdStr, @CMD_DATE) then
  begin
    action := SA_DATE;
  end
  else if StrCmpWide(cmdStr, @CMD_POWEROFF) then
  begin
    action := SA_POWEROFF;
  end
  else if StrCmpWide(cmdStr, @CMD_REBOOT) then
  begin
    action := SA_REBOOT;
  end
  else if StrCmpWide(cmdStr, @CMD_UNAME) then
  begin
    action := SA_UNAME;
  end
  else if StrStartsWithWide(cmdStr, @CMD_CAT) then
  begin
    action := SA_CAT;
    CopyWideArg(cmdStr + 4, outArg, argLen, 255);
  end
  else if StrStartsWithWide(cmdStr, @CMD_RUN) then
  begin
    action := SA_RUN;
    CopyWideArg(cmdStr + 4, outArg, argLen, 255);
  end
  else if StrStartsWithWide(cmdStr, @CMD_DAEMON) then
  begin
    action := SA_DAEMON;
    CopyWideArg(cmdStr + 7, outArg, argLen, 255);
  end
  else if StrCmpWide(cmdStr, @CMD_LOGOUT) then
  begin
    action := SA_LOGOUT;
  end
  else
  begin
    action := SA_UNKNOWN;
    { Copy whole command as argument for error display }
    CopyWideArg(cmdStr, outArg, argLen, 255);
  end;

  outAction^ := Byte(action);
  outArgLen^ := argLen;
  InternalShell_ParseCommand_Pas := 1;
end;

{ ========================================================================
  Execution of parsed commands (ported from InternalShell.cs)
  ======================================================================== }

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

procedure Say(const msg: AnsiString);
begin
  Con_Print(W(msg));
end;

procedure SayRed(const msg: AnsiString);
begin
  Con_SetColor($00FF0000);
  Con_Print(W(msg));
end;

procedure PrintArg(arg: PWord; len: Word);
var
  i: Word;
begin
  i := 0;
  while i < len do
  begin
    if arg[i] = 0 then Break;
    Con_DrawChar(arg[i]);
    Inc(i);
  end;
end;

procedure HandleCat(arg: PWord; argLen: Word);
var
  fSize, i: Cardinal;
  fBuf: PByte;
  c: Word;
begin
  if (argLen = 0) or (arg[0] = 0) then Exit;
  fSize := 0;
  fBuf := Fat16K_ReadFile(arg, @fSize, -1);
  if fBuf = nil then
  begin
    SayRed('[!] cat: File not found on FAT16.'#13#10);
    Exit;
  end;

  if fSize > 16384 then
    SayRed('[!] File too large (>16KB). Refusing to print to prevent Terminal freeze.'#13#10)
  else
  begin
    Con_SetColor($00FFFFFF);
    for i := 0 to fSize - 1 do
    begin
      c := fBuf[i];
      if c = 13 then Continue;
      if IsPrintableChar(c) <> 0 then Con_DrawChar(c)
      else Con_DrawChar(Ord('.'));
    end;
    Say(#13#10);
  end;
  Heap_Free(fBuf);
end;

procedure HandleRunOrDaemon(id: Integer; arg: PWord; argLen: Word; isDaemon: Boolean; ctx: PQWord);
var
  fileSize: Cardinal;
  rawData: PByte;
  isJailed: Boolean;
begin
  if (argLen = 0) or (arg[0] = 0) then
  begin
    Ctx_SetRet(ctx, 0);
    Exit;
  end;

  fileSize := 0;
  Arch_EnableInterrupts;
  rawData := Fat16K_ReadFile(arg, @fileSize, id);

  if rawData = nil then
  begin
    SayRed('[!] Kernel: Execute failed! File not found or OOM: ');
    Con_Print(arg);
    Say(#13#10);
    Exit;
  end;

  if (rawData[0] <> Ord('M')) or (rawData[1] <> Ord('Z')) then
  begin
    SayRed('[!] Kernel FATAL: Corrupted PE Header!'#13#10);
    Heap_Free(rawData);
    Ctx_SetRet(ctx, 0);
    Exit;
  end;

  Con_SetColor($00FFFF00);
  isJailed := (Sched_GetThreadUID(id) <> 0) or (Sched_GetThreadGID(id) <> 0);
  if isJailed then
  begin
    Con_SetColor($00FF00FF);
    Say('[!] ZERO TRUST: Untrusted App detected! Jailing in Phantom Sandbox...'#13#10);
  end;

  PELoader_LoadAndRun(rawData, isDaemon, isJailed, False, arg, 1);

  if isDaemon then Con_SetColor($0000FF00);
end;

procedure HandleLogout(id: Integer; ctx: PQWord);
var
  currentUid, fileSize: Cardinal;
  rawData: PByte;
  irq: Boolean;
  i: Integer;
begin
  currentUid := Sched_GetThreadUID(id);
  Con_SetColor($00FFFF00);
  Say(#13#10'[*] Saving session... Logging out...'#13#10);

  fileSize := 0;
  Arch_EnableInterrupts;

  { Reload the login program from the volume root. (The C# port of this
    handler read ETC/PASSWD here and then tested it for an MZ header, which
    could never succeed; it was a botched edit of the original, which read
    syslogon.exe.) }
  Fat16K_Cd(W(''), -1);
  rawData := Fat16K_ReadFile(W('syslogon.exe'), @fileSize, id);
  if (rawData <> nil) and (rawData[0] = Ord('M')) and (rawData[1] = Ord('Z')) then
    PELoader_LoadAndRun(rawData, False, False, True, W('syslogon.exe'), 1)
  else
  begin
    SayRed('[!] FATAL: Cannot find syslogon.exe! System Halt!'#13#10);
    if rawData <> nil then Heap_Free(rawData);
    while True do Arch_Halt;
  end;

  if currentUid <> 0 then
  begin
    { Take down everything the logging-out user still has running. }
    irq := Sched_AcquireSchedLockSafe;
    for i := 1 to Sched_GetThreadCount - 1 do
      if (i <> id) and (Sched_GetThreadActive(i) = 1) and (Sched_GetThreadUID(i) = currentUid) then
      begin
        Sched_SetThreadActive(i, 0);
        Sched_SetThreadUID(i, 9999);
      end;
    Sched_ReleaseSchedLockSafe(irq);
  end;
  Sched_TerminateCurrentTask;
end;

function InternalShell_Dispatch(id: Integer; currentTicks: QWord; isKing: Boolean;
  ctx: PQWord): QWord;
var
  cmdPtr: QWord;
  action: Byte;
  argLen: Word;
  arg: array[0..255] of Word;
  isDaemon: Boolean;
  totalSeconds, ms: QWord;
begin
  InternalShell_Dispatch := 0;

  cmdPtr := Ctx_GetArg(ctx, 1);
  if (cmdPtr = 0) or (not UserPtrOk(cmdPtr)) then
  begin
    Ctx_SetRet(ctx, 0);
    Exit;
  end;

  action := 0;
  argLen := 0;
  if InternalShell_ParseCommand_Pas(PWord(cmdPtr), @action, @arg[0], @argLen) = 0 then
  begin
    Ctx_SetRet(ctx, 0);
    Exit;
  end;

  case TShellAction(action) of
    SA_CLEAR:
      Con_Clear($00111111);
    SA_HELP:
      Say('NekkoOS Microkernel'#13#10'Commands: clear, help, mem, uptime, pci, date, uname, run, daemon, ls, cat, cd, write'#13#10);
    SA_MEM:
      begin
        Say('Free memory:'#9#9);
        Con_PrintHex(PMM_GetFreePages * 4096 div (1024 * 1024));
        Say(' MB'#13#10);
      end;
    SA_UPTIME:
      begin
        { currentTicks counts timer ticks, not milliseconds. }
        ms := currentTicks * 1000 div Hal_TickFrequency;
        totalSeconds := ms div 1000;
        ms := ms mod 1000;
        Say('System Uptime: ');
        Con_PrintHex(totalSeconds);
        Say(' seconds, ');
        Con_PrintHex(ms);
        Say(' ms'#13#10#13#10);
      end;
    SA_PCI:
      Pci_ScanBus;
    SA_DATE:
      Hal_PrintWallClock;
    SA_POWEROFF:
      if isKing then Power_Shutdown
      else SayRed('[!] Permission Denied: Only Root can shutdown the system!'#13#10);
    SA_REBOOT:
      if isKing then Power_Reboot
      else SayRed('[!] Permission Denied: Only Root can reboot the system!'#13#10);
    SA_UNAME:
      Say('NekkoOS Microkernel x86_64'#13#10);
    SA_CAT:
      HandleCat(@arg[0], argLen);
    SA_RUN, SA_DAEMON:
      begin
        isDaemon := TShellAction(action) = SA_DAEMON;
        if (not isKing) and isDaemon then
        begin
          SayRed('[!] Permission Denied: Only Root can spawn Daemons!'#13#10);
          Con_SetColor($00FFFFFF);
          Ctx_SetRet(ctx, 0);
          Exit;
        end;
        HandleRunOrDaemon(id, @arg[0], argLen, isDaemon, ctx);
      end;
    SA_LOGOUT:
      HandleLogout(id, ctx);
  else
    begin
      SayRed('Kernel: Unknown Command or handled by Ring 3: ');
      PrintArg(@arg[0], argLen);
      Say(#13#10);
    end;
  end;

  Con_SetColor($00FFFFFF);
  Ctx_SetRet(ctx, 1);
end;

function InternalShell_Dispatch_Pas(id: Integer; currentTicks: QWord; isKing: Byte;
  ctx: PQWord): QWord; cdecl; public name 'InternalShell_Dispatch_Pas';
begin
  InternalShell_Dispatch_Pas := InternalShell_Dispatch(id, currentTicks, isKing <> 0, ctx);
end;

end.
