{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: ata_app - Ring-3 ATA/IDE daemon.
  PORTED FROM: src/apps/ATA_Driver.cs.

  FAT16.exe (fat16_app.pas) owns the file system and never touches an IDE
  port itself; it asks this daemon over IPC. That split exists so the disk
  stack has exactly one port-level user at a time.

  THE SHARED-HARDWARE LOCK IS THE WHOLE POINT
  The kernel's own raw ATA driver runs on the other cores (SMP). Two
  entities driving 0x1F0-0x1F7 concurrently corrupt each other's command
  protocol. Every raw IN/OUT below is therefore bracketed by
  App_AcquireAtaHw / App_ReleaseAtaHw (vDSO slots 34/35). Note the lock is
  held across SyscallYield inside the busy-wait loops: the lock is a
  hardware lock, not a thread lock, and releasing it mid-transaction would
  hand a half-issued command to the kernel.

  SIZE IS DETECTED, NEVER ASSUMED
  DetectDiskSize issues IDENTIFY DEVICE and caches words 60/61. Hardcoding
  a sector count would silently read past the end of whatever image
  build.sh produced that day. 0 means "not detected" and callers fall back
  to the old 24-bit ceiling.

  IPC PROTOCOL (consumed by fat16_app.pas):
    in  10/12/14  read / write / flush, payload = LBA
    out 11/13/15  success (read/write carry the shared window address)
    out 111       failure
  =========================================================================
}

unit ata_app;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}

interface

{ PE entry point. The loader looks for this symbol by name. }
procedure AppMain; cdecl; public name 'AppMain';

implementation

uses app_api, kstring;

const
  { Task file registers - the eight registers of a primary IDE channel. }
  ATA_PORT_DATA       = $1F0;
  ATA_PORT_SECTOR_CNT = $1F2;
  ATA_PORT_LBA_LOW    = $1F3;
  ATA_PORT_LBA_MID    = $1F4;
  ATA_PORT_LBA_HIGH   = $1F5;
  ATA_PORT_DRIVE_HEAD = $1F6;
  ATA_PORT_STATUS     = $1F7;
  { Device control / alternate status of the primary channel. }
  ATA_PORT_CONTROL    = $3F6;

  { Status register bits (ATA/ATAPI status register, 0x1F7). }
  ATA_ST_BUSY = $80;   { BSY  - command in progress, do not touch data port }
  ATA_ST_DRQ  = $08;   { DRQ  - data ready, PIO transfer may proceed }
  ATA_ST_DF   = $20;   { DF   - device fault }
  ATA_ST_ERR  = $01;   { ERR  - command failed }

  ATA_CMD_READ     = $20;   { READ SECTORS          }
  ATA_CMD_WRITE    = $30;   { WRITE SECTORS         }
  ATA_CMD_IDENTIFY = $EC;   { IDENTIFY DEVICE       }
  ATA_CMD_FLUSH    = $E7;   { FLUSH CACHE           }

  { Device/head register byte. $A0 selects the master with LBA28; $E0 adds
    the top nibble of the 28-bit LBA. }
  ATA_DRIVE_MASTER = $A0;
  ATA_DRIVE_LBA    = $E0;

  { Spin budget for one register wait, in iterations rather than
    milliseconds. Each iteration yields, so the daemon stays schedulable. }
  ATA_SPIN_LIMIT = 300000;

  { IDENTIFY DEVICE returns exactly 256 16-bit words. Words 60/61 hold the
    LBA28 addressable sector count. }
  ATA_IDENTIFY_WORDS  = 256;
  ATA_IDENTIFY_TOTAL_LOW  = 60;
  ATA_IDENTIFY_TOTAL_HIGH = 61;

  { One sector is 512 words on the data port. }
  ATA_SECTOR_WORDS = 256;

  { IPC types. 9 is the "here is my shared window" announcement consumed by
    the kernel; 10/12/14 are requests from FAT16.exe; 11/13/15 are the
    matching acknowledgements; 111 is the universal failure code. }
  IPC_ATA_READY      = 9;
  IPC_ATA_READ       = 10;
  IPC_ATA_READ_DONE  = 11;
  IPC_ATA_WRITE      = 12;
  IPC_ATA_WRITE_DONE = 13;
  IPC_ATA_FLUSH      = 14;
  IPC_ATA_FLUSH_DONE = 15;
  IPC_ATA_ERROR      = 111;
  IPC_SIGTERM        = $DEAD;

  { Cache-flush retries before declaring the platter may hold unwritten
    data on SIGTERM. }
  FLUSH_MAX_ATTEMPTS = 3;

type
  { The shared window is one physical page range mapped into every daemon.
    Offsets matter: FAT16.exe casts AtaRawBuffer as ushort[256] and casts
    FatRequestName/FatResponseData as UTF-16 strings, so this layout is an
    ABI shared with the kernel and with fat16_app. Keep it byte for byte. }
  PSharedMemoryBlock = ^TSharedMemoryBlock;
  TSharedMemoryBlock = packed record
    ShellCommandBuffer: array[0..4095] of Byte;
    FatRequestName:     array[0..4095] of Byte;
    FatResponseData:    array[0..8191] of Byte;
    AtaRawBuffer:       array[0..4095] of Byte;
  end;

var
  { 0 = size not detected yet; callers fall back to the 24-bit ceiling. }
  DetectedSectorCount: Cardinal = 0;

  SharedAddr: QWord = 0;
  { (ushort*)shared->AtaRawBuffer - the sector staging area, reached through
    the record so the layout lives in exactly one place. }
  Shared:     PSharedMemoryBlock = nil;
  AtaRaw:     PWord = nil;

  { IDENTIFY DEVICE staging. Static rather than stack-allocated: no heap,
    no exceptions, and it keeps the data off a busy-wait stack frame. }
  IdentifyData: array[0..ATA_IDENTIFY_WORDS - 1] of Word;
function AtaReadStatus: Byte; inline;
begin
  AtaReadStatus := Byte(App_InByte(ATA_PORT_STATUS) and $FF);
end;

{ Which ports this daemon is allowed to touch. Mirrors the C# helper. }
function IsPortGranted(port: Word): Boolean;
begin
  if (port >= $1F0) and (port <= $1F7) then IsPortGranted := True
  else IsPortGranted := port = ATA_PORT_CONTROL;
end;

{ After AppApi_Init every slot must resolve to a non-nil stub address. }
function IsAPIInitialized: Boolean;
begin
  IsAPIInitialized :=
    (AppApi_Slot(APP_SLOT_GET_SHARED_MEM) <> nil) and
    (AppApi_Slot(APP_SLOT_SEND_IPC)      <> nil) and
    (AppApi_Slot(APP_SLOT_RECEIVE_IPC)   <> nil) and
    (AppApi_Slot(APP_SLOT_PRINT)         <> nil) and
    (AppApi_Slot(APP_SLOT_EXIT)          <> nil);
end;

{ Block until the drive drops BSY. Bounded: a wedged controller must cost
  us one failed request, not a wedged boot. }
function WaitATA: Boolean;
var
  timeout: LongInt;
begin
  timeout := ATA_SPIN_LIMIT;
  while timeout > 0 do
  begin
    if not IsPortGranted(ATA_PORT_STATUS) then
    begin
      App_Print(W('[!] FATAL: ATA port 0x1F7 not granted!'#13#10));
      Exit(False);
    end;
    if (AtaReadStatus and ATA_ST_BUSY) = 0 then Exit(True);
    App_Yield;
    Dec(timeout);
  end;
  WaitATA := False;
end;

{ IDENTIFY DEVICE to learn the real disk capacity. Caller holds the lock. }
procedure DetectDiskSize;
var
  status: Byte;
  timeout: LongInt;
  i: Integer;
  totalSectors: Cardinal;
begin
  if not WaitATA then Exit;

  App_OutByte(ATA_PORT_DRIVE_HEAD, ATA_DRIVE_MASTER);
  App_OutByte(ATA_PORT_SECTOR_CNT, 0);
  App_OutByte(ATA_PORT_LBA_LOW, 0);
  App_OutByte(ATA_PORT_LBA_MID, 0);
  App_OutByte(ATA_PORT_LBA_HIGH, 0);
  App_OutByte(ATA_PORT_STATUS, ATA_CMD_IDENTIFY);

  status := AtaReadStatus;
  if status = 0 then Exit;   { nothing plugged in at this position }

  timeout := ATA_SPIN_LIMIT;
  while timeout > 0 do
  begin
    status := AtaReadStatus;
    if (status and ATA_ST_BUSY) = 0 then Break;
    App_Yield;
    Dec(timeout);
  end;
  if (timeout <= 0) or ((status and ATA_ST_ERR) <> 0) then Exit;

  while True do
  begin
    status := AtaReadStatus;
    if (status and ATA_ST_ERR) <> 0 then Exit;   { failed midway }
    if (status and ATA_ST_DRQ) <> 0 then Break;
  end;

  for i := 0 to ATA_IDENTIFY_WORDS - 1 do
    IdentifyData[i] := App_InWord(ATA_PORT_DATA);

  totalSectors := Cardinal(IdentifyData[ATA_IDENTIFY_TOTAL_LOW]) or
                 (Cardinal(IdentifyData[ATA_IDENTIFY_TOTAL_HIGH]) shl 16);
  if totalSectors > 0 then DetectedSectorCount := totalSectors;
end;

function IsLbaInRange(lba: Cardinal): Boolean;
begin
  if DetectedSectorCount <> 0 then
  begin
    IsLbaInRange := lba < DetectedSectorCount;
    Exit;
  end;
  IsLbaInRange := lba <= $FFFFFF;   { fallback when detection failed }
end;

{ $FF from a floating bus means nothing is listening on the channel. }
function IsATAControllerSupported: Boolean;
var
  status: Byte;
begin
  if not IsPortGranted(ATA_PORT_STATUS) then Exit(False);
  App_AcquireAtaHw;
  status := AtaReadStatus;
  App_ReleaseAtaHw;
  IsATAControllerSupported := status <> $FF;
end;

{ Last line of defence at shutdown: push the drive's write cache to the
  platter ourselves, independently of the kernel's Power path. A single
  ERR here is often just controller noise, so retry before crying out. }
procedure CleanupResources;
var
  attempt: LongInt;
  timeout: LongInt;
  error: Boolean;
  flushed: Boolean;
  status: Byte;
begin
  App_AcquireAtaHw;

  flushed := False;
  attempt := 1;
  while (attempt <= FLUSH_MAX_ATTEMPTS) and (not flushed) do
  begin
    App_OutByte(ATA_PORT_STATUS, ATA_CMD_FLUSH);
    timeout := ATA_SPIN_LIMIT;
    error := False;
    while timeout > 0 do
    begin
      status := AtaReadStatus;
      if (status and ATA_ST_BUSY) = 0 then Break;
      if (status and ATA_ST_ERR) <> 0 then
      begin
        error := True;
        Break;
      end;
      App_Yield;
      Dec(timeout);
    end;

    if (not error) and (timeout > 0) then
      flushed := True
    else if attempt < FLUSH_MAX_ATTEMPTS then
      App_Print(W('[!] ATA: Flush-on-exit attempt failed, retrying...'#13#10));

    Inc(attempt);
  end;

  if not flushed then
    App_Print(W('[!!!] ATA FATAL: Cache flush-on-exit failed after all retries! DATA LOSS POSSIBLE!'#13#10));

  App_ReleaseAtaHw;
end;

{ Shared tail of the read/write request loops: wait for BSY to clear, then
  classify. Returns True on DRQ (transfer may start), False after reporting
  an error through printError. }
function WaitDrqOrReport(printError: PWord): Boolean; inline;
var
  status: Byte;
begin
  WaitDrqOrReport := False;
  while True do
  begin
    status := AtaReadStatus;
    if (status and ATA_ST_BUSY) <> 0 then
    begin
      App_Yield;
      Continue;
    end;
    if ((status and ATA_ST_ERR) <> 0) or ((status and ATA_ST_DF) <> 0) then
    begin
      App_Print(printError);
      Exit(False);
    end;
    if (status and ATA_ST_DRQ) <> 0 then Exit(True);
  end;
end;

procedure AppMain; cdecl;
var
  msg: array[0..2] of QWord;   { TMessage is 24 bytes; see app_api }
  p: Word;
  i: LongInt;
  msgType: Cardinal;
  clientId: Cardinal;
  lba: Cardinal;
  status: Byte;
  isError: Boolean;
begin
  AppApi_Init;

  if not IsAPIInitialized then
  begin
    App_Print(W('[!] FATAL: API not initialized in ATA Driver!'#13#10));
    App_Exit;
    Exit;
  end;

  if not IsATAControllerSupported then
  begin
    App_Print(W('[!] FATAL: ATA controller not supported!'#13#10));
    App_Exit;
    Exit;
  end;

  for p := $1F0 to $1F7 do App_GrantPort(p);
  App_GrantPort(ATA_PORT_CONTROL);

  { Learn the real capacity before serving the first request - afterwards
    the alternative is reading past the end of the image. }
  App_AcquireAtaHw;
  DetectDiskSize;
  App_ReleaseAtaHw;

  SharedAddr := App_GetSharedMem;
  if SharedAddr = 0 then
  begin
    App_Print(W('[!] FATAL: Failed to get shared memory in ATA Driver!'#13#10));
    App_Exit;
    Exit;
  end;
  Shared := PSharedMemoryBlock(Pointer(SharedAddr));
  AtaRaw := PWord(PByte(@Shared^.AtaRawBuffer[0]));

  App_SendIPC(0, IPC_ATA_READY, SharedAddr);

  App_Print(W('[+] ATA Daemon (Ring 3) Forged in Steel & Waiting...'#13#10));

  while True do
  begin
    if App_ReceiveIPC(@msg[0]) = 1 then
    begin
      if (App_MsgSender(@msg[0]) = 0) and
         (App_MsgType(@msg[0]) = 0) and
         (App_MsgPayload(@msg[0]) = 0) then
      begin
        App_Print(W('[!] FATAL: Invalid IPC message received!'#13#10));
        Continue;
      end;

      clientId := App_MsgSender(@msg[0]);
      msgType  := App_MsgType(@msg[0]);
      lba      := Cardinal(App_MsgPayload(@msg[0]) and QWord($FFFFFFFF));

      { ---------------------------------------------------------------
        READ: one sector into the shared staging buffer.
        --------------------------------------------------------------- }
      if msgType = IPC_ATA_READ then
      begin
        if not IsLbaInRange(lba) then
        begin
          App_Print(W('[!] FATAL: Invalid LBA address in ATA Read!'#13#10));
          App_SendIPC(clientId, IPC_ATA_ERROR, 0);
          Continue;
        end;

        App_AcquireAtaHw;

        App_OutByte(ATA_PORT_DRIVE_HEAD,
          Word(Cardinal(ATA_DRIVE_LBA) or ((lba shr 24) and Cardinal($0F))));

        if not WaitATA then
        begin
          App_ReleaseAtaHw;
          App_SendIPC(clientId, IPC_ATA_ERROR, 0);
          Continue;
        end;

        App_OutByte(ATA_PORT_SECTOR_CNT, 1);
        App_OutByte(ATA_PORT_LBA_LOW,  Word(lba and $FF));
        App_OutByte(ATA_PORT_LBA_MID,  Word((lba shr 8) and $FF));
        App_OutByte(ATA_PORT_LBA_HIGH, Word((lba shr 16) and $FF));
        App_OutByte(ATA_PORT_STATUS, ATA_CMD_READ);

        if WaitDrqOrReport(W('[!] ATA Ring 3: Read Error!'#13#10)) then
        begin
          for i := 0 to ATA_SECTOR_WORDS - 1 do
            AtaRaw[i] := App_InWord(ATA_PORT_DATA);
          App_ReleaseAtaHw;
          App_SendIPC(clientId, IPC_ATA_READ_DONE, SharedAddr);
        end
        else
        begin
          App_ReleaseAtaHw;
          App_SendIPC(clientId, IPC_ATA_ERROR, 0);
        end;
      end

      { ---------------------------------------------------------------
        WRITE: one sector out of the shared staging buffer, then flush.
        --------------------------------------------------------------- }
      else if msgType = IPC_ATA_WRITE then
      begin
        if not IsLbaInRange(lba) then
        begin
          App_Print(W('[!] FATAL: Invalid LBA address in ATA Write!'#13#10));
          App_SendIPC(clientId, IPC_ATA_ERROR, 0);
          Continue;
        end;

        App_AcquireAtaHw;

        App_OutByte(ATA_PORT_DRIVE_HEAD,
          Word(Cardinal(ATA_DRIVE_LBA) or ((lba shr 24) and Cardinal($0F))));

        if not WaitATA then
        begin
          App_ReleaseAtaHw;
          App_SendIPC(clientId, IPC_ATA_ERROR, 0);
          Continue;
        end;

        App_OutByte(ATA_PORT_SECTOR_CNT, 1);
        App_OutByte(ATA_PORT_LBA_LOW,  Word(lba and $FF));
        App_OutByte(ATA_PORT_LBA_MID,  Word((lba shr 8) and $FF));
        App_OutByte(ATA_PORT_LBA_HIGH, Word((lba shr 16) and $FF));
        App_OutByte(ATA_PORT_STATUS, ATA_CMD_WRITE);

        isError := not WaitDrqOrReport(W('[!] ATA Ring 3: Write Timeout!'#13#10));

        if not isError then
        begin
          if AtaRaw = nil then
          begin
            App_Print(W('[!] FATAL: Null ATA raw buffer in Read!'#13#10));
            App_ReleaseAtaHw;
            App_SendIPC(clientId, IPC_ATA_ERROR, 0);
            Continue;
          end;

          for i := 0 to ATA_SECTOR_WORDS - 1 do
            App_OutWord(ATA_PORT_DATA, AtaRaw[i]);

          App_OutByte(ATA_PORT_STATUS, ATA_CMD_FLUSH);

          { The original loop had no DRQ wait here: one status read, then
            classify. Keep it - adding a wait would change how long the
            hardware lock is held. }
          while True do
          begin
            status := AtaReadStatus;
            if (status and ATA_ST_BUSY) <> 0 then
            begin
              App_Yield;
              Continue;
            end;
            if ((status and ATA_ST_ERR) <> 0) or
               ((status and ATA_ST_DF) <> 0) then
            begin
              App_Print(W('[!] ATA Ring 3: Platter write/flush failed!'#13#10));
              isError := True;
            end;
            Break;
          end;
        end;

        App_ReleaseAtaHw;
        if not isError then App_SendIPC(clientId, IPC_ATA_WRITE_DONE, SharedAddr)
        else App_SendIPC(clientId, IPC_ATA_ERROR, 0);
      end

      { ---------------------------------------------------------------
        FLUSH CACHE: independent, so callers can sync without writing.
        --------------------------------------------------------------- }
      else if msgType = IPC_ATA_FLUSH then
      begin
        App_AcquireAtaHw;

        App_OutByte(ATA_PORT_STATUS, ATA_CMD_FLUSH);
        isError := False;

        while True do
        begin
          status := AtaReadStatus;
          if (status and ATA_ST_BUSY) = 0 then Break;
          if (status and ATA_ST_ERR) <> 0 then
          begin
            App_Print(W('[!] ATA Ring 3: Cache flush failed!'#13#10));
            isError := True;
            Break;
          end;
          App_Yield;
        end;

        App_ReleaseAtaHw;
        if not isError then App_SendIPC(clientId, IPC_ATA_FLUSH_DONE, 0)
        else App_SendIPC(clientId, IPC_ATA_ERROR, 0);
      end

      else if msgType = IPC_SIGTERM then
      begin
        App_Print(W('[*] ATA: SIGTERM received. Sweeping workspace and signing off. Goodbye!'#13#10));
        CleanupResources;
        App_Exit;
      end;
      { Anything else is dropped: the next App_ReceiveIPC blocks anyway,
        and spinning on an unknown type would stall the whole disk stack. }
    end
    else
    begin
      App_WaitIPC;
    end;
  end;
end;

end.