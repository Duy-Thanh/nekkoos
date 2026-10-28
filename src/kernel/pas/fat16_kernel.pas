{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: fat16_kernel - kernel-side FAT16 client.
  PORTED FROM: src/kernel/FAT16.cs.

  Two ways to reach the disk:
    * Early boot, before the FAT16 daemon exists (UseDaemon = False, or the
      caller is thread 0 / forced to 0): read the volume directly through the
      ring-0 ATA driver. Read-only; this is how ATA.EXE, FAT16.EXE and
      MOUSE.EXE themselves are loaded.
    * Afterwards: the ring-3 FAT16 daemon owns the filesystem (permissions,
      directories, writes). The kernel only relays requests over IPC and
      moves data through the shared-memory window. There is deliberately no
      raw fallback for mkdir/rm/chmod/chown: access control must stay in ring 3.

  Only the entry points something calls are ported. The C# file also had a
  raw WriteFile, Ls, Cat, Run and FAT editing helpers that nothing used.
  =========================================================================
}
unit fat16_kernel;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

procedure Fat16K_Init;

{ Returns a heap buffer with the file's bytes (caller frees), or nil.
  callerThreadOverride >= 0 pins the identity used for IPC and the daemon
  decision (0 forces the raw path); -1 means "whoever is running". }
function  Fat16K_ReadFile(filename: PWord; outSize: PCardinal; callerThreadOverride: Integer): PByte;

procedure Fat16K_Cd(dirname: PWord; callerThreadOverride: Integer);
function  Fat16K_ListDir(outBuf: PWord; outCap: Integer; callerThread: Integer): Boolean;
function  Fat16K_WriteFileRelay(filename: PWord; data: PByte; size: Cardinal; callerThread: Integer): Integer;
function  Fat16K_MakeDir(dirname: PWord; callerThread: Integer): Integer;
function  Fat16K_RemoveFile(filename: PWord; callerThread: Integer): Integer;
function  Fat16K_RemoveDir(dirname: PWord; callerThread: Integer): Integer;
function  Fat16K_Chmod(path: PWord; mode: Cardinal; callerThread: Integer): Integer;
function  Fat16K_Chown(path, ownerStr: PWord; callerThread: Integer): Integer;

function  Fat16K_GetUseDaemon: Boolean;
procedure Fat16K_SetUseDaemon(v: Boolean);
function  Fat16K_GetDaemonId: Cardinal;
procedure Fat16K_SetDaemonId(v: Cardinal);
function  Fat16K_GetTrustedThreadId: Integer;
procedure Fat16K_SetTrustedThreadId(v: Integer);

implementation

uses arch_interface, console, fat16, heap, ipc_kernel, kstate, kstring,
  libc, pmm, scheduler, spinlock, ata_kernel;

const
  { KernelSharedMemBlock offsets. }
  SHM_REQUEST_NAME  = 4096;
  SHM_RESPONSE_DATA = 4096 + 4096;
  SHM_RESPONSE_SIZE = 8192;

  SECTOR_BYTES = 512;

  { A wait that long means the daemon is gone, not slow. }
  DAEMON_SPIN_LIMIT = QWord(2000000000);

  { IPC protocol with the FAT16 daemon. }
  REQ_READ        = 30;  RSP_READ_SIZE    = 31;  REQ_READ_ACK = 311;
  RSP_READ_CHUNK  = 38;  REQ_READ_NEXT    = 39;  RSP_READ_EOF = 42;
  REQ_WRITE       = 32;  RSP_WRITE_NEED   = 33;  REQ_WRITE_CHUNK = 34;  RSP_WRITE_DONE = 35;
  REQ_CD          = 36;  RSP_CD           = 37;
  REQ_LS          = 40;  RSP_LS           = 41;
  REQ_MKDIR       = 44;  RSP_MKDIR        = 45;
  REQ_RM          = 46;  RSP_RM           = 47;
  REQ_RMDIR       = 48;  RSP_RMDIR        = 49;
  REQ_CHMOD       = 58;  RSP_CHMOD        = 59;
  REQ_CHOWN       = 60;  RSP_CHOWN        = 61;

var
  UseDaemon: Boolean = False;
  DaemonId: Cardinal = 0;
  { Thread id of the daemon as recorded by the kernel when it spawned it. Unlike
    DaemonId (set after the handshake) it cannot be spoofed by a program that
    merely claims the name; syscall 5 uses it to authenticate the daemon. }
  TrustedThreadId: Integer = -1;

  { Cached BPB fields and derived geometry. }
  BytesPerSector: Word = 512;
  SectorsPerCluster: Byte = 1;
  ReservedSectorCount: Word = 0;
  FatStartLba: Cardinal = 0;
  RootDirLba: Cardinal = 0;
  FirstDataSector: Cardinal = 0;
  RootDirSectors: Cardinal = 0;
  CurrentDirCluster: Word = 0;
  IsInitialized: Boolean = False;

  VfsStateLock: Cardinal = 0;
  VfsIsBusy: Boolean = False;

function Fat16K_GetUseDaemon: Boolean;
begin
  Fat16K_GetUseDaemon := UseDaemon;
end;

procedure Fat16K_SetUseDaemon(v: Boolean);
begin
  UseDaemon := v;
end;

function Fat16K_GetDaemonId: Cardinal;
begin
  Fat16K_GetDaemonId := DaemonId;
end;

procedure Fat16K_SetDaemonId(v: Cardinal);
begin
  DaemonId := v;
end;

function Fat16K_GetTrustedThreadId: Integer;
begin
  Fat16K_GetTrustedThreadId := TrustedThreadId;
end;

procedure Fat16K_SetTrustedThreadId(v: Integer);
begin
  TrustedThreadId := v;
end;

{ ── Small helpers ────────────────────────────────────────────────────────── }

procedure Err(const msg: AnsiString);
begin
  Con_SetColor($00FF0000);
  Con_Print(W(msg));
end;

procedure ErrWhite(const msg: AnsiString);
begin
  Err(msg);
  Con_SetColor($00FFFFFF);
end;

function SharedMem: PByte;
begin
  SharedMem := Ata_GetSharedMem;
end;

procedure AcquireVfs;
var
  irq: Byte;
begin
  while True do
  begin
    irq := Spinlock_AcquireSafe_Pas(@VfsStateLock);
    if not VfsIsBusy then
    begin
      VfsIsBusy := True;
      Spinlock_ReleaseSafe_Pas(@VfsStateLock, irq);
      Exit;
    end;
    Spinlock_ReleaseSafe_Pas(@VfsStateLock, irq);
    Sched_Yield;
  end;
end;

procedure ReleaseVfs;
var
  irq: Byte;
begin
  irq := Spinlock_AcquireSafe_Pas(@VfsStateLock);
  VfsIsBusy := False;
  Spinlock_ReleaseSafe_Pas(@VfsStateLock, irq);
end;

procedure WakeDaemon;
var
  i: Integer;
  irq: Boolean;
  n: PByte;
begin
  if DaemonId = 0 then
  begin
    irq := Sched_AcquireSchedLockSafe;
    for i := 1 to Sched_GetThreadCount - 1 do
    begin
      n := Sched_GetThreadName(i);
      if (n <> nil) and (n[0] = Ord('F')) and (n[1] = Ord('A')) and (n[2] = Ord('T')) then
      begin
        DaemonId := Cardinal(i);
        Break;
      end;
    end;
    Sched_ReleaseSchedLockSafe(irq);
  end;

  if (DaemonId <> 0) and (Integer(DaemonId) < Sched_GetThreadCount) then
  begin
    irq := Sched_AcquireSchedLockSafe;
    Sched_SetThreadActive(Integer(DaemonId), 1);
    Sched_ReleaseSchedLockSafe(irq);
  end;
end;

{ Count one more spin; True means give up. }
function DaemonWaitTimedOut(var spin: QWord): Boolean;
begin
  Inc(spin);
  if spin > DAEMON_SPIN_LIMIT then
  begin
    ErrWhite('[!] VFS: FAT16 daemon not responding (timeout)!'#13#10);
    DaemonWaitTimedOut := True;
  end
  else
    DaemonWaitTimedOut := False;
end;

{ Copy a request name into the shared window under the window lock. }
procedure PutRequestName(shared: PByte; name: PWord);
var
  irq: Byte;
begin
  irq := Spinlock_AcquireSafe_Pas(@kstate_SharedMemLock);
  StrCpyLimited(PWord(shared + SHM_REQUEST_NAME), name, 255);
  Spinlock_ReleaseSafe_Pas(@kstate_SharedMemLock, irq);
end;

{ One request/one reply round trip with a numeric result in the payload.
  Returns False on timeout. }
function RoundTrip(callerThread: Integer; reqType, rspType: Cardinal; payload: QWord;
  out outVal: QWord): Boolean;
var
  rType, rSender: Cardinal;
  rPayload: QWord;
  spin: QWord;
begin
  RoundTrip := False;
  outVal := 0;
  IpcK_Send(reqType, Cardinal(callerThread), DaemonId, payload);
  WakeDaemon;

  rType := 0; rSender := 0; rPayload := 0;
  spin := 0;
  while True do
  begin
    if IpcK_ReceiveForRaw(Cardinal(callerThread), rType, rSender, rPayload) and
       (rType = rspType) then
    begin
      outVal := rPayload;
      RoundTrip := True;
      Exit;
    end;
    if DaemonWaitTimedOut(spin) then Exit;
    IpcK_WaitForMessage(Cardinal(callerThread));
  end;
end;

{ ── Init and raw directory walking ───────────────────────────────────────── }

procedure Fat16K_Init;
var
  bpb: PByte;
  rootSectors, rootLba, firstData: Cardinal;
  partType: Byte;
  partLba: Cardinal;
begin
  bpb := PByte(Heap_Alloc(SECTOR_BYTES));
  if bpb = nil then
  begin
    Err('[!] FATAL: Failed to allocate BPB buffer in FAT16 Init!'#13#10);
    Exit;
  end;

  Ata_ReadSector(0, bpb);

  { MBR partition entry 1 at offset 446: type at +4, LBA start at +8. }
  partType := bpb[446 + 4];
  partLba := PCardinal(bpb + 446 + 8)^;
  if (partType > 0) and (partLba > 0) then
  begin
    FatStartLba := partLba;
    Ata_ReadSector(FatStartLba, bpb);
  end
  else
    FatStartLba := 0;

  BytesPerSector := PWord(bpb + 11)^;
  SectorsPerCluster := bpb[13];
  ReservedSectorCount := PWord(bpb + 14)^;

  { A zeroed BPB would divide by zero below; patch both the cache and the
    buffer ParseBPB reads. }
  if BytesPerSector = 0 then
  begin
    BytesPerSector := 512;
    PWord(bpb + 11)^ := 512;
  end;
  if SectorsPerCluster = 0 then
  begin
    SectorsPerCluster := 1;
    bpb[13] := 1;
  end;

  FAT16_ParseBPB_Pas(bpb, @rootSectors, @rootLba, @firstData);
  RootDirSectors := rootSectors;
  RootDirLba := FatStartLba + rootLba;
  FirstDataSector := FatStartLba + firstData;

  IsInitialized := True;
  CurrentDirCluster := 0;

  Heap_Free(bpb);
  Con_SetColor($0000FF00);
  Con_Print(W('[+] VFS FAT16 Initialized Successfully!'#13#10));
end;

{ Look a name up in the current directory. Returns True when found. }
function FindEntry(name: PWord; outCluster: PWord; outSize: PCardinal; outAttr: PByte): Boolean;
var
  sectorBuf, formatted, fatBuf: PByte;
  found, abort: Boolean;
  s, st, k: Integer;
  cluster: Word;
  clusterLba, fatSector: Cardinal;
  sec: Cardinal;
begin
  FindEntry := False;
  if (name = nil) or (outCluster = nil) or (outSize = nil) or (outAttr = nil) then
  begin
    Err('[!] FATAL: Null pointer in FindEntry!'#13#10);
    Exit;
  end;

  sectorBuf := PByte(Heap_Alloc(SECTOR_BYTES));
  formatted := PByte(Heap_Alloc(11));
  if (sectorBuf = nil) or (formatted = nil) then
  begin
    Err('[!] FATAL: Failed to allocate memory in FindEntry!'#13#10);
    if sectorBuf <> nil then Heap_Free(sectorBuf);
    if formatted <> nil then Heap_Free(formatted);
    Exit;
  end;

  if (name[0] = Ord('.')) and (name[1] = Ord('.')) and (name[2] = 0) then
  begin
    formatted[0] := Ord('.');
    formatted[1] := Ord('.');
    for k := 2 to 10 do formatted[k] := Ord(' ');
  end
  else
    FormatFATName(name, formatted);

  found := False;

  if CurrentDirCluster = 0 then
  begin
    if RootDirSectors > $10000 then
    begin
      Err('[!] FATAL: Invalid root directory sectors in FindEntry!'#13#10);
      Heap_Free(sectorBuf);
      Heap_Free(formatted);
      Exit;
    end;

    sec := 0;
    while sec < RootDirSectors do
    begin
      Ata_ReadSector(RootDirLba + sec, sectorBuf);
      st := FAT16_CheckSector_Pas(sectorBuf, formatted, outCluster, outSize, outAttr, nil, nil, nil);
      if st = 1 then begin found := True; Break; end;
      if st = 2 then Break;
      Inc(sec);
    end;
  end
  else
  begin
    cluster := CurrentDirCluster;
    fatBuf := PByte(Heap_Alloc(SECTOR_BYTES));
    if fatBuf = nil then
    begin
      Err('[!] FATAL: Failed to allocate FAT buffer in FindEntry!'#13#10);
      Heap_Free(sectorBuf);
      Heap_Free(formatted);
      Exit;
    end;

    while (cluster >= $0002) and (cluster <= $FFEF) do
    begin
      clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, cluster, SectorsPerCluster);
      if clusterLba > $FFFFFF then
      begin
        Err('[!] FATAL: Invalid cluster LBA in FindEntry!'#13#10);
        Heap_Free(fatBuf);
        Heap_Free(sectorBuf);
        Heap_Free(formatted);
        Exit;
      end;

      abort := False;
      for s := 0 to SectorsPerCluster - 1 do
      begin
        Ata_ReadSector(clusterLba + Cardinal(s), sectorBuf);
        st := FAT16_CheckSector_Pas(sectorBuf, formatted, outCluster, outSize, outAttr, nil, nil, nil);
        if st = 1 then begin found := True; Break; end;
        if st = 2 then begin abort := True; Break; end;
      end;
      if found or abort then Break;

      fatSector := FAT16_FatSectorForCluster_Pas(FatStartLba, ReservedSectorCount, cluster);
      Ata_ReadSector(fatSector, fatBuf);
      cluster := FAT16_GetNextCluster_Pas(fatBuf, cluster);
    end;
    Heap_Free(fatBuf);
  end;

  Heap_Free(sectorBuf);
  Heap_Free(formatted);
  FindEntry := found;
end;

{ Raw read: follow the cluster chain through the ring-0 ATA driver. }
function RawReadFile(filename: PWord; outSize: PCardinal): PByte;
var
  cluster: Word;
  fileSize: Cardinal;
  attr: Byte;
  fileBuffer, sectorBuf, fatBuf, ptr: PByte;
  bytesRead, clusterLba, fatSector: Cardinal;
  s, b: Integer;
begin
  RawReadFile := nil;
  if not IsInitialized then Exit;

  cluster := 0; fileSize := 0; attr := 0;
  FindEntry(filename, @cluster, @fileSize, @attr);

  if (cluster = 0) and (fileSize = 0) then
  begin
    Err('[!] App not found on disk!'#13#10);
    Exit;
  end;

  fileBuffer := PByte(Heap_Alloc(fileSize));
  if fileBuffer = nil then
  begin
    Err('[!] FAT16: Out of Heap Memory!'#13#10);
    Exit;
  end;
  sectorBuf := PByte(Heap_Alloc(SECTOR_BYTES));
  if sectorBuf = nil then begin Heap_Free(fileBuffer); Exit; end;
  fatBuf := PByte(Heap_Alloc(SECTOR_BYTES));
  if fatBuf = nil then begin Heap_Free(fileBuffer); Heap_Free(sectorBuf); Exit; end;

  bytesRead := 0;
  ptr := fileBuffer;

  while (cluster >= $0002) and (cluster <= $FFEF) and (bytesRead < fileSize) do
  begin
    clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, cluster, SectorsPerCluster);
    if clusterLba > $FFFFFF then
    begin
      Err('[!] FATAL: Invalid cluster LBA in ReadFile!'#13#10);
      Heap_Free(sectorBuf); Heap_Free(fatBuf); Heap_Free(fileBuffer);
      Exit;
    end;

    for s := 0 to SectorsPerCluster - 1 do
    begin
      Ata_ReadSector(clusterLba + Cardinal(s), sectorBuf);
      for b := 0 to SECTOR_BYTES - 1 do
      begin
        if bytesRead >= fileSize then Break;
        ptr^ := sectorBuf[b];
        Inc(ptr);
        Inc(bytesRead);
      end;
      if bytesRead >= fileSize then Break;
    end;

    fatSector := FAT16_FatSectorForCluster_Pas(FatStartLba, ReservedSectorCount, cluster);
    if fatSector > $FFFFFF then
    begin
      Err('[!] FATAL: Invalid FAT sector in ReadFile!'#13#10);
      Heap_Free(sectorBuf); Heap_Free(fatBuf); Heap_Free(fileBuffer);
      Exit;
    end;

    Ata_ReadSector(fatSector, fatBuf);
    cluster := FAT16_GetNextCluster_Pas(fatBuf, cluster);
  end;

  Heap_Free(sectorBuf);
  Heap_Free(fatBuf);
  if outSize <> nil then outSize^ := fileSize;
  RawReadFile := fileBuffer;
end;

{ Daemon read: the daemon announces the size, then streams 512-byte chunks
  through the response window; the kernel acks each one. }
function DaemonReadFile(filename: PWord; outSize: PCardinal; callerThread: Integer): PByte;
var
  shared, dataChunk, daemonBuf: PByte;
  rType, rSender, daemonSize, offset: Cardinal;
  rPayload: QWord;
  spin: QWord;
  irq: Byte;
  i: Integer;
begin
  DaemonReadFile := nil;
  shared := SharedMem;
  if shared = nil then
  begin
    Err('[!] FATAL: Failed to get shared memory in ReadFile!'#13#10);
    Exit;
  end;

  PutRequestName(shared, filename);

  IpcK_Send(REQ_READ, Cardinal(callerThread), DaemonId, 0);
  WakeDaemon;

  rType := 0; rSender := 0; rPayload := 0;
  daemonSize := 0;
  daemonBuf := nil;
  dataChunk := shared + SHM_RESPONSE_DATA;
  spin := 0;

  if QWord(shared) + SHM_RESPONSE_DATA + SHM_RESPONSE_SIZE > Pmm_GetTotalPages * 4096 then
  begin
    Err('[!] FATAL: Shared memory FatResponseData out of bounds in ReadFile!'#13#10);
    Exit;
  end;

  while True do
  begin
    if IpcK_ReceiveForRaw(Cardinal(callerThread), rType, rSender, rPayload) then
    begin
      if rType = RSP_READ_SIZE then
      begin
        daemonSize := Cardinal(rPayload);
        if daemonSize = 0 then Exit;     { empty or missing }

        if outSize <> nil then outSize^ := daemonSize;
        daemonBuf := PByte(Heap_Alloc(daemonSize));
        if daemonBuf = nil then
        begin
          ErrWhite('[!] FAT16 Kernel: OOM! Cannot allocate IPC Read buffer!'#13#10);
          Exit;
        end;

        IpcK_Send(REQ_READ_ACK, Cardinal(callerThread), DaemonId, 0);
        WakeDaemon;
      end
      else if rType = RSP_READ_CHUNK then
      begin
        offset := Cardinal(rPayload);
        if offset >= daemonSize then
        begin
          Err('[!] FATAL: Invalid offset in ReadFile!'#13#10);
          if daemonBuf <> nil then Heap_Free(daemonBuf);
          Exit;
        end;

        { Copy under the window lock so the daemon cannot overwrite mid-copy. }
        irq := Spinlock_AcquireSafe_Pas(@kstate_SharedMemLock);
        for i := 0 to SECTOR_BYTES - 1 do
          if offset + Cardinal(i) < daemonSize then
            daemonBuf[offset + Cardinal(i)] := dataChunk[i];
        Spinlock_ReleaseSafe_Pas(@kstate_SharedMemLock, irq);

        IpcK_Send(REQ_READ_NEXT, Cardinal(callerThread), DaemonId, 0);
        WakeDaemon;
      end
      else if rType = RSP_READ_EOF then
      begin
        DaemonReadFile := daemonBuf;
        Exit;
      end;
    end;

    if DaemonWaitTimedOut(spin) then
    begin
      Con_SetColor($00FF00FF);
      Con_Print(W('[!] VFS: daemon timeout!'#13#10));
      Con_SetColor($00FFFFFF);
      Exit;
    end;
    IpcK_WaitForMessage(Cardinal(callerThread));
  end;
end;

function Fat16K_ReadFile(filename: PWord; outSize: PCardinal; callerThreadOverride: Integer): PByte;
var
  caller: Integer;
begin
  Fat16K_ReadFile := nil;
  if filename = nil then
  begin
    Err('[!] FATAL: Null filename in ReadFile!'#13#10);
    Exit;
  end;

  AcquireVfs;

  { If the caller pinned its identity before enabling interrupts, trust that
    over re-reading it here: a timer tick in between may have moved this core
    to another thread, and the IPC would then go out under the wrong UID. }
  if callerThreadOverride >= 0 then caller := callerThreadOverride
  else caller := Sched_GetCurrentThreadId;

  if UseDaemon and (caller <> 0) then
    Fat16K_ReadFile := DaemonReadFile(filename, outSize, caller)
  else
    Fat16K_ReadFile := RawReadFile(filename, outSize);

  ReleaseVfs;
end;

{ ── Daemon-only operations ───────────────────────────────────────────────── }

procedure Fat16K_Cd(dirname: PWord; callerThreadOverride: Integer);
var
  caller: Integer;
  shared: PByte;
  reply: QWord;
  cluster: Word;
  size: Cardinal;
  attr: Byte;
begin
  if dirname = nil then
  begin
    Err('[!] FATAL: Null dirname in Cd!'#13#10);
    Exit;
  end;

  AcquireVfs;

  { An override of 0 keeps the kernel's own cwd (raw path) separate from the
    daemon's, which is what kernel-initiated reads of /ETC rely on. }
  if callerThreadOverride >= 0 then caller := callerThreadOverride
  else caller := Sched_GetCurrentThreadId;

  if UseDaemon and (caller <> 0) then
  begin
    shared := SharedMem;
    if shared = nil then
    begin
      Err('[!] FATAL: Failed to get shared memory in Cd!'#13#10);
      ReleaseVfs;
      Exit;
    end;

    PutRequestName(shared, dirname);

    if RoundTrip(caller, REQ_CD, RSP_CD, 0, reply) then
    begin
      if reply = 0 then
        Err('[!] Thu muc khong ton tai hoac day la File!'#13#10);
    end
    else
      ErrWhite('[!] VFS: FAT16 daemon timeout (Cd)!'#13#10);

    ReleaseVfs;
    Exit;
  end;

  if not IsInitialized then begin ReleaseVfs; Exit; end;
  if (dirname[0] = Ord('\')) and (dirname[1] = 0) then
  begin
    CurrentDirCluster := 0;
    ReleaseVfs;
    Exit;
  end;

  cluster := 0; size := 0; attr := 0;
  FindEntry(dirname, @cluster, @size, @attr);
  if (attr and $10) <> 0 then
    CurrentDirCluster := cluster
  else
    Err('[!] Thu muc khong ton tai hoac day la File!'#13#10);
  ReleaseVfs;
end;

function Fat16K_ListDir(outBuf: PWord; outCap: Integer; callerThread: Integer): Boolean;
var
  shared: PByte;
  reply: QWord;
  irq: Byte;
begin
  Fat16K_ListDir := False;
  if (outBuf = nil) or (outCap <= 0) then Exit;

  AcquireVfs;
  shared := SharedMem;
  if shared = nil then begin ReleaseVfs; Exit; end;

  if RoundTrip(callerThread, REQ_LS, RSP_LS, 0, reply) then
  begin
    { The listing is in the response window, not the request name. Copy it out
      so the caller never holds a pointer into shared memory after the lock. }
    irq := Spinlock_AcquireSafe_Pas(@kstate_SharedMemLock);
    StrCpyLimited(outBuf, PWord(shared + SHM_RESPONSE_DATA), Cardinal(outCap) - 1);
    Spinlock_ReleaseSafe_Pas(@kstate_SharedMemLock, irq);
    Fat16K_ListDir := True;
  end
  else
  begin
    Con_SetColor($00FF00FF);
    Con_Print(W('[!] VFS: daemon timeout!'#13#10));
    Con_SetColor($00FFFFFF);
  end;
  ReleaseVfs;
end;

function Fat16K_WriteFileRelay(filename: PWord; data: PByte; size: Cardinal; callerThread: Integer): Integer;
var
  shared, dataChunk: PByte;
  rType, rSender, offset: Cardinal;
  rPayload: QWord;
  spin: QWord;
  irq: Byte;
  i: Integer;
begin
  Fat16K_WriteFileRelay := 0;
  if (filename = nil) or (data = nil) then Exit;

  AcquireVfs;
  shared := SharedMem;
  if shared = nil then begin ReleaseVfs; Exit; end;

  PutRequestName(shared, filename);

  IpcK_Send(REQ_WRITE, Cardinal(callerThread), DaemonId, size);
  WakeDaemon;

  rType := 0; rSender := 0; rPayload := 0;
  dataChunk := shared + SHM_RESPONSE_DATA;
  spin := 0;

  while True do
  begin
    if IpcK_ReceiveForRaw(Cardinal(callerThread), rType, rSender, rPayload) then
    begin
      if rType = RSP_WRITE_NEED then
      begin
        offset := Cardinal(rPayload);
        if offset >= size then begin ReleaseVfs; Exit; end;
        irq := Spinlock_AcquireSafe_Pas(@kstate_SharedMemLock);
        for i := 0 to SECTOR_BYTES - 1 do
          if offset + Cardinal(i) < size then dataChunk[i] := data[offset + Cardinal(i)]
          else dataChunk[i] := 0;
        Spinlock_ReleaseSafe_Pas(@kstate_SharedMemLock, irq);
        IpcK_Send(REQ_WRITE_CHUNK, Cardinal(callerThread), DaemonId, 0);
        WakeDaemon;
      end
      else if rType = RSP_WRITE_DONE then
      begin
        Fat16K_WriteFileRelay := Integer(rPayload);
        ReleaseVfs;
        Exit;
      end;
    end;

    if DaemonWaitTimedOut(spin) then
    begin
      Con_SetColor($00FF00FF);
      Con_Print(W('[!] VFS: daemon timeout!'#13#10));
      Con_SetColor($00FFFFFF);
      ReleaseVfs;
      Exit;
    end;
    IpcK_WaitForMessage(Cardinal(callerThread));
  end;
end;

{ Shared shape of mkdir / rm / rmdir: name in, status code out. }
function NameRequest(name: PWord; callerThread: Integer; reqType, rspType: Cardinal): Integer;
var
  shared: PByte;
  reply: QWord;
begin
  NameRequest := 0;
  if name = nil then Exit;

  AcquireVfs;
  shared := SharedMem;
  if shared = nil then begin ReleaseVfs; Exit; end;

  PutRequestName(shared, name);
  if RoundTrip(callerThread, reqType, rspType, 0, reply) then
    NameRequest := Integer(reply);
  ReleaseVfs;
end;

function Fat16K_MakeDir(dirname: PWord; callerThread: Integer): Integer;
begin
  Fat16K_MakeDir := NameRequest(dirname, callerThread, REQ_MKDIR, RSP_MKDIR);
end;

function Fat16K_RemoveFile(filename: PWord; callerThread: Integer): Integer;
begin
  Fat16K_RemoveFile := NameRequest(filename, callerThread, REQ_RM, RSP_RM);
end;

function Fat16K_RemoveDir(dirname: PWord; callerThread: Integer): Integer;
begin
  { The C# version sent this request twice (a stray duplicate left in by an
    edit), leaving an unread reply in the mailbox. Once is what it meant. }
  Fat16K_RemoveDir := NameRequest(dirname, callerThread, REQ_RMDIR, RSP_RMDIR);
end;

function Fat16K_Chmod(path: PWord; mode: Cardinal; callerThread: Integer): Integer;
var
  shared: PByte;
  names: PWord;
  idx: Integer;
  irq: Byte;
  reply: QWord;
begin
  Fat16K_Chmod := 0;
  if path = nil then Exit;

  AcquireVfs;
  shared := SharedMem;
  if shared = nil then begin ReleaseVfs; Exit; end;

  { Request layout the daemon expects: path, NUL, decimal mode, NUL. }
  names := PWord(shared + SHM_REQUEST_NAME);
  irq := Spinlock_AcquireSafe_Pas(@kstate_SharedMemLock);
  idx := Integer(StrCpyLimited(names, path, 255));
  names[idx] := 0;
  Inc(idx);
  AppendDecimalWide_Pas(names, @idx, 4096, mode);
  names[idx] := 0;
  Spinlock_ReleaseSafe_Pas(@kstate_SharedMemLock, irq);

  if RoundTrip(callerThread, REQ_CHMOD, RSP_CHMOD, 0, reply) then
    Fat16K_Chmod := Integer(reply);
  ReleaseVfs;
end;

function Fat16K_Chown(path, ownerStr: PWord; callerThread: Integer): Integer;
var
  shared: PByte;
  names: PWord;
  idx: Integer;
  irq: Byte;
  reply: QWord;
begin
  Fat16K_Chown := 0;
  if (path = nil) or (ownerStr = nil) then Exit;

  AcquireVfs;
  shared := SharedMem;
  if shared = nil then begin ReleaseVfs; Exit; end;

  names := PWord(shared + SHM_REQUEST_NAME);
  irq := Spinlock_AcquireSafe_Pas(@kstate_SharedMemLock);
  idx := Integer(StrCpyLimited(names, path, 255));
  names[idx] := 0;
  Inc(idx);
  StrAppend_Pas(names, ownerStr, @idx, 4096);
  names[idx] := 0;
  Spinlock_ReleaseSafe_Pas(@kstate_SharedMemLock, irq);

  if RoundTrip(callerThread, REQ_CHOWN, RSP_CHOWN, 0, reply) then
    Fat16K_Chown := Integer(reply);
  ReleaseVfs;
end;

{ ── cdecl exports for FAT16.cs ── }

procedure Fat16K_Init_Pas; cdecl; public name 'Fat16K_Init_Pas';
begin
  Fat16K_Init;
end;

function Fat16K_ReadFile_Pas(filename: PWord; outSize: PCardinal; callerOverride: Integer): PByte;
  cdecl; public name 'Fat16K_ReadFile_Pas';
begin
  Fat16K_ReadFile_Pas := Fat16K_ReadFile(filename, outSize, callerOverride);
end;

procedure Fat16K_Cd_Pas(dirname: PWord; callerOverride: Integer); cdecl; public name 'Fat16K_Cd_Pas';
begin
  Fat16K_Cd(dirname, callerOverride);
end;

function Fat16K_ListDir_Pas(outBuf: PWord; outCap, caller: Integer): Byte; cdecl; public name 'Fat16K_ListDir_Pas';
begin
  Fat16K_ListDir_Pas := Ord(Fat16K_ListDir(outBuf, outCap, caller));
end;

function Fat16K_WriteFileRelay_Pas(filename: PWord; data: PByte; size: Cardinal; caller: Integer): Integer;
  cdecl; public name 'Fat16K_WriteFileRelay_Pas';
begin
  Fat16K_WriteFileRelay_Pas := Fat16K_WriteFileRelay(filename, data, size, caller);
end;

function Fat16K_MakeDir_Pas(name: PWord; caller: Integer): Integer; cdecl; public name 'Fat16K_MakeDir_Pas';
begin
  Fat16K_MakeDir_Pas := Fat16K_MakeDir(name, caller);
end;

function Fat16K_RemoveFile_Pas(name: PWord; caller: Integer): Integer; cdecl; public name 'Fat16K_RemoveFile_Pas';
begin
  Fat16K_RemoveFile_Pas := Fat16K_RemoveFile(name, caller);
end;

function Fat16K_RemoveDir_Pas(name: PWord; caller: Integer): Integer; cdecl; public name 'Fat16K_RemoveDir_Pas';
begin
  Fat16K_RemoveDir_Pas := Fat16K_RemoveDir(name, caller);
end;

function Fat16K_Chmod_Pas(path: PWord; mode: Cardinal; caller: Integer): Integer; cdecl; public name 'Fat16K_Chmod_Pas';
begin
  Fat16K_Chmod_Pas := Fat16K_Chmod(path, mode, caller);
end;

function Fat16K_Chown_Pas(path, owner: PWord; caller: Integer): Integer; cdecl; public name 'Fat16K_Chown_Pas';
begin
  Fat16K_Chown_Pas := Fat16K_Chown(path, owner, caller);
end;

function Fat16K_GetUseDaemon_Pas: Byte; cdecl; public name 'Fat16K_GetUseDaemon_Pas';
begin
  Fat16K_GetUseDaemon_Pas := Ord(UseDaemon);
end;

procedure Fat16K_SetUseDaemon_Pas(v: Byte); cdecl; public name 'Fat16K_SetUseDaemon_Pas';
begin
  UseDaemon := v <> 0;
end;

function Fat16K_GetDaemonId_Pas: Cardinal; cdecl; public name 'Fat16K_GetDaemonId_Pas';
begin
  Fat16K_GetDaemonId_Pas := DaemonId;
end;

procedure Fat16K_SetDaemonId_Pas(v: Cardinal); cdecl; public name 'Fat16K_SetDaemonId_Pas';
begin
  DaemonId := v;
end;

function Fat16K_GetTrustedThreadId_Pas: Integer; cdecl; public name 'Fat16K_GetTrustedThreadId_Pas';
begin
  Fat16K_GetTrustedThreadId_Pas := TrustedThreadId;
end;

procedure Fat16K_SetTrustedThreadId_Pas(v: Integer); cdecl; public name 'Fat16K_SetTrustedThreadId_Pas';
begin
  TrustedThreadId := v;
end;

end.
