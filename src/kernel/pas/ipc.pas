{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: IPC - Lock-free MPMC Message Queue (Pascal Implementation)
  PURPOSE: Architecture-independent MPMC queue algorithm using atomic
           exchange and memory barriers. Atomic primitives (XCHG, fences)
           are architecture-specific but abstracted as function calls, so
           the algorithm itself is portable.
  =========================================================================
}

unit ipc;

{$mode objfpc}
{$h+}
{$M-}

interface

{ Message struct layout (C# LayoutKind.Sequential, 24 bytes):
  - Type: Cardinal (4 bytes) at offset 0
  - Sender: Cardinal (4 bytes) at offset 4
  - Receiver: Cardinal (4 bytes) at offset 8
  - IsLocked: Cardinal (4 bytes) at offset 12
  - Payload: QWord (8 bytes) at offset 16
}
const
  MSG_TYPE_OFFSET = 0;
  MSG_SENDER_OFFSET = 4;
  MSG_RECEIVER_OFFSET = 8;
  MSG_ISLOCKED_OFFSET = 12;
  MSG_PAYLOAD_OFFSET = 16;
  MSG_SIZE = 24;

{ Core MPMC send operation. Returns 1 if success, 0 if fail (queue full).
  Sets needsWakeup=1 and wakeReceiverId if OS should wake receiver thread. }
function IPC_SendCore(queue: Pointer; maxMessages: Integer; msgType, sender, receiver: Cardinal;
                      payload: QWord; out needsWakeup: Byte; out wakeReceiverId: Cardinal): Byte;
  cdecl; public name 'IPC_SendCore_Pas';

{ Receive message for specific receiver. Returns 1 if success, 0 if no message. }
function IPC_ReceiveFor(queue: Pointer; maxMessages: Integer; receiverId: Cardinal;
                        out msgType, sender: Cardinal; out payload: QWord): Byte;
  cdecl; public name 'IPC_ReceiveFor_Pas';

{ Receive any message (broadcast receive). Returns 1 if success, 0 if no message. }
function IPC_Receive(queue: Pointer; maxMessages: Integer;
                     out msgType, sender, receiver: Cardinal; out payload: QWord): Byte;
  cdecl; public name 'IPC_Receive_Pas';

{ Clear all messages for a specific thread (sender or receiver). }
procedure IPC_ClearMailbox(queue: Pointer; maxMessages: Integer; threadId: Cardinal);
  cdecl; public name 'IPC_ClearMailbox_Pas';

implementation

{ External atomic primitives from Hardware.asm (x86_64 LOCK XCHG + fences) }
function Arch_AtomicExchange(var location: Cardinal; newValue: Cardinal): Cardinal; cdecl; external name 'Arch_AtomicExchange';
procedure Arch_StoreFence; cdecl; external name 'Arch_StoreFence';
procedure Arch_FullFence; cdecl; external name 'Arch_FullFence';

{ Helper: get pointer to message[i] }
function GetMessage(queue: Pointer; index: Integer): PByte; inline;
begin
  GetMessage := PByte(queue) + (index * MSG_SIZE);
end;

{ Helper: read Cardinal field from message }
function GetMsgCardinal(msg: PByte; offset: Integer): Cardinal; inline;
begin
  GetMsgCardinal := PCardinal(msg + offset)^;
end;

{ Helper: write Cardinal field to message }
procedure SetMsgCardinal(msg: PByte; offset: Integer; value: Cardinal); inline;
begin
  PCardinal(msg + offset)^ := value;
end;

{ Helper: read QWord field from message }
function GetMsgQWord(msg: PByte; offset: Integer): QWord; inline;
begin
  GetMsgQWord := PQWord(msg + offset)^;
end;

{ Helper: write QWord field to message }
procedure SetMsgQWord(msg: PByte; offset: Integer; value: QWord); inline;
begin
  PQWord(msg + offset)^ := value;
end;

{ Helper: atomic exchange on IsLocked field }
function TryLockMessage(msg: PByte): Boolean; inline;
var
  lockField: PCardinal;
begin
  lockField := PCardinal(msg + MSG_ISLOCKED_OFFSET);
  TryLockMessage := Arch_AtomicExchange(lockField^, 1) = 0;
end;

{ Helper: unlock message }
procedure UnlockMessage(msg: PByte); inline;
begin
  SetMsgCardinal(msg, MSG_ISLOCKED_OFFSET, 0);
end;

function IPC_SendCore(queue: Pointer; maxMessages: Integer; msgType, sender, receiver: Cardinal;
                      payload: QWord; out needsWakeup: Byte; out wakeReceiverId: Cardinal): Byte; cdecl;
var
  i: Integer;
  msg: PByte;
begin
  IPC_SendCore := 0;
  needsWakeup := 0;
  wakeReceiverId := 0;

  if (queue = nil) or (msgType = 0) then Exit;

  { [MPMC ALGORITHM] Scan for empty slot, lock atomically, place message }
  for i := 0 to maxMessages - 1 do
  begin
    msg := GetMessage(queue, i);

    { [OPTIMIZATION] Check if slot is empty and unlocked before attempting XCHG }
    if (GetMsgCardinal(msg, MSG_TYPE_OFFSET) = 0) and
       (GetMsgCardinal(msg, MSG_ISLOCKED_OFFSET) = 0) then
    begin
      { Atomic lock acquisition }
      if TryLockMessage(msg) then
      begin
        { Double-check after acquiring lock (another thread may have filled it) }
        if GetMsgCardinal(msg, MSG_TYPE_OFFSET) = 0 then
        begin
          { Place message }
          SetMsgCardinal(msg, MSG_SENDER_OFFSET, sender);
          SetMsgCardinal(msg, MSG_RECEIVER_OFFSET, receiver);
          SetMsgQWord(msg, MSG_PAYLOAD_OFFSET, payload);

          Arch_FullFence(); { Ensure all fields written before Type }

          SetMsgCardinal(msg, MSG_TYPE_OFFSET, msgType); { Commit message }

          Arch_StoreFence();
          UnlockMessage(msg);

          { Signal OS to wake receiver (C# will check Scheduler.Threads[receiver].Active) }
          needsWakeup := 1;
          wakeReceiverId := receiver;

          IPC_SendCore := 1;
          Exit;
        end;

        { Slot was taken by another thread, unlock and continue }
        UnlockMessage(msg);
      end;
    end;
  end;
end;

function IPC_ReceiveFor(queue: Pointer; maxMessages: Integer; receiverId: Cardinal;
                        out msgType, sender: Cardinal; out payload: QWord): Byte; cdecl;
var
  i: Integer;
  msg: PByte;
  msgReceiver: Cardinal;
begin
  IPC_ReceiveFor := 0;
  msgType := 0;
  sender := 0;
  payload := 0;

  if queue = nil then Exit;

  for i := 0 to maxMessages - 1 do
  begin
    msg := GetMessage(queue, i);

    { Check if message exists for this receiver }
    if (GetMsgCardinal(msg, MSG_TYPE_OFFSET) <> 0) and
       (GetMsgCardinal(msg, MSG_RECEIVER_OFFSET) = receiverId) and
       (GetMsgCardinal(msg, MSG_ISLOCKED_OFFSET) = 0) then
    begin
      if TryLockMessage(msg) then
      begin
        { Double-check after lock }
        msgReceiver := GetMsgCardinal(msg, MSG_RECEIVER_OFFSET);
        if (GetMsgCardinal(msg, MSG_TYPE_OFFSET) <> 0) and (msgReceiver = receiverId) then
        begin
          { Read message }
          msgType := GetMsgCardinal(msg, MSG_TYPE_OFFSET);
          sender := GetMsgCardinal(msg, MSG_SENDER_OFFSET);
          payload := GetMsgQWord(msg, MSG_PAYLOAD_OFFSET);

          { Clear message }
          Arch_StoreFence();
          SetMsgCardinal(msg, MSG_TYPE_OFFSET, 0);
          Arch_StoreFence();
          UnlockMessage(msg);

          IPC_ReceiveFor := 1;
          Exit;
        end;

        UnlockMessage(msg);
      end;
    end;
  end;
end;

function IPC_Receive(queue: Pointer; maxMessages: Integer;
                     out msgType, sender, receiver: Cardinal; out payload: QWord): Byte; cdecl;
var
  i: Integer;
  msg: PByte;
begin
  IPC_Receive := 0;
  msgType := 0;
  sender := 0;
  receiver := 0;
  payload := 0;

  if queue = nil then Exit;

  for i := 0 to maxMessages - 1 do
  begin
    msg := GetMessage(queue, i);

    if (GetMsgCardinal(msg, MSG_TYPE_OFFSET) <> 0) and
       (GetMsgCardinal(msg, MSG_ISLOCKED_OFFSET) = 0) then
    begin
      if TryLockMessage(msg) then
      begin
        if GetMsgCardinal(msg, MSG_TYPE_OFFSET) <> 0 then
        begin
          msgType := GetMsgCardinal(msg, MSG_TYPE_OFFSET);
          sender := GetMsgCardinal(msg, MSG_SENDER_OFFSET);
          receiver := GetMsgCardinal(msg, MSG_RECEIVER_OFFSET);
          payload := GetMsgQWord(msg, MSG_PAYLOAD_OFFSET);

          Arch_StoreFence();
          SetMsgCardinal(msg, MSG_TYPE_OFFSET, 0);
          Arch_StoreFence();
          UnlockMessage(msg);

          IPC_Receive := 1;
          Exit;
        end;

        UnlockMessage(msg);
      end;
    end;
  end;
end;

procedure IPC_ClearMailbox(queue: Pointer; maxMessages: Integer; threadId: Cardinal); cdecl;
var
  i: Integer;
  msg: PByte;
  msgSender, msgReceiver: Cardinal;
begin
  if queue = nil then Exit;

  for i := 0 to maxMessages - 1 do
  begin
    msg := GetMessage(queue, i);

    if GetMsgCardinal(msg, MSG_TYPE_OFFSET) <> 0 then
    begin
      msgSender := GetMsgCardinal(msg, MSG_SENDER_OFFSET);
      msgReceiver := GetMsgCardinal(msg, MSG_RECEIVER_OFFSET);

      if (msgReceiver = threadId) or (msgSender = threadId) then
      begin
        if TryLockMessage(msg) then
        begin
          { Re-check after lock }
          if GetMsgCardinal(msg, MSG_TYPE_OFFSET) <> 0 then
          begin
            msgSender := GetMsgCardinal(msg, MSG_SENDER_OFFSET);
            msgReceiver := GetMsgCardinal(msg, MSG_RECEIVER_OFFSET);

            if (msgReceiver = threadId) or (msgSender = threadId) then
            begin
              SetMsgCardinal(msg, MSG_SENDER_OFFSET, 0);
              SetMsgCardinal(msg, MSG_RECEIVER_OFFSET, 0);
              SetMsgQWord(msg, MSG_PAYLOAD_OFFSET, 0);
              Arch_StoreFence();
              SetMsgCardinal(msg, MSG_TYPE_OFFSET, 0);
            end;
          end;

          UnlockMessage(msg);
        end;
      end;
    end;
  end;
end;

end.
