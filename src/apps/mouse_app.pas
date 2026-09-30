{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: mouse_app - Ring-3 PS/2 mouse daemon.
  PORTED FROM: src/apps/Mouse.cs (deleted).

  Runs as a user process. It announces itself to the kernel, wakes the PS/2
  mouse, then sits in a loop relaying packets to the display server.

  HANDSHAKE ORDER IS THE POINT OF THIS PORT
  The kernel blocks up to 30 s on IPC type 44 before starting SYSLOGON, so
  the handshake is sent FIRST, as soon as this process is alive - before any
  PS/2 access. If the controller is slow, wedged, or absent, we lose the
  mouse, not the boot. Sending it last (the previous order) meant a single
  unresponsive 8042 froze the entire system for half a minute.

  Every PS/2 wait is bounded. A PS/2 controller answers in microseconds; a
  bounded spin that gives up is correct, an unbounded one is a hang.
  =========================================================================
}

unit mouse_app;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ PE entry point. The loader looks for this symbol by name. }
procedure AppMain; cdecl; public name 'AppMain';

implementation

uses app_api;

const
  PS2_DATA_PORT   = $60;
  PS2_STATUS_PORT = $64;

  { Status bit 1: input buffer full, a command byte is still pending. }
  PS2_STATUS_IBF = 2;
  { Status bit 0: output buffer full, a response byte is waiting. }
  PS2_STATUS_OBF = 1;

  { 8042 command: the byte after this is destined for the AUX (mouse)
    device rather than the keyboard. }
  PS2_CMD_WRITE_AUX = $D4;

  { AUX commands used during bring-up. }
  PS2_AUX_ENABLE       = $A8;
  PS2_AUX_READ_CONFIG  = $20;
  PS2_AUX_WRITE_CONFIG = $60;
  PS2_AUX_SET_DEFAULTS = $F6;
  PS2_AUX_ENABLE_REPORTING = $F4;

  { Spin budget for one controller wait. Generous for microsecond hardware,
    but finite - see the module header. }
  PS2_SPIN_LIMIT = 5000;

  { IPC types. 44 is the boot handshake; 2 is a raw packet relayed upward;
    3 is what the display server expects to receive. }
  IPC_MOUSE_READY  = 44;
  IPC_RAW_PACKET   = 2;
  IPC_DWM_MOUSE    = 3;

  { How long to keep looking for the display server before giving up and
    simply dropping packets. }
  DSRV_LOOKUP_MS    = 1000;
  DSRV_LOOKUP_STEP  = 5;

  DSERV_NAME = 'DSRV.EXE';

var
  dwmId: LongInt = -1;

function WaitWrite: Boolean; inline;
var
  t: Integer;
begin
  t := PS2_SPIN_LIMIT;
  while (App_InByte(PS2_STATUS_PORT) and PS2_STATUS_IBF) <> 0 do
  begin
    Dec(t);
    if t <= 0 then Exit(False);
  end;
  WaitWrite := True;
end;

function WaitRead: Boolean; inline;
var
  t: Integer;
begin
  t := PS2_SPIN_LIMIT;
  while (App_InByte(PS2_STATUS_PORT) and 1) = 0 do
  begin
    Dec(t);
    if t <= 0 then Exit(False);
  end;
  WaitRead := True;
end;

{ Write a command to the AUX device and swallow its ACK. }
function WriteMouse(cmd: Word): Boolean;
begin
  WriteMouse := False;
  if not WaitWrite then Exit;
  App_OutByte(PS2_STATUS_PORT, PS2_CMD_WRITE_AUX);
  if not WaitWrite then Exit;
  App_OutByte(PS2_DATA_PORT, cmd);
  if not WaitRead then Exit;
  App_InByte(PS2_DATA_PORT);   { ACK byte }
  WriteMouse := True;
end;

{ Drain any bytes the controller buffered. Bounded on purpose - see header. }
procedure DrainController;
var
  budget: Integer;
begin
  budget := 100000;
  while (App_InByte(PS2_STATUS_PORT) and 1) <> 0 do
  begin
    Dec(budget);
    if budget <= 0 then Break;
    App_InByte(PS2_DATA_PORT);
  end;
end;

{ Look for the display server, but not forever. A missing DSRV.EXE must
  degrade to "no forwarding", not to a hang. }
function FindDisplayServer: LongInt;
var
  waited: Integer;
  nameBuf: array[0..15] of Word;
  i: Integer;
  s: AnsiString;
begin
  for i := 1 to Length(DSERV_NAME) do
    nameBuf[i - 1] := Word(Byte(DSERV_NAME[i]));
  nameBuf[Length(DSERV_NAME)] := 0;

  waited := 0;
  FindDisplayServer := -1;
  while waited < DSRV_LOOKUP_MS do
  begin
    FindDisplayServer := App_GetPIDByName(@nameBuf[0]);
    if FindDisplayServer <> -1 then Exit;
    App_Sleep(DSRV_LOOKUP_STEP);
    Inc(waited, DSRV_LOOKUP_STEP);
  end;
end;

procedure AppMain; cdecl;
var
  msg: array[0..1] of QWord;   { TMessage is 24 bytes; see app_api }
  mouseOk: Boolean;
  status: Word;
  p0, p1, p2: Word;
  dx, dy, clicks: LongInt;
  payload: QWord;
begin
  AppApi_Init;

  { Ask the kernel for the two PS/2 ports. }
  App_GrantPort(PS2_DATA_PORT);
  App_GrantPort(PS2_STATUS_PORT);

  { ==========================================================
    ANNOUNCE FIRST. See the module header: the kernel is blocked
    waiting for this, and nothing below may be allowed to delay it.
    ========================================================== }
  App_SendIPC(0, IPC_MOUSE_READY, 0);

  DrainController;

  { Bring the controller up. Every step is optional: on failure we still
    run, we just never receive hardware packets. }
  mouseOk := True;
  if WaitWrite then App_OutByte(PS2_STATUS_PORT, PS2_AUX_ENABLE)
  else mouseOk := False;
  if mouseOk and WaitWrite then App_OutByte(PS2_STATUS_PORT, PS2_AUX_READ_CONFIG)
  else mouseOk := False;

  if mouseOk and WaitRead then
  begin
    status := App_InByte(PS2_DATA_PORT);
    status := status or 2;          { enable the AUX interrupt line }
    if WaitWrite then App_OutByte(PS2_STATUS_PORT, PS2_AUX_WRITE_CONFIG);
    if WaitWrite then App_OutByte(PS2_DATA_PORT, status);
  end
  else
    mouseOk := False;

  if mouseOk then
  begin
    WriteMouse(PS2_AUX_SET_DEFAULTS);
    WriteMouse(PS2_AUX_ENABLE_REPORTING);
  end;

  dwmId := FindDisplayServer;

  { Relay packets. }
  while True do
  begin
    if App_ReceiveIPC(@msg[0]) = 1 then
    begin
      if App_MsgType(@msg[0]) = IPC_RAW_PACKET then
      begin
        payload := App_MsgPayload(@msg[0]);
        p0 := Word(payload and $FF);
        p1 := Word((payload shr 8) and $FF);
        p2 := Word((payload shr 16) and $FF);

        dx := p1;
        dy := p2;

        { Sign-extend from the 8-bit signed deltas the controller sends. }
        if (p0 and $10) <> 0 then dx := dx or LongInt($FFFFFF00);
        if (p0 and $20) <> 0 then dy := dy or LongInt($FFFFFF00);

        { The Y axis of a PS/2 device points up; the screen's points down. }
        dy := -dy;

        clicks := p0 and $07;
        payload := (QWord(clicks) shl 32) or
                   (QWord(Word(dx)) shl 16) or QWord(Word(dy));

        if dwmId <> -1 then App_SendIPC(Cardinal(dwmId), IPC_DWM_MOUSE, payload);
      end;
      { Other types (stray IPC, shutdown notices) are ignored on purpose:
        the loop must keep running, and the next receive blocks. }
    end
    else
    begin
      App_WaitIPC;
    end;
  end;
end;

end.
