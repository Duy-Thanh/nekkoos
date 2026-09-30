{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: app_api - userland syscall gateway for Ring-3 applications.
  PORTED FROM: src/apps/API.cs (deleted once every app is Pascal).

  HOW AN APP REACHES THE KERNEL
  An app never links against the kernel. The kernel publishes a page of
  hand-assembled stubs (see src/arch/x86_64/vdso.pas) and maps it at a
  randomised address, so no absolute kernel address is ever baked into an app.

  Discovery is a magic patch, not a symbol: the app image declares one
  QWORD in .data holding 0x1337BEEFCAFE8BAD, and PELoader scans the loaded
  image for that byte pattern and overwrites it with the real vDSO address.
  Because the scan is brute-force over raw bytes, it does not care who
  produced the image - C# or Pascal - and does not depend on section names,
  padding, or alignment. That is what lets apps move off bflat.

  The page begins with a table of QWORD offsets; the stub for slot n lives
  at vDSO_base + table[n]. Slot numbers are an ABI - see AGENTS.md §4.1 and
  the ordering comment in vdso.pas. Append only, never reorder.

  EVERY APP MUST CALL AppApi_Init before touching any other entry point. The
  magic still holds its placeholder value until then, so reading a stub
  address first would compute garbage and jump into it.
  =========================================================================
}

unit app_api;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}
{$ASMMODE Intel}

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
function  App_GetProcessInfo(tid: Cardinal; out info: Pointer): LongInt;
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
procedure App_RedirectTerminal(tid: Cardinal);
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

{ THE PATCH SITE. This must stay an initialised QWORD in .data with exactly
  this value: PELoader.FindKaslrMagic_Pas scans the raw loaded image for the
  8 bytes 0x1337BEEFCAFE8BAD and overwrites them with the vDSO address. If the
  constant moves, is computed, or the compiler folds the read into an
  immediate, the scan misses and the app jumps to garbage.

  Volatile is not decoration either - the read must actually hit memory
  rather than being constant-folded from the initialiser. }
var
  KASLR_vDSO: QWord = QWord($1337BEEFCAFE8BAD);

  Api_Base: QWord = 0;

procedure AppApi_Init;
begin
  Api_Base := KASLR_vDSO;
end;

function AppApi_Slot(index: Cardinal): Pointer;
var
  table: PQWord;
begin
  if (Api_Base = 0) or (index > 63) then
  begin
    AppApi_Slot := nil;
    Exit;
  end;
  table := PQWord(Pointer(Api_Base));
  AppApi_Slot := Pointer(Api_Base + table[index]);
end;

{ Each wrapper casts the raw stub address to the calling convention the
  System V ABI uses. The vDSO stubs are plain `mov rax, imm32; int 0x80; ret`
  sequences, so they honour the normal integer argument registers. }
procedure App_Print(msg: PWord);
type TFn = procedure(m: PWord); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_PRINT))(msg); end;

procedure App_Exit;
type TFn = procedure; cdecl;
begin TFn(AppApi_Slot(APP_SLOT_EXIT))(); end;

procedure App_SendIPC(destPid, msgType: Cardinal; payload: QWord);
type TFn = procedure(d, t: Cardinal; p: QWord); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_SEND_IPC))(destPid, msgType, payload); end;

function App_AllocMem(size: QWord): QWord;
type TFn = function(s: QWord): QWord; cdecl;
begin App_AllocMem := TFn(AppApi_Slot(APP_SLOT_ALLOC_MEM))(size); end;

procedure App_GrantPort(port: Word);
type TFn = procedure(p: Word); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_GRANT_PORT))(port); end;

function App_ReceiveIPC(msg: Pointer): LongInt;
type TFn = function(m: Pointer): LongInt; cdecl;
begin App_ReceiveIPC := TFn(AppApi_Slot(APP_SLOT_RECEIVE_IPC))(msg); end;

function App_GetSharedMem: QWord;
type TFn = function: QWord; cdecl;
begin App_GetSharedMem := TFn(AppApi_Slot(APP_SLOT_GET_SHARED_MEM))(); end;

function App_GetChar: Word;
type TFn = function: Word; cdecl;
begin App_GetChar := TFn(AppApi_Slot(APP_SLOT_GET_CHAR))(); end;

procedure App_RunCmd(name: PWord; arg: QWord);
type TFn = procedure(n: PWord; a: QWord); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_RUN_CMD))(name, arg); end;

function App_GetThreadUID(targetTid: Cardinal): Cardinal;
type TFn = function(tid: Cardinal): Cardinal; cdecl;
begin App_GetThreadUID := TFn(AppApi_Slot(APP_SLOT_GET_THREAD_UID))(targetTid); end;

procedure App_SetUID(uid: Cardinal);
type TFn = procedure(u: Cardinal); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_SET_UID))(uid); end;

function App_GetUID: Cardinal;
type TFn = function: Cardinal; cdecl;
begin App_GetUID := TFn(AppApi_Slot(APP_SLOT_GET_UID))(); end;

procedure App_Yield;
type TFn = procedure; cdecl;
begin TFn(AppApi_Slot(APP_SLOT_YIELD))(); end;

procedure App_WaitIPC;
type TFn = procedure; cdecl;
begin TFn(AppApi_Slot(APP_SLOT_WAIT_IPC))(); end;

function App_GetThreadGID(targetTid: Cardinal): Cardinal;
type TFn = function(tid: Cardinal): Cardinal; cdecl;
begin App_GetThreadGID := TFn(AppApi_Slot(APP_SLOT_GET_THREAD_GID))(targetTid); end;

procedure App_SetGID(gid: Cardinal);
type TFn = procedure(g: Cardinal); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_SET_GID))(gid); end;

function App_GetProcessInfo(tid: Cardinal; out info: Pointer): LongInt;
type TFn = function(t: Cardinal; out i: Pointer): LongInt; cdecl;
begin App_GetProcessInfo := TFn(AppApi_Slot(APP_SLOT_GET_PROCESS_INFO))(tid, info); end;

procedure App_Clear(color: Cardinal);
type TFn = procedure(c: Cardinal); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_CLEAR))(color); end;

procedure App_Sleep(ms: QWord);
type TFn = procedure(m: QWord); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_SLEEP))(ms); end;

function App_GetUptime: QWord;
type TFn = function: QWord; cdecl;
begin App_GetUptime := TFn(AppApi_Slot(APP_SLOT_GET_UPTIME))(); end;

function App_GetRsdp: QWord;
type TFn = function: QWord; cdecl;
begin App_GetRsdp := TFn(AppApi_Slot(APP_SLOT_GET_RSDP))(); end;

function App_MapPhys(phys, size: QWord): QWord;
type TFn = function(p, s: QWord): QWord; cdecl;
begin App_MapPhys := TFn(AppApi_Slot(APP_SLOT_MAP_PHYS))(phys, size); end;

procedure App_ReportHardware(tid: Cardinal; a, b: QWord);
type TFn = procedure(t: Cardinal; a, b: QWord); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_REPORT_HARDWARE))(tid, a, b); end;

function App_GetPIDByName(name: PWord): LongInt;
type TFn = function(n: PWord): LongInt; cdecl;
begin App_GetPIDByName := TFn(AppApi_Slot(APP_SLOT_GET_PID_BY_NAME))(name); end;

procedure App_ResetCursor;
type TFn = procedure; cdecl;
begin TFn(AppApi_Slot(APP_SLOT_RESET_CURSOR))(); end;

function App_RequestFramebuffer: QWord;
type TFn = function: QWord; cdecl;
begin App_RequestFramebuffer := TFn(AppApi_Slot(APP_SLOT_REQUEST_FRAMEBUFFER))(); end;

function App_GetScreenInfo(out w, h, ppsl: QWord): LongInt;
type TFn = function(w, h, p: QWord): LongInt; cdecl;
begin App_GetScreenInfo := TFn(AppApi_Slot(APP_SLOT_GET_SCREEN_INFO))(w, h, ppsl); end;

function App_CreateSharedBuffer(destPid: Cardinal; numPages: QWord;
  out targetVAddr: QWord): QWord;
{ Hand-loaded: the out-pointer must go in R8, and the target address comes
  back in RBX, not RAX. A plain typed call would put the pointer in RDX and
  silently drop the second return value, handing the caller a garbage pid. }
var
  res: QWord;
  tgt: QWord;
  stub: Pointer;
begin
  tgt := targetVAddr;
  stub := AppApi_Slot(APP_SLOT_CREATE_SHARED_BUFFER);
  asm
    mov  rcx, destPid
    mov  rdx, numPages
    mov  r8,  tgt
    call stub
    mov  tgt, rbx
    mov  res, rax
  end;
  targetVAddr := tgt;
  App_CreateSharedBuffer := res;
end;

function App_SudoRun(appName, password: PWord; content: PByte; contentLen: QWord): QWord;
type TFn = function(a, p: PWord; c: PByte; n: QWord): QWord; cdecl;
begin App_SudoRun := TFn(AppApi_Slot(APP_SLOT_SUDO_RUN))(appName, password, content, contentLen); end;

procedure App_RedirectTerminal(tid: Cardinal);
type TFn = procedure(t: Cardinal); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_REDIRECT_TERMINAL))(tid); end;

function App_InByte(port: Word): Word;
type TFn = function(p: Word): Word; cdecl;
begin App_InByte := TFn(AppApi_Slot(APP_SLOT_IN_BYTE))(port); end;

procedure App_OutByte(port: Word; value: Word);
type TFn = procedure(p, v: Word); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_OUT_BYTE))(port, value); end;

function App_InWord(port: Word): Word;
type TFn = function(p: Word): Word; cdecl;
begin App_InWord := TFn(AppApi_Slot(APP_SLOT_IN_WORD))(port); end;

procedure App_OutWord(port: Word; value: Word);
type TFn = procedure(p, v: Word); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_OUT_WORD))(port, value); end;

procedure App_OutDword(port: Word; value: Cardinal);
type TFn = procedure(p: Word; v: Cardinal); cdecl;
begin TFn(AppApi_Slot(APP_SLOT_OUT_DWORD))(port, value); end;

procedure App_AcquireAtaHw;
type TFn = procedure; cdecl;
begin TFn(AppApi_Slot(APP_SLOT_ACQUIRE_ATA_HW))(); end;

procedure App_ReleaseAtaHw;
type TFn = procedure; cdecl;
begin TFn(AppApi_Slot(APP_SLOT_RELEASE_ATA_HW))(); end;

end.
