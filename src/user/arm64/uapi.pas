{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: uapi - syscall wrappers for ARM64 user programs.

  The x86 app_api reaches the kernel through a vDSO table patched in by the
  PE loader. ARM64 programs are ELF and call `svc` directly through the
  trampoline in crt0.S; the syscall numbers are the shared table
  (AGENTS.md section 4.1).
  =========================================================================
}
unit uapi;

{$mode objfpc}
{$TYPEINFO OFF}
{$M-}

interface

const
  { IPC message as written by syscall 8 (24 bytes). }
  MSG_SIZE = 24;

function  U_Sys(n, a1, a2, a3, a4: QWord): QWord; cdecl; external name 'uapi_sys';
function  U_Sys2(n, a1, a2, a3: QWord; out2: PQWord): QWord; cdecl; external name 'uapi_sys2';
procedure U_Fence; cdecl; external name 'uapi_fence';

procedure U_Exit;
procedure U_Print(s: PWord);
procedure U_PrintDec(v: QWord);
function  U_SendIPC(receiver, msgType: Cardinal; payload: QWord): Boolean;
{ Non-blocking: True and `msg` filled when a message was waiting. }
function  U_ReceiveIPC(msg: PByte): Boolean;
{ Give up the CPU until a message arrives or a couple of ticks pass. }
procedure U_Yield;
function  U_GetSharedMem: QWord;
function  U_MapPhys(phys, pages: QWord): QWord;
function  U_AllocDma(pages: QWord; out phys: QWord): QWord;
function  U_PidByName(name: PWord): Int64;

function  U_MsgType(msg: PByte): Cardinal;
function  U_MsgSender(msg: PByte): Cardinal;
function  U_MsgPayload(msg: PByte): QWord;

implementation

const
  SYS_EXIT = 0;  SYS_PRINT = 1;  SYS_SEND = 5;  SYS_RECEIVE = 8;
  SYS_MAPPHYS = 12;  SYS_PIDBYNAME = 14;  SYS_SHAREDMEM = 99;  SYS_YIELD = 100;
  SYS_ALLOCDMA = 102;

procedure U_Exit;
begin
  U_Sys(SYS_EXIT, 0, 0, 0, 0);
end;

procedure U_Print(s: PWord);
begin
  U_Sys(SYS_PRINT, QWord(s), 0, 0, 0);
end;

procedure U_PrintDec(v: QWord);
var
  buf: array[0..20] of Word;
  tmp: array[0..19] of Word;
  n, i: Integer;
begin
  n := 0;
  repeat
    tmp[n] := Ord('0') + (v mod 10);
    v := v div 10;
    Inc(n);
  until v = 0;
  for i := 0 to n - 1 do buf[i] := tmp[n - 1 - i];
  buf[n] := 0;
  U_Print(@buf[0]);
end;

function U_SendIPC(receiver, msgType: Cardinal; payload: QWord): Boolean;
begin
  U_SendIPC := U_Sys(SYS_SEND, receiver, msgType, payload, 0) = 1;
end;

function U_ReceiveIPC(msg: PByte): Boolean;
begin
  U_ReceiveIPC := U_Sys(SYS_RECEIVE, QWord(msg), 0, 0, 0) = 1;
end;

procedure U_Yield;
begin
  U_Sys(SYS_YIELD, 0, 0, 0, 0);
end;

function U_GetSharedMem: QWord;
begin
  U_GetSharedMem := U_Sys(SYS_SHAREDMEM, 0, 0, 0, 0);
end;

function U_MapPhys(phys, pages: QWord): QWord;
begin
  U_MapPhys := U_Sys(SYS_MAPPHYS, phys, pages, 0, 0);
end;

function U_AllocDma(pages: QWord; out phys: QWord): QWord;
begin
  phys := 0;
  U_AllocDma := U_Sys2(SYS_ALLOCDMA, pages, 0, 0, @phys);
end;

function U_PidByName(name: PWord): Int64;
begin
  U_PidByName := Int64(U_Sys(SYS_PIDBYNAME, QWord(name), 0, 0, 0));
end;

function U_MsgType(msg: PByte): Cardinal;
begin
  U_MsgType := PCardinal(msg)^;
end;

function U_MsgSender(msg: PByte): Cardinal;
begin
  U_MsgSender := PCardinal(msg + 4)^;
end;

function U_MsgPayload(msg: PByte): QWord;
begin
  U_MsgPayload := PQWord(msg + 16)^;
end;

end.
