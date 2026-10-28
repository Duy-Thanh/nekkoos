{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: ata_kernel - Ring-0 ATA PIO driver and ATA-daemon bridge.
  PORTED FROM: src/kernel/ATA.cs.

  Two paths, chosen per call:
    * UseDaemon set and the caller is not thread 0: forward the request to
      the Ring-3 ATA daemon over IPC and read the answer back out of the
      shared-memory window.
    * Otherwise (early boot, or the shutdown path): talk to the controller
      directly with PIO, under the hardware lock.

  The hardware lock is shared with the daemon through syscalls 60/61, which
  is why Ata_HwLock* are exported: ATA.EXE and the kernel must never touch
  ports 0x1F0-0x1F7 at the same time.
  =========================================================================
}
unit ata_kernel;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

function  Ata_GetUseDaemon: Boolean;
procedure Ata_SetUseDaemon(v: Boolean);
function  Ata_GetDaemonId: Cardinal;
procedure Ata_SetDaemonId(v: Cardinal);

procedure Ata_ReadSector(lba: Cardinal; buffer: PByte);
procedure Ata_WriteSector(lba: Cardinal; buffer: PByte);
procedure Ata_FlushCache;

procedure Ata_HwLockAcquire;
procedure Ata_HwLockRelease;
function  Ata_HwLockIsLocked: Boolean;

{ Base of the 5-page shared window (allocated on first use), or nil. }
function  Ata_GetSharedMem: PByte;

implementation

uses arch_interface, io, kstring, kstate, libc, pmm, spinlock, terminal,
  scheduler, ipc_kernel, arch_hal;

const
  { KernelSharedMemBlock: ShellCommand(4K) + FatRequest(4K) + FatResponse(8K)
    precede AtaRawBuffer. }
  ATA_RAW_OFFSET = 4096 + 4096 + 8192;
  SECTOR_BYTES   = 512;

  ATA_PORT_DATA   = $1F0;
  ATA_PORT_COUNT  = $1F2;
  ATA_PORT_LBA0   = $1F3;
  ATA_PORT_LBA1   = $1F4;
  ATA_PORT_LBA2   = $1F5;
  ATA_PORT_DRIVE  = $1F6;
  ATA_PORT_STATUS = $1F7;

var
  UseDaemon: Boolean = False;
  DaemonId: Cardinal = 0;

  AtaStateLock: Cardinal = 0;
  AtaIsBusy: Boolean = False;
  AtaHardwareLock: Cardinal = 0;

  DetectedSectorCount: Cardinal = 0;

function Ata_GetUseDaemon: Boolean;
begin
  Ata_GetUseDaemon := UseDaemon;
end;

procedure Ata_SetUseDaemon(v: Boolean);
begin
  UseDaemon := v;
end;

function Ata_GetDaemonId: Cardinal;
begin
  Ata_GetDaemonId := DaemonId;
end;

procedure Ata_SetDaemonId(v: Cardinal);
begin
  DaemonId := v;
end;

procedure Fatal(const msg: AnsiString);
begin
  Terminal_SetColor_Pas($00FF0000);
  Terminal_Print_Pas(W(msg));
  Terminal_SetColor_Pas($00FFFFFF);
end;

{ ── Hardware lock (shared with ATA.EXE via syscalls 60/61) ────────────────── }

procedure Ata_HwLockAcquire;
begin
  Spinlock_Acquire_Pas(@AtaHardwareLock);
end;

procedure Ata_HwLockRelease;
begin
  Spinlock_Release_Pas(@AtaHardwareLock);
end;

function Ata_HwLockIsLocked: Boolean;
begin
  Ata_HwLockIsLocked := Spinlock_IsLocked_Pas(@AtaHardwareLock) <> 0;
end;

{ ── Shared window ────────────────────────────────────────────────────────── }

function Ata_GetSharedMem: PByte;
var
  irq: Boolean;
begin
  if kstate_SharedRAM_Phys = 0 then
  begin
    { Serialise the allocation against other kernel threads. }
    irq := Sched_AcquireSchedLockSafe;
    if kstate_SharedRAM_Phys = 0 then
    begin
      kstate_SharedRAM_Phys := QWord(Pmm_AllocateContiguousPages(5));
      if kstate_SharedRAM_Phys = 0 then
      begin
        Sched_ReleaseSchedLockSafe(irq);
        Fatal('[!] FATAL: Failed to allocate shared memory for ATA!'#13#10);
        Ata_GetSharedMem := nil;
        Exit;
      end;
      MemSet(Pointer(kstate_SharedRAM_Phys), 0, 5 * 4096);
    end;
    Sched_ReleaseSchedLockSafe(irq);
  end;

  if (kstate_SharedRAM_Phys = 0) or
     (kstate_SharedRAM_Phys >= Pmm_GetTotalPages * 4096) then
  begin
    Fatal('[!] FATAL: Invalid GlobalSharedRAM_Phys in ATA GetSharedMem!'#13#10);
    Ata_GetSharedMem := nil;
    Exit;
  end;

  Ata_GetSharedMem := PByte(Pointer(kstate_SharedRAM_Phys));
end;

{ Copy between a kernel buffer and AtaRawBuffer under the window lock.
  toWindow = True copies buffer -> window. }
function CopyRawBuffer(buffer: PByte; toWindow: Boolean; const failMsg: AnsiString): Boolean;
var
  shared: PByte;
  irq: Byte;
begin
  CopyRawBuffer := False;
  shared := Ata_GetSharedMem;
  if shared = nil then
  begin
    Fatal(failMsg);
    Exit;
  end;

  { AtaRawBuffer has to lie inside physical memory. }
  if (QWord(shared) = 0) or
     (QWord(shared) + ATA_RAW_OFFSET + SECTOR_BYTES > Pmm_GetTotalPages * 4096) then
  begin
    Fatal('[!] FATAL: Shared memory AtaRawBuffer out of bounds!'#13#10);
    Exit;
  end;

  irq := Spinlock_AcquireSafe_Pas(@kstate_SharedMemLock);
  if toWindow then
    MemCopy(shared + ATA_RAW_OFFSET, buffer, SECTOR_BYTES)
  else
    MemCopy(buffer, shared + ATA_RAW_OFFSET, SECTOR_BYTES);
  Spinlock_ReleaseSafe_Pas(@kstate_SharedMemLock, irq);
  CopyRawBuffer := True;
end;

{ ── Daemon bridge ────────────────────────────────────────────────────────── }

procedure WakeDaemon;
var
  irq: Boolean;
begin
  if (DaemonId = 0) or (Integer(DaemonId) >= Sched_GetThreadCount) then Exit;
  irq := Sched_AcquireSchedLockSafe;
  if Sched_GetThreadActive(Integer(DaemonId)) = 2 then
    Sched_SetThreadActive(Integer(DaemonId), 1);
  Sched_ReleaseSchedLockSafe(irq);
end;

procedure AcquireAtaAsync;
var
  irq: Byte;
begin
  while True do
  begin
    irq := Spinlock_AcquireSafe_Pas(@AtaStateLock);
    if not AtaIsBusy then
    begin
      AtaIsBusy := True;
      Spinlock_ReleaseSafe_Pas(@AtaStateLock, irq);
      Exit;
    end;
    Spinlock_ReleaseSafe_Pas(@AtaStateLock, irq);
    Sched_Yield;
  end;
end;

procedure ReleaseAtaAsync;
var
  irq: Byte;
begin
  irq := Spinlock_AcquireSafe_Pas(@AtaStateLock);
  AtaIsBusy := False;
  Spinlock_ReleaseSafe_Pas(@AtaStateLock, irq);
end;

{ ── Direct PIO ───────────────────────────────────────────────────────────── }

function WaitAtaHardware: Boolean;
var
  timeout: Integer;
begin
  timeout := 1000000;
  while timeout > 0 do
  begin
    if (Io_In8(ATA_PORT_STATUS) and $80) = 0 then
    begin
      WaitAtaHardware := True;
      Exit;
    end;
    Dec(timeout);
  end;
  WaitAtaHardware := False;
end;

{ IDENTIFY DEVICE (0xEC) to learn the real disk size, never a hard-coded one.
  Only reached while UseDaemon is False. }
procedure DetectDiskSize;
var
  status: Byte;
  timeout, i: Integer;
  identify: array[0..255] of Word;
  total: Cardinal;
begin
  if not Hal_HasPortIo then Exit;
  if not WaitAtaHardware then Exit;

  Io_Out8(ATA_PORT_DRIVE, $A0);
  Io_Out8(ATA_PORT_COUNT, 0);
  Io_Out8(ATA_PORT_LBA0, 0);
  Io_Out8(ATA_PORT_LBA1, 0);
  Io_Out8(ATA_PORT_LBA2, 0);
  Io_Out8(ATA_PORT_STATUS, $EC);

  status := Io_In8(ATA_PORT_STATUS);
  if status = 0 then Exit;

  timeout := 1000000;
  while timeout > 0 do
  begin
    status := Io_In8(ATA_PORT_STATUS);
    if (status and $80) = 0 then Break;
    Dec(timeout);
  end;
  if (timeout <= 0) or ((status and $01) <> 0) then Exit;

  while True do
  begin
    status := Io_In8(ATA_PORT_STATUS);
    if (status and $01) <> 0 then Exit;
    if (status and $08) <> 0 then Break;
  end;

  for i := 0 to 255 do identify[i] := Io_In16(ATA_PORT_DATA);

  total := Cardinal(identify[60]) or (Cardinal(identify[61]) shl 16);
  if total > 0 then DetectedSectorCount := total;
end;

function IsLbaInRange(lba: Cardinal): Boolean;
var
  irq: Byte;
begin
  irq := Spinlock_AcquireSafe_Pas(@AtaHardwareLock);
  if DetectedSectorCount = 0 then DetectDiskSize;
  Spinlock_ReleaseSafe_Pas(@AtaHardwareLock, irq);

  if DetectedSectorCount <> 0 then
    IsLbaInRange := lba < DetectedSectorCount
  else
    IsLbaInRange := lba <= $FFFFFF;
end;

procedure SelectLba(lba: Cardinal);
begin
  Io_Out8(ATA_PORT_DRIVE, Byte($E0 or ((lba shr 24) and $0F)));
end;

procedure SetupTransfer(lba: Cardinal);
begin
  Io_Out8(ATA_PORT_COUNT, 1);
  Io_Out8(ATA_PORT_LBA0, Byte(lba and $FF));
  Io_Out8(ATA_PORT_LBA1, Byte((lba shr 8) and $FF));
  Io_Out8(ATA_PORT_LBA2, Byte((lba shr 16) and $FF));
end;

{ ── Public operations ────────────────────────────────────────────────────── }

procedure Ata_ReadSector(lba: Cardinal; buffer: PByte);
var
  caller: Integer;
  rType, rSender: Cardinal;
  rPayload: QWord;
  irq: Byte;
  status: Byte;
  i: Integer;
  w: PWord;
begin
  if buffer = nil then
  begin
    Fatal('[!] FATAL: Null buffer in ATA ReadSector!'#13#10);
    Exit;
  end;

  caller := Sched_GetCurrentThreadId;

  { The range check probes the controller (IDENTIFY over port I/O), so it
    belongs to the direct path only. Through the daemon, the daemon checks
    the LBA against its own device, and the kernel must not touch hardware it
    may not even have (ARM64: there are no I/O ports; the probe hung). }
  if not (UseDaemon and (caller <> 0)) and (not IsLbaInRange(lba)) then
  begin
    Fatal('[!] FATAL: Invalid LBA address in ATA ReadSector!'#13#10);
    Exit;
  end;

  if UseDaemon and (caller <> 0) then
  begin
    AcquireAtaAsync;
    IpcK_Send(10, Cardinal(caller), DaemonId, lba);
    WakeDaemon;

    rType := 0; rSender := 0; rPayload := 0;
    while True do
    begin
      if IpcK_ReceiveForRaw(Cardinal(caller), rType, rSender, rPayload) then
      begin
        if rType = 11 then
        begin
          if not CopyRawBuffer(buffer, False,
            '[!] FATAL: Failed to get shared memory in ATA ReadSector!'#13#10) then
          begin
            ReleaseAtaAsync;
            Exit;
          end;
          ReleaseAtaAsync;
          Exit;
        end
        else if rType = 111 then
        begin
          Fatal('[!] ATA Ring 0: Read Error from Daemon!'#13#10);
          ReleaseAtaAsync;
          Exit;
        end;
      end;
      Sched_Yield;
    end;
  end;

  { Direct controller access: only where the controller can exist. }
  if not Hal_HasPortIo then
  begin
    Fatal('[!] ATA: no direct disk access on this architecture (daemon not up)'#13#10);
    Exit;
  end;

  irq := Spinlock_AcquireSafe_Pas(@AtaHardwareLock);

  SelectLba(lba);

  if not WaitAtaHardware then
  begin
    Fatal('[!] ATA HW Read Error: Drive Select Timeout!'#13#10);
    Spinlock_ReleaseSafe_Pas(@AtaHardwareLock, irq);
    Exit;
  end;

  SetupTransfer(lba);
  Io_Out8(ATA_PORT_STATUS, $20);   { READ SECTORS (PIO) }

  while True do
  begin
    status := Io_In8(ATA_PORT_STATUS);
    if (status and $80) <> 0 then Continue;          { wait for BSY to clear }

    if ((status and $01) <> 0) or ((status and $20) <> 0) then
    begin
      Fatal('[!] ATA HW Read Error!'#13#10);
      Spinlock_ReleaseSafe_Pas(@AtaHardwareLock, irq);
      Exit;
    end;

    if (status and $08) <> 0 then Break;             { DRQ: data is ready }
  end;

  w := PWord(buffer);
  for i := 0 to 255 do w[i] := Io_In16(ATA_PORT_DATA);

  Spinlock_ReleaseSafe_Pas(@AtaHardwareLock, irq);
end;

procedure Ata_WriteSector(lba: Cardinal; buffer: PByte);
var
  caller: Integer;
  rType, rSender: Cardinal;
  rPayload: QWord;
  irq: Byte;
  status: Byte;
  i: Integer;
  w: PWord;
begin
  if buffer = nil then
  begin
    Fatal('[!] FATAL: Null buffer in ATA WriteSector!'#13#10);
    Exit;
  end;

  caller := Sched_GetCurrentThreadId;

  { The range check probes the controller (IDENTIFY over port I/O), so it
    belongs to the direct path only. Through the daemon, the daemon checks
    the LBA against its own device, and the kernel must not touch hardware it
    may not even have (ARM64: there are no I/O ports; the probe hung). }
  if not (UseDaemon and (caller <> 0)) and (not IsLbaInRange(lba)) then
  begin
    Fatal('[!] FATAL: Invalid LBA address in ATA WriteSector!'#13#10);
    Exit;
  end;

  if UseDaemon and (caller <> 0) then
  begin
    AcquireAtaAsync;

    if not CopyRawBuffer(buffer, True,
      '[!] FATAL: Failed to get shared memory in ATA WriteSector!'#13#10) then
    begin
      ReleaseAtaAsync;
      Exit;
    end;

    IpcK_Send(12, Cardinal(caller), DaemonId, lba);
    WakeDaemon;

    rType := 0; rSender := 0; rPayload := 0;
    while True do
    begin
      if IpcK_ReceiveForRaw(Cardinal(caller), rType, rSender, rPayload) then
      begin
        if rType = 13 then
        begin
          ReleaseAtaAsync;
          Exit;
        end
        else if rType = 111 then
        begin
          Fatal('[!] ATA Ring 0: Write Error from Daemon!'#13#10);
          ReleaseAtaAsync;
          Exit;
        end;
      end;
      Sched_Yield;
    end;
  end;

  { Direct controller access: only where the controller can exist. }
  if not Hal_HasPortIo then
  begin
    Fatal('[!] ATA: no direct disk access on this architecture (daemon not up)'#13#10);
    Exit;
  end;

  irq := Spinlock_AcquireSafe_Pas(@AtaHardwareLock);

  if not WaitAtaHardware then
  begin
    Spinlock_ReleaseSafe_Pas(@AtaHardwareLock, irq);
    Exit;
  end;

  SelectLba(lba);

  if not WaitAtaHardware then
  begin
    Fatal('[!] ATA HW Write Error: Drive Select Timeout!'#13#10);
    Spinlock_ReleaseSafe_Pas(@AtaHardwareLock, irq);
    Exit;
  end;

  SetupTransfer(lba);
  Io_Out8(ATA_PORT_STATUS, $30);   { WRITE SECTORS (PIO) }

  while True do
  begin
    status := Io_In8(ATA_PORT_STATUS);
    if (status and $80) <> 0 then Continue;

    if ((status and $01) <> 0) or ((status and $20) <> 0) then
    begin
      Fatal('[!] ATA HW Write error: DRQ Timeout!'#13#10);
      Spinlock_ReleaseSafe_Pas(@AtaHardwareLock, irq);
      Exit;
    end;
    if (status and $08) <> 0 then Break;
  end;

  w := PWord(buffer);
  for i := 0 to 255 do Io_Out16(ATA_PORT_DATA, w[i]);

  Io_Out8(ATA_PORT_STATUS, $E7);   { CACHE FLUSH }

  while True do
  begin
    status := Io_In8(ATA_PORT_STATUS);
    if (status and $80) <> 0 then Continue;

    if ((status and $01) <> 0) or ((status and $20) <> 0) then
    begin
      Fatal('[!] ATA HW Write error: Platter write/flush failed!'#13#10);
      Spinlock_ReleaseSafe_Pas(@AtaHardwareLock, irq);
      Exit;
    end;
    Break;
  end;

  Spinlock_ReleaseSafe_Pas(@AtaHardwareLock, irq);
end;

procedure Ata_FlushCache;
var
  caller: Integer;
  rType, rSender: Cardinal;
  rPayload: QWord;
  irq: Byte;
  status: Byte;
begin
  caller := Sched_GetCurrentThreadId;

  if UseDaemon and (caller <> 0) then
  begin
    AcquireAtaAsync;
    IpcK_Send(14, Cardinal(caller), DaemonId, 0);
    WakeDaemon;

    rType := 0; rSender := 0; rPayload := 0;
    while True do
    begin
      if IpcK_ReceiveForRaw(Cardinal(caller), rType, rSender, rPayload) then
      begin
        if rType = 15 then
        begin
          ReleaseAtaAsync;
          Exit;
        end
        else if rType = 111 then
        begin
          Fatal('[!] ATA Ring 0: Flush Error from Daemon!'#13#10);
          ReleaseAtaAsync;
          Exit;
        end;
      end;
      Sched_Yield;
    end;
  end;

  { Direct controller access: only where the controller can exist. }
  if not Hal_HasPortIo then
  begin
    { The disk daemon flushes (or writes through) on its own. }
    Exit;
  end;

  irq := Spinlock_AcquireSafe_Pas(@AtaHardwareLock);

  Io_Out8(ATA_PORT_STATUS, $E7);   { 0xE7 is FLUSH CACHE; 0xEA would be the EXT variant }

  while True do
  begin
    status := Io_In8(ATA_PORT_STATUS);
    if (status and $80) = 0 then Break;
    if (status and $01) <> 0 then
    begin
      Fatal('[!] ATA HW Write error: Cache flush failed!'#13#10);
      Spinlock_ReleaseSafe_Pas(@AtaHardwareLock, irq);
      Exit;
    end;
  end;

  Spinlock_ReleaseSafe_Pas(@AtaHardwareLock, irq);
end;

{ ── cdecl exports for ATA.cs ── }

function Ata_GetUseDaemon_Pas: Byte; cdecl; public name 'Ata_GetUseDaemon_Pas';
begin
  Ata_GetUseDaemon_Pas := Ord(UseDaemon);
end;

procedure Ata_SetUseDaemon_Pas(v: Byte); cdecl; public name 'Ata_SetUseDaemon_Pas';
begin
  UseDaemon := v <> 0;
end;

function Ata_GetDaemonId_Pas: Cardinal; cdecl; public name 'Ata_GetDaemonId_Pas';
begin
  Ata_GetDaemonId_Pas := DaemonId;
end;

procedure Ata_SetDaemonId_Pas(v: Cardinal); cdecl; public name 'Ata_SetDaemonId_Pas';
begin
  DaemonId := v;
end;

procedure Ata_ReadSector_Pas(lba: Cardinal; buffer: PByte); cdecl; public name 'Ata_ReadSector_Pas';
begin
  Ata_ReadSector(lba, buffer);
end;

procedure Ata_WriteSector_Pas(lba: Cardinal; buffer: PByte); cdecl; public name 'Ata_WriteSector_Pas';
begin
  Ata_WriteSector(lba, buffer);
end;

procedure Ata_FlushCache_Pas; cdecl; public name 'Ata_FlushCache_Pas';
begin
  Ata_FlushCache;
end;

procedure Ata_HwLockAcquire_Pas; cdecl; public name 'Ata_HwLockAcquire_Pas';
begin
  Ata_HwLockAcquire;
end;

procedure Ata_HwLockRelease_Pas; cdecl; public name 'Ata_HwLockRelease_Pas';
begin
  Ata_HwLockRelease;
end;

function Ata_HwLockIsLocked_Pas: Byte; cdecl; public name 'Ata_HwLockIsLocked_Pas';
begin
  Ata_HwLockIsLocked_Pas := Ord(Ata_HwLockIsLocked);
end;

function Ata_GetSharedMem_Pas: PByte; cdecl; public name 'Ata_GetSharedMem_Pas';
begin
  Ata_GetSharedMem_Pas := Ata_GetSharedMem;
end;

end.
