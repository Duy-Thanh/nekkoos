{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: ipc_kernel - owner of the kernel IPC mailbox.
  PORTED FROM: src/kernel/IPC.cs (queue ownership + wake-up policy).

  ipc.pas holds the lock-free MPMC queue algorithm and is queue-agnostic;
  this unit owns the one real queue, allocates it, and applies the
  scheduler-side policy (waking a sleeping receiver after a send).
  =========================================================================
}
unit ipc_kernel;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

{ Allocate the mailbox: `capacity` messages of 24 bytes each. }
procedure IpcK_Init(capacity: Integer);

function IpcK_Send(msgType, sender, receiver: Cardinal; payload: QWord): Boolean;

{ Interrupt-safe: the XCHG-based queue needs no extra locking, so this is the
  same operation plus the "queue not initialised" diagnostic. }
function IpcK_SendFromInterrupt(msgType, sender, receiver: Cardinal; payload: QWord): Boolean;

function IpcK_ReceiveForRaw(receiverId: Cardinal;
  var outType, outSender: Cardinal; var outPayload: QWord): Boolean;
function IpcK_ReceiveRaw(var outType, outSender, outReceiver: Cardinal;
  var outPayload: QWord): Boolean;

procedure IpcK_ClearMailbox(threadId: Cardinal);

function IpcK_GetQueue: Pointer;
function IpcK_GetMax: Integer;
function IpcK_HasMessageFor(receiverId: Cardinal): Boolean;

implementation

uses arch_interface, pmm, libc, terminal, kstring, ipc, scheduler;

const
  MESSAGE_SIZE = 24;   { Type, Sender, Receiver, IsLocked (4 x u32) + Payload (u64) }
  MSG_OFF_TYPE   = 0;
  MSG_OFF_SENDER = 4;
  MSG_OFF_LOCKED = 12;
  MSG_OFF_PAYLOAD = 16;

var
  Queue: Pointer = nil;
  MaxMessages: Integer = 0;

procedure Fatal(const msg: AnsiString); inline;
begin
  Terminal_SetColor_Pas($00FF0000);
  Terminal_Print_Pas(W(msg));
end;

function IpcK_GetQueue: Pointer;
begin
  IpcK_GetQueue := Queue;
end;

function IpcK_GetMax: Integer;
begin
  IpcK_GetMax := MaxMessages;
end;

procedure IpcK_Init(capacity: Integer);
var
  requiredBytes, numPages: QWord;
begin
  if (capacity <= 0) or (capacity > 100000) then
  begin
    Fatal('[!] FATAL: Invalid IPC capacity!'#13#10);
    Exit;
  end;

  MaxMessages := capacity;
  requiredBytes := QWord(MaxMessages) * MESSAGE_SIZE;
  numPages := (requiredBytes + 4095) div 4096;

  if numPages > 10000 then
  begin
    Fatal('[!] FATAL: IPC memory allocation too large!'#13#10);
    Exit;
  end;

  Queue := Pmm_AllocateContiguousPages(numPages);
  if Queue = nil then
  begin
    Fatal('[!] FATAL: Cannot allocate memory for IPC queue!'#13#10);
    Exit;
  end;

  if (QWord(Queue) and 7) <> 0 then
  begin
    Fatal('[!] FATAL: IPC queue is not 8-byte aligned!'#13#10);
    Exit;
  end;

  MemSet(Queue, 0, numPages * 4096);
  Arch_StoreFence;
  { scheduler.pas clears a thread's mailbox when it dies. }
  Sched_SetIpcQueue(Queue, MaxMessages);

  Terminal_SetColor_Pas($00FFFF00);
  Terminal_Print_Pas(W('[+] IPC Mailbox (Atomic XCHG MPMC): '));
  Terminal_PrintDec_Pas(QWord(MaxMessages));
  Terminal_Print_Pas(W(' slots secured.'#13#10));
end;

function IpcK_Send(msgType, sender, receiver: Cardinal; payload: QWord): Boolean;
var
  needsWakeup: Byte;
  wakeId: Cardinal;
  ok: Byte;
  irq: Boolean;
begin
  IpcK_Send := False;
  if Queue = nil then Exit;
  if msgType = 0 then Exit;

  needsWakeup := 0;
  wakeId := 0;
  ok := IPC_SendCore(Queue, MaxMessages, msgType, sender, receiver, payload,
    needsWakeup, wakeId);

  if (ok <> 0) and (needsWakeup <> 0) then
  begin
    { [CVE-2026-001] Wake the receiver under the scheduler lock so a timer
      interrupt or another core cannot change Active underneath us. }
    irq := Sched_AcquireSchedLockSafe;
    if Sched_GetThreadActive(Integer(wakeId)) = 2 then
    begin
      Sched_SetThreadActive(Integer(wakeId), 1);
      Sched_SetThreadWakeUpTick(Integer(wakeId), 0);
    end;
    Sched_ReleaseSchedLockSafe(irq);
  end;

  IpcK_Send := ok <> 0;
end;

function IpcK_SendFromInterrupt(msgType, sender, receiver: Cardinal; payload: QWord): Boolean;
begin
  if Queue = nil then
  begin
    Fatal('[!] FATAL: IPC queue not initialized!'#13#10);
    IpcK_SendFromInterrupt := False;
    Exit;
  end;
  IpcK_SendFromInterrupt := IpcK_Send(msgType, sender, receiver, payload);
end;

function IpcK_ReceiveForRaw(receiverId: Cardinal;
  var outType, outSender: Cardinal; var outPayload: QWord): Boolean;
var
  t, s: Cardinal;
  p: QWord;
begin
  IpcK_ReceiveForRaw := False;
  if Queue = nil then Exit;
  t := 0; s := 0; p := 0;
  if IPC_ReceiveFor(Queue, MaxMessages, receiverId, t, s, p) <> 0 then
  begin
    outType := t;
    outSender := s;
    outPayload := p;
    IpcK_ReceiveForRaw := True;
  end;
end;

function IpcK_ReceiveRaw(var outType, outSender, outReceiver: Cardinal;
  var outPayload: QWord): Boolean;
var
  t, s, r: Cardinal;
  p: QWord;
begin
  IpcK_ReceiveRaw := False;
  if Queue = nil then Exit;
  t := 0; s := 0; r := 0; p := 0;
  if IPC_Receive(Queue, MaxMessages, t, s, r, p) <> 0 then
  begin
    outType := t;
    outSender := s;
    outReceiver := r;
    outPayload := p;
    IpcK_ReceiveRaw := True;
  end;
end;

procedure IpcK_ClearMailbox(threadId: Cardinal);
begin
  if Queue = nil then
  begin
    Fatal('[!] FATAL: IPC queue not initialized!'#13#10);
    Exit;
  end;
  IPC_ClearMailbox(Queue, MaxMessages, threadId);
end;

function IpcK_HasMessageFor(receiverId: Cardinal): Boolean;
begin
  IpcK_HasMessageFor := (Queue <> nil) and
    (HasMessageForReceiver(Queue, MaxMessages, receiverId) <> 0);
end;

{ ── cdecl exports for IPC.cs ── }

procedure IpcK_Init_Pas(capacity: Integer); cdecl; public name 'IpcK_Init_Pas';
begin
  IpcK_Init(capacity);
end;

function IpcK_Send_Pas(msgType, sender, receiver: Cardinal; payload: QWord): Byte;
  cdecl; public name 'IpcK_Send_Pas';
begin
  IpcK_Send_Pas := Ord(IpcK_Send(msgType, sender, receiver, payload));
end;

function IpcK_SendFromInterrupt_Pas(msgType, sender, receiver: Cardinal; payload: QWord): Byte;
  cdecl; public name 'IpcK_SendFromInterrupt_Pas';
begin
  IpcK_SendFromInterrupt_Pas := Ord(IpcK_SendFromInterrupt(msgType, sender, receiver, payload));
end;

function IpcK_ReceiveForRaw_Pas(receiverId: Cardinal;
  outType, outSender: PCardinal; outPayload: PQWord): Byte;
  cdecl; public name 'IpcK_ReceiveForRaw_Pas';
begin
  IpcK_ReceiveForRaw_Pas := 0;
  if (outType = nil) or (outSender = nil) or (outPayload = nil) then Exit;
  IpcK_ReceiveForRaw_Pas := Ord(IpcK_ReceiveForRaw(receiverId, outType^, outSender^, outPayload^));
end;

function IpcK_ReceiveRaw_Pas(outType, outSender, outReceiver: PCardinal;
  outPayload: PQWord): Byte; cdecl; public name 'IpcK_ReceiveRaw_Pas';
begin
  IpcK_ReceiveRaw_Pas := 0;
  if (outType = nil) or (outSender = nil) or (outReceiver = nil) or
     (outPayload = nil) then Exit;
  IpcK_ReceiveRaw_Pas := Ord(IpcK_ReceiveRaw(outType^, outSender^, outReceiver^, outPayload^));
end;

procedure IpcK_ClearMailbox_Pas(threadId: Cardinal); cdecl; public name 'IpcK_ClearMailbox_Pas';
begin
  IpcK_ClearMailbox(threadId);
end;

function IpcK_GetQueue_Pas: Pointer; cdecl; public name 'IpcK_GetQueue_Pas';
begin
  IpcK_GetQueue_Pas := Queue;
end;

function IpcK_GetMax_Pas: Integer; cdecl; public name 'IpcK_GetMax_Pas';
begin
  IpcK_GetMax_Pas := MaxMessages;
end;

function IpcK_HasMessageFor_Pas(receiverId: Cardinal): Byte; cdecl; public name 'IpcK_HasMessageFor_Pas';
begin
  IpcK_HasMessageFor_Pas := Ord(IpcK_HasMessageFor(receiverId));
end;

end.
