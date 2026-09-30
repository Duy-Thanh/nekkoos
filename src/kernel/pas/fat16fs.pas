{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: fat16fs - Kernel-side FAT16 VFS (Pascal port)
  PORTED FROM: src/kernel/FAT16.cs (1338 lines, kept until this unit is wired)

  The filesystem layer sits on top of the block device: ata_hw supplies the
  sector I/O, the KernelSharedMemBlock window and the kernel bindings, while
  fat16.pas supplies the pure protocol helpers (BPB math, cluster math,
  sector scanning). Nothing is reimplemented here that fat16.pas already
  owns - those helpers are called directly, so one implementation stays
  shared with the Ring-3 FAT16.Driver.

  DEPENDENCY LAYERING (no cycles - see docs/PASCAL_PORTING.md 6):
    fat16fs -> ata_hw, fat16, heap, libc, terminal, kstring, io,
              spinlock, pmm
  Nothing uses fat16fs, and none of those units uses fat16fs, so the link
  order is free.

  NAMING: every public symbol carries the Fat16fs_ prefix. The bare FAT16_*
  namespace already belongs to fat16.pas; reusing it would produce duplicate
  exported symbols and break the link. The C# cluster limits are mirrored
  locally as FAT16FS_* constants for the same reason and must stay identical
  to fat16.pas' values.

  RECORDS: MBR_Partition, FAT_BPB and FAT_DirectoryEntry are on-disk
  structures shared with the FAT16/ATA daemons, so they live in the
  implementation section as packed records and the interface exposes only
  Pointer plus scalar accessors. Sizes were verified against the C#
  originals with a SizeOf probe: 16 / 36 / 32 bytes.

  FAITHFULNESS NOTES (behaviour deliberately preserved from FAT16.cs):
    - RemoveDir sends IPC type 48 twice and releases the shared-memory lock
      between the two sends. Kept verbatim: the daemon tolerates it, and
      changing it would change the on-wire protocol.
    - Cd's raw path has its own CurrentDirCluster, independent of the
      daemon's, which is what Sudo.cs and InternalShell.cs rely on when
      they pass callerThreadOverride = 0.
    - DaemonWaitTimedOut prints on every call once the spin counter is
      exhausted, so a stuck daemon produces a message flood. Kept as is.
    - The C#'s "partType <= 0xFF" and "FATSize16 > 0x10000" tests are
      tautological for a Byte and a Word respectively. Only the reachable
      halves are kept, with a comment where that happens.
  =========================================================================
}

unit fat16fs;

{$mode objfpc}
{$h+}
{$inline on}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}
{$ASMMODE Intel}

interface

const
  { ── On-disk cluster limits, mirrored from src/kernel/FAT16.cs ──────── }
  FAT16FS_MAX_CLUSTER  = $FFEF;
  FAT16FS_MIN_CLUSTER  = $0002;
  FAT16FS_FREE_CLUSTER = $0000;
  FAT16FS_EOF_CLUSTER  = $FFFF;

  FAT16FS_SECTOR_SIZE  = 512;
  FAT16FS_MAX_SECTORS  = $10000;   { RootDirSectors sanity ceiling }
  FAT16FS_MAX_LBA      = $FFFFFF;  { clusterLba / fatSector ceiling }

  { A directory entry is 32 bytes, so a 512-byte sector holds 16 of them. }
  FAT16FS_DIRENTRY_SIZE = 32;
  FAT16FS_ENTRIES_PER_SECTOR = 16;

  { ── MBR partition table entry (MBR_Partition, Pack = 1, 16 bytes) ─── }
  MBR_PART_TABLE_OFF   = 446;
  MBR_PART_TYPE_OFF    = 450;
  MBR_PART_LBA_OFF     = 454;

  { ── FAT_DirectoryEntry field offsets (Pack = 1, 32 bytes) ─────────── }
  DE_NAME_OFF          = 0;    { 11 bytes }
  DE_ATTR_OFF          = 11;
  DE_RESERVED_OFF      = 12;
  DE_TIME_TENTHS_OFF   = 13;
  DE_CREATION_TIME_OFF = 14;
  DE_CREATION_DATE_OFF = 16;
  DE_LAST_ACCESS_OFF   = 18;
  DE_CLUSTER_HIGH_OFF  = 20;
  DE_WRITE_TIME_OFF    = 22;
  DE_WRITE_DATE_OFF    = 24;
  DE_CLUSTER_LOW_OFF   = 26;
  DE_FILE_SIZE_OFF     = 28;

  { ── Daemon IPC message types exchanged with FAT16.Driver ──────────── }
  FAT16FS_IPC_READ_REQ    = 30;
  FAT16FS_IPC_READ_SIZE   = 31;
  FAT16FS_IPC_READ_CHUNK  = 38;
  FAT16FS_IPC_READ_ACK    = 39;
  FAT16FS_IPC_READ_DONE   = 42;
  FAT16FS_IPC_WRITE_REQ   = 32;
  FAT16FS_IPC_WRITE_CHUNK = 33;
  FAT16FS_IPC_WRITE_ACK   = 34;
  FAT16FS_IPC_WRITE_DONE  = 35;
  FAT16FS_IPC_CD_REQ      = 36;
  FAT16FS_IPC_CD_REPLY    = 37;
  FAT16FS_IPC_LS_REQ      = 40;
  FAT16FS_IPC_LS_REPLY    = 41;
  FAT16FS_IPC_MKDIR_REQ   = 44;
  FAT16FS_IPC_MKDIR_REPLY = 45;
  FAT16FS_IPC_RM_REQ      = 46;
  FAT16FS_IPC_RM_REPLY    = 47;
  FAT16FS_IPC_RMDIR_REQ   = 48;
  FAT16FS_IPC_RMDIR_REPLY = 49;
  FAT16FS_IPC_CHMOD_REQ   = 58;
  FAT16FS_IPC_CHMOD_REPLY = 59;
  FAT16FS_IPC_CHOWN_REQ   = 60;
  FAT16FS_IPC_CHOWN_REPLY = 61;

  { ── FAT directory entry attribute bits ───────────────────────────── }
  FAT16FS_ATTR_DELETED   = $E5;
  FAT16FS_ATTR_VOLUME    = $08;
  FAT16FS_ATTR_DIRECTORY = $10;
  FAT16FS_ATTR_LFN       = $0F;
  FAT16FS_ATTR_ARCHIVE   = $20;

  { Bounded FAT chain walk. A malformed FAT that points a cluster at itself
    would otherwise spin forever while the caller holds the VFS lock; the
    C# has no such bound. See the report for this deliberate hardening. }
  FAT16FS_MAX_CHAIN_STEPS = 65536;

  { Cap used when staging a name or an owner string into FatRequestName. }
  FAT16FS_REQUEST_CAP = 255;

{ ═══════════════════════════════════════════════════════════════════════
  HANDSHAKE STATE - was Driver.FAT16.UseDaemon / DaemonId / TrustedThreadId
  ═══════════════════════════════════════════════════════════════════════ }

procedure Fat16fs_SetDaemon(useDaemon: Boolean; daemonId: Cardinal); cdecl;
function  Fat16fs_GetUseDaemon: Boolean; cdecl;
function  Fat16fs_GetDaemonId: Cardinal; cdecl;
procedure Fat16fs_SetTrustedThreadId(tid: Integer); cdecl;
function  Fat16fs_GetTrustedThreadId: Integer; cdecl;

{ ═══════════════════════════════════════════════════════════════════════
  MOUNTED-STATE ACCESSORS
  ═══════════════════════════════════════════════════════════════════════ }

procedure Fat16fs_Init; cdecl;
function  Fat16fs_IsInitialized: Boolean; cdecl;

function  Fat16fs_BpbPtr: Pointer; cdecl;             { -> TFatBpb, read-only }
function  Fat16fs_BpbBytesPerSector: Word; cdecl;
function  Fat16fs_BpbSectorsPerCluster: Byte; cdecl;
function  Fat16fs_BpbReservedSectorCount: Word; cdecl;
function  Fat16fs_BpbFatSize16: Word; cdecl;
function  Fat16fs_FatStartLba: Cardinal; cdecl;
function  Fat16fs_RootDirLba: Cardinal; cdecl;
function  Fat16fs_FirstDataSector: Cardinal; cdecl;
function  Fat16fs_RootDirSectors: Cardinal; cdecl;

function  Fat16fs_GetCurrentDirCluster: Word; cdecl;
procedure Fat16fs_SetCurrentDirCluster(cluster: Word); cdecl;

{ ═══════════════════════════════════════════════════════════════════════
  VFS SERIALISATION
  ═══════════════════════════════════════════════════════════════════════ }

procedure Fat16fs_AcquireVfs; cdecl;
procedure Fat16fs_ReleaseVfs; cdecl;
function  Fat16fs_VfsIsBusy: Boolean; cdecl;

{ ═══════════════════════════════════════════════════════════════════════
  PUBLIC FILESYSTEM API (was Driver.FAT16)
  ═══════════════════════════════════════════════════════════════════════ }

{ Reads a whole file, or nil on failure. The caller owns the buffer and
  hands it back to Fat16fs_Free. Pass callerThreadOverride = -1 to use the
  current thread; pass 0 to force the raw Ring-0 path. }
function  Fat16fs_ReadFile(filename: PWord; outSize: PCardinal;
    callerThreadOverride: Integer): PByte; cdecl;

procedure Fat16fs_Free(buf: PByte); cdecl;

procedure Fat16fs_WriteFile(filename: PWord; data: PByte; size: Cardinal); cdecl;
function  Fat16fs_WriteFileRelay(filename: PWord; data: PByte; size: Cardinal;
    callerThreadOverride: Integer): Integer; cdecl;

function  Fat16fs_GetFatEntry(cluster: Word): Word; cdecl;
procedure Fat16fs_SetFatEntry(cluster: Word; value: Word); cdecl;
function  Fat16fs_FindFreeCluster: Word; cdecl;

procedure Fat16fs_Cd(dirname: PWord; callerThreadOverride: Integer); cdecl;
function  Fat16fs_ListDir(outBuf: PWord; outCap: Integer;
    callerThreadOverride: Integer): Boolean; cdecl;
function  Fat16fs_MakeDir(dirname: PWord; callerThreadOverride: Integer): Integer; cdecl;
function  Fat16fs_RemoveFile(filename: PWord; callerThreadOverride: Integer): Integer; cdecl;
function  Fat16fs_RemoveDir(dirname: PWord; callerThreadOverride: Integer): Integer; cdecl;
function  Fat16fs_Chmod(path: PWord; mode: Cardinal;
    callerThreadOverride: Integer): Integer; cdecl;
function  Fat16fs_Chown(path: PWord; ownerStr: PWord;
    callerThreadOverride: Integer): Integer; cdecl;

procedure Fat16fs_Ls; cdecl;
procedure Fat16fs_Cat(filename: PWord); cdecl;
procedure Fat16fs_Run(filename: PWord); cdecl;

{ Directory lookup shared by the raw ReadFile and Cd paths. }
function  Fat16fs_FindEntry(name: PWord; outCluster: PWord; outSize: PCardinal;
    outAttr: PByte): Boolean; cdecl;

implementation

uses fat16, ata_hw, heap, libc, terminal, kstring, io, spinlock, pmm;

{ ── On-disk records. Implementation-only so FPC emits no RTTI; the
     interface exposes Pointer and scalar accessors instead. Sizes match the
     C# originals and were verified with a SizeOf probe. ─────────────── }
type
  { [StructLayout(LayoutKind.Sequential, Pack = 1)] MBR_Partition - 16 bytes }
  TMbrPartition = packed record
    Status:      Byte;
    ChsFirst:    array[0 .. 2] of Byte;
    PartType:    Byte;
    ChsLast:     array[0 .. 2] of Byte;
    LbaStart:    Cardinal;
    SectorCount: Cardinal;
  end;
  PMbrPartition = ^TMbrPartition;

  { [StructLayout(LayoutKind.Sequential, Pack = 1)] FAT_BPB - 36 bytes.
    The field offsets are the on-disk BPB layout and are read directly by
    fat16.pas' FAT16_ParseBPB_Pas, so none of them may move. }
  TFatBpb = packed record
    JumpBoot:          array[0 .. 2] of Byte;   { +0  }
    OEMName:           array[0 .. 7] of Byte;   { +3  }
    BytesPerSector:    Word;                    { +11 }
    SectorsPerCluster: Byte;                   { +13 }
    ReservedSectorCount: Word;                  { +14 }
    NumFATs:           Byte;                    { +16 }
    RootEntryCount:    Word;                    { +17 }
    TotalSectors16:    Word;                    { +19 }
    Media:             Byte;                    { +21 }
    FATSize16:         Word;                    { +22 }
    SectorsPerTrack:   Word;                    { +24 }
    NumberOfHeads:     Word;                    { +26 }
    HiddenSectors:     Cardinal;                { +28 }
    TotalSectors32:    Cardinal;                { +32 }
  end;
  PFatBpb = ^TFatBpb;

  { [StructLayout(LayoutKind.Sequential, Pack = 1)] FAT_DirectoryEntry - 32 }
  TFatDirectoryEntry = packed record
    Name:               array[0 .. 10] of Byte;  { +0  }
    Attributes:         Byte;                    { +11 }
    Reserved:           Byte;                    { +12 }
    CreationTimeTenths: Byte;                    { +13 }
    CreationTime:       Word;                    { +14 }
    CreationDate:       Word;                    { +16 }
    LastAccessDate:     Word;                    { +18 }
    FirstClusterHigh:   Word;                    { +20 }
    WriteTime:          Word;                    { +22 }
    WriteDate:          Word;                    { +24 }
    FirstClusterLow:    Word;                    { +26 }
    FileSize:           Cardinal;                { +28 }
  end;
  PFatDirectoryEntry = ^TFatDirectoryEntry;

{ ── Mounted state (was C# static fields on Driver.FAT16) ────────────── }
var
  Fat16fs_UseDaemon: Byte = 0;
  Fat16fs_DaemonId: Cardinal = 0;
  Fat16fs_TrustedThreadId: Integer = -1;

  Fat16fs_CachedBpb: TFatBpb;
  Fat16fs_FatStart: Cardinal = 0;
  Fat16fs_RootDir: Cardinal = 0;
  Fat16fs_FirstData: Cardinal = 0;
  Fat16fs_RootSectors: Cardinal = 0;
  Fat16fs_CurrentDirCluster: Word = 0;
  Fat16fs_Initialized: Byte = 0;

  { C# VfsStateLock + VfsIsBusy }
  Fat16fs_VfsLock: Cardinal = 0;
  Fat16fs_VfsBusy: Byte = 0;

{ ═══════════════════════════════════════════════════════════════════════
  THIN HELPERS
  ═══════════════════════════════════════════════════════════════════════ }

procedure Fat16fs_SetColor(color: Cardinal); inline;
begin
  AtaHw_SetColor(color);
end;

procedure Fat16fs_Print(str: PWord); inline;
begin
  AtaHw_Print(str);
end;

procedure Fat16fs_DrawChar(c: Word); inline;
begin
  AtaHw_DrawChar(c);
end;

{ Heap.Alloc from src/kernel/Heap.cs, including its fatal response to heap
  corruption. heap.pas already enforces the size ceilings, so only the error
  policy lives here. }
function Fat16fs_Alloc(size: Cardinal): PByte;
var
  p: Pointer;
  code: Byte;
begin
  Fat16fs_Alloc := nil;
  if size = 0 then Exit;

  code := Heap_AllocBlock(size, p);
  if code = HEAP_OK then
  begin
    Fat16fs_Alloc := PByte(p);
    Exit;
  end;

  if code = HEAP_CORRUPTION then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] MPU FATAL: HEAP CORRUPTION DETECTED DURING ALLOC!'#13#10));
    while true do Io_Hlt;
  end;
  { HEAP_OOM and friends fall through to the nil the C# returned. }
end;

procedure Fat16fs_Free(buf: PByte); cdecl;
var
  code: Byte;
begin
  if buf = nil then Exit;

  code := Heap_FreeBlock(buf);
  if code = HEAP_OK then Exit;

  if code = HEAP_CORRUPTION then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] MPU FATAL: HEAP CORRUPTION! INVALID HEADER MAGIC!'#13#10));
    while true do Io_Hlt;
  end
  else if code = HEAP_INVALID_PTR then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] MPU BLOCKED: INVALID POINTER FREE DETECTED!'#13#10));
  end
  else if code = HEAP_DOUBLE_FREE then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] MPU WARNING: DOUBLE FREE DETECTED!'#13#10));
  end
  else if code = HEAP_OVERFLOW then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] MPU FATAL: HEAP BUFFER OVERFLOW DETECTED!'#13#10));
    while true do Io_Hlt;
  end;
end;

{ [FIX FREEZE] Shared spin budget for every daemon wait loop. Passing the
  threshold reports a timeout instead of hanging the kernel forever while it
  still holds the VFS lock. Note this prints on every call once exhausted,
  exactly like the C# helper it replaces. }
function Fat16fs_DaemonWaitTimedOut(var spin: QWord): Boolean;
begin
  Inc(spin);
  if spin > 2000000000 then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] VFS: FAT16 daemon not responding (timeout)!'#13#10));
    Fat16fs_SetColor($00FFFFFF);
    Fat16fs_DaemonWaitTimedOut := True;
    Exit;
  end;
  Fat16fs_DaemonWaitTimedOut := False;
end;

procedure Fat16fs_TimeoutMsg; inline;
begin
  Fat16fs_SetColor($00FF00FF);
  Fat16fs_Print(W('[!] VFS: daemon timeout!'#13#10));
  Fat16fs_SetColor($00FFFFFF);
end;

{ ═══════════════════════════════════════════════════════════════════════
  HANDSHAKE / DAEMON PLUMBING
  ═══════════════════════════════════════════════════════════════════════ }

procedure Fat16fs_SetDaemon(useDaemon: Boolean; daemonId: Cardinal); cdecl;
begin
  if useDaemon then Fat16fs_UseDaemon := 1 else Fat16fs_UseDaemon := 0;
  Fat16fs_DaemonId := daemonId;
end;

function Fat16fs_GetUseDaemon: Boolean; cdecl;
begin
  Fat16fs_GetUseDaemon := Fat16fs_UseDaemon <> 0;
end;

function Fat16fs_GetDaemonId: Cardinal; cdecl;
begin
  Fat16fs_GetDaemonId := Fat16fs_DaemonId;
end;

procedure Fat16fs_SetTrustedThreadId(tid: Integer); cdecl;
begin
  Fat16fs_TrustedThreadId := tid;
  { Syscall.cs case 5 compares this against Driver.FAT16.DaemonId, so keep
    the copy ata_hw holds for the ATA side in step. }
  AtaHw_SetTrustedThreadId(tid);
end;

function Fat16fs_GetTrustedThreadId: Integer; cdecl;
begin
  Fat16fs_GetTrustedThreadId := Fat16fs_TrustedThreadId;
end;

{ Wake the Ring-3 FAT16 daemon. Before the handshake the id is unknown, so
  the thread table is scanned for the process name, exactly as the C# did.
  Offsets 80 and 8 are Thread.Name[0] and Thread.Active. }
procedure Fat16fs_WakeDaemon;
var
  i, threadCount: Integer;
  t: PByte;
  irq: Byte;
begin
  if Fat16fs_DaemonId = 0 then
  begin
    irq := AtaHw_AcquireSchedLockSafe;
    threadCount := AtaHw_ThreadCount;
    i := 1;
    while i < threadCount do
    begin
      t := PByte(AtaHw_ThreadAt(Cardinal(i)));
      if t <> nil then
      begin
        if (t[80] = Ord('F')) and (t[81] = Ord('A')) and (t[82] = Ord('T')) then
        begin
          Fat16fs_DaemonId := Cardinal(i);
          Break;
        end;
      end;
      Inc(i);
    end;
    AtaHw_ReleaseSchedLockSafe(irq);
  end;

  if (Fat16fs_DaemonId = 0) or (Fat16fs_DaemonId >= Cardinal(AtaHw_ThreadCount)) then Exit;

  t := PByte(AtaHw_ThreadAt(Fat16fs_DaemonId));
  if t = nil then Exit;

  irq := AtaHw_AcquireSchedLockSafe;
  t[8] := 1;   { Active = Runnable }
  AtaHw_ReleaseSchedLockSafe(irq);
end;

{ ═══════════════════════════════════════════════════════════════════════
  MOUNTED-STATE ACCESSORS
  ═══════════════════════════════════════════════════════════════════════ }

function Fat16fs_IsInitialized: Boolean; cdecl;
begin
  Fat16fs_IsInitialized := Fat16fs_Initialized <> 0;
end;

function Fat16fs_BpbPtr: Pointer; cdecl;
begin
  Fat16fs_BpbPtr := @Fat16fs_CachedBpb;
end;

function Fat16fs_BpbBytesPerSector: Word; cdecl;
begin
  Fat16fs_BpbBytesPerSector := Fat16fs_CachedBpb.BytesPerSector;
end;

function Fat16fs_BpbSectorsPerCluster: Byte; cdecl;
begin
  Fat16fs_BpbSectorsPerCluster := Fat16fs_CachedBpb.SectorsPerCluster;
end;

function Fat16fs_BpbReservedSectorCount: Word; cdecl;
begin
  Fat16fs_BpbReservedSectorCount := Fat16fs_CachedBpb.ReservedSectorCount;
end;

function Fat16fs_BpbFatSize16: Word; cdecl;
begin
  Fat16fs_BpbFatSize16 := Fat16fs_CachedBpb.FATSize16;
end;

function Fat16fs_FatStartLba: Cardinal; cdecl;
begin
  Fat16fs_FatStartLba := Fat16fs_FatStart;
end;

function Fat16fs_RootDirLba: Cardinal; cdecl;
begin
  Fat16fs_RootDirLba := Fat16fs_RootDir;
end;

function Fat16fs_FirstDataSector: Cardinal; cdecl;
begin
  Fat16fs_FirstDataSector := Fat16fs_FirstData;
end;

function Fat16fs_RootDirSectors: Cardinal; cdecl;
begin
  Fat16fs_RootDirSectors := Fat16fs_RootSectors;
end;

function Fat16fs_GetCurrentDirCluster: Word; cdecl;
begin
  Fat16fs_GetCurrentDirCluster := Fat16fs_CurrentDirCluster;
end;

procedure Fat16fs_SetCurrentDirCluster(cluster: Word); cdecl;
begin
  Fat16fs_CurrentDirCluster := cluster;
end;

{ ═══════════════════════════════════════════════════════════════════════
  VFS SERIALISATION
  ═══════════════════════════════════════════════════════════════════════ }

procedure Fat16fs_AcquireVfs; cdecl;
var
  irq: Byte;
begin
  while true do
  begin
    irq := Spinlock_AcquireSafe_Pas(@Fat16fs_VfsLock);
    if Fat16fs_VfsBusy = 0 then
    begin
      Fat16fs_VfsBusy := 1;
      Spinlock_ReleaseSafe_Pas(@Fat16fs_VfsLock, irq);
      Exit;
    end;
    Spinlock_ReleaseSafe_Pas(@Fat16fs_VfsLock, irq);
    AtaHw_Yield;
  end;
end;

procedure Fat16fs_ReleaseVfs; cdecl;
var
  irq: Byte;
begin
  irq := Spinlock_AcquireSafe_Pas(@Fat16fs_VfsLock);
  Fat16fs_VfsBusy := 0;
  Spinlock_ReleaseSafe_Pas(@Fat16fs_VfsLock, irq);
end;

function Fat16fs_VfsIsBusy: Boolean; cdecl;
begin
  Fat16fs_VfsIsBusy := Fat16fs_VfsBusy <> 0;
end;

{ ═══════════════════════════════════════════════════════════════════════
  MOUNT
  ═══════════════════════════════════════════════════════════════════════ }

procedure Fat16fs_Init; cdecl;
var
  bpbBuf: PByte;
  bpbPtr: PFatBpb;
  rootDirSectors, rootDirLba, firstDataSector: Cardinal;
  partLba: Cardinal;
begin
  bpbBuf := Fat16fs_Alloc(FAT16FS_SECTOR_SIZE);
  if bpbBuf = nil then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Failed to allocate BPB buffer in FAT16 Init!'#13#10));
    Exit;
  end;

  { LBA 0 is the MBR. The partition entry at +446 says where the volume
    actually starts; a non-zero type byte with a non-zero LBA is treated as
    a real partition. The C# also tests Type <= 0xFF, which is tautological
    for a byte, so only the reachable tests are kept here. }
  Ata_ReadSector(0, bpbBuf);

  partLba := PCardinal(bpbBuf + MBR_PART_LBA_OFF)^;
  if (bpbBuf[MBR_PART_TYPE_OFF] > 0) and (partLba > 0) then
  begin
    Fat16fs_FatStart := partLba;
    Ata_ReadSector(Fat16fs_FatStart, bpbBuf);
  end
  else
    Fat16fs_FatStart := 0;

  bpbPtr := PFatBpb(bpbBuf);
  Fat16fs_CachedBpb := bpbPtr^;

  { Repair the two fields the driver depends on, in both the cache and the
    live buffer, so FAT16_ParseBPB_Pas reads the same values. }
  if Fat16fs_CachedBpb.BytesPerSector = 0 then
  begin
    Fat16fs_CachedBpb.BytesPerSector := FAT16FS_SECTOR_SIZE;
    bpbPtr^.BytesPerSector := FAT16FS_SECTOR_SIZE;
  end;
  if Fat16fs_CachedBpb.SectorsPerCluster = 0 then
  begin
    Fat16fs_CachedBpb.SectorsPerCluster := 1;
    bpbPtr^.SectorsPerCluster := 1;
  end;

  FAT16_ParseBPB_Pas(bpbBuf, @rootDirSectors, @rootDirLba, @firstDataSector);

  Fat16fs_RootSectors := rootDirSectors;
  Fat16fs_RootDir    := Fat16fs_FatStart + rootDirLba;
  Fat16fs_FirstData  := Fat16fs_FatStart + firstDataSector;
  Fat16fs_Initialized := 1;
  Fat16fs_CurrentDirCluster := 0;

  Fat16fs_Free(bpbBuf);

  Fat16fs_SetColor($0000FF00);
  Fat16fs_Print(W('[+] VFS FAT16 Initialized Successfully!'#13#10));
end;

{ ═══════════════════════════════════════════════════════════════════════
  DIRECTORY LOOKUP
  ═══════════════════════════════════════════════════════════════════════ }

{ FAT16.cs CheckSectorInline: the kernel side ignores owner and perms, so
  the three trailing out-params are passed as nil. }
function CheckSectorInline(buf: PByte; formattedName: PByte;
    outCluster: PWord; outSize: PCardinal; outAttr: PByte): Integer; inline;
begin
  if (buf = nil) or (formattedName = nil) or (outCluster = nil) or
     (outSize = nil) or (outAttr = nil) then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Null pointer in CheckSectorInline!'#13#10));
    CheckSectorInline := -1;
    Exit;
  end;
  CheckSectorInline := FAT16_CheckSector_Pas(buf, formattedName, outCluster,
                                             outSize, outAttr, nil, nil, nil);
end;

function Fat16fs_FindEntry(name: PWord; outCluster: PWord; outSize: PCardinal;
    outAttr: PByte): Boolean; cdecl;
var
  sectorBuf, formattedName, fatBuf: PByte;
  found: Boolean;
  s, secIdx: Cardinal;
  st: Integer;
  cluster: Word;
  clusterLba, fatSector: Cardinal;
  abort: Boolean;
  chainSteps: Cardinal;
  k: Integer;
begin
  Fat16fs_FindEntry := False;

  if (name = nil) or (outCluster = nil) or (outSize = nil) or (outAttr = nil) then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Null pointer in FindEntry!'#13#10));
    Exit;
  end;

  sectorBuf     := Fat16fs_Alloc(FAT16FS_SECTOR_SIZE);
  formattedName := Fat16fs_Alloc(11);

  if (sectorBuf = nil) or (formattedName = nil) then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Failed to allocate memory in FindEntry!'#13#10));
    Fat16fs_Free(sectorBuf);
    Fat16fs_Free(formattedName);
    Exit;
  end;

  { ".." has no 8.3 name of its own, so it is written out by hand. }
  if (name[0] = Ord('.')) and (name[1] = Ord('.')) and (name[2] = 0) then
  begin
    formattedName[0] := Ord('.');
    formattedName[1] := Ord('.');
    for k := 2 to 10 do
      formattedName[k] := Ord(' ');
  end
  else
    FormatFATName(name, formattedName);

  found := False;

  if Fat16fs_CurrentDirCluster = 0 then
  begin
    { Fixed-area root: a linear scan of the root directory sectors. }
    if Fat16fs_RootSectors > FAT16FS_MAX_SECTORS then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Invalid root directory sectors in FindEntry!'#13#10));
      Fat16fs_Free(sectorBuf);
      Fat16fs_Free(formattedName);
      Exit;
    end;

    s := 0;
    while s < Fat16fs_RootSectors do
    begin
      Ata_ReadSector(Fat16fs_RootDir + s, sectorBuf);
      st := CheckSectorInline(sectorBuf, formattedName, outCluster, outSize, outAttr);
      if st = 1 then
      begin
        found := True;
        Break;
      end;
      if st = 2 then Break;
      Inc(s);
    end;
  end
  else
  begin
    { Subdirectory: walk the cluster chain, scanning every sector. }
    cluster := Fat16fs_CurrentDirCluster;
    fatBuf := Fat16fs_Alloc(FAT16FS_SECTOR_SIZE);

    if fatBuf = nil then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Failed to allocate FAT buffer in FindEntry!'#13#10));
      Fat16fs_Free(sectorBuf);
      Fat16fs_Free(formattedName);
      Exit;
    end;

    chainSteps := 0;
    while (cluster >= FAT16FS_MIN_CLUSTER) and (cluster <= FAT16FS_MAX_CLUSTER) do
    begin
      if chainSteps >= FAT16FS_MAX_CHAIN_STEPS then Break;

      if (cluster < FAT16FS_MIN_CLUSTER) or (cluster > FAT16FS_MAX_CLUSTER) then
      begin
        Fat16fs_SetColor($00FF0000);
        Fat16fs_Print(W('[!] FATAL: Invalid cluster number in FindEntry!'#13#10));
        Fat16fs_Free(fatBuf);
        Fat16fs_Free(sectorBuf);
        Fat16fs_Free(formattedName);
        Exit;
      end;

      clusterLba := FAT16_ClusterLba_Pas(Fat16fs_FirstData, cluster,
                                         Fat16fs_CachedBpb.SectorsPerCluster);
      abort := False;

      if clusterLba > FAT16FS_MAX_LBA then
      begin
        Fat16fs_SetColor($00FF0000);
        Fat16fs_Print(W('[!] FATAL: Invalid cluster LBA in FindEntry!'#13#10));
        Fat16fs_Free(fatBuf);
        Fat16fs_Free(sectorBuf);
        Fat16fs_Free(formattedName);
        Exit;
      end;

      secIdx := 0;
      while secIdx < Fat16fs_CachedBpb.SectorsPerCluster do
      begin
        Ata_ReadSector(clusterLba + secIdx, sectorBuf);
        st := CheckSectorInline(sectorBuf, formattedName, outCluster, outSize, outAttr);
        if st = 1 then
        begin
          found := True;
          Break;
        end;
        if st = 2 then
        begin
          abort := True;
          Break;
        end;
        Inc(secIdx);
      end;
      if found or abort then Break;

      fatSector := FAT16_FatSectorForCluster_Pas(Fat16fs_FatStart,
                    Fat16fs_CachedBpb.ReservedSectorCount, cluster);

      if clusterLba > FAT16FS_MAX_LBA then
      begin
        Fat16fs_SetColor($00FF0000);
        Fat16fs_Print(W('[!] FATAL: Invalid cluster LBA in FindEntry!'#13#10));
        Fat16fs_Free(fatBuf);
        Fat16fs_Free(sectorBuf);
        Fat16fs_Free(formattedName);
        Exit;
      end;

      Ata_ReadSector(fatSector, fatBuf);
      cluster := FAT16_GetNextCluster_Pas(fatBuf, cluster);
      Inc(chainSteps);
    end;
    Fat16fs_Free(fatBuf);
  end;

  Fat16fs_Free(sectorBuf);
  Fat16fs_Free(formattedName);

  Fat16fs_FindEntry := found;
end;

{ ═══════════════════════════════════════════════════════════════════════
  FAT TABLE
  ═══════════════════════════════════════════════════════════════════════ }

function Fat16fs_GetFatEntry(cluster: Word): Word; cdecl;
var
  fatSector: Cardinal;
  buf: PByte;
begin
  Fat16fs_GetFatEntry := 0;

  if Fat16fs_Initialized = 0 then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: FAT16 not initialized in GetFatEntry!'#13#10));
    Exit;
  end;

  if (cluster < FAT16FS_MIN_CLUSTER) or (cluster > FAT16FS_MAX_CLUSTER) then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Invalid cluster number in GetFatEntry!'#13#10));
    Exit;
  end;

  fatSector := FAT16_FatSectorForCluster_Pas(Fat16fs_FatStart,
                    Fat16fs_CachedBpb.ReservedSectorCount, cluster);
  if fatSector > FAT16FS_MAX_LBA then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Invalid FAT sector in GetFatEntry!'#13#10));
    Exit;
  end;

  buf := Fat16fs_Alloc(FAT16FS_SECTOR_SIZE);
  if buf = nil then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Failed to allocate buffer in GetFatEntry!'#13#10));
    Exit;
  end;

  Ata_ReadSector(fatSector, buf);
  Fat16fs_GetFatEntry := FAT16_GetNextCluster_Pas(buf, cluster);
  Fat16fs_Free(buf);
end;

procedure Fat16fs_SetFatEntry(cluster: Word; value: Word); cdecl;
var
  fatSector, entryOffset: Cardinal;
  buf: PByte;
begin
  if Fat16fs_Initialized = 0 then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: FAT16 not initialized in SetFatEntry!'#13#10));
    Exit;
  end;

  if (cluster < FAT16FS_MIN_CLUSTER) or (cluster > FAT16FS_MAX_CLUSTER) then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Invalid cluster number in SetFatEntry!'#13#10));
    Exit;
  end;

  fatSector := FAT16_FatSectorForCluster_Pas(Fat16fs_FatStart,
                    Fat16fs_CachedBpb.ReservedSectorCount, cluster);
  if fatSector > FAT16FS_MAX_LBA then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Invalid FAT sector in SetFatEntry!'#13#10));
    Exit;
  end;

  buf := Fat16fs_Alloc(FAT16FS_SECTOR_SIZE);
  if buf = nil then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Failed to allocate buffer in SetFatEntry!'#13#10));
    Exit;
  end;

  { Modify, then mirror into the second FAT so the copies stay consistent. }
  Ata_ReadSector(fatSector, buf);
  entryOffset := FAT16_FatEntryOffset_Pas(cluster);
  PWord(buf + entryOffset)^ := value;
  Ata_WriteSector(fatSector, buf);
  Ata_WriteSector(fatSector + Fat16fs_CachedBpb.FATSize16, buf);
  Fat16fs_Free(buf);
end;

function Fat16fs_FindFreeCluster: Word; cdecl;
var
  fatBuf: PByte;
  s: Cardinal;
  baseCluster: Word;
  found: Word;
begin
  Fat16fs_FindFreeCluster := 0;

  if Fat16fs_Initialized = 0 then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: FAT16 not initialized in FindFreeCluster!'#13#10));
    Exit;
  end;

  { FATSize16 is a Word, so the C#'s "> 0x10000" half can never fire; only
    the zero test is reachable and is kept. }
  if Fat16fs_CachedBpb.FATSize16 = 0 then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Invalid FAT size in FindFreeCluster!'#13#10));
    Exit;
  end;

  fatBuf := Fat16fs_Alloc(FAT16FS_SECTOR_SIZE);
  if fatBuf = nil then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Failed to allocate FAT buffer in FindFreeCluster!'#13#10));
    Exit;
  end;

  s := 0;
  while s < Fat16fs_CachedBpb.FATSize16 do
  begin
    Ata_ReadSector(Fat16fs_FatStart + Fat16fs_CachedBpb.ReservedSectorCount + s,
                   fatBuf);

    { Each 512-byte FAT sector holds 256 16-bit entries. }
    baseCluster := Word(s * 256);
    found := FAT16_FindFreeCluster_Pas(baseCluster, fatBuf, s);
    if found <> 0 then
    begin
      if (found < FAT16FS_MIN_CLUSTER) or (found > FAT16FS_MAX_CLUSTER) then
      begin
        Fat16fs_SetColor($00FF0000);
        Fat16fs_Print(W('[!] FATAL: Invalid cluster number in FindFreeCluster!'#13#10));
        Fat16fs_Free(fatBuf);
        Exit;
      end;

      { Mark EOC in both FAT copies before handing the cluster out. }
      PWord(fatBuf)[found - baseCluster] := FAT16FS_EOF_CLUSTER;
      Ata_WriteSector(Fat16fs_FatStart + Fat16fs_CachedBpb.ReservedSectorCount + s,
                      fatBuf);
      Ata_WriteSector(Fat16fs_FatStart + Fat16fs_CachedBpb.ReservedSectorCount +
                      Cardinal(Fat16fs_CachedBpb.FATSize16) + s, fatBuf);
      Fat16fs_Free(fatBuf);
      Fat16fs_FindFreeCluster := found;
      Exit;
    end;
    Inc(s);
  end;

  Fat16fs_Free(fatBuf);
end;

{ ═══════════════════════════════════════════════════════════════════════
  READ
  ═══════════════════════════════════════════════════════════════════════ }

function Fat16fs_ReadFile(filename: PWord; outSize: PCardinal;
    callerThreadOverride: Integer): PByte; cdecl;
var
  callerThread: Integer;
  shared: Pointer;
  sharedNameBuf: PWord;
  dataChunk, cp: PByte;
  sharedBaseChk: QWord;
  fatRespOffset: QWord;
  smIrq: Byte;
  msgType, sender: Cardinal;
  payload: QWord;
  daemonFileSize: Cardinal;
  daemonFileBuffer: PByte;
  spin: QWord;
  cluster: Word;
  fileSize: Cardinal;
  attr: Byte;
  fileBuffer, sectorBuf, fatBuf: PByte;
  bytesRead, copied, s: Cardinal;
  cursor: PByte;
  clusterLba, fatSector: Cardinal;
  chainSteps: Cardinal;
begin
  if filename = nil then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Null filename in ReadFile!'#13#10));
    Exit(nil);
  end;

  Fat16fs_AcquireVfs;

  { [FIX SECURITY] Honour an id the caller pinned before re-enabling
    interrupts. A timer IRQ landing in between would otherwise send the IPC
    under the wrong identity, and CheckAccess would then reject the genuine
    caller, root included. }
  if callerThreadOverride >= 0 then
    callerThread := callerThreadOverride
  else
    callerThread := AtaHw_CurrentThreadId;

  if (Fat16fs_UseDaemon <> 0) and (callerThread <> 0) then
  begin
    shared := AtaHw_GetSharedMemSilent;
    if shared = nil then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Failed to get shared memory in ReadFile!'#13#10));
      Fat16fs_ReleaseVfs;
      Exit(nil);
    end;

    sharedNameBuf := AtaHw_SharedFatRequestName;
    smIrq := AtaHw_SharedMemLockAcquire;
    StrCpyLimited(sharedNameBuf, filename, FAT16FS_REQUEST_CAP);
    AtaHw_SharedMemLockRelease(smIrq);

    AtaHw_IpcSend(FAT16FS_IPC_READ_REQ, Cardinal(callerThread),
                  Fat16fs_DaemonId, 0);
    Fat16fs_WakeDaemon;

    msgType := 0; sender := 0; payload := 0;
    daemonFileSize := 0;
    daemonFileBuffer := nil;
    dataChunk := AtaHw_SharedFatResponseData;

    { FatResponseData must lie inside the physical window. }
    sharedBaseChk := QWord(PByte(shared));
    fatRespOffset := KSM_OFF_FAT_RESPONSE;
    if (sharedBaseChk = 0) or (dataChunk = nil) or
       (sharedBaseChk + fatRespOffset + KSM_FAT_RESPONSE_SIZE >
        PMM_GetTotalPages * 4096) then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Shared memory FatResponseData out of bounds in ReadFile!'#13#10));
      Fat16fs_ReleaseVfs;
      Exit(nil);
    end;

    spin := 0;
    while true do
    begin
      if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload) then
      begin
        if msgType = FAT16FS_IPC_READ_SIZE then
        begin
          daemonFileSize := Cardinal(payload);
          if daemonFileSize = 0 then
          begin
            Fat16fs_ReleaseVfs;
            Exit(nil);
          end;

          if outSize <> nil then outSize^ := daemonFileSize;
          daemonFileBuffer := Fat16fs_Alloc(daemonFileSize);
          if daemonFileBuffer = nil then
          begin
            Fat16fs_SetColor($00FF0000);
            Fat16fs_Print(W('[!] FAT16 Kernel: OOM! Cannot allocate IPC Read buffer!'#13#10));
            Fat16fs_SetColor($00FFFFFF);
            Fat16fs_ReleaseVfs;
            Exit(nil);
          end;

          AtaHw_IpcSend(FAT16FS_IPC_READ_ACK, Cardinal(callerThread),
                        Fat16fs_DaemonId, 0);
          Fat16fs_WakeDaemon;
        end
        else if msgType = FAT16FS_IPC_READ_CHUNK then
        begin
          if Cardinal(payload) >= daemonFileSize then
          begin
            Fat16fs_SetColor($00FF0000);
            Fat16fs_Print(W('[!] FATAL: Invalid offset in ReadFile!'#13#10));
            Fat16fs_ReleaseVfs;
            Fat16fs_Free(daemonFileBuffer);
            Exit(nil);
          end;

          { Copy out of the shared window under its lock: the Ring-3 writer
            is a separate thread. The bound is re-checked on every byte. }
          smIrq := AtaHw_SharedMemLockAcquire;
          cp := dataChunk;
          s := 0;
          while (s < 512) and (Cardinal(payload) + s < daemonFileSize) do
          begin
            if QWord(cp) >= sharedBaseChk + fatRespOffset + KSM_FAT_RESPONSE_SIZE then
            begin
              Fat16fs_SetColor($00FF0000);
              Fat16fs_Print(W('[!] FATAL: FatResponseData index out of bounds!'#13#10));
              Fat16fs_Free(daemonFileBuffer);
              AtaHw_SharedMemLockRelease(smIrq);
              Fat16fs_ReleaseVfs;
              Exit(nil);
            end;
            daemonFileBuffer[Cardinal(payload) + s] := cp^;
            Inc(cp);
            Inc(s);
          end;
          AtaHw_SharedMemLockRelease(smIrq);

          AtaHw_IpcSend(FAT16FS_IPC_READ_ACK, Cardinal(callerThread),
                        Fat16fs_DaemonId, 0);
          Fat16fs_WakeDaemon;
        end
        else if msgType = FAT16FS_IPC_READ_DONE then
        begin
          Fat16fs_ReleaseVfs;
          Exit(daemonFileBuffer);
        end;
      end;

      if Fat16fs_DaemonWaitTimedOut(spin) then
      begin
        Fat16fs_TimeoutMsg;
        Fat16fs_ReleaseVfs;
        Exit(nil);
      end;
      AtaHw_Yield;
    end;
  end;

  { ── Raw Ring-0 path ── }
  if Fat16fs_Initialized = 0 then
  begin
    Fat16fs_ReleaseVfs;
    Exit(nil);
  end;

  cluster := 0;
  fileSize := 0;
  attr := 0;
  Fat16fs_FindEntry(filename, @cluster, @fileSize, @attr);

  if (cluster = 0) and (fileSize = 0) then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] App not found on disk!'#13#10));
    Fat16fs_ReleaseVfs;
    Exit(nil);
  end;

  fileBuffer := Fat16fs_Alloc(fileSize);
  if fileBuffer = nil then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FAT16: Out of Heap Memory!'#13#10));
    Fat16fs_ReleaseVfs;
    Exit(nil);
  end;

  sectorBuf := Fat16fs_Alloc(FAT16FS_SECTOR_SIZE);
  if sectorBuf = nil then
  begin
    Fat16fs_Free(fileBuffer);
    Fat16fs_ReleaseVfs;
    Exit(nil);
  end;

  fatBuf := Fat16fs_Alloc(FAT16FS_SECTOR_SIZE);
  if fatBuf = nil then
  begin
    Fat16fs_Free(fileBuffer);
    Fat16fs_Free(sectorBuf);
    Fat16fs_ReleaseVfs;
    Exit(nil);
  end;

  bytesRead := 0;
  cursor := fileBuffer;
  chainSteps := 0;

  while (cluster >= FAT16FS_MIN_CLUSTER) and (cluster <= FAT16FS_MAX_CLUSTER)
        and (bytesRead < fileSize) do
  begin
    if chainSteps >= FAT16FS_MAX_CHAIN_STEPS then Break;
    Inc(chainSteps);

    if (cluster < FAT16FS_MIN_CLUSTER) or (cluster > FAT16FS_MAX_CLUSTER) then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Invalid cluster number in ReadFile!'#13#10));
      Fat16fs_Free(sectorBuf);
      Fat16fs_Free(fatBuf);
      Fat16fs_Free(fileBuffer);
      Fat16fs_ReleaseVfs;
      Exit(nil);
    end;

    clusterLba := FAT16_ClusterLba_Pas(Fat16fs_FirstData, cluster,
                                       Fat16fs_CachedBpb.SectorsPerCluster);
    if clusterLba > FAT16FS_MAX_LBA then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Invalid cluster LBA in ReadFile!'#13#10));
      Fat16fs_Free(sectorBuf);
      Fat16fs_Free(fatBuf);
      Fat16fs_Free(fileBuffer);
      Fat16fs_ReleaseVfs;
      Exit(nil);
    end;

    s := 0;
    while (s < Fat16fs_CachedBpb.SectorsPerCluster) and (bytesRead < fileSize) do
    begin
      Ata_ReadSector(clusterLba + s, sectorBuf);
      copied := 0;
      while (copied < FAT16FS_SECTOR_SIZE) and (bytesRead < fileSize) do
      begin
        cursor^ := sectorBuf[copied];
        Inc(cursor);
        Inc(bytesRead);
        Inc(copied);
      end;
      Inc(s);
    end;

    fatSector := FAT16_FatSectorForCluster_Pas(Fat16fs_FatStart,
                  Fat16fs_CachedBpb.ReservedSectorCount, cluster);
    if fatSector > FAT16FS_MAX_LBA then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Invalid FAT sector in ReadFile!'#13#10));
      Fat16fs_Free(sectorBuf);
      Fat16fs_Free(fatBuf);
      Fat16fs_Free(fileBuffer);
      Fat16fs_ReleaseVfs;
      Exit(nil);
    end;

    Ata_ReadSector(fatSector, fatBuf);
    cluster := FAT16_GetNextCluster_Pas(fatBuf, cluster);
  end;

  Fat16fs_Free(sectorBuf);
  Fat16fs_Free(fatBuf);

  if outSize <> nil then outSize^ := fileSize;

  Fat16fs_ReleaseVfs;
  Fat16fs_ReadFile := fileBuffer;
end;

{ ═══════════════════════════════════════════════════════════════════════
  WRITE
  ═══════════════════════════════════════════════════════════════════════ }

procedure Fat16fs_WriteFile(filename: PWord; data: PByte; size: Cardinal); cdecl;
var
  callerThread: Integer;
  shared: Pointer;
  sharedNameBuf: PWord;
  dataChunk: PByte;
  smIrq: Byte;
  msgType, sender: Cardinal;
  payload: QWord;
  spin: QWord;
  clusterSize, numClusters, allocated: Cardinal;
  firstCluster, prevCluster, currentCluster, c: Word;
  bytesWritten: Cardinal;
  sectorBuf, formattedName, cursor: PByte;
  clusterLba: Cardinal;
  saved: Boolean;
  s, secIdx: Cardinal;
  i: Integer;
  de: PByte;
  ent: PFatDirectoryEntry;
  chainSteps: Cardinal;
begin
  if (filename = nil) or (data = nil) then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Null filename or data in WriteFile!'#13#10));
    Exit;
  end;

  Fat16fs_AcquireVfs;

  callerThread := AtaHw_CurrentThreadId;

  if (Fat16fs_UseDaemon <> 0) and (callerThread <> 0) then
  begin
    shared := AtaHw_GetSharedMemSilent;
    if shared = nil then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Failed to get shared memory in WriteFile!'#13#10));
      Fat16fs_ReleaseVfs;
      Exit;
    end;

    sharedNameBuf := AtaHw_SharedFatRequestName;
    smIrq := AtaHw_SharedMemLockAcquire;
    StrCpyLimited(sharedNameBuf, filename, FAT16FS_REQUEST_CAP);
    AtaHw_SharedMemLockRelease(smIrq);

    AtaHw_IpcSend(FAT16FS_IPC_WRITE_REQ, Cardinal(callerThread),
                  Fat16fs_DaemonId, QWord(size));
    Fat16fs_WakeDaemon;

    msgType := 0; sender := 0; payload := 0;
    spin := 0;
    dataChunk := AtaHw_SharedFatResponseData;

    while true do
    begin
      if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload) then
      begin
        if msgType = FAT16FS_IPC_WRITE_CHUNK then
        begin
          if Cardinal(payload) >= size then
          begin
            Fat16fs_SetColor($00FF0000);
            Fat16fs_Print(W('[!] FATAL: Invalid offset in WriteFile!'#13#10));
            Fat16fs_ReleaseVfs;
            Exit;
          end;

          smIrq := AtaHw_SharedMemLockAcquire;
          for i := 0 to 511 do
            if Cardinal(payload) + Cardinal(i) < size then
              dataChunk[i] := data[Cardinal(payload) + Cardinal(i)]
            else
              dataChunk[i] := 0;
          AtaHw_SharedMemLockRelease(smIrq);

          AtaHw_IpcSend(FAT16FS_IPC_WRITE_ACK, Cardinal(callerThread),
                        Fat16fs_DaemonId, 0);
          Fat16fs_WakeDaemon;
        end
        else if msgType = FAT16FS_IPC_WRITE_DONE then
        begin
          if payload = 1 then
          begin
            Fat16fs_SetColor($0000FF00);
            Fat16fs_Print(W('[+] IPC Write complete! File committed to Platter!'#13#10));
          end;
          Fat16fs_ReleaseVfs;
          Exit;
        end;
      end;

      if Fat16fs_DaemonWaitTimedOut(spin) then
      begin
        Fat16fs_TimeoutMsg;
        Fat16fs_ReleaseVfs;
        Exit;
      end;
      AtaHw_Yield;
    end;
  end;

  { ── Raw Ring-0 path ── }
  if Fat16fs_Initialized = 0 then
  begin
    Fat16fs_ReleaseVfs;
    Exit;
  end;

  if Fat16fs_CachedBpb.SectorsPerCluster = 0 then
    Fat16fs_CachedBpb.SectorsPerCluster := 1;

  clusterSize := Cardinal(Fat16fs_CachedBpb.SectorsPerCluster) * FAT16FS_SECTOR_SIZE;
  numClusters := (size + clusterSize - 1) div clusterSize;
  if numClusters = 0 then numClusters := 1;

  firstCluster := 0;
  prevCluster := 0;
  allocated := 0;

  c := FAT16FS_MIN_CLUSTER;
  while c < FAT16FS_MAX_CLUSTER do
  begin
    if Fat16fs_GetFatEntry(c) = FAT16FS_FREE_CLUSTER then
    begin
      if allocated = 0 then firstCluster := c
      else Fat16fs_SetFatEntry(prevCluster, c);

      Fat16fs_SetFatEntry(c, FAT16FS_EOF_CLUSTER);
      prevCluster := c;
      Inc(allocated);

      if allocated = numClusters then Break;
    end;
    Inc(c);
  end;

  if allocated < numClusters then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] Disk Full!'#13#10));
    Fat16fs_ReleaseVfs;
    Exit;
  end;

  sectorBuf := Fat16fs_Alloc(FAT16FS_SECTOR_SIZE);
  if sectorBuf = nil then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Failed to allocate sector buffer in WriteFile!'#13#10));
    Fat16fs_ReleaseVfs;
    Exit;
  end;

  bytesWritten := 0;
  currentCluster := firstCluster;
  chainSteps := 0;

  while (currentCluster >= FAT16FS_MIN_CLUSTER) and
        (currentCluster <= FAT16FS_MAX_CLUSTER) and
        (bytesWritten < size) do
  begin
    if chainSteps >= FAT16FS_MAX_CHAIN_STEPS then Break;
    Inc(chainSteps);

    clusterLba := FAT16_ClusterLba_Pas(Fat16fs_FirstData, currentCluster,
                                      Fat16fs_CachedBpb.SectorsPerCluster);
    if clusterLba > FAT16FS_MAX_LBA then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Invalid cluster LBA in WriteFile!'#13#10));
      Fat16fs_Free(sectorBuf);
      Fat16fs_ReleaseVfs;
      Exit;
    end;

    secIdx := 0;
    while (secIdx < Fat16fs_CachedBpb.SectorsPerCluster) and (bytesWritten < size) do
    begin
      { Tail sectors are zero padded so stale bytes never leak out. }
      MemSet(sectorBuf, 0, FAT16FS_SECTOR_SIZE);
      cursor := sectorBuf;
      i := 0;
      while (bytesWritten < size) and (i < FAT16FS_SECTOR_SIZE) do
      begin
        cursor^ := data[bytesWritten];
        Inc(cursor);
        Inc(bytesWritten);
        Inc(i);
      end;
      Ata_WriteSector(clusterLba + secIdx, sectorBuf);
      Inc(secIdx);
    end;

    currentCluster := Fat16fs_GetFatEntry(currentCluster);
  end;

  formattedName := Fat16fs_Alloc(11);
  if formattedName = nil then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Failed to allocate formatted name buffer in WriteFile!'#13#10));
    Fat16fs_Free(sectorBuf);
    Fat16fs_ReleaseVfs;
    Exit;
  end;

  FormatFATName(filename, formattedName);

  { Commit the directory entry into the first free slot of the root. }
  saved := False;
  s := 0;
  while s < Fat16fs_RootSectors do
  begin
    if s >= Fat16fs_RootSectors then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Invalid root directory sector in WriteFile!'#13#10));
      Fat16fs_Free(sectorBuf);
      Fat16fs_Free(formattedName);
      Fat16fs_ReleaseVfs;
      Exit;
    end;

    Ata_ReadSector(Fat16fs_RootDir + s, sectorBuf);
    i := 0;
    while i < FAT16FS_ENTRIES_PER_SECTOR do
    begin
      ent := PFatDirectoryEntry(sectorBuf + i * FAT16FS_DIRENTRY_SIZE);
      de := PByte(ent);
      if (de[DE_NAME_OFF] = $00) or (de[DE_NAME_OFF] = FAT16FS_ATTR_DELETED) then
      begin
        for secIdx := 0 to 10 do
          ent^.Name[secIdx] := formattedName[secIdx];

        ent^.Attributes         := FAT16FS_ATTR_ARCHIVE;
        ent^.Reserved           := 0;
        ent^.CreationTimeTenths := 0;
        ent^.CreationTime       := 0;
        ent^.CreationDate       := 0;
        ent^.LastAccessDate     := 0;
        ent^.WriteTime          := 0;
        ent^.WriteDate          := 0;
        ent^.FirstClusterHigh   := 0;
        ent^.FirstClusterLow    := firstCluster;
        ent^.FileSize           := size;

        Ata_WriteSector(Fat16fs_RootDir + s, sectorBuf);
        saved := True;
        Break;
      end;
      Inc(i);
    end;
    if saved then Break;
    Inc(s);
  end;

  Fat16fs_Free(sectorBuf);
  Fat16fs_Free(formattedName);
  Ata_FlushCache;

  Fat16fs_ReleaseVfs;
end;

{ [SUDO - temporary root via IPC] Relay wrapper for "write <path>".
  InternalShell.cs already read the real content from the keyboard in
  Ring-3 (identical to a plain write) before calling sudo; this only
  forwards that content to the daemon, which is already running as root, in
  a single IPC round trip. It deliberately does NOT stage the content
  through AtaRawBuffer/FatResponseData, because those two buffers are being
  used as the live transfer window by WriteFile and ATA.ReadSector/
  WriteSector at this very moment and would be overwritten. }
function Fat16fs_WriteFileRelay(filename: PWord; data: PByte; size: Cardinal;
    callerThreadOverride: Integer): Integer; cdecl;
var
  callerThread: Integer;
  shared: Pointer;
  sharedNameBuf: PWord;
  dataChunk: PByte;
  smIrq: Byte;
  msgType, sender: Cardinal;
  payload: QWord;
  spin: QWord;
  i: Integer;
begin
  if (filename = nil) or (data = nil) then Exit(0);

  Fat16fs_AcquireVfs;
  callerThread := callerThreadOverride;

  shared := AtaHw_GetSharedMemSilent;
  if shared = nil then
  begin
    Fat16fs_ReleaseVfs;
    Exit(0);
  end;

  sharedNameBuf := AtaHw_SharedFatRequestName;
  smIrq := AtaHw_SharedMemLockAcquire;
  StrCpyLimited(sharedNameBuf, filename, FAT16FS_REQUEST_CAP);
  AtaHw_SharedMemLockRelease(smIrq);

  AtaHw_IpcSend(FAT16FS_IPC_WRITE_REQ, Cardinal(callerThread),
                Fat16fs_DaemonId, QWord(size));
  Fat16fs_WakeDaemon;

  msgType := 0; sender := 0; payload := 0;
  dataChunk := AtaHw_SharedFatResponseData;
  spin := 0;

  while true do
  begin
    if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload) then
    begin
      if msgType = FAT16FS_IPC_WRITE_CHUNK then
      begin
        if Cardinal(payload) >= size then
        begin
          Fat16fs_ReleaseVfs;
          Exit(0);
        end;

        smIrq := AtaHw_SharedMemLockAcquire;
        for i := 0 to 511 do
          if Cardinal(payload) + Cardinal(i) < size then
            dataChunk[i] := data[Cardinal(payload) + Cardinal(i)]
          else
            dataChunk[i] := 0;
        AtaHw_SharedMemLockRelease(smIrq);

        AtaHw_IpcSend(FAT16FS_IPC_WRITE_ACK, Cardinal(callerThread),
                      Fat16fs_DaemonId, 0);
        Fat16fs_WakeDaemon;
      end
      else if msgType = FAT16FS_IPC_WRITE_DONE then
      begin
        Fat16fs_ReleaseVfs;
        Exit(Integer(payload));
      end;
    end;

    if Fat16fs_DaemonWaitTimedOut(spin) then
    begin
      Fat16fs_TimeoutMsg;
      Fat16fs_ReleaseVfs;
      Exit(0);
    end;
    AtaHw_Yield;
  end;
end;

{ ═══════════════════════════════════════════════════════════════════════
  DIRECTORY OPERATIONS - all thin IPC relays to the Ring-3 daemon.

  These wrappers exist only so FAT16.Driver (the Ring-3 daemon) can perform
  mkdir/rm/rmdir/chmod/chown. The kernel has no raw implementation of any of
  them: the checks, the permission model and the find/rm/rmdir logic all
  live in Ring-3, keeping the split microkernel-like. Syscall case 94 merely
  elevates the real UID/GID of the calling thread to 0 for the duration of
  one IPC round trip and then restores it.
  ═══════════════════════════════════════════════════════════════════════ }

{ Copy a name into FatRequestName under the shared-memory lock. }
procedure StageName(dst: PWord; src: PWord); inline;
var
  i: Integer;
begin
  i := 0;
  while (src[i] <> 0) and (i < FAT16FS_REQUEST_CAP) do
  begin
    dst[i] := src[i];
    Inc(i);
  end;
  dst[i] := 0;
end;

function Fat16fs_ListDir(outBuf: PWord; outCap: Integer;
    callerThreadOverride: Integer): Boolean; cdecl;
var
  callerThread: Integer;
  shared: Pointer;
  listing: PWord;
  smIrq: Byte;
  msgType, sender: Cardinal;
  payload: QWord;
  spin: QWord;
begin
  if (outBuf = nil) or (outCap <= 0) then Exit(False);

  Fat16fs_AcquireVfs;
  callerThread := callerThreadOverride;

  shared := AtaHw_GetSharedMemSilent;
  if shared = nil then
  begin
    Fat16fs_ReleaseVfs;
    Exit(False);
  end;

  AtaHw_IpcSend(FAT16FS_IPC_LS_REQ, Cardinal(callerThread),
                Fat16fs_DaemonId, 0);
  Fat16fs_WakeDaemon;

  msgType := 0; sender := 0; payload := 0;
  spin := 0;

  while true do
  begin
    if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload)
       and (msgType = FAT16FS_IPC_LS_REPLY) then
    begin
      { The listing lives in FatResponseData. Copy it out so the caller never
        keeps a pointer into shared memory after ReleaseVfs. }
      listing := PWord(AtaHw_SharedFatResponseData);
      smIrq := AtaHw_SharedMemLockAcquire;
      StrCpyLimited(outBuf, listing, Cardinal(outCap) - 1);
      AtaHw_SharedMemLockRelease(smIrq);
      Fat16fs_ReleaseVfs;
      Exit(True);
    end;

    if Fat16fs_DaemonWaitTimedOut(spin) then
    begin
      Fat16fs_TimeoutMsg;
      Fat16fs_ReleaseVfs;
      Exit(False);
    end;
    AtaHw_Yield;
  end;
end;

function Fat16fs_MakeDir(dirname: PWord; callerThreadOverride: Integer): Integer; cdecl;
var
  callerThread: Integer;
  shared: Pointer;
  sharedNameBuf: PWord;
  smIrq: Byte;
  msgType, sender: Cardinal;
  payload: QWord;
  spin: QWord;
begin
  if dirname = nil then Exit(0);

  Fat16fs_AcquireVfs;
  callerThread := callerThreadOverride;

  shared := AtaHw_GetSharedMemSilent;
  if shared = nil then
  begin
    Fat16fs_ReleaseVfs;
    Exit(0);
  end;

  sharedNameBuf := AtaHw_SharedFatRequestName;
  smIrq := AtaHw_SharedMemLockAcquire;
  StageName(sharedNameBuf, dirname);
  AtaHw_SharedMemLockRelease(smIrq);

  AtaHw_IpcSend(FAT16FS_IPC_MKDIR_REQ, Cardinal(callerThread),
                Fat16fs_DaemonId, 0);
  Fat16fs_WakeDaemon;

  msgType := 0; sender := 0; payload := 0;
  spin := 0;

  while true do
  begin
    if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload)
       and (msgType = FAT16FS_IPC_MKDIR_REPLY) then
    begin
      Fat16fs_ReleaseVfs;
      Exit(Integer(payload));
    end;
    if Fat16fs_DaemonWaitTimedOut(spin) then
    begin
      Fat16fs_ReleaseVfs;
      Exit(0);
    end;
    AtaHw_Yield;
  end;
end;

function Fat16fs_RemoveFile(filename: PWord; callerThreadOverride: Integer): Integer; cdecl;
var
  callerThread: Integer;
  shared: Pointer;
  sharedNameBuf: PWord;
  smIrq: Byte;
  msgType, sender: Cardinal;
  payload: QWord;
  spin: QWord;
begin
  if filename = nil then Exit(0);

  Fat16fs_AcquireVfs;
  callerThread := callerThreadOverride;

  shared := AtaHw_GetSharedMemSilent;
  if shared = nil then
  begin
    Fat16fs_ReleaseVfs;
    Exit(0);
  end;

  sharedNameBuf := AtaHw_SharedFatRequestName;
  smIrq := AtaHw_SharedMemLockAcquire;
  StrCpyLimited(sharedNameBuf, filename, FAT16FS_REQUEST_CAP);
  AtaHw_SharedMemLockRelease(smIrq);

  AtaHw_IpcSend(FAT16FS_IPC_RM_REQ, Cardinal(callerThread),
                Fat16fs_DaemonId, 0);
  Fat16fs_WakeDaemon;

  msgType := 0; sender := 0; payload := 0;
  spin := 0;

  while true do
  begin
    if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload)
       and (msgType = FAT16FS_IPC_RM_REPLY) then
    begin
      Fat16fs_ReleaseVfs;
      Exit(Integer(payload));
    end;
    if Fat16fs_DaemonWaitTimedOut(spin) then
    begin
      Fat16fs_ReleaseVfs;
      Exit(0);
    end;
    AtaHw_Yield;
  end;
end;

function Fat16fs_RemoveDir(dirname: PWord; callerThreadOverride: Integer): Integer; cdecl;
var
  callerThread: Integer;
  shared: Pointer;
  sharedNameBuf: PWord;
  smIrq: Byte;
  msgType, sender: Cardinal;
  payload: QWord;
  spin: QWord;
begin
  if dirname = nil then Exit(0);

  Fat16fs_AcquireVfs;
  callerThread := callerThreadOverride;

  shared := AtaHw_GetSharedMemSilent;
  if shared = nil then
  begin
    Fat16fs_ReleaseVfs;
    Exit(0);
  end;

  sharedNameBuf := AtaHw_SharedFatRequestName;
  smIrq := AtaHw_SharedMemLockAcquire;
  StrCpyLimited(sharedNameBuf, dirname, FAT16FS_REQUEST_CAP);

  { Faithful to FAT16.cs: the send below happens twice, with the lock
    released in between. The daemon tolerates the duplicate, and removing
    it would change the wire protocol, so both sends are kept. }
  AtaHw_IpcSend(FAT16FS_IPC_RMDIR_REQ, Cardinal(callerThread),
                Fat16fs_DaemonId, 0);
  AtaHw_SharedMemLockRelease(smIrq);

  AtaHw_IpcSend(FAT16FS_IPC_RMDIR_REQ, Cardinal(callerThread),
                Fat16fs_DaemonId, 0);
  Fat16fs_WakeDaemon;

  msgType := 0; sender := 0; payload := 0;
  spin := 0;

  while true do
  begin
    if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload)
       and (msgType = FAT16FS_IPC_RMDIR_REPLY) then
    begin
      Fat16fs_ReleaseVfs;
      Exit(Integer(payload));
    end;
    if Fat16fs_DaemonWaitTimedOut(spin) then
    begin
      Fat16fs_ReleaseVfs;
      Exit(0);
    end;
    AtaHw_Yield;
  end;
end;

function Fat16fs_Chmod(path: PWord; mode: Cardinal;
    callerThreadOverride: Integer): Integer; cdecl;
var
  callerThread: Integer;
  shared: Pointer;
  sharedNameBuf: PWord;
  smIrq: Byte;
  msgType, sender: Cardinal;
  payload: QWord;
  spin: QWord;
  idx: Integer;
begin
  if path = nil then Exit(0);

  Fat16fs_AcquireVfs;
  callerThread := callerThreadOverride;

  shared := AtaHw_GetSharedMemSilent;
  if shared = nil then
  begin
    Fat16fs_ReleaseVfs;
    Exit(0);
  end;

  sharedNameBuf := AtaHw_SharedFatRequestName;
  smIrq := AtaHw_SharedMemLockAcquire;
  idx := Integer(StrCpyLimited(sharedNameBuf, path, FAT16FS_REQUEST_CAP));
  sharedNameBuf[idx] := 0;
  Inc(idx);
  { The decimal mode is appended after the path, NUL separated - the exact
    convention FAT16.Driver case 58 expects, matching Shell.cs chmod. }
  AppendDecimalWide_Pas(sharedNameBuf, @idx, 4096, mode);
  sharedNameBuf[idx] := 0;
  AtaHw_SharedMemLockRelease(smIrq);

  AtaHw_IpcSend(FAT16FS_IPC_CHMOD_REQ, Cardinal(callerThread),
                Fat16fs_DaemonId, 0);
  Fat16fs_WakeDaemon;

  msgType := 0; sender := 0; payload := 0;
  spin := 0;

  while true do
  begin
    if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload)
       and (msgType = FAT16FS_IPC_CHMOD_REPLY) then
    begin
      Fat16fs_ReleaseVfs;
      Exit(Integer(payload));
    end;
    if Fat16fs_DaemonWaitTimedOut(spin) then
    begin
      Fat16fs_ReleaseVfs;
      Exit(0);
    end;
    AtaHw_Yield;
  end;
end;

function Fat16fs_Chown(path: PWord; ownerStr: PWord;
    callerThreadOverride: Integer): Integer; cdecl;
var
  callerThread: Integer;
  shared: Pointer;
  sharedNameBuf: PWord;
  smIrq: Byte;
  msgType, sender: Cardinal;
  payload: QWord;
  spin: QWord;
  idx: Integer;
begin
  if (path = nil) or (ownerStr = nil) then Exit(0);

  Fat16fs_AcquireVfs;
  callerThread := callerThreadOverride;

  shared := AtaHw_GetSharedMemSilent;
  if shared = nil then
  begin
    Fat16fs_ReleaseVfs;
    Exit(0);
  end;

  sharedNameBuf := AtaHw_SharedFatRequestName;
  smIrq := AtaHw_SharedMemLockAcquire;
  idx := Integer(StrCpyLimited(sharedNameBuf, path, FAT16FS_REQUEST_CAP));
  sharedNameBuf[idx] := 0;
  Inc(idx);
  StrAppend_Pas(sharedNameBuf, ownerStr, @idx, 4096);
  sharedNameBuf[idx] := 0;
  AtaHw_SharedMemLockRelease(smIrq);

  AtaHw_IpcSend(FAT16FS_IPC_CHOWN_REQ, Cardinal(callerThread),
                Fat16fs_DaemonId, 0);
  Fat16fs_WakeDaemon;

  msgType := 0; sender := 0; payload := 0;
  spin := 0;

  while true do
  begin
    if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload)
       and (msgType = FAT16FS_IPC_CHOWN_REPLY) then
    begin
      Fat16fs_ReleaseVfs;
      Exit(Integer(payload));
    end;
    if Fat16fs_DaemonWaitTimedOut(spin) then
    begin
      Fat16fs_ReleaseVfs;
      Exit(0);
    end;
    AtaHw_Yield;
  end;
end;

procedure Fat16fs_Cd(dirname: PWord; callerThreadOverride: Integer); cdecl;
var
  callerThread: Integer;
  shared: Pointer;
  sharedNameBuf: PWord;
  smIrq: Byte;
  msgType, sender: Cardinal;
  payload: QWord;
  spin: QWord;
  cluster: Word;
  size: Cardinal;
  attr: Byte;
begin
  if dirname = nil then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Null dirname in Cd!'#13#10));
    Exit;
  end;

  Fat16fs_AcquireVfs;

  { Same rule as ReadFile: callerThreadOverride = 0 bypasses the daemon and
    drives the kernel's OWN CurrentDirCluster (the raw path), so the kernel's
    system-file reads - verifying sudo against ETC/PASSWD and ETC/SUDOERS -
    never share cwd state with the Ring-3 daemon. Two independent states. }
  if callerThreadOverride >= 0 then
    callerThread := callerThreadOverride
  else
    callerThread := AtaHw_CurrentThreadId;

  if (Fat16fs_UseDaemon <> 0) and (callerThread <> 0) then
  begin
    shared := AtaHw_GetSharedMemSilent;
    if shared = nil then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Failed to get shared memory in Cd!'#13#10));
      Fat16fs_ReleaseVfs;
      Exit;
    end;

    sharedNameBuf := AtaHw_SharedFatRequestName;
    smIrq := AtaHw_SharedMemLockAcquire;
    StageName(sharedNameBuf, dirname);
    AtaHw_SharedMemLockRelease(smIrq);

    AtaHw_IpcSend(FAT16FS_IPC_CD_REQ, Cardinal(callerThread),
                  Fat16fs_DaemonId, 0);
    Fat16fs_WakeDaemon;

    msgType := 0; sender := 0; payload := 0;

    { [FIX FREEZE] Bounded wait: a lost wakeup or a deadlock has to surface
      as an error, not as a kernel hung forever while holding the VFS lock. }
    spin := 0;
    while true do
    begin
      if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload)
         and (msgType = FAT16FS_IPC_CD_REPLY) then
      begin
        if payload = 0 then
        begin
          Fat16fs_SetColor($00FF0000);
          Fat16fs_Print(W('[!] Thu muc khong ton tai hoac day la File!'#13#10));
        end;
        Fat16fs_ReleaseVfs;
        Exit;
      end;

      Inc(spin);
      if spin > 2000000000 then
      begin
        Fat16fs_SetColor($00FF0000);
        Fat16fs_Print(W('[!] VFS: FAT16 daemon timeout (Cd)!'#13#10));
        Fat16fs_SetColor($00FFFFFF);
        Fat16fs_ReleaseVfs;
        Exit;
      end;
      AtaHw_Yield;
    end;
  end;

  if Fat16fs_Initialized = 0 then
  begin
    Fat16fs_ReleaseVfs;
    Exit;
  end;

  if (dirname[0] = Ord('\')) and (dirname[1] = 0) then
  begin
    Fat16fs_CurrentDirCluster := 0;
    Fat16fs_ReleaseVfs;
    Exit;
  end;

  cluster := 0;
  size := 0;
  attr := 0;
  Fat16fs_FindEntry(dirname, @cluster, @size, @attr);

  if (attr and FAT16FS_ATTR_DIRECTORY) <> 0 then
    Fat16fs_CurrentDirCluster := cluster
  else
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] Thu muc khong ton tai hoac day la File!'#13#10));
  end;
  Fat16fs_ReleaseVfs;
end;

{ ═══════════════════════════════════════════════════════════════════════
  LISTING
  ═══════════════════════════════════════════════════════════════════════ }

{ A 512-byte sector holds 16 directory entries; the record is addressed
  through raw offsets so the code reads exactly like the C# original. }
procedure PrintEntriesInline(buf: PByte);
var
  i, j, s2, printed, digits: Integer;
  de: PByte;
  attrs: Byte;
  c: Word;
  fileSize: Cardinal;
  temp: QWord;
begin
  for i := 0 to FAT16FS_ENTRIES_PER_SECTOR - 1 do
  begin
    de := buf + i * FAT16FS_DIRENTRY_SIZE;

    if de[DE_NAME_OFF] = $00 then Exit;
    if (de[DE_NAME_OFF] = FAT16FS_ATTR_DELETED) or
       (de[DE_ATTR_OFF] = FAT16FS_ATTR_LFN) or
       ((de[DE_ATTR_OFF] and FAT16FS_ATTR_VOLUME) <> 0) then Continue;

    attrs := de[DE_ATTR_OFF];
    fileSize := PCardinal(de + DE_FILE_SIZE_OFF)^;

    Fat16fs_SetColor($00FFFFFF);

    printed := 0;
    for j := 0 to 7 do
    begin
      c := de[DE_NAME_OFF + j];
      if (c = Ord(' ')) or (c = 0) then Break;
      if (c >= 32) and (c <= 126) then Fat16fs_DrawChar(c)
      else Fat16fs_DrawChar(Ord(' '));
      Inc(printed);
    end;

    if (de[DE_NAME_OFF + 8] <> Ord(' ')) and (de[DE_NAME_OFF + 8] <> 0) then
    begin
      Fat16fs_DrawChar(Ord('.'));
      Inc(printed);
      for j := 8 to 10 do
      begin
        c := de[DE_NAME_OFF + j];
        if (c = Ord(' ')) or (c = 0) then Break;
        if (c >= 32) and (c <= 126) then Fat16fs_DrawChar(c)
        else Fat16fs_DrawChar(Ord(' '));
        Inc(printed);
      end;
    end;

    for s2 := printed to 15 do
      Fat16fs_DrawChar(Ord(' '));

    Fat16fs_Print(W(' | '#13#10));

    Fat16fs_SetColor($0000FF00);
    AtaHw_PrintDec(QWord(fileSize));

    digits := 1;
    temp := fileSize;
    while temp >= 10 do
    begin
      Inc(digits);
      temp := temp div 10;
    end;
    for s2 := 0 to 10 - digits - 1 do
      Fat16fs_Print(W(' '));

    Fat16fs_Print(W(' | '#13#10));

    Fat16fs_SetColor($00FF00FF);
    if (attrs and FAT16FS_ATTR_DIRECTORY) <> 0 then
      Fat16fs_Print(W('<DIR>'#13#10))
    else
      Fat16fs_Print(W('FILE'#13#10));
  end;
end;

procedure Fat16fs_Ls; cdecl;
var
  callerThread: Integer;
  msgType, sender: Cardinal;
  payload: QWord;
  spin: QWord;
  smIrq: Byte;
  shared: Pointer;
  sectorBuf, fatBuf: PByte;
  cluster: Word;
  clusterLba, fatSector, s, secIdx: Cardinal;
  chainSteps: Cardinal;
begin
  Fat16fs_AcquireVfs;
  callerThread := AtaHw_CurrentThreadId;

  if (Fat16fs_UseDaemon <> 0) and (callerThread <> 0) then
  begin
    AtaHw_IpcSend(FAT16FS_IPC_LS_REQ, Cardinal(callerThread),
                  Fat16fs_DaemonId, 0);
    Fat16fs_WakeDaemon;

    msgType := 0; sender := 0; payload := 0;
    spin := 0;

    while true do
    begin
      if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload)
         and (msgType = FAT16FS_IPC_LS_REPLY) then
      begin
        Fat16fs_SetColor($00FFFF00);
        Fat16fs_Print(W('FILENAME        | PERMS    | SIZE       | TYPE'#13#10'-------------------------------------------------'#13#10));
        Fat16fs_SetColor($00FFFFFF);

        shared := AtaHw_GetSharedMemSilent;
        if shared = nil then
        begin
          Fat16fs_SetColor($00FF0000);
          Fat16fs_Print(W('[!] FATAL: Failed to get shared memory in Ls!'#13#10));
          Fat16fs_ReleaseVfs;
          Exit;
        end;

        smIrq := AtaHw_SharedMemLockAcquire;
        Fat16fs_Print(PWord(AtaHw_SharedFatResponseData));
        AtaHw_SharedMemLockRelease(smIrq);
        Fat16fs_ReleaseVfs;
        Exit;
      end;

      if Fat16fs_DaemonWaitTimedOut(spin) then
      begin
        Fat16fs_ReleaseVfs;
        Exit;
      end;
      AtaHw_Yield;
    end;
  end;

  if Fat16fs_Initialized = 0 then
  begin
    Fat16fs_ReleaseVfs;
    Exit;
  end;

  sectorBuf := Fat16fs_Alloc(FAT16FS_SECTOR_SIZE);
  if sectorBuf = nil then
  begin
    Fat16fs_SetColor($00FF0000);
    Fat16fs_Print(W('[!] FATAL: Failed to allocate sector buffer in Ls!'#13#10));
    Fat16fs_ReleaseVfs;
    Exit;
  end;

  Fat16fs_SetColor($00FFFF00);
  Fat16fs_Print(W('FILENAME        | SIZE       | TYPE'#13#10'------------------------------------'#13#10));

  if Fat16fs_CurrentDirCluster = 0 then
  begin
    if Fat16fs_RootSectors > FAT16FS_MAX_SECTORS then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Invalid root directory sectors in Ls!'#13#10));
      Fat16fs_Free(sectorBuf);
      Fat16fs_ReleaseVfs;
      Exit;
    end;

    s := 0;
    while s < Fat16fs_RootSectors do
    begin
      if s >= Fat16fs_RootSectors then
      begin
        Fat16fs_SetColor($00FF0000);
        Fat16fs_Print(W('[!] FATAL: Invalid root directory sector in Ls!'#13#10));
        Fat16fs_Free(sectorBuf);
        Fat16fs_ReleaseVfs;
        Exit;
      end;

      Ata_ReadSector(Fat16fs_RootDir + s, sectorBuf);
      PrintEntriesInline(sectorBuf);
      Inc(s);
    end;
  end
  else
  begin
    cluster := Fat16fs_CurrentDirCluster;
    fatBuf := Fat16fs_Alloc(FAT16FS_SECTOR_SIZE);
    if fatBuf = nil then
    begin
      Fat16fs_SetColor($00FF0000);
      Fat16fs_Print(W('[!] FATAL: Failed to allocate FAT buffer in Ls!'#13#10));
      Fat16fs_Free(sectorBuf);
      Fat16fs_ReleaseVfs;
      Exit;
    end;

    chainSteps := 0;
    while (cluster >= FAT16FS_MIN_CLUSTER) and (cluster <= FAT16FS_MAX_CLUSTER) do
    begin
      if chainSteps >= FAT16FS_MAX_CHAIN_STEPS then Break;
      Inc(chainSteps);

      if (cluster < FAT16FS_MIN_CLUSTER) or (cluster > FAT16FS_MAX_CLUSTER) then
      begin
        Fat16fs_SetColor($00FF0000);
        Fat16fs_Print(W('[!] FATAL: Invalid cluster number in Ls!'#13#10));
        Fat16fs_Free(fatBuf);
        Fat16fs_Free(sectorBuf);
        Fat16fs_ReleaseVfs;
        Exit;
      end;

      clusterLba := FAT16_ClusterLba_Pas(Fat16fs_FirstData, cluster,
                                         Fat16fs_CachedBpb.SectorsPerCluster);
      if clusterLba > FAT16FS_MAX_LBA then
      begin
        Fat16fs_SetColor($00FF0000);
        Fat16fs_Print(W('[!] FATAL: Invalid cluster LBA in Ls!'#13#10));
        Fat16fs_Free(fatBuf);
        Fat16fs_Free(sectorBuf);
        Fat16fs_ReleaseVfs;
        Exit;
      end;

      secIdx := 0;
      while secIdx < Fat16fs_CachedBpb.SectorsPerCluster do
      begin
        Ata_ReadSector(clusterLba + secIdx, sectorBuf);
        PrintEntriesInline(sectorBuf);
        Inc(secIdx);
      end;

      fatSector := FAT16_FatSectorForCluster_Pas(Fat16fs_FatStart,
                    Fat16fs_CachedBpb.ReservedSectorCount, cluster);
      if fatSector > FAT16FS_MAX_LBA then
      begin
        Fat16fs_SetColor($00FF0000);
        Fat16fs_Print(W('[!] FATAL: Invalid FAT sector in Ls!'#13#10));
        Fat16fs_Free(fatBuf);
        Fat16fs_Free(sectorBuf);
        Fat16fs_ReleaseVfs;
        Exit;
      end;

      Ata_ReadSector(fatSector, fatBuf);
      cluster := FAT16_GetNextCluster_Pas(fatBuf, cluster);
    end;
    Fat16fs_Free(fatBuf);
  end;

  Fat16fs_Free(sectorBuf);
  Fat16fs_ReleaseVfs;
end;

{ ═══════════════════════════════════════════════════════════════════════
  CONVENIENCE
  ═══════════════════════════════════════════════════════════════════════ }

procedure Fat16fs_Cat(filename: PWord); cdecl;
var
  fileSize: Cardinal;
  buf: PByte;
  i: Cardinal;
  c: Word;
begin
  fileSize := 0;
  buf := Fat16fs_ReadFile(filename, @fileSize, -1);
  if buf = nil then Exit;

  Fat16fs_SetColor($00FFFFFF);
  for i := 0 to fileSize - 1 do
  begin
    c := buf[i];
    if c <> 13 then Fat16fs_DrawChar(c);   { a bare CR would rewind the cursor }
  end;
  Fat16fs_Print(W(#13#10));

  Fat16fs_Free(buf);
end;

{ Jumps straight into a freshly loaded image. Win64 cdecl, so no shadow
  space is reserved, matching the C# delegate* unmanaged<void>. }
procedure Fat16fs_Run(filename: PWord); cdecl;
var
  fileSize: Cardinal;
  codeSegment: PByte;
begin
  fileSize := 0;
  codeSegment := Fat16fs_ReadFile(filename, @fileSize, -1);
  if codeSegment = nil then Exit;

  Fat16fs_SetColor($00FFFF00);
  Fat16fs_Print(W('[*] App loaded to RAM at '));
  AtaHw_PrintHex(QWord(codeSegment));
  Fat16fs_Print(W(#13#10'[*] Executing...'#13#10));

  asm
    mov rax, codeSegment
    call rax
  end;

  Fat16fs_SetColor($0000FF00);
  Fat16fs_Print(W('[+] App exited gracefully. Freeing memory...'#13#10));

  Fat16fs_Free(codeSegment);
end;

end.
