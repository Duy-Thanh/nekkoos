{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: app_api (ARM64) - the user API with the same interface as
  src/apps/app_api.pas, so the Ring-3 apps compile unchanged for EL0.

  x86 reaches the kernel through vDSO stubs found via a patched table; here
  every slot is a small cdecl function that issues `svc` through the crt0
  trampoline. AppApi_Slot returns those functions, so apps that call a slot
  through a function pointer (fat16_app, stress_app) work too.

  Register mapping (traps_arm64 / syscall_dispatch): number x8, argument i
  in x_i. Syscalls 90-93 read argument 0, so their parameter goes in x0.
  There are no I/O ports on ARM64: the port helpers read 0 and write nothing.
  =========================================================================
}
unit app_api;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}

interface

const
  { Slot indices into the vDSO table. Named so call sites read like the C# did. }
  APP_SLOT_PRINT                 = 0;
  APP_SLOT_EXIT                  = 1;
  APP_SLOT_SEND_IPC              = 2;
  APP_SLOT_ALLOC_MEM             = 3;
  APP_SLOT_GRANT_PORT            = 4;
  APP_SLOT_RECEIVE_IPC           = 5;
  APP_SLOT_GET_SHARED_MEM        = 6;
  APP_SLOT_GET_CHAR              = 7;
  APP_SLOT_RUN_CMD               = 8;
  APP_SLOT_GET_THREAD_UID        = 9;
  APP_SLOT_SET_UID               = 10;
  APP_SLOT_GET_UID               = 11;
  APP_SLOT_YIELD                 = 12;
  APP_SLOT_WAIT_IPC              = 13;
  APP_SLOT_GET_THREAD_GID        = 14;
  APP_SLOT_SET_GID               = 15;
  APP_SLOT_GET_PROCESS_INFO      = 16;
  APP_SLOT_CLEAR                 = 17;
  APP_SLOT_SLEEP                 = 18;
  APP_SLOT_GET_UPTIME            = 19;
  APP_SLOT_GET_RSDP              = 20;
  APP_SLOT_MAP_PHYS              = 21;
  APP_SLOT_REPORT_HARDWARE       = 22;
  APP_SLOT_GET_PID_BY_NAME       = 23;
  APP_SLOT_RESET_CURSOR          = 24;
  APP_SLOT_REQUEST_FRAMEBUFFER   = 25;
  APP_SLOT_GET_SCREEN_INFO       = 26;
  APP_SLOT_CREATE_SHARED_BUFFER  = 27;
  APP_SLOT_REDIRECT_TERMINAL     = 28;
  APP_SLOT_IN_BYTE               = 29;
  APP_SLOT_OUT_BYTE              = 30;
  APP_SLOT_IN_WORD               = 31;
  APP_SLOT_OUT_WORD              = 32;
  APP_SLOT_OUT_DWORD             = 33;
  APP_SLOT_ACQUIRE_ATA_HW        = 34;
  APP_SLOT_RELEASE_ATA_HW        = 35;
  APP_SLOT_SUDO_RUN              = 36;

  { TMessage and TProcessInfo are deliberately NOT exposed here. A record
    reachable from the interface makes FPC emit RTTI for it and for its field
    types, and lld then fails on
      undefined symbol: RTTI_$SYSTEM_$$_LONGWORD$indirect
    which is exactly the trap documented in AGENTS.md §6.3b. The layouts live
    in the implementation section; callers pass a raw Pointer and read the
    fields through the accessors below, which keeps the layout in one place
    and the link clean. }

{ Resolve the vDSO. MUST be the first call in every app. Idempotent. }
procedure AppApi_Init;

{ Address of the stub for a slot, or nil if the slot is out of range. }
function AppApi_Slot(index: Cardinal): Pointer;

{ Convenience wrappers matching the C# delegate* signatures. These are
  declared with plain types rather than procedural types on purpose: a
  procedural type is fine under TYPEINFO OFF, but casting a raw address to
  one at every call site is noisier than a wrapper. }
procedure App_Print(msg: PWord);
procedure App_Exit;
procedure App_SendIPC(destPid, msgType: Cardinal; payload: QWord);
function  App_AllocMem(size: QWord): QWord;
procedure App_GrantPort(port: Word);
function  App_ReceiveIPC(msg: Pointer): LongInt;
function  App_GetSharedMem: QWord;
function  App_GetChar: Word;
procedure App_RunCmd(name: PWord; arg: QWord);
function  App_GetThreadUID(targetTid: Cardinal): Cardinal;
procedure App_SetUID(uid: Cardinal);
function  App_GetUID: Cardinal;
procedure App_Yield;
procedure App_WaitIPC;
function  App_GetThreadGID(targetTid: Cardinal): Cardinal;
procedure App_SetGID(gid: Cardinal);
{ Fill a process record (55 bytes, read it with App_Proc*) for thread `tid`.
  `info` names the buffer: pass a pointer to your own record, or nil to use a
  buffer inside app_api (overwritten by the next call). On success (1) `info`
  points at the filled record. The kernel writes the record WHERE info points;
  this wrapper used to pass the address of the `info` variable itself, so the
  kernel wrote 55 bytes over an 8-byte pointer on the caller's stack and
  top.exe died with a GPF on return. }
function  App_GetProcessInfo(tid: Cardinal; var info: Pointer): LongInt;
procedure App_Clear(color: Cardinal);
procedure App_Sleep(ms: QWord);
function  App_GetUptime: QWord;
function  App_GetRsdp: QWord;
function  App_MapPhys(phys, size: QWord): QWord;
procedure App_ReportHardware(tid: Cardinal; a, b: QWord);
function  App_GetPIDByName(name: PWord): LongInt;
procedure App_ResetCursor;
function  App_RequestFramebuffer: QWord;
function  App_GetScreenInfo(out w, h, ppsl: QWord): LongInt;
{ Create a shared buffer owned by destPid (0 = the caller's own).
  Args: destPid in RCX, page count in RDX, out-pointer in R8. The kernel
  returns the caller's address in RAX and the TARGET's address in RBX. }
function  App_CreateSharedBuffer(destPid: Cardinal; numPages: QWord;
  out targetVAddr: QWord): QWord;
{ Run a command as another user. Args: appName, password, optional content
  buffer and its length. Slot 36. }
function  App_SudoRun(appName, password: PWord; content: PByte; contentLen: QWord): QWord;
{ Syscall 52: point the kernel console at another framebuffer (root only).
  The kernel reads (framebuffer, width, height, scanline); the old wrapper took
  a thread id, which matched nothing. No app calls it yet. }
procedure App_RedirectTerminal(newFb: QWord; w, h, scanLine: Cardinal);
function  App_InByte(port: Word): Word;
procedure App_OutByte(port: Word; value: Word);
function  App_InWord(port: Word): Word;
procedure App_OutWord(port: Word; value: Word);
procedure App_OutDword(port: Word; value: Cardinal);
procedure App_AcquireAtaHw;
procedure App_ReleaseAtaHw;

{ Field accessors for the private records. A pointer of nil yields a zero /
  no-op, so callers do not need to bounds-check. }
function App_MsgType(p: Pointer): Cardinal;
function App_MsgSender(p: Pointer): Cardinal;
function App_MsgReceiver(p: Pointer): Cardinal;
function App_MsgPayload(p: Pointer): QWord;
procedure App_MsgPayloadSet(p: Pointer; v: QWord);

function App_ProcID(p: Pointer): Cardinal;
function App_ProcUID(p: Pointer): Cardinal;
function App_ProcGID(p: Pointer): Cardinal;
function App_ProcActive(p: Pointer): Byte;
function App_ProcHeap(p: Pointer): QWord;
function App_ProcCpuTicks(p: Pointer): QWord;
function App_ProcPhysPages(p: Pointer): Cardinal;
function App_ProcVirtPages(p: Pointer): Cardinal;
function App_ProcName(p: Pointer; dest: PWord; destChars: Integer): Integer;

implementation

function Sys(n, a1, a2, a3, a4: QWord): QWord; cdecl; external name 'uapi_sys';
function Sys2(n, a1, a2, a3: QWord; out2: PQWord): QWord; cdecl; external name 'uapi_sys2';
{ Syscall whose argument is read from argument 0 (x0). }
function Sys0(n, a0: QWord): QWord; cdecl; external name 'uapi_sys0';

{ --- Record layouts, implementation only (see the note in the interface) ---
  These mirror the kernel's C# originals byte for byte. TMessage is 24 bytes
  (4+4+4+4+8). }
type
  PMessage = ^TMessage;
  TMessage = packed record
    { 'Type' is a reserved word in Pascal, hence MsgType. The ABI is the
      position and width, not the name. }
    MsgType:  Cardinal;
    Sender:   Cardinal;
    Receiver: Cardinal;
    Padding:  Cardinal;
    Payload:  QWord;
  end;

  PProcessInfo = ^TProcessInfo;
  TProcessInfo = packed record
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

{ --- TMessage field accessors --- }
function App_MsgType(p: Pointer): Cardinal; inline;
begin if p = nil then exit; App_MsgType := PMessage(p)^.MsgType; end;

function App_MsgSender(p: Pointer): Cardinal; inline;
begin if p = nil then exit; App_MsgSender := PMessage(p)^.Sender; end;

function App_MsgReceiver(p: Pointer): Cardinal; inline;
begin if p = nil then exit; App_MsgReceiver := PMessage(p)^.Receiver; end;

function App_MsgPayload(p: Pointer): QWord; inline;
begin if p = nil then exit; App_MsgPayload := PMessage(p)^.Payload; end;

procedure App_MsgPayloadSet(p: Pointer; v: QWord); inline;
begin if p = nil then exit; PMessage(p)^.Payload := v; end;

{ --- TProcessInfo field accessors --- }
function App_ProcID(p: Pointer): Cardinal; inline;
begin if p = nil then exit; App_ProcID := PProcessInfo(p)^.ID; end;

function App_ProcUID(p: Pointer): Cardinal; inline;
begin if p = nil then exit; App_ProcUID := PProcessInfo(p)^.UID; end;

function App_ProcGID(p: Pointer): Cardinal; inline;
begin if p = nil then exit; App_ProcGID := PProcessInfo(p)^.GID; end;

function App_ProcActive(p: Pointer): Byte; inline;
begin if p = nil then exit; App_ProcActive := PProcessInfo(p)^.Active; end;

function App_ProcIsJailed(p: Pointer): Byte; inline;
begin if p = nil then exit; App_ProcIsJailed := PProcessInfo(p)^.IsJailed; end;

function App_ProcIsPhantomDead(p: Pointer): Byte; inline;
begin if p = nil then exit; App_ProcIsPhantomDead := PProcessInfo(p)^.IsPhantomDead; end;

function App_ProcHeap(p: Pointer): QWord; inline;
begin if p = nil then exit; App_ProcHeap := PProcessInfo(p)^.HeapMemory; end;

function App_ProcCpuTicks(p: Pointer): QWord; inline;
begin if p = nil then exit; App_ProcCpuTicks := PProcessInfo(p)^.CpuTicks; end;

function App_ProcPhysPages(p: Pointer): Cardinal; inline;
begin if p = nil then exit; App_ProcPhysPages := PProcessInfo(p)^.PhysPages; end;

function App_ProcVirtPages(p: Pointer): Cardinal; inline;
begin if p = nil then exit; App_ProcVirtPages := PProcessInfo(p)^.VirtPages; end;

{ Process name as a NUL-terminated UTF-16 string, copied into the caller's
  buffer because the record is private. Returns bytes copied. }
function App_ProcName(p: Pointer; dest: PWord; destChars: Integer): Integer;
var
  src: PProcessInfo;
  i: Integer;
begin
  App_ProcName := 0;
  if (p = nil) or (dest = nil) or (destChars <= 0) then Exit;
  src := PProcessInfo(p);
  i := 0;
  while (i < 16) and (i < destChars - 1) do
  begin
    dest[i] := Word(src^.Name[i]);
    if src^.Name[i] = 0 then
    begin
      Inc(i);
      Break;
    end;
    Inc(i);
  end;
  dest[i] := 0;
  App_ProcName := i;
end;


{ ── Slot functions (cdecl, same shapes as the x86 vDSO stubs) ────────────── }

procedure S_Print(m: PWord); cdecl;                 begin Sys(1, QWord(m), 0, 0, 0); end;
procedure S_Exit; cdecl;                            begin Sys(0, 0, 0, 0, 0); end;
procedure S_SendIPC(d, t: Cardinal; p: QWord); cdecl; begin Sys(5, d, t, p, 0); end;
function  S_AllocMem(s: QWord): QWord; cdecl;       begin S_AllocMem := Sys(6, s, 0, 0, 0); end;
procedure S_GrantPort(p: Word); cdecl;              begin Sys(7, p, 0, 0, 0); end;
function  S_ReceiveIPC(m: Pointer): LongInt; cdecl; begin S_ReceiveIPC := LongInt(Sys(8, QWord(m), 0, 0, 0)); end;
function  S_GetSharedMem: QWord; cdecl;             begin S_GetSharedMem := Sys(99, 0, 0, 0, 0); end;
function  S_GetChar: Word; cdecl;                   begin S_GetChar := Word(Sys(4, 0, 0, 0, 0)); end;
procedure S_RunCmd(n: PWord; a: QWord); cdecl;      begin Sys(88, QWord(n), a, 0, 0); end;
function  S_GetThreadUID(tid: Cardinal): Cardinal; cdecl; begin S_GetThreadUID := Cardinal(Sys0(90, tid)); end;
procedure S_SetUID(u: Cardinal); cdecl;             begin Sys0(91, u); end;
function  S_GetUID: Cardinal; cdecl;                begin S_GetUID := Cardinal(Sys(89, 0, 0, 0, 0)); end;
procedure S_Yield; cdecl;                           begin Sys(98, 0, 0, 0, 0); end;
procedure S_WaitIPC; cdecl;                         begin Sys(100, 0, 0, 0, 0); end;
function  S_GetThreadGID(tid: Cardinal): Cardinal; cdecl; begin S_GetThreadGID := Cardinal(Sys0(92, tid)); end;
procedure S_SetGID(g: Cardinal); cdecl;             begin Sys0(93, g); end;
function  S_GetProcessInfo(t: Cardinal; buf: Pointer): LongInt; cdecl;
begin S_GetProcessInfo := LongInt(Sys(10, t, QWord(buf), 0, 0)); end;
procedure S_Clear(c: Cardinal); cdecl;              begin Sys(3, c, 0, 0, 0); end;
procedure S_Sleep(m: QWord); cdecl;                 begin Sys(97, m, 0, 0, 0); end;
function  S_GetUptime: QWord; cdecl;                begin S_GetUptime := Sys(96, 0, 0, 0, 0); end;
function  S_GetRsdp: QWord; cdecl;                  begin S_GetRsdp := Sys(11, 0, 0, 0, 0); end;
function  S_MapPhys(p, s: QWord): QWord; cdecl;     begin S_MapPhys := Sys(12, p, s, 0, 0); end;
procedure S_ReportHardware(t: Cardinal; a, b: QWord); cdecl; begin Sys(13, t, a, b, 0); end;
function  S_GetPIDByName(n: PWord): LongInt; cdecl; begin S_GetPIDByName := LongInt(Sys(14, QWord(n), 0, 0, 0)); end;
procedure S_ResetCursor; cdecl;                     begin Sys(399, 0, 0, 0, 0); end;
function  S_RequestFramebuffer: QWord; cdecl;       begin S_RequestFramebuffer := Sys(50, 0, 0, 0, 0); end;
function  S_GetScreenInfo(w, h, p: QWord): LongInt; cdecl; begin S_GetScreenInfo := LongInt(Sys(51, w, h, p, 0)); end;
function  S_CreateSharedBuffer(d: Cardinal; n: QWord; outTarget: PQWord): QWord; cdecl;
begin S_CreateSharedBuffer := Sys2(101, d, n, QWord(outTarget), outTarget); end;
procedure S_RedirectTerminal(fb: QWord; w, h, sl: Cardinal); cdecl; begin Sys(52, fb, w, h, sl); end;
function  S_InByte(port: Word): Word; cdecl;        begin S_InByte := 0; end;
procedure S_OutByte(port, value: Word); cdecl;      begin end;
function  S_InWord(port: Word): Word; cdecl;        begin S_InWord := 0; end;
procedure S_OutWord(port, value: Word); cdecl;      begin end;
procedure S_OutDword(port: Word; value: Cardinal); cdecl; begin end;
procedure S_AcquireAtaHw; cdecl;                    begin Sys(60, 0, 0, 0, 0); end;
procedure S_ReleaseAtaHw; cdecl;                    begin Sys(61, 0, 0, 0, 0); end;
function  S_SudoRun(a, p: PWord; c: PByte; n: QWord): QWord; cdecl;
begin S_SudoRun := Sys(94, QWord(a), QWord(p), QWord(c), n); end;

const
  SLOT_COUNT = 37;
var
  Slots: array[0..SLOT_COUNT - 1] of Pointer;

procedure AppApi_Init;
begin
  Slots[APP_SLOT_PRINT] := @S_Print;                Slots[APP_SLOT_EXIT] := @S_Exit;
  Slots[APP_SLOT_SEND_IPC] := @S_SendIPC;           Slots[APP_SLOT_ALLOC_MEM] := @S_AllocMem;
  Slots[APP_SLOT_GRANT_PORT] := @S_GrantPort;       Slots[APP_SLOT_RECEIVE_IPC] := @S_ReceiveIPC;
  Slots[APP_SLOT_GET_SHARED_MEM] := @S_GetSharedMem; Slots[APP_SLOT_GET_CHAR] := @S_GetChar;
  Slots[APP_SLOT_RUN_CMD] := @S_RunCmd;             Slots[APP_SLOT_GET_THREAD_UID] := @S_GetThreadUID;
  Slots[APP_SLOT_SET_UID] := @S_SetUID;             Slots[APP_SLOT_GET_UID] := @S_GetUID;
  Slots[APP_SLOT_YIELD] := @S_Yield;                Slots[APP_SLOT_WAIT_IPC] := @S_WaitIPC;
  Slots[APP_SLOT_GET_THREAD_GID] := @S_GetThreadGID; Slots[APP_SLOT_SET_GID] := @S_SetGID;
  Slots[APP_SLOT_GET_PROCESS_INFO] := @S_GetProcessInfo; Slots[APP_SLOT_CLEAR] := @S_Clear;
  Slots[APP_SLOT_SLEEP] := @S_Sleep;                Slots[APP_SLOT_GET_UPTIME] := @S_GetUptime;
  Slots[APP_SLOT_GET_RSDP] := @S_GetRsdp;           Slots[APP_SLOT_MAP_PHYS] := @S_MapPhys;
  Slots[APP_SLOT_REPORT_HARDWARE] := @S_ReportHardware; Slots[APP_SLOT_GET_PID_BY_NAME] := @S_GetPIDByName;
  Slots[APP_SLOT_RESET_CURSOR] := @S_ResetCursor;   Slots[APP_SLOT_REQUEST_FRAMEBUFFER] := @S_RequestFramebuffer;
  Slots[APP_SLOT_GET_SCREEN_INFO] := @S_GetScreenInfo; Slots[APP_SLOT_CREATE_SHARED_BUFFER] := @S_CreateSharedBuffer;
  Slots[APP_SLOT_REDIRECT_TERMINAL] := @S_RedirectTerminal; Slots[APP_SLOT_IN_BYTE] := @S_InByte;
  Slots[APP_SLOT_OUT_BYTE] := @S_OutByte;           Slots[APP_SLOT_IN_WORD] := @S_InWord;
  Slots[APP_SLOT_OUT_WORD] := @S_OutWord;           Slots[APP_SLOT_OUT_DWORD] := @S_OutDword;
  Slots[APP_SLOT_ACQUIRE_ATA_HW] := @S_AcquireAtaHw; Slots[APP_SLOT_RELEASE_ATA_HW] := @S_ReleaseAtaHw;
  Slots[APP_SLOT_SUDO_RUN] := @S_SudoRun;
end;

function AppApi_Slot(index: Cardinal): Pointer;
begin
  if index >= SLOT_COUNT then AppApi_Slot := nil
  else AppApi_Slot := Slots[index];
end;

procedure App_Print(msg: PWord);                     begin S_Print(msg); end;
procedure App_Exit;                                  begin S_Exit; end;
procedure App_SendIPC(destPid, msgType: Cardinal; payload: QWord); begin S_SendIPC(destPid, msgType, payload); end;
function  App_AllocMem(size: QWord): QWord;          begin App_AllocMem := S_AllocMem(size); end;
procedure App_GrantPort(port: Word);                 begin S_GrantPort(port); end;
function  App_ReceiveIPC(msg: Pointer): LongInt;     begin App_ReceiveIPC := S_ReceiveIPC(msg); end;
function  App_GetSharedMem: QWord;                   begin App_GetSharedMem := S_GetSharedMem; end;
function  App_GetChar: Word;                         begin App_GetChar := S_GetChar; end;
procedure App_RunCmd(name: PWord; arg: QWord);       begin S_RunCmd(name, arg); end;
function  App_GetThreadUID(targetTid: Cardinal): Cardinal; begin App_GetThreadUID := S_GetThreadUID(targetTid); end;
procedure App_SetUID(uid: Cardinal);                 begin S_SetUID(uid); end;
function  App_GetUID: Cardinal;                      begin App_GetUID := S_GetUID; end;
procedure App_Yield;                                 begin S_Yield; end;
procedure App_WaitIPC;                               begin S_WaitIPC; end;
function  App_GetThreadGID(targetTid: Cardinal): Cardinal; begin App_GetThreadGID := S_GetThreadGID(targetTid); end;
procedure App_SetGID(gid: Cardinal);                 begin S_SetGID(gid); end;
var
  ProcInfoBuf: array[0..63] of Byte;

function  App_GetProcessInfo(tid: Cardinal; var info: Pointer): LongInt;
begin
  if info = nil then info := @ProcInfoBuf[0];
  App_GetProcessInfo := S_GetProcessInfo(tid, info);
end;
procedure App_Clear(color: Cardinal);                begin S_Clear(color); end;
procedure App_Sleep(ms: QWord);                      begin S_Sleep(ms); end;
function  App_GetUptime: QWord;                      begin App_GetUptime := S_GetUptime; end;
function  App_GetRsdp: QWord;                        begin App_GetRsdp := S_GetRsdp; end;
function  App_MapPhys(phys, size: QWord): QWord;     begin App_MapPhys := S_MapPhys(phys, size); end;
procedure App_ReportHardware(tid: Cardinal; a, b: QWord); begin S_ReportHardware(tid, a, b); end;
function  App_GetPIDByName(name: PWord): LongInt;    begin App_GetPIDByName := S_GetPIDByName(name); end;
procedure App_ResetCursor;                           begin S_ResetCursor; end;
function  App_RequestFramebuffer: QWord;             begin App_RequestFramebuffer := S_RequestFramebuffer; end;
function  App_GetScreenInfo(out w, h, ppsl: QWord): LongInt;
begin App_GetScreenInfo := S_GetScreenInfo(QWord(@w), QWord(@h), QWord(@ppsl)); end;
function  App_CreateSharedBuffer(destPid: Cardinal; numPages: QWord; out targetVAddr: QWord): QWord;
begin
  targetVAddr := 0;
  App_CreateSharedBuffer := S_CreateSharedBuffer(destPid, numPages, @targetVAddr);
end;
function  App_SudoRun(appName, password: PWord; content: PByte; contentLen: QWord): QWord;
begin App_SudoRun := S_SudoRun(appName, password, content, contentLen); end;
procedure App_RedirectTerminal(newFb: QWord; w, h, scanLine: Cardinal); begin S_RedirectTerminal(newFb, w, h, scanLine); end;
function  App_InByte(port: Word): Word;              begin App_InByte := S_InByte(port); end;
procedure App_OutByte(port: Word; value: Word);      begin S_OutByte(port, value); end;
function  App_InWord(port: Word): Word;              begin App_InWord := S_InWord(port); end;
procedure App_OutWord(port: Word; value: Word);      begin S_OutWord(port, value); end;
procedure App_OutDword(port: Word; value: Cardinal); begin S_OutDword(port, value); end;
procedure App_AcquireAtaHw;                          begin S_AcquireAtaHw; end;
procedure App_ReleaseAtaHw;                          begin S_ReleaseAtaHw; end;

end.
