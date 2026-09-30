{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: fat16_app - Ring-3 FAT16 file system daemon.
  PORTED FROM: src/apps/FAT16_Driver.cs.

  This process is the whole file system. The kernel owns the mount and the
  boot, but every ls/cat/cd/write/mkdir/rm/chmod/chown from userland is
  served here. Three rules shape the code:

  1. NO ATA PORTS, EVER. All disk traffic goes to ata_app.pas over IPC
     (read/write/flush) because the kernel's raw driver shares those ports
     with us from another core. Reaching for 0x1F0 directly from here would
     interleave two command protocols on one channel.

  2. THE IPC PROTOCOL IS AN ABI. The kernel blocks on our type-39
     announcement before starting the login program, and Shell.exe speaks
     to us over types 30-61. Type numbers and payload meanings below are
     not free to change.

  3. NO CLOSURES, NO HEAP. Everything is a static or one of the three
     AllocMem windows taken at startup, so a request handler can never
     fault on an allocation that does not exist.

  The directory entry is a repurposed FAT16 entry: NekkoOS overlaid owner
  UID/GID and permission bits onto fields FAT never used meaningfully
  (see TDirEntry). fat16.pas reads the same offsets, which is why that
  unit is shared rather than duplicated.
  =========================================================================
}

unit fat16_app;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}

interface

{ PE entry point. The loader looks for this symbol by name. }
procedure AppMain; cdecl; public name 'AppMain';

implementation

uses app_api, libc, fat16, kstring;

const
  R_OK = 4;
  W_OK = 2;
  X_OK = 1;

  { UNIX-ish modes used when the driver creates an entry. }
  DIR_PERMS  = 493;   { 0755 }
  FILE_PERMS = 420;   { 0644 }

  { Access bits in the 9-bit permission word: three triads, owner first. }
  PERM_RWX          = 511;   { 0777 }
  TRIAD_SHIFT_OWNER = 6;
  TRIAD_SHIFT_GROUP = 3;
  TRIAD_MASK        = $07;

  { Lowest and highest valid FAT16 cluster numbers, and the chain end. }
  CLUSTER_MIN = $0002;
  CLUSTER_MAX = $FFEF;
  { Last cluster the free-space scan looks at (0xFFEF itself is excluded). }
  CLUSTER_SCAN_MAX = CLUSTER_MAX - 1;
  FAT_EOC = $FFFF;

  { One sector, one directory entry, entries per sector. }
  SECTOR_SIZE    = 512;
  DIRENTRY_SIZE  = 32;
  DIR_PER_SECTOR = SECTOR_SIZE div DIRENTRY_SIZE;

  { MBR: the first partition table entry sits 446 bytes into sector 0. }
  MBR_PART_TABLE_OFFSET = 446;

  { Ring buffer of messages that arrived while we were blocked on ATA.

    The C# original declared 2048 slots but backed the ring with a single
    page, which holds 4096/24 = 170 messages, and then indexed the array as
    though all 2048 were real. Past the 170th deferred message that scribbled
    up to ~48 KB into the RecursePool allocation.

    The ring now wraps at its real capacity. The queue is bounded either way -
    EnqueuePending drops the message when the next head would collide with the
    tail - so this only stops the overflow, and the shared block keeps the
    layout the kernel maps. Growing the block to 49152 bytes was the other
    option, but that changes the size the kernel hands out. }
  PENDING_MAX = 4096 div 24;   { 170, the real capacity; TMessage is 24 bytes,
                                    which is declared further down }

  { Recursion guard for RM -RF: 32 levels x 512 bytes = 16384, exactly the
    four pages allocated as RecursePool. }
  NUKE_MAX_DEPTH = 32;

  { Sanity ceilings inherited from the C# original. They only fire on a
    corrupt BPB, but firing is better than a 16 million iteration loop. }
  MAX_ROOT_DIR_SECTORS = $10000;
  MAX_LBA28           = $FFFFFF;

  { Attempts against a wedged ATA daemon before a request is abandoned.
    Zero would hang the entire file system forever. }
  ATA_RETRY_LIMIT = 5;

  { Cap for one LS response, in UTF-16 characters. FatResponseData is 8192
    bytes = 4096 characters, so this leaves room for the terminator. }
  LS_MAX_CHARS = 4000;

  { --- ATA side of the protocol (consumed by ata_app.pas) --- }
  ATA_IPC_READ       = 10;
  ATA_IPC_READ_DONE  = 11;
  ATA_IPC_WRITE      = 12;
  ATA_IPC_WRITE_DONE = 13;
  ATA_IPC_FLUSH      = 14;
  ATA_IPC_FLUSH_DONE = 15;
  ATA_IPC_ERROR      = 111;

  { --- Client side of the protocol (Shell.exe, dsrv.exe, explorer.exe, and
    the kernel boot handshake) --- }
  FAT_READY_HANDSHAKE = 39;   { to the kernel: "FAT16 is online" }

  FS_READ_REQ      = 30;
  FS_READ_SIZE     = 31;   { payload = file size, or 0 on failure }
  FS_WRITE_REQ     = 32;
  FS_WRITE_ASK     = 33;   { payload = byte offset the client must fill }
  FS_WRITE_GIVE    = 34;
  FS_WRITE_RESULT  = 35;   { payload = 1 success, 0 failure }
  FS_CD_REQ        = 36;
  FS_CD_RESULT     = 37;
  FS_READ_CHUNK    = 38;
  FS_READ_ACK      = 39;   { client confirms one chunk landed }
  FS_LS_REQ        = 40;
  FS_LS_RESULT     = 41;
  FS_READ_EOF      = 42;
  FS_READ_START    = 311;  { client is ready for the first chunk }
  FS_MKDIR_REQ     = 44;
  FS_MKDIR_RESULT  = 45;
  FS_RM_REQ        = 46;
  FS_RM_RESULT     = 47;   { 1 deleted, 2 target was a directory, 0 denied/absent }
  FS_RMRF_REQ      = 48;
  FS_RMRF_RESULT   = 49;
  FS_MKDIRAS_REQ   = 56;   { path \0 uid : gid }
  FS_MKDIRAS_RESULT = 57;
  FS_CHMOD_REQ     = 58;   { path \0 mode (decimal) }
  FS_CHMOD_RESULT  = 59;
  FS_CHOWN_REQ     = 60;   { path \0 uid : gid }
  FS_CHOWN_RESULT  = 61;

  FS_SIGTERM       = $DEAD;

  { Directory entry attribute bits actually consulted. }
  ATTR_VOLUME_ID = $08;
  ATTR_DIRECTORY = $10;
  ATTR_LFN       = $0F;

  { Name[0] values. }
  DIR_FREE_SLOT = $00;   { no further entries in this sector }
  DIR_DELETED   = $E5;

type
  { The shared window is one physical page range mapped into every daemon.
    The offsets are an ABI with the kernel and with ata_app.pas. }
  PSharedMemoryBlock = ^TSharedMemoryBlock;
  TSharedMemoryBlock = packed record
    ShellCommandBuffer: array[0..4095] of Byte;
    FatRequestName:     array[0..4095] of Byte;
    FatResponseData:    array[0..8191] of Byte;
    AtaRawBuffer:       array[0..4095] of Byte;
  end;

  { One page of scratch space taken at startup. Everything the handlers
    need lives here, so no handler can ever fail to allocate. }
  PWorkspaceBlock = ^TWorkspaceBlock;
  TWorkspaceBlock = packed record
    SectorBuf:     array[0..511] of Byte;
    FatBuf:        array[0..511] of Byte;
    FormattedName: array[0..15] of Byte;
    PrivateName:   array[0..255] of Word;
  end;

  { One FAT16 directory entry after NekkoOS overlaid ownership and
    permission bits onto fields stock FAT never used meaningfully. The
    offsets are load-bearing: fat16.pas reads attr at 11, OwnerGID at 12,
    Permissions at 18, OwnerUID at 20, cluster at 26 and size at 28. }
  PDirEntry = ^TDirEntry;
  TDirEntry = packed record
    Name:            array[0..10] of Byte;
    Attributes:      Byte;
    OwnerGID:        Word;
    CreationTime:    Word;
    CreationDate:    Word;
    Permissions:     Word;
    OwnerUID:        Word;
    WriteTime:       Word;
    WriteDate:       Word;
    FirstClusterLow: Word;
    FileSize:        Cardinal;
  end;

  PBpb = ^TBpb;
  TBpb = packed record
    JumpBoot:           array[0..2] of Byte;
    OEMName:            array[0..7] of Byte;
    BytesPerSector:     Word;
    SectorsPerCluster:  Byte;
    ReservedSectorCount: Word;
    NumFATs:            Byte;
    RootEntryCount:     Word;
    TotalSectors16:     Word;
    Media:              Byte;
    FATSize16:          Word;
    SectorsPerTrack:    Word;
    NumberOfHeads:      Word;
    HiddenSectors:      Cardinal;
    TotalSectors32:     Cardinal;
  end;

  { MBR partition table entry. 'Type' is a reserved word in Pascal. }
  PPartitionEntry = ^TPartitionEntry;
  TPartitionEntry = packed record
    Status:        Byte;
    ChsFirst:      array[0..2] of Byte;
    PartitionType: Byte;
    ChsLast:       array[0..2] of Byte;
    LbaStart:      Cardinal;
    SectorCount:   Cardinal;
  end;

  { IPC envelope. Layout must match app_api's private TMessage. }
  PMessage = ^TMessage;
  TMessage = packed record
    MsgType:  Cardinal;
    Sender:   Cardinal;
    Receiver: Cardinal;
    Padding:  Cardinal;
    Payload:  QWord;
  end;

var
  { PID of the ATA daemon, resolved once at startup. }
  AtaPid: Cardinal = 0;

  Fat_SharedMem: PSharedMemoryBlock = nil;
  SharedAddr:    QWord = 0;

  { Deferred messages. Fat_PendingQueue is the one page the kernel handed us;
    the ring bound is PENDING_MAX. }
  Fat_PendingQueue: PMessage  = nil;
  PendingHead:      LongInt   = 0;
  PendingTail:      LongInt   = 0;

  { Per-level 512-byte buffer for the RM -RF walk. }
  RecursePool: PByte   = nil;
  NukeDepth:   LongInt = 0;

  { Cached copy of the BIOS parameter block. Fat_ParseBPB reads the live
    sector; everything afterwards reads this. }
  CachedBPB: TBpb;

  FatStartLba:     Cardinal = 0;
  RootDirLba:      Cardinal = 0;
  FirstDataSector: Cardinal = 0;
  RootDirSectors:  Cardinal = 0;
  CurrentDirCluster: Word = 0;

  { The one file that must not inherit the public read granted to ownerless
    system binaries: it holds the password salt and hash. build.sh always
    mcopy's it to exactly this name, so matching on the name is safe. }
  SecretName: array[0..10] of Byte =
    (Ord('P'), Ord('A'), Ord('S'), Ord('S'), Ord('W'), Ord('D'),
     Ord(' '), Ord(' '), Ord(' '), Ord(' '), Ord(' '));

{ ---------------------------------------------------------------------
  Access control
  --------------------------------------------------------------------- }

{ Syscall 90 / 92 read the target thread id from the first argument, so
  these go through the vDSO stub directly: the app_api convenience wrappers
  are typed for the "no argument" self variants (syscall 89 / 93 take none)
  and would drop the thread id we actually need. }
function GetThreadUidOf(tid: Cardinal): Cardinal;
type TFn = function(t: Cardinal): Cardinal; cdecl;
begin
  GetThreadUidOf := TFn(AppApi_Slot(APP_SLOT_GET_THREAD_UID))(tid);
end;

function GetThreadGidOf(tid: Cardinal): Cardinal;
type TFn = function(t: Cardinal): Cardinal; cdecl;
begin
  GetThreadGidOf := TFn(AppApi_Slot(APP_SLOT_GET_THREAD_GID))(tid);
end;

function IsSecretName(formattedName: PByte): Boolean;
var
  i: Integer;
begin
  IsSecretName := True;
  if formattedName = nil then
  begin
    IsSecretName := False;
    Exit;
  end;
  for i := 0 to 10 do
    if formattedName[i] <> SecretName[i] then
    begin
      IsSecretName := False;
      Exit;
    end;
end;

{ UNIX-style permission check. cUID = 0 (root) always wins.

  The binaries build.sh mcopy's straight onto the disk (SHELL.EXE,
  FAT16.EXE, TOP.EXE, ...) never went through this driver's WRITE handler,
  so they carry no real OwnerUID/OwnerGID/Permissions - those bytes are
  whatever mtools wrote as the copy timestamp. Only OwnerUID is trusted as
  an "unowned" signal because the alternative, also requiring OwnerGID = 0,
  depends on a timestamp field that is rarely zero and locked ordinary
  users out of files they plainly should be able to run.

  For an unowned file: public read and execute, but not write - only root
  may replace or delete a system binary. }
function CheckAccess(cUID, cGID: Cardinal; fUID, fGID, perms: Word;
  requestedMode: LongInt): Boolean;
var
  p: Word;
  targetBits: LongInt;
begin
  if cUID = 0 then Exit(True);

  if (fUID = 0) and ((requestedMode and W_OK) = 0) then Exit(True);

  p := perms;
  if p > PERM_RWX then p := DIR_PERMS;

  if cUID = Cardinal(fUID) then
    targetBits := (p shr TRIAD_SHIFT_OWNER) and TRIAD_MASK
  else if cGID = Cardinal(fGID) then
    targetBits := (p shr TRIAD_SHIFT_GROUP) and TRIAD_MASK
  else
    targetBits := p and TRIAD_MASK;

  CheckAccess := (targetBits and requestedMode) = requestedMode;
end;

{ ---------------------------------------------------------------------
  Transport to the ATA daemon
  --------------------------------------------------------------------- }

{ Park a message for a different client that arrived while we were blocked
  on ATA. The main loop drains the queue before it reads the IPC port. }
procedure EnqueuePending(msg: PMessage);
var
  nextHead: LongInt;
begin
  nextHead := (PendingHead + 1) mod PENDING_MAX;
  if nextHead <> PendingTail then
  begin
    Fat_PendingQueue[PendingHead] := msg^;
    PendingHead := nextHead;
  end
  else
    App_Print(W('[WARN] FAT Server PendingQueue OVERFLOW!'#13#10));
end;

procedure ReadSectorIPC(lba: Cardinal; buffer: PByte);
var
  res: TMessage;
  retryCount: LongInt;
  i: Integer;
begin
  if buffer = nil then Exit;

  App_SendIPC(AtaPid, ATA_IPC_READ, lba);
  retryCount := 0;

  while True do
  begin
    if App_ReceiveIPC(@res) = 1 then
    begin
      if res.Sender = AtaPid then
      begin
        if res.MsgType = ATA_IPC_READ_DONE then
        begin
          for i := 0 to SECTOR_SIZE - 1 do
            buffer[i] := Fat_SharedMem^.AtaRawBuffer[i];
          Break;
        end
        else if res.MsgType = ATA_IPC_ERROR then
        begin
          Inc(retryCount);
          if retryCount >= ATA_RETRY_LIMIT then
          begin
            App_Print(W('[!] FAT16: ATA is dead. Aborting ReadSector.'#13#10));
            Break;
          end;
          App_SendIPC(AtaPid, ATA_IPC_READ, lba);
        end;
      end
      else
        EnqueuePending(@res);
    end
    else
      App_WaitIPC;
  end;
end;

procedure WriteSectorIPC(lba: Cardinal; buffer: PByte);
var
  res: TMessage;
  retryCount: LongInt;
  i: Integer;
begin
  if buffer = nil then
  begin
    App_Print(W('[!] FATAL: Null buffer in WriteSectorIPC!'#13#10));
    Exit;
  end;

  if lba > MAX_LBA28 then
  begin
    App_Print(W('[!] FATAL: Invalid LBA address in WriteSectorIPC!'#13#10));
    Exit;
  end;

  for i := 0 to SECTOR_SIZE - 1 do
    Fat_SharedMem^.AtaRawBuffer[i] := buffer[i];
  App_SendIPC(AtaPid, ATA_IPC_WRITE, lba);
  retryCount := 0;

  while True do
  begin
    if App_ReceiveIPC(@res) = 1 then
    begin
      if res.Sender = AtaPid then
      begin
        if res.MsgType = ATA_IPC_WRITE_DONE then
          Break
        else if res.MsgType = ATA_IPC_ERROR then
        begin
          { An error ACK used to match no branch at all here, so the wait
            spun forever and the whole daemon - plus every client waiting on
            it - hung. Retry a bounded number of times instead. }
          Inc(retryCount);
          if retryCount >= ATA_RETRY_LIMIT then
          begin
            App_Print(W('[!] FAT16: ATA is dead. Aborting WriteSector.'#13#10));
            Break;
          end;
          for i := 0 to SECTOR_SIZE - 1 do
            Fat_SharedMem^.AtaRawBuffer[i] := buffer[i];
          App_SendIPC(AtaPid, ATA_IPC_WRITE, lba);
        end;
      end
      else
        EnqueuePending(@res);
    end
    else
      App_WaitIPC;
  end;
end;

procedure FlushCacheIPC;
var
  res: TMessage;
  retryCount: LongInt;
begin
  App_SendIPC(AtaPid, ATA_IPC_FLUSH, 0);
  retryCount := 0;

  while True do
  begin
    if App_ReceiveIPC(@res) = 1 then
    begin
      if res.Sender = AtaPid then
      begin
        if res.MsgType = ATA_IPC_FLUSH_DONE then
          Break
        else if res.MsgType = ATA_IPC_ERROR then
        begin
          Inc(retryCount);
          if retryCount >= ATA_RETRY_LIMIT then
          begin
            App_Print(W('[!] FAT16: ATA is dead. Aborting FlushCache.'#13#10));
            Break;
          end;
          App_SendIPC(AtaPid, ATA_IPC_FLUSH, 0);
        end;
      end
      else
        EnqueuePending(@res);
    end
    else
      App_WaitIPC;
  end;
end;

{ ---------------------------------------------------------------------
  FAT table access
  --------------------------------------------------------------------- }

function GetFatEntry(cluster: Word; fatBuf: PByte): Word;
var
  fatSector: Cardinal;
begin
  fatSector := FAT16_FatSectorForCluster_Pas(FatStartLba,
                CachedBPB.ReservedSectorCount, cluster);
  ReadSectorIPC(fatSector, fatBuf);
  GetFatEntry := FAT16_GetNextCluster_Pas(fatBuf, cluster);
end;

{ Every FAT write goes to both FAT copies: a mirrored volume that has lost
  parity between them is exactly the failure that loses a file later. }
procedure SetFatEntry(cluster, value: Word; fatBuf: PByte);
var
  fatSector: Cardinal;
  entryOffset: Cardinal;
begin
  fatSector := FAT16_FatSectorForCluster_Pas(FatStartLba,
                CachedBPB.ReservedSectorCount, cluster);
  ReadSectorIPC(fatSector, fatBuf);
  entryOffset := FAT16_FatEntryOffset_Pas(cluster);
  PWord(fatBuf + entryOffset)^ := value;
  WriteSectorIPC(fatSector, fatBuf);
  WriteSectorIPC(fatSector + CachedBPB.FATSize16, fatBuf);
end;

{ ---------------------------------------------------------------------
  Directory lookup
  --------------------------------------------------------------------- }

function IsValidCluster(cluster: Word): Boolean; inline;
begin
  IsValidCluster := (cluster >= CLUSTER_MIN) and (cluster <= CLUSTER_MAX);
end;

{ Look a name up in the current directory. Returns True when the entry
  exists; the out parameters carry its chain head, size, attributes and
  ownership regardless. The caller initialises them, exactly as the C# did,
  because FAT16_CheckSector only writes them on a match. }
function FindEntry(name: PWord; outCluster: PWord; outSize: PCardinal;
  outAttr: PByte; outOwnerUID: PWord; outOwnerGID: PWord; outPerms: PWord;
  sectorBuf, fatBuf, formattedName: PByte): Boolean;
var
  cluster: Word;
  nextCluster: Word;
  s: LongInt;
  st: Integer;
  clusterLba: Cardinal;
  fatSector: Cardinal;
  found: Boolean;
  abortScan: Boolean;
  k: Integer;
begin
  if (name = nil) or (outCluster = nil) or (outSize = nil) or (outAttr = nil) or
     (outOwnerUID = nil) or (outOwnerGID = nil) or (outPerms = nil) or
     (sectorBuf = nil) or (fatBuf = nil) or (formattedName = nil) then
  begin
    App_Print(W('[!] FATAL: Null pointer in FindEntry!'#13#10));
    Exit(False);
  end;

  { ".." never survives FormatFATName (it would become "..       " with a
    NUL in the middle), so it is special-cased. }
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

  if CurrentDirCluster = 0 then
  begin
    if RootDirSectors > MAX_ROOT_DIR_SECTORS then
    begin
      App_Print(W('[!] FATAL: Invalid root directory sectors in FindEntry!'#13#10));
      Exit(False);
    end;

    for s := 0 to LongInt(RootDirSectors) - 1 do
    begin
      ReadSectorIPC(RootDirLba + Cardinal(s), sectorBuf);
      st := FAT16_CheckSector_Pas(sectorBuf, formattedName, outCluster,
             outSize, outAttr, outOwnerUID, outOwnerGID, outPerms);
      if st = 1 then
      begin
        found := True;
        Break;
      end;
      if st = 2 then Break;
    end;
  end
  else
  begin
    cluster := CurrentDirCluster;
    while IsValidCluster(cluster) do
    begin
      if not IsValidCluster(cluster) then
      begin
        App_Print(W('[!] FATAL: Invalid cluster number in FindEntry!'#13#10));
        Exit(False);
      end;

      clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, cluster,
                     CachedBPB.SectorsPerCluster);
      if clusterLba > MAX_LBA28 then
      begin
        App_Print(W('[!] FATAL: Invalid cluster LBA in FindEntry!'#13#10));
        Exit(False);
      end;

      abortScan := False;
      for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
      begin
        ReadSectorIPC(clusterLba + Cardinal(s), sectorBuf);
        st := FAT16_CheckSector_Pas(sectorBuf, formattedName, outCluster,
               outSize, outAttr, outOwnerUID, outOwnerGID, outPerms);
        if st = 1 then
        begin
          found := True;
          Break;
        end;
        if st = 2 then
        begin
          abortScan := True;
          Break;
        end;
      end;
      if found or abortScan then Break;

      fatSector := FAT16_FatSectorForCluster_Pas(FatStartLba,
                    CachedBPB.ReservedSectorCount, cluster);
      if fatSector > MAX_LBA28 then
      begin
        App_Print(W('[!] FATAL: Invalid FAT sector in FindEntry!'#13#10));
        Exit(False);
      end;

      ReadSectorIPC(fatSector, fatBuf);
      nextCluster := FAT16_GetNextCluster_Pas(fatBuf, cluster);
      cluster := nextCluster;
    end;
  end;

  FindEntry := (outSize^ > 0) or (outAttr^ <> 0) or (outCluster^ <> 0);
end;

{ ---------------------------------------------------------------------
  LS rendering
  --------------------------------------------------------------------- }

procedure AppendChar(c: Word; outStr: PWord; var outIdx: LongInt; maxChars: LongInt);
begin
  if (outStr = nil) or (outIdx < 0) or (outIdx >= maxChars) then Exit;
  outStr[outIdx] := c;
  Inc(outIdx);
end;

procedure AppendStr(str: PWord; outStr: PWord; var outIdx: LongInt; maxChars: LongInt);
var
  k: LongInt;
begin
  if str = nil then Exit;
  k := 0;
  while str[k] <> 0 do
  begin
    AppendChar(str[k], outStr, outIdx, maxChars);
    Inc(k);
  end;
end;

{ Right-aligned size in a 10 column field. }
procedure AppendNumPadded(num: QWord; outStr: PWord; var outIdx: LongInt; maxChars: LongInt);
var
  rev: array[0..19] of Word;
  revCount: LongInt;
  temp: QWord;
  digits: LongInt;
  t2: QWord;
  s: LongInt;
begin
  revCount := 0;
  temp := num;
  if temp = 0 then
  begin
    rev[revCount] := Ord('0');
    Inc(revCount);
  end
  else
    while temp > 0 do
    begin
      rev[revCount] := Ord('0') + Word(temp mod 10);
      Inc(revCount);
      temp := temp div 10;
    end;

  while revCount > 0 do
  begin
    Dec(revCount);
    AppendChar(rev[revCount], outStr, outIdx, maxChars);
  end;

  digits := 1;
  t2 := num;
  while t2 >= 10 do
  begin
    Inc(digits);
    t2 := t2 div 10;
  end;
  if num = 0 then digits := 1;

  for s := 0 to 9 - digits do
    AppendStr(W(' '), outStr, outIdx, maxChars);
end;

{ Nine permission bits, most significant first: rwx rwx rwx. }
procedure FormatPermissions(perms: Word; entryKind: Word; outStr: PWord;
  var outIdx: LongInt; maxChars: LongInt);
var
  shift: Integer;
begin
  AppendChar(entryKind, outStr, outIdx, maxChars);
  for shift := 8 downto 0 do
  begin
    if (perms and (Word(1) shl shift)) <> 0 then
    begin
      if (shift mod 3) = 2 then AppendChar(Ord('r'), outStr, outIdx, maxChars)
      else if (shift mod 3) = 1 then AppendChar(Ord('w'), outStr, outIdx, maxChars)
      else AppendChar(Ord('x'), outStr, outIdx, maxChars);
    end
    else
      AppendChar(Ord('-'), outStr, outIdx, maxChars);
  end;
end;

function PrintableOrSpace(c: Word): Word; inline;
begin
  if (c >= 32) and (c <= 126) then PrintableOrSpace := c
  else PrintableOrSpace := Ord(' ');
end;

procedure ProcessLSSector(buf: PByte; outStr: PWord; var outIdx: LongInt; maxChars: LongInt);
var
  entries: PDirEntry;
  i, j: Integer;
  printed: Integer;
  c: Word;
  permType: Word;
begin
  if (buf = nil) or (outStr = nil) then
  begin
    App_Print(W('[!] FATAL: Null pointer in ProcessLSSector!'#13#10));
    Exit;
  end;

  if (outIdx < 0) or (outIdx >= maxChars) then
  begin
    App_Print(W('[!] FATAL: Invalid output index in ProcessLSSector!'#13#10));
    Exit;
  end;

  entries := PDirEntry(buf);
  for i := 0 to DIR_PER_SECTOR - 1 do
  begin
    if entries[i].Name[0] = DIR_FREE_SLOT then Exit;
    if (entries[i].Name[0] = DIR_DELETED) or
       (entries[i].Attributes = ATTR_LFN) or
       ((entries[i].Attributes and ATTR_VOLUME_ID) <> 0) then Continue;

    { Base name, 8 columns padded. }
    printed := 0;
    for j := 0 to 7 do
    begin
      c := Word(entries[i].Name[j]);
      if (c = Ord(' ')) or (c = 0) then Break;
      AppendChar(PrintableOrSpace(c), outStr, outIdx, maxChars);
      Inc(printed);
    end;

    { Extension, only when there is one. }
    if (entries[i].Name[8] <> Ord(' ')) and (entries[i].Name[8] <> 0) then
    begin
      AppendChar(Ord('.'), outStr, outIdx, maxChars);
      Inc(printed);
      for j := 8 to 10 do
      begin
        c := Word(entries[i].Name[j]);
        if (c = Ord(' ')) or (c = 0) then Break;
        AppendChar(PrintableOrSpace(c), outStr, outIdx, maxChars);
        Inc(printed);
      end;
    end;

    while printed < 16 do
    begin
      AppendChar(Ord(' '), outStr, outIdx, maxChars);
      Inc(printed);
    end;

    AppendStr(W(' | '), outStr, outIdx, maxChars);
    if (entries[i].Attributes and ATTR_DIRECTORY) <> 0 then
      permType := Ord('d')
    else
      permType := Ord('-');
    FormatPermissions(entries[i].Permissions, permType, outStr, outIdx, maxChars);
    AppendStr(W(' | '), outStr, outIdx, maxChars);
    AppendNumPadded(entries[i].FileSize, outStr, outIdx, maxChars);
    AppendStr(W(' bytes | '), outStr, outIdx, maxChars);
    if (entries[i].Attributes and ATTR_DIRECTORY) <> 0 then
      AppendStr(W('<DIR>'#13#10), outStr, outIdx, maxChars)
    else
      AppendStr(W('FILE'#13#10), outStr, outIdx, maxChars);
  end;
end;

{ ---------------------------------------------------------------------
  Directory mutation helpers
  --------------------------------------------------------------------- }

function NameMatches(entry: PDirEntry; formattedName: PByte): Boolean;
var
  j: Integer;
begin
  for j := 0 to 10 do
    if entry^.Name[j] <> formattedName[j] then Exit(False);
  NameMatches := True;
end;

procedure CopyFormattedName(entry: PDirEntry; formattedName: PByte);
var
  j: Integer;
begin
  for j := 0 to 10 do
    entry^.Name[j] := formattedName[j];
end;

{ Free a whole cluster chain, entry point aside. }
procedure FreeClusterChain(targetCluster: Word; fatBuf: PByte);
var
  cur: Word;
  next: Word;
begin
  if targetCluster < CLUSTER_MIN then Exit;
  cur := targetCluster;
  while IsValidCluster(cur) do
  begin
    next := GetFatEntry(cur, fatBuf);
    SetFatEntry(cur, 0, fatBuf);
    cur := next;
  end;
end;

{ --- WRITE: reuse a free slot, stamping ownership and permissions --- }
procedure ProcessWriteSector(lba: Cardinal; formattedName: PByte;
  firstCluster: Word; fileSize: Cardinal; callerUID, callerGID: Cardinal;
  sectorBuf: PByte; var saved: Boolean);
var
  entries: PDirEntry;
  i: Integer;
begin
  if saved then Exit;
  ReadSectorIPC(lba, sectorBuf);
  entries := PDirEntry(sectorBuf);
  for i := 0 to DIR_PER_SECTOR - 1 do
  begin
    if (entries[i].Name[0] = DIR_FREE_SLOT) or (entries[i].Name[0] = DIR_DELETED) then
    begin
      CopyFormattedName(@entries[i], formattedName);
      entries[i].Attributes := $20;            { archive, a regular file }
      entries[i].OwnerGID := Word(callerGID);
      entries[i].CreationTime := 0;
      entries[i].CreationDate := 0;
      entries[i].Permissions := FILE_PERMS;
      entries[i].WriteTime := 0;
      entries[i].WriteDate := 0;
      entries[i].OwnerUID := Word(callerUID);
      entries[i].FirstClusterLow := firstCluster;
      entries[i].FileSize := fileSize;
      WriteSectorIPC(lba, sectorBuf);
      saved := True;
      Exit;
    end;
  end;
end;

{ --- MKDIR --- }
procedure ProcessMkdirSector(lba: Cardinal; formattedName: PByte;
  newCluster: Word; callerUID, callerGID: Cardinal; sectorBuf: PByte;
  var created: Boolean);
var
  entries: PDirEntry;
  i: Integer;
begin
  if created then Exit;
  ReadSectorIPC(lba, sectorBuf);
  entries := PDirEntry(sectorBuf);
  for i := 0 to DIR_PER_SECTOR - 1 do
  begin
    if (entries[i].Name[0] = DIR_FREE_SLOT) or (entries[i].Name[0] = DIR_DELETED) then
    begin
      CopyFormattedName(@entries[i], formattedName);
      entries[i].Attributes := ATTR_DIRECTORY;
      entries[i].OwnerGID := Word(callerGID);
      entries[i].CreationTime := 0;
      entries[i].CreationDate := 0;
      entries[i].Permissions := DIR_PERMS;
      entries[i].OwnerUID := Word(callerUID);
      entries[i].WriteTime := 0;
      entries[i].WriteDate := 0;
      entries[i].FirstClusterLow := newCluster;
      entries[i].FileSize := 0;
      WriteSectorIPC(lba, sectorBuf);
      created := True;
      Exit;
    end;
  end;
end;

{ --- CHMOD / CHOWN: same find-and-patch-in-place, different fields --- }
procedure ProcessChattrSector(lba: Cardinal; formattedName: PByte;
  sectorBuf: PByte; var found: Boolean; applyOwner: Boolean;
  newUID, newGID: Cardinal; applyPerms: Boolean; newPerms: Word);
var
  entries: PDirEntry;
  i: Integer;
begin
  if found then Exit;
  ReadSectorIPC(lba, sectorBuf);
  entries := PDirEntry(sectorBuf);
  for i := 0 to DIR_PER_SECTOR - 1 do
  begin
    if entries[i].Name[0] = DIR_FREE_SLOT then Exit;
    if entries[i].Name[0] = DIR_DELETED then Continue;
    if NameMatches(@entries[i], formattedName) then
    begin
      if applyOwner then
      begin
        entries[i].OwnerUID := Word(newUID);
        entries[i].OwnerGID := Word(newGID);
      end;
      if applyPerms then
        entries[i].Permissions := newPerms;
      WriteSectorIPC(lba, sectorBuf);
      found := True;
      Exit;
    end;
  end;
end;

{ --- RM: unlink a file, refusing directories --- }
procedure ProcessRmSector(lba: Cardinal; formattedName: PByte;
  callerUID, callerGID: Cardinal; fatBuf, sectorBuf: PByte;
  var deleted, isDirError, accessDenied: Boolean);
var
  entries: PDirEntry;
  i: Integer;
  startCluster: Word;
begin
  if deleted or isDirError or accessDenied then Exit;
  ReadSectorIPC(lba, sectorBuf);
  entries := PDirEntry(sectorBuf);
  for i := 0 to DIR_PER_SECTOR - 1 do
  begin
    if entries[i].Name[0] = DIR_FREE_SLOT then Exit;
    if entries[i].Name[0] = DIR_DELETED then Continue;
    if NameMatches(@entries[i], formattedName) then
    begin
      if not CheckAccess(callerUID, callerGID, entries[i].OwnerUID,
           entries[i].OwnerGID, entries[i].Permissions, W_OK) then
      begin
        accessDenied := True;
        Exit;
      end;
      if (entries[i].Attributes and ATTR_DIRECTORY) <> 0 then
      begin
        isDirError := True;
        Exit;
      end;
      startCluster := entries[i].FirstClusterLow;
      entries[i].Name[0] := DIR_DELETED;
      WriteSectorIPC(lba, sectorBuf);
      if startCluster >= CLUSTER_MIN then
        FreeClusterChain(startCluster, fatBuf);
      deleted := True;
      Exit;
    end;
  end;
end;

{ --- Overwrite path: drop the old entry and chain without reporting --- }
procedure ProcessSilentRm(lba: Cardinal; formattedName: PByte;
  targetCluster: Word; fatBuf, sectorBuf: PByte; var deletedOld: Boolean);
var
  entries: PDirEntry;
  i: Integer;
begin
  if deletedOld then Exit;
  ReadSectorIPC(lba, sectorBuf);
  entries := PDirEntry(sectorBuf);
  for i := 0 to DIR_PER_SECTOR - 1 do
  begin
    if entries[i].Name[0] = DIR_FREE_SLOT then Exit;
    if entries[i].Name[0] = DIR_DELETED then Continue;
    if NameMatches(@entries[i], formattedName) then
    begin
      entries[i].Name[0] := DIR_DELETED;
      WriteSectorIPC(lba, sectorBuf);
      if targetCluster >= CLUSTER_MIN then
        FreeClusterChain(targetCluster, fatBuf);
      deletedOld := True;
      Exit;
    end;
  end;
end;

{ ---------------------------------------------------------------------
  MKDIR
  --------------------------------------------------------------------- }

{ Grow the current directory's cluster chain by one cluster. Returns the new
  cluster, or 0 when the volume is full. }
function ExpandDirectoryChain(fatBuf: PByte): Word;
var
  lastCluster: Word;
  next: Word;
  expandCluster: Word;
  c: Word;
begin
  lastCluster := CurrentDirCluster;
  while True do
  begin
    next := GetFatEntry(lastCluster, fatBuf);
    if IsValidCluster(next) then lastCluster := next else Break;
  end;

  ExpandDirectoryChain := 0;
  for c := 2 to CLUSTER_SCAN_MAX do
  begin
    if GetFatEntry(c, fatBuf) = 0 then
    begin
      expandCluster := c;
      SetFatEntry(lastCluster, expandCluster, fatBuf);
      SetFatEntry(expandCluster, FAT_EOC, fatBuf);
      ExpandDirectoryChain := expandCluster;
      Exit;
    end;
  end;
end;

procedure DoMkdir(privateName: PWord; effectiveOwnerUID, effectiveOwnerGID,
  callerUID, callerGID, client: Cardinal; sectorBuf, fatBuf, formattedName: PByte;
  responseType: Cardinal);
var
  canCreateHere: Boolean;
  curDirLba: Cardinal;
  entries: PDirEntry;
  dotEntries: PDirEntry;
  tmpCluster: Word;
  tmpSize: Cardinal;
  tmpAttr: Byte;
  tmpOwnerUID: Word;
  tmpOwnerGID: Word;
  tmpPerms: Word;
  newCluster: Word;
  newClusterLba: Cardinal;
  c: Word;
  created: Boolean;
  curClus: Word;
  clusterLba: Cardinal;
  expandCluster: Word;
  expandLba: Cardinal;
  b, s: LongInt;
begin
  if FatNameValid(privateName) = 0 then
  begin
    App_Print(W('[!] Ten qua dai! FAT16 ho da 8 ky tu + duoi 3 ky tu (vi du: PROJECT.C)'#13#10));
    App_SendIPC(client, responseType, 0);
    App_Yield;
    Exit;
  end;

  FormatFATName(privateName, formattedName);

  canCreateHere := False;
  if CurrentDirCluster = 0 then
  begin
    if callerUID = 0 then canCreateHere := True;
  end
  else
  begin
    curDirLba := FAT16_ClusterLba_Pas(FirstDataSector, CurrentDirCluster,
                   CachedBPB.SectorsPerCluster);
    ReadSectorIPC(curDirLba, sectorBuf);
    entries := PDirEntry(sectorBuf);
    { entries[0] is the "." entry, which carries the directory's own
      ownership - that is what the permission check reads. }
    if CheckAccess(callerUID, callerGID, entries[0].OwnerUID,
         entries[0].OwnerGID, entries[0].Permissions, W_OK) then
      canCreateHere := True;
  end;

  tmpCluster := 0; tmpSize := 0; tmpAttr := 0;
  tmpOwnerUID := 0; tmpOwnerGID := 0; tmpPerms := 0;
  if FindEntry(privateName, @tmpCluster, @tmpSize, @tmpAttr, @tmpOwnerUID,
       @tmpOwnerGID, @tmpPerms, sectorBuf, fatBuf, formattedName) then
  begin
    App_SendIPC(client, responseType, 0);
    App_Yield;
    Exit;
  end
  else if not canCreateHere then
  begin
    App_Print(W('[!] Access Denied: You do not own or have Write (w) permission on this Directory!'#13#10));
    App_SendIPC(client, responseType, 0);
    App_Yield;
    Exit;
  end;

  newCluster := 0;
  for c := 2 to CLUSTER_SCAN_MAX do
  begin
    if GetFatEntry(c, fatBuf) = 0 then
    begin
      newCluster := c;
      SetFatEntry(c, FAT_EOC, fatBuf);
      Break;
    end;
  end;

  if newCluster = 0 then
  begin
    App_SendIPC(client, responseType, 0);
    App_Yield;
    Exit;
  end;

  { Zero the new cluster, then write its "." and ".." entries. }
  newClusterLba := FAT16_ClusterLba_Pas(FirstDataSector, newCluster,
                 CachedBPB.SectorsPerCluster);
  for b := 0 to SECTOR_SIZE - 1 do
    sectorBuf[b] := 0;
  for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
    WriteSectorIPC(newClusterLba + Cardinal(s), sectorBuf);

  ReadSectorIPC(newClusterLba, sectorBuf);
  dotEntries := PDirEntry(sectorBuf);

  for b := 0 to 10 do
    dotEntries[0].Name[b] := Ord(' ');
  dotEntries[0].Name[0] := Ord('.');
  dotEntries[0].Attributes := ATTR_DIRECTORY;
  dotEntries[0].OwnerUID := Word(effectiveOwnerUID);
  dotEntries[0].OwnerGID := Word(effectiveOwnerGID);
  dotEntries[0].Permissions := DIR_PERMS;
  dotEntries[0].FirstClusterLow := newCluster;

  for b := 0 to 10 do
    dotEntries[1].Name[b] := Ord(' ');
  dotEntries[1].Name[0] := Ord('.');
  dotEntries[1].Name[1] := Ord('.');
  dotEntries[1].Attributes := ATTR_DIRECTORY;
  dotEntries[1].OwnerUID := Word(effectiveOwnerUID);
  dotEntries[1].OwnerGID := Word(effectiveOwnerGID);
  dotEntries[1].Permissions := DIR_PERMS;
  dotEntries[1].FirstClusterLow := CurrentDirCluster;
  WriteSectorIPC(newClusterLba, sectorBuf);

  created := False;
  if CurrentDirCluster = 0 then
  begin
    for s := 0 to LongInt(RootDirSectors) - 1 do
      ProcessMkdirSector(RootDirLba + Cardinal(s), formattedName, newCluster,
        effectiveOwnerUID, effectiveOwnerGID, sectorBuf, created);
  end
  else
  begin
    curClus := CurrentDirCluster;
    while IsValidCluster(curClus) do
    begin
      clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, curClus,
                     CachedBPB.SectorsPerCluster);
      for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
        ProcessMkdirSector(clusterLba + Cardinal(s), formattedName, newCluster,
          effectiveOwnerUID, effectiveOwnerGID, sectorBuf, created);
      curClus := GetFatEntry(curClus, fatBuf);
    end;
  end;

  if created then
  begin
    FlushCacheIPC;
    App_SendIPC(client, responseType, 1);
    Exit;
  end;

  { The directory had no free slot. Either grow it, or - for the root
    directory, which is fixed size by the BPB - give the cluster back. }
  if CurrentDirCluster = 0 then
  begin
    SetFatEntry(newCluster, 0, fatBuf);
    FlushCacheIPC;
    App_SendIPC(client, responseType, 0);
    Exit;
  end;

  expandCluster := ExpandDirectoryChain(fatBuf);
  if expandCluster = 0 then
  begin
    SetFatEntry(newCluster, 0, fatBuf);
    FlushCacheIPC;
    App_SendIPC(client, responseType, 0);
    Exit;
  end;

  expandLba := FAT16_ClusterLba_Pas(FirstDataSector, expandCluster,
                CachedBPB.SectorsPerCluster);
  for b := 0 to SECTOR_SIZE - 1 do
    sectorBuf[b] := 0;
  for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
    WriteSectorIPC(expandLba + Cardinal(s), sectorBuf);

  dotEntries := PDirEntry(sectorBuf);
  CopyFormattedName(@dotEntries[0], formattedName);
  dotEntries[0].Attributes := ATTR_DIRECTORY;
  dotEntries[0].OwnerGID := Word(effectiveOwnerGID);
  dotEntries[0].CreationTime := 0;
  dotEntries[0].CreationDate := 0;
  dotEntries[0].Permissions := DIR_PERMS;
  dotEntries[0].OwnerUID := Word(effectiveOwnerUID);
  dotEntries[0].WriteTime := 0;
  dotEntries[0].WriteDate := 0;
  dotEntries[0].FirstClusterLow := newCluster;
  dotEntries[0].FileSize := 0;
  WriteSectorIPC(expandLba, sectorBuf);
  FlushCacheIPC;
  App_SendIPC(client, responseType, 1);
end;

{ ---------------------------------------------------------------------
  CHMOD / CHOWN
  --------------------------------------------------------------------- }

procedure DoChmod(privateName: PWord; callerUID, callerGID, client: Cardinal;
  sectorBuf, fatBuf, formattedName: PByte; newPerms: Word);
var
  curCluster: Word;
  curSize: Cardinal;
  curAttr: Byte;
  curUID: Word;
  curGID: Word;
  curPerms: Word;
  found: Boolean;
  cur: Word;
  clusterLba: Cardinal;
  s: LongInt;
begin
  FormatFATName(privateName, formattedName);
  curCluster := 0; curSize := 0; curAttr := 0;
  curUID := 0; curGID := 0; curPerms := 0;
  if not FindEntry(privateName, @curCluster, @curSize, @curAttr, @curUID,
       @curGID, @curPerms, sectorBuf, fatBuf, formattedName) then
  begin
    App_SendIPC(client, FS_CHMOD_RESULT, 0);
    App_Yield;
    Exit;
  end;

  { chmod of yourself is allowed; otherwise you must be the owner. }
  if (callerUID <> 0) and (callerUID <> Cardinal(curUID)) then
  begin
    App_Print(W('[!] Access Denied: Only the owner or root can chmod this entry!'#13#10));
    App_SendIPC(client, FS_CHMOD_RESULT, 0);
    App_Yield;
    Exit;
  end;

  found := False;
  if CurrentDirCluster = 0 then
  begin
    for s := 0 to LongInt(RootDirSectors) - 1 do
      ProcessChattrSector(RootDirLba + Cardinal(s), formattedName, sectorBuf,
        found, False, 0, 0, True, newPerms);
  end
  else
  begin
    cur := CurrentDirCluster;
    while IsValidCluster(cur) do
    begin
      clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, cur,
                     CachedBPB.SectorsPerCluster);
      for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
        ProcessChattrSector(clusterLba + Cardinal(s), formattedName, sectorBuf,
          found, False, 0, 0, True, newPerms);
      cur := GetFatEntry(cur, fatBuf);
    end;
  end;

  if found then
  begin
    FlushCacheIPC;
    App_SendIPC(client, FS_CHMOD_RESULT, 1);
  end
  else
    App_SendIPC(client, FS_CHMOD_RESULT, 0);
end;

{ chown is root-only, as on UNIX: an ordinary owner cannot hand their file
  to somebody else and thereby escape the permission model. }
procedure DoChown(privateName: PWord; callerUID, callerGID, client: Cardinal;
  sectorBuf, fatBuf, formattedName: PByte; newUID, newGID: Cardinal);
var
  curCluster: Word;
  curSize: Cardinal;
  curAttr: Byte;
  curUID: Word;
  curGID: Word;
  curPerms: Word;
  found: Boolean;
  cur: Word;
  clusterLba: Cardinal;
  dotLba: Cardinal;
  dotEntries: PDirEntry;
  s: LongInt;
begin
  FormatFATName(privateName, formattedName);
  curCluster := 0; curSize := 0; curAttr := 0;
  curUID := 0; curGID := 0; curPerms := 0;
  if not FindEntry(privateName, @curCluster, @curSize, @curAttr, @curUID,
       @curGID, @curPerms, sectorBuf, fatBuf, formattedName) then
  begin
    App_SendIPC(client, FS_CHOWN_RESULT, 0);
    App_Yield;
    Exit;
  end;

  if callerUID <> 0 then
  begin
    App_Print(W('[!] Access Denied: Only root can chown!'#13#10));
    App_SendIPC(client, FS_CHOWN_RESULT, 0);
    App_Yield;
    Exit;
  end;

  found := False;
  if CurrentDirCluster = 0 then
  begin
    for s := 0 to LongInt(RootDirSectors) - 1 do
      ProcessChattrSector(RootDirLba + Cardinal(s), formattedName, sectorBuf,
        found, True, newUID, newGID, False, 0);
  end
  else
  begin
    cur := CurrentDirCluster;
    while IsValidCluster(cur) do
    begin
      clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, cur,
                     CachedBPB.SectorsPerCluster);
      for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
        ProcessChattrSector(clusterLba + Cardinal(s), formattedName, sectorBuf,
          found, True, newUID, newGID, False, 0);
      cur := GetFatEntry(cur, fatBuf);
    end;
  end;

  { A directory keeps its ownership a second time in its own "." entry,
    which is what DoMkdir and CheckAccess consult. Patch it too or the new
    owner is not really the owner. }
  if found and ((curAttr and ATTR_DIRECTORY) <> 0) and (curCluster >= CLUSTER_MIN) then
  begin
    dotLba := FAT16_ClusterLba_Pas(FirstDataSector, curCluster,
                CachedBPB.SectorsPerCluster);
    ReadSectorIPC(dotLba, sectorBuf);
    dotEntries := PDirEntry(sectorBuf);
    if dotEntries[0].Name[0] = Ord('.') then
    begin
      dotEntries[0].OwnerUID := Word(newUID);
      dotEntries[0].OwnerGID := Word(newGID);
      WriteSectorIPC(dotLba, sectorBuf);
    end;
  end;

  if found then
  begin
    FlushCacheIPC;
    App_SendIPC(client, FS_CHOWN_RESULT, 1);
  end
  else
    App_SendIPC(client, FS_CHOWN_RESULT, 0);
end;

{ ---------------------------------------------------------------------
  RM - RF
  --------------------------------------------------------------------- }

{ Recursively unlink everything under a directory. Each level uses its own
  512-byte buffer out of RecursePool so a deep tree cannot exhaust the
  stack. Depth is capped; the cap is a correctness limit, not just a
  safety net, because the pool is sized for exactly NUKE_MAX_DEPTH levels. }
procedure DestroyDirectory(dirCluster: Word; fatBuf: PByte);
var
  localBuf: PByte;
  curClus: Word;
  clusterLba: Cardinal;
  lba: Cardinal;
  entries: PDirEntry;
  modified: Boolean;
  c: Integer;
  s: LongInt;
  itemCluster: Word;
  fClus: Word;
  next: Word;
  isDot, isDotDot: Boolean;
begin
  if not IsValidCluster(dirCluster) then Exit;

  if fatBuf = nil then
  begin
    App_Print(W('[!] FATAL: Null FAT buffer in DestroyDirectory!'#13#10));
    Exit;
  end;

  if NukeDepth >= NUKE_MAX_DEPTH then Exit;

  localBuf := RecursePool + (NukeDepth * SECTOR_SIZE);
  Inc(NukeDepth);

  curClus := dirCluster;
  while IsValidCluster(curClus) do
  begin
    if not IsValidCluster(curClus) then
    begin
      App_Print(W('[!] FATAL: Invalid cluster number in DestroyDirectory loop!'#13#10));
      Exit;
    end;

    clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, curClus,
                   CachedBPB.SectorsPerCluster);
    if clusterLba > MAX_LBA28 then
    begin
      App_Print(W('[!] FATAL: Invalid cluster LBA in DestroyDirectory!'#13#10));
      Exit;
    end;

    for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
    begin
      lba := clusterLba + Cardinal(s);
      ReadSectorIPC(lba, localBuf);
      entries := PDirEntry(localBuf);
      modified := False;

      for c := 0 to DIR_PER_SECTOR - 1 do
      begin
        if entries[c].Name[0] = DIR_FREE_SLOT then Break;
        if entries[c].Name[0] = DIR_DELETED then Continue;
        isDot := (entries[c].Name[0] = Ord('.')) and (entries[c].Name[1] = Ord(' '));
        isDotDot := (entries[c].Name[0] = Ord('.')) and (entries[c].Name[1] = Ord('.')) and
                    (entries[c].Name[2] = Ord(' '));
        if isDot or isDotDot then Continue;

        itemCluster := entries[c].FirstClusterLow;
        if (entries[c].Attributes and ATTR_DIRECTORY) <> 0 then
          DestroyDirectory(itemCluster, fatBuf);

        if itemCluster >= CLUSTER_MIN then
        begin
          fClus := itemCluster;
          while IsValidCluster(fClus) do
          begin
            if not IsValidCluster(fClus) then
            begin
              App_Print(W('[!] FATAL: Invalid cluster number in DestroyDirectory FAT traversal!'#13#10));
              Exit;
            end;
            next := GetFatEntry(fClus, fatBuf);
            SetFatEntry(fClus, 0, fatBuf);
            fClus := next;
          end;
        end;
        entries[c].Name[0] := DIR_DELETED;
        modified := True;
      end;
      if modified then WriteSectorIPC(lba, localBuf);
    end;
    curClus := GetFatEntry(curClus, fatBuf);
  end;
  Dec(NukeDepth);
end;

{ Find the target and nuke it. errorCode: 0 nothing yet, 1 removed,
  2 target was not a directory, 4 write permission denied. }
procedure FindAndNuke(lba: Cardinal; formattedName: PByte; callerUID,
  callerGID: Cardinal; fatBuf, sectorBuf: PByte; var deleted: Boolean;
  var errorCode: Cardinal);
var
  entries: PDirEntry;
  i: Integer;
  targetCluster: Word;
begin
  if deleted or (errorCode <> 0) then Exit;
  ReadSectorIPC(lba, sectorBuf);
  entries := PDirEntry(sectorBuf);
  for i := 0 to DIR_PER_SECTOR - 1 do
  begin
    if entries[i].Name[0] = DIR_FREE_SLOT then Exit;
    if entries[i].Name[0] = DIR_DELETED then Continue;

    if NameMatches(@entries[i], formattedName) then
    begin
      if not CheckAccess(callerUID, callerGID, entries[i].OwnerUID,
           entries[i].OwnerGID, entries[i].Permissions, W_OK) then
      begin
        errorCode := 4;
        Exit;
      end;
      if (entries[i].Attributes and ATTR_DIRECTORY) = 0 then
      begin
        errorCode := 2;
        Exit;
      end;

      targetCluster := entries[i].FirstClusterLow;
      DestroyDirectory(targetCluster, fatBuf);

      if targetCluster >= CLUSTER_MIN then
        FreeClusterChain(targetCluster, fatBuf);

      entries[i].Name[0] := DIR_DELETED;
      WriteSectorIPC(lba, sectorBuf);
      deleted := True;
      errorCode := 1;
      Exit;
    end;
  end;
end;

{ ---------------------------------------------------------------------
  Path parsing for the compound commands
  --------------------------------------------------------------------- }

{ Requests like MKDIR_AS, CHMOD and CHOWN pack a second field after the
  path: "NAME \0 uid : gid" or "NAME \0 mode". Copies the path into the
  workspace and returns where the second field starts. }
function SplitCompoundRequest(sharedName: PWord; privateName: PWord): Cardinal;
var
  nameLen: Cardinal;
begin
  nameLen := StrCpyLimited(privateName, sharedName, 255);
  SplitCompoundRequest := nameLen + 1;
end;

procedure ParseUIDGID(sharedName: PWord; fromPos: LongInt; var outUID, outGID: Cardinal);
var
  p: LongInt;
begin
  outUID := Atoi(sharedName + fromPos);
  p := fromPos;
  while (sharedName[p] <> 0) and (sharedName[p] >= Ord('0')) and
        (sharedName[p] <= Ord('9')) do
    Inc(p);
  if sharedName[p] = Ord(':') then Inc(p);
  outGID := Atoi(sharedName + p);
end;

{ ---------------------------------------------------------------------
  Entry point
  --------------------------------------------------------------------- }

procedure AppMain; cdecl;
var
  ataName: array[0..7] of Word;
  pid: LongInt;
  i: Integer;
  workspaceAddr: QWord;
  ws: PWorkspaceBlock;
  sectorBuf: PByte;
  fatBuf: PByte;
  formattedName: PByte;
  privateName: PWord;
  sharedName: PWord;
  dataChunk: PByte;
  outStr: PWord;
  bpbPtr: PByte;
  part1: PPartitionEntry;
  isSuperFloppy: Boolean;
  rootDirSectorsLocal: Cardinal;
  rootDirLbaLocal: Cardinal;
  firstDataSectorLocal: Cardinal;
  msg: TMessage;
  hasMsg: Boolean;
  msgType: Cardinal;
  client: Cardinal;
  callerUID: Cardinal;
  callerGID: Cardinal;

  { READ }
  cluster: Word;
  fileSize: Cardinal;
  attr: Byte;
  ownerUID: Word;
  ownerGID: Word;
  perms: Word;
  canReadFile: Boolean;
  ack: TMessage;
  bytesRead: Cardinal;
  clusterLba: Cardinal;
  s: LongInt;
  b: LongInt;

  { WRITE }
  existCluster: Word;
  existSize: Cardinal;
  existAttr: Byte;
  existOwnerUID: Word;
  existOwnerGID: Word;
  existPerms: Word;
  canCreateHere: Boolean;
  bytesPerSectorU: QWord;
  totalSectorsU: QWord;
  maxFileBytes: QWord;
  curDirLba: Cardinal;
  deletedOld: Boolean;
  targetCluster: Word;
  curClus: Word;
  clusterSize: Cardinal;
  numClusters: Cardinal;
  firstCluster: Word;
  prevCluster: Word;
  allocated: Cardinal;
  c: Word;
  bytesWritten: Cardinal;
  currentCluster: Word;
  saved: Boolean;
  nextClus: Word;
  expandCluster: Word;
  expandLba: Cardinal;
  entries: PDirEntry;
  dataRes: TMessage;

  { RM / RM -RF }
  deleted: Boolean;
  isDirError: Boolean;
  accessDenied: Boolean;
  errorCode: Cardinal;

  { CD }
  cdCluster: Word;
  cdSize: Cardinal;
  cdAttr: Byte;
  cdOwnerUID: Word;
  cdOwnerGID: Word;
  cdPerms: Word;

  { LS }
  outIdx: LongInt;

  { MKDIR / CHMOD / CHOWN }
  nameLen: Cardinal;
  p: LongInt;
  targetUID: Cardinal;
  targetGID: Cardinal;
  mode: Cardinal;
begin
  AppApi_Init;

  for i := 1 to Length('ATA.EXE') do
    ataName[i - 1] := Word(Byte(('ATA.EXE')[i]));
  ataName[Length('ATA.EXE')] := 0;

  pid := App_GetPIDByName(@ataName[0]);
  if pid = -1 then
  begin
    App_Print(W('[!] FATAL: ATA.EXE Daemon not found! FAT16 Locked!'#13#10));
    App_Exit;
    Exit;
  end;
  AtaPid := Cardinal(pid);

  App_Print(W('[*] FAT Server (Ring 3) Initializing... Calling ATA via IPC...'#13#10));

  { The workspace is one page and the block below is 1552 bytes, so a single
    allocation is enough for the whole request path. }
  workspaceAddr := App_AllocMem(1);
  if workspaceAddr = 0 then
  begin
    App_Print(W('[!] FATAL: Failed to allocate workspace memory in FAT16 Driver!'#13#10));
    App_Exit;
    Exit;
  end;

  ws := PWorkspaceBlock(Pointer(workspaceAddr));
  sectorBuf     := PByte(@ws^.SectorBuf[0]);
  fatBuf        := PByte(@ws^.FatBuf[0]);
  formattedName := PByte(@ws^.FormattedName[0]);
  privateName   := PWord(@ws^.PrivateName[0]);

  Fat_PendingQueue := PMessage(Pointer(App_AllocMem(1)));
  if Fat_PendingQueue = nil then
  begin
    App_Print(W('[!] FATAL: Failed to allocate pending queue in FAT16 Driver!'#13#10));
    App_Exit;
    Exit;
  end;

  PendingHead := 0;
  PendingTail := 0;

  { 32 levels x 512 bytes for the RM -RF walk. }
  RecursePool := PByte(Pointer(App_AllocMem(4)));
  if RecursePool = nil then
  begin
    App_Print(W('[!] FATAL: Failed to allocate recurse pool in FAT16 Driver!'#13#10));
    App_Exit;
    Exit;
  end;

  SharedAddr := App_GetSharedMem;
  Fat_SharedMem := PSharedMemoryBlock(Pointer(SharedAddr));
  if Fat_SharedMem = nil then
  begin
    App_Print(W('[!] FATAL: Failed to get shared memory in FAT16 Driver!'#13#10));
    App_Exit;
    Exit;
  end;

  { ---- Mount ---- }
  ReadSectorIPC(0, sectorBuf);

  isSuperFloppy := False;
  if (sectorBuf[0] = $EB) and (sectorBuf[2] = $90) then
    isSuperFloppy := True
  else if sectorBuf[0] = $E9 then
    isSuperFloppy := True;

  if isSuperFloppy then
    FatStartLba := 0
  else
  begin
    part1 := PPartitionEntry(sectorBuf + MBR_PART_TABLE_OFFSET);
    if (part1^.PartitionType > 0) and (part1^.LbaStart > 0) then
    begin
      FatStartLba := part1^.LbaStart;
      ReadSectorIPC(FatStartLba, sectorBuf);
    end
    else
    begin
      App_Print(W('[!] FATAL: Invalid partition in FAT16 Driver!'#13#10));
      App_Exit;
      Exit;
    end;
  end;

  bpbPtr := sectorBuf;
  CachedBPB := PBpb(bpbPtr)^;
  if CachedBPB.BytesPerSector = 0 then
  begin
    CachedBPB.BytesPerSector := SECTOR_SIZE;
    PBpb(bpbPtr)^.BytesPerSector := SECTOR_SIZE;
  end;

  FAT16_ParseBPB_Pas(bpbPtr, @rootDirSectorsLocal, @rootDirLbaLocal,
                     @firstDataSectorLocal);
  RootDirSectors  := rootDirSectorsLocal;
  RootDirLba     := FatStartLba + rootDirLbaLocal;
  FirstDataSector := FatStartLba + firstDataSectorLocal;

  { The kernel is blocked on this until it arrives. Do not move it. }
  App_SendIPC(0, FAT_READY_HANDSHAKE, 0);
  App_Print(W('[+] FAT Server (Ring 3) Online & Listening for File Requests!'#13#10));

  while True do
  begin
    { Drain the deferred queue first: those messages were already
      dequeued from the kernel, so new arrivals may have to wait. }
    if PendingHead <> PendingTail then
    begin
      msg := Fat_PendingQueue[PendingTail];
      PendingTail := (PendingTail + 1) mod PENDING_MAX;
      hasMsg := True;
    end
    else if App_ReceiveIPC(@msg) = 1 then
      hasMsg := True
    else
      hasMsg := False;

    if not hasMsg then
    begin
      App_WaitIPC;
      Continue;
    end;

    client    := msg.Sender;
    msgType   := msg.MsgType;
    callerUID := GetThreadUidOf(client);
    callerGID := GetThreadGidOf(client);

    { ---------------------------------------------------------------
      READ (30)
      --------------------------------------------------------------- }
    if msgType = FS_READ_REQ then
    begin
      sharedName := PWord(@Fat_SharedMem^.FatRequestName[0]);
      StrCpyLimited(privateName, sharedName, 255);

      cluster := 0; fileSize := 0; attr := 0;
      ownerUID := 0; ownerGID := 0; perms := 0;
      FindEntry(privateName, @cluster, @fileSize, @attr, @ownerUID, @ownerGID,
                @perms, sectorBuf, fatBuf, formattedName);

      { Every file type goes through the same check now. Previously .EXE
        files skipped it entirely, letting an ordinary user read a
        restricted root-owned binary. }
      canReadFile := CheckAccess(callerUID, callerGID, ownerUID, ownerGID,
                    perms, R_OK);
      { /ETC/PASSWD does not get the public-read default even though it is
        an ownerless system file: it holds the salt and hash. }
      if IsSecretName(formattedName) and (callerUID <> 0) then
        canReadFile := False;

      if (cluster <> 0) and (not canReadFile) then
      begin
        App_Print(W('[!] Access Denied: You do not have Read (r) permission for this file!'#13#10));
        App_SendIPC(client, FS_READ_SIZE, 0);
        App_Yield;
        Continue;
      end;

      if (cluster = 0) and (fileSize = 0) then
      begin
        App_SendIPC(client, FS_READ_SIZE, 0);
        App_Yield;
        Continue;
      end;

      App_SendIPC(client, FS_READ_SIZE, fileSize);

      while True do
      begin
        if (App_ReceiveIPC(@ack) = 1) and (ack.MsgType = FS_READ_START) and
           (ack.Sender = client) then Break;
        App_Yield;
      end;

      bytesRead := 0;
      dataChunk := PByte(@Fat_SharedMem^.FatResponseData[0]);

      while IsValidCluster(cluster) and (bytesRead < fileSize) do
      begin
        clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, cluster,
                       CachedBPB.SectorsPerCluster);
        for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
        begin
          if bytesRead >= fileSize then Break;
          ReadSectorIPC(clusterLba + Cardinal(s), sectorBuf);
          for b := 0 to SECTOR_SIZE - 1 do
            if bytesRead + Cardinal(b) < fileSize then
              dataChunk[b] := sectorBuf[b];
          App_SendIPC(client, FS_READ_CHUNK, bytesRead);
          while True do
          begin
            if (App_ReceiveIPC(@ack) = 1) and (ack.MsgType = FS_READ_ACK) and
               (ack.Sender = client) then Break;
            App_Yield;
          end;
          bytesRead := bytesRead + SECTOR_SIZE;
        end;
        cluster := GetFatEntry(cluster, fatBuf);
      end;

      App_SendIPC(client, FS_READ_EOF, 1);
    end

    { ---------------------------------------------------------------
      WRITE (32)
      --------------------------------------------------------------- }
    else if msgType = FS_WRITE_REQ then
    begin
      fileSize := Cardinal(msg.Payload and QWord($FFFFFFFF));
      if CachedBPB.SectorsPerCluster = 0 then
        CachedBPB.SectorsPerCluster := 1;
      if fileSize = 0 then fileSize := 1;

      { The client declares the size it intends to send. Unbounded, that
        made the cluster count below overflow for a size near 2^32 and
        allocate too few clusters. Cap it by the disk capacity actually
        reported in the BPB - never by a hardcoded number. }
      bytesPerSectorU := SECTOR_SIZE;
      if CachedBPB.BytesPerSector <> 0 then
        bytesPerSectorU := CachedBPB.BytesPerSector;
      totalSectorsU := CachedBPB.TotalSectors32;
      if totalSectorsU = 0 then totalSectorsU := CachedBPB.TotalSectors16;
      maxFileBytes := totalSectorsU * bytesPerSectorU;
      if (maxFileBytes <> 0) and (QWord(fileSize) > maxFileBytes) then
      begin
        App_Print(W('[!] Access Denied: Declared file size exceeds disk capacity!'#13#10));
        App_SendIPC(client, FS_WRITE_RESULT, 0);
        App_Yield;
        Continue;
      end;

      sharedName := PWord(@Fat_SharedMem^.FatRequestName[0]);
      StrCpyLimited(privateName, sharedName, 255);

      canCreateHere := False;
      if CurrentDirCluster = 0 then
      begin
        if callerUID = 0 then canCreateHere := True;
      end
      else
      begin
        curDirLba := FAT16_ClusterLba_Pas(FirstDataSector, CurrentDirCluster,
                       CachedBPB.SectorsPerCluster);
        ReadSectorIPC(curDirLba, sectorBuf);
        entries := PDirEntry(sectorBuf);
        if CheckAccess(callerUID, callerGID, entries[0].OwnerUID,
             entries[0].OwnerGID, entries[0].Permissions, W_OK) then
          canCreateHere := True;
      end;

      existCluster := 0; existSize := 0; existAttr := 0;
      existOwnerUID := 0; existOwnerGID := 0; existPerms := 0;

      if FindEntry(privateName, @existCluster, @existSize, @existAttr,
           @existOwnerUID, @existOwnerGID, @existPerms, sectorBuf, fatBuf,
           formattedName) then
      begin
        if not CheckAccess(callerUID, callerGID, existOwnerUID, existOwnerGID,
             existPerms, W_OK) then
        begin
          App_Print(W('[!] Access Denied: You do not have Write (w) permission for this file!'#13#10));
          App_SendIPC(client, FS_WRITE_RESULT, 0);
          App_Yield;
          Continue;
        end;

        if (existAttr and ATTR_DIRECTORY) <> 0 then
        begin
          App_Print(W('[!] Access Denied! Cannot overwrite a Directory.'#13#10));
          App_SendIPC(client, FS_WRITE_RESULT, 0);
          App_Yield;
          Continue;
        end;

        { Overwrite: drop the old entry and free its chain first. }
        targetCluster := existCluster;
        deletedOld := False;
        if CurrentDirCluster = 0 then
        begin
          for s := 0 to LongInt(RootDirSectors) - 1 do
            ProcessSilentRm(RootDirLba + Cardinal(s), formattedName,
              targetCluster, fatBuf, sectorBuf, deletedOld);
        end
        else
        begin
          curClus := CurrentDirCluster;
          while IsValidCluster(curClus) do
          begin
            clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, curClus,
                           CachedBPB.SectorsPerCluster);
            for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
              ProcessSilentRm(clusterLba + Cardinal(s), formattedName,
                targetCluster, fatBuf, sectorBuf, deletedOld);
            curClus := GetFatEntry(curClus, fatBuf);
          end;
        end;
        FlushCacheIPC;
      end
      else if not canCreateHere then
      begin
        App_Print(W('[!] Access Denied: You do not own this Directory! Cannot create files here.'#13#10));
        App_SendIPC(client, FS_WRITE_RESULT, 0);
        App_Yield;
        Continue;
      end;

      clusterSize := Cardinal(CachedBPB.SectorsPerCluster) * SECTOR_SIZE;
      numClusters := (fileSize + clusterSize - 1) div clusterSize;
      if numClusters = 0 then numClusters := 1;

      firstCluster := 0;
      prevCluster := 0;
      allocated := 0;
      for c := 2 to CLUSTER_SCAN_MAX do
      begin
        if GetFatEntry(c, fatBuf) = 0 then
        begin
          if allocated = 0 then firstCluster := c
          else SetFatEntry(prevCluster, c, fatBuf);
          SetFatEntry(c, FAT_EOC, fatBuf);
          prevCluster := c;
          Inc(allocated);
          if allocated = numClusters then Break;
        end;
      end;

      if allocated < numClusters then
      begin
        App_SendIPC(client, FS_WRITE_RESULT, 0);
        App_Yield;
        Continue;
      end;

      { Pull the content through the shared response buffer, one sector at a
        time, so a large file never needs its own mapping. }
      bytesWritten := 0;
      currentCluster := firstCluster;
      dataChunk := PByte(@Fat_SharedMem^.FatResponseData[0]);

      while IsValidCluster(currentCluster) and (bytesWritten < fileSize) do
      begin
        clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, currentCluster,
                       CachedBPB.SectorsPerCluster);
        for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
        begin
          if bytesWritten >= fileSize then Break;
          App_SendIPC(client, FS_WRITE_ASK, bytesWritten);
          while True do
          begin
            if (App_ReceiveIPC(@dataRes) = 1) and
               (dataRes.MsgType = FS_WRITE_GIVE) and
               (dataRes.Sender = client) then Break;
            App_Yield;
          end;

          for b := 0 to SECTOR_SIZE - 1 do
            sectorBuf[b] := 0;
          for b := 0 to SECTOR_SIZE - 1 do
          begin
            if bytesWritten < fileSize then
            begin
              sectorBuf[b] := dataChunk[b];
              Inc(bytesWritten);
            end;
          end;
          WriteSectorIPC(clusterLba + Cardinal(s), sectorBuf);
        end;
        currentCluster := GetFatEntry(currentCluster, fatBuf);
      end;

      FormatFATName(privateName, formattedName);
      saved := False;

      if CurrentDirCluster = 0 then
      begin
        for s := 0 to LongInt(RootDirSectors) - 1 do
          ProcessWriteSector(RootDirLba + Cardinal(s), formattedName,
            firstCluster, fileSize, callerUID, callerGID, sectorBuf, saved);
      end
      else
      begin
        curClus := CurrentDirCluster;
        while IsValidCluster(curClus) do
        begin
          clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, curClus,
                         CachedBPB.SectorsPerCluster);
          for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
            ProcessWriteSector(clusterLba + Cardinal(s), formattedName,
              firstCluster, fileSize, callerUID, callerGID, sectorBuf, saved);
          curClus := GetFatEntry(curClus, fatBuf);
        end;
      end;

      FlushCacheIPC;

      if saved then
      begin
        App_SendIPC(client, FS_WRITE_RESULT, 1);
        Continue;
      end;

      { No free slot: the root directory is fixed size by the BPB, and a
        subdirectory has to grow. }
      if CurrentDirCluster = 0 then
      begin
        FlushCacheIPC;
        App_SendIPC(client, FS_WRITE_RESULT, 0);
        Continue;
      end;

      expandCluster := ExpandDirectoryChain(fatBuf);
      if expandCluster = 0 then
      begin
        curClus := firstCluster;
        while IsValidCluster(curClus) do
        begin
          nextClus := GetFatEntry(curClus, fatBuf);
          SetFatEntry(curClus, 0, fatBuf);
          curClus := nextClus;
        end;
        FlushCacheIPC;
        App_SendIPC(client, FS_WRITE_RESULT, 0);
        Continue;
      end;

      expandLba := FAT16_ClusterLba_Pas(FirstDataSector, expandCluster,
                  CachedBPB.SectorsPerCluster);
      for b := 0 to SECTOR_SIZE - 1 do
        sectorBuf[b] := 0;
      for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
        WriteSectorIPC(expandLba + Cardinal(s), sectorBuf);

      entries := PDirEntry(sectorBuf);
      CopyFormattedName(@entries[0], formattedName);
      entries[0].Attributes := $20;
      entries[0].OwnerGID := Word(callerGID);
      entries[0].CreationTime := 0;
      entries[0].CreationDate := 0;
      entries[0].Permissions := FILE_PERMS;
      entries[0].OwnerUID := Word(callerUID);
      entries[0].WriteTime := 0;
      entries[0].WriteDate := 0;
      entries[0].FirstClusterLow := firstCluster;
      entries[0].FileSize := fileSize;
      WriteSectorIPC(expandLba, sectorBuf);
      FlushCacheIPC;
      App_SendIPC(client, FS_WRITE_RESULT, 1);
    end

    { ---------------------------------------------------------------
      CD (36)
      --------------------------------------------------------------- }
    else if msgType = FS_CD_REQ then
    begin
      sharedName := PWord(@Fat_SharedMem^.FatRequestName[0]);
      StrCpyLimited(privateName, sharedName, 255);

      if (privateName[0] = Ord('\')) and (privateName[1] = 0) then
      begin
        CurrentDirCluster := 0;
        App_SendIPC(client, FS_CD_RESULT, 1);
        Continue;
      end;

      cdCluster := 0; cdSize := 0; cdAttr := 0;
      cdOwnerUID := 0; cdOwnerGID := 0; cdPerms := 0;
      FindEntry(privateName, @cdCluster, @cdSize, @cdAttr, @cdOwnerUID,
                @cdOwnerGID, @cdPerms, sectorBuf, fatBuf, formattedName);

      if (cdAttr and ATTR_DIRECTORY) <> 0 then
      begin
        if not CheckAccess(callerUID, callerGID, cdOwnerUID, cdOwnerGID,
             cdPerms, X_OK) then
        begin
          App_Print(W('[!] Access Denied: You do not have Execute (x) permission to enter this directory!'#13#10));
          App_SendIPC(client, FS_CD_RESULT, 0);
        end
        else
        begin
          CurrentDirCluster := cdCluster;
          App_SendIPC(client, FS_CD_RESULT, 1);
        end;
      end
      else
        App_SendIPC(client, FS_CD_RESULT, 0);
    end

    { ---------------------------------------------------------------
      LS (40)
      --------------------------------------------------------------- }
    else if msgType = FS_LS_REQ then
    begin
      outStr := PWord(@Fat_SharedMem^.FatResponseData[0]);
      outIdx := 0;

      if CurrentDirCluster = 0 then
      begin
        for s := 0 to LongInt(RootDirSectors) - 1 do
        begin
          if outIdx >= LS_MAX_CHARS then Break;
          ReadSectorIPC(RootDirLba + Cardinal(s), sectorBuf);
          ProcessLSSector(sectorBuf, outStr, outIdx, LS_MAX_CHARS);
        end;
      end
      else
      begin
        cluster := CurrentDirCluster;
        while IsValidCluster(cluster) do
        begin
          if outIdx >= LS_MAX_CHARS then Break;
          clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, cluster,
                         CachedBPB.SectorsPerCluster);
          for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
          begin
            ReadSectorIPC(clusterLba + Cardinal(s), sectorBuf);
            ProcessLSSector(sectorBuf, outStr, outIdx, LS_MAX_CHARS);
          end;
          cluster := GetFatEntry(cluster, fatBuf);
        end;
      end;
      outStr[outIdx] := 0;
      App_SendIPC(client, FS_LS_RESULT, 1);
    end

    { ---------------------------------------------------------------
      MKDIR (44)
      --------------------------------------------------------------- }
    else if msgType = FS_MKDIR_REQ then
    begin
      sharedName := PWord(@Fat_SharedMem^.FatRequestName[0]);
      StrCpyLimited(privateName, sharedName, 255);
      DoMkdir(privateName, callerUID, callerGID, callerUID, callerGID,
              client, sectorBuf, fatBuf, formattedName, FS_MKDIR_RESULT);
    end

    { ---------------------------------------------------------------
      MKDIR_AS (56) - root only, lets root pre-create a directory owned
      by somebody else.
      --------------------------------------------------------------- }
    else if msgType = FS_MKDIRAS_REQ then
    begin
      if callerUID <> 0 then
      begin
        App_Print(W('[!] Access Denied: MKDIR_AS requires root privileges!'#13#10));
        App_SendIPC(client, FS_MKDIRAS_RESULT, 0);
        App_Yield;
        Continue;
      end;

      sharedName := PWord(@Fat_SharedMem^.FatRequestName[0]);
      nameLen := SplitCompoundRequest(sharedName, privateName);
      p := LongInt(nameLen);
      ParseUIDGID(sharedName, p, targetUID, targetGID);

      DoMkdir(privateName, targetUID, targetGID, callerUID, callerGID,
              client, sectorBuf, fatBuf, formattedName, FS_MKDIRAS_RESULT);
    end

    { ---------------------------------------------------------------
      CHMOD (58) - path \0 mode (decimal)
      --------------------------------------------------------------- }
    else if msgType = FS_CHMOD_REQ then
    begin
      sharedName := PWord(@Fat_SharedMem^.FatRequestName[0]);
      nameLen := SplitCompoundRequest(sharedName, privateName);
      p := LongInt(nameLen);
      mode := Atoi(sharedName + p);

      DoChmod(privateName, callerUID, callerGID, client, sectorBuf, fatBuf,
              formattedName, Word(mode));
    end

    { ---------------------------------------------------------------
      CHOWN (60) - path \0 uid:gid
      --------------------------------------------------------------- }
    else if msgType = FS_CHOWN_REQ then
    begin
      sharedName := PWord(@Fat_SharedMem^.FatRequestName[0]);
      nameLen := SplitCompoundRequest(sharedName, privateName);
      p := LongInt(nameLen);
      ParseUIDGID(sharedName, p, targetUID, targetGID);

      DoChown(privateName, callerUID, callerGID, client, sectorBuf, fatBuf,
              formattedName, targetUID, targetGID);
    end

    { ---------------------------------------------------------------
      RM (46) - files only; RM -RF is type 48.
      --------------------------------------------------------------- }
    else if msgType = FS_RM_REQ then
    begin
      sharedName := PWord(@Fat_SharedMem^.FatRequestName[0]);
      StrCpyLimited(privateName, sharedName, 255);
      FormatFATName(privateName, formattedName);

      deleted := False;
      isDirError := False;
      accessDenied := False;

      if CurrentDirCluster = 0 then
      begin
        for s := 0 to LongInt(RootDirSectors) - 1 do
          ProcessRmSector(RootDirLba + Cardinal(s), formattedName, callerUID,
            callerGID, fatBuf, sectorBuf, deleted, isDirError, accessDenied);
      end
      else
      begin
        cluster := CurrentDirCluster;
        while IsValidCluster(cluster) do
        begin
          clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, cluster,
                         CachedBPB.SectorsPerCluster);
          for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
            ProcessRmSector(clusterLba + Cardinal(s), formattedName, callerUID,
              callerGID, fatBuf, sectorBuf, deleted, isDirError, accessDenied);
          cluster := GetFatEntry(cluster, fatBuf);
        end;
      end;
      FlushCacheIPC;

      if accessDenied then
      begin
        App_Print(W('[!] Access Denied! You do not own this file.'#13#10));
        App_SendIPC(client, FS_RM_RESULT, 0);
      end
      else if isDirError then
        App_SendIPC(client, FS_RM_RESULT, 2)
      else if deleted then
        App_SendIPC(client, FS_RM_RESULT, 1)
      else
        App_SendIPC(client, FS_RM_RESULT, 0);
    end

    { ---------------------------------------------------------------
      RM -RF (48)
      --------------------------------------------------------------- }
    else if msgType = FS_RMRF_REQ then
    begin
      sharedName := PWord(@Fat_SharedMem^.FatRequestName[0]);
      StrCpyLimited(privateName, sharedName, 255);
      FormatFATName(privateName, formattedName);
      if formattedName[0] = Ord('.') then
      begin
        App_SendIPC(client, FS_RMRF_RESULT, 0);
        App_Yield;
        Continue;
      end;

      deleted := False;
      errorCode := 0;

      if CurrentDirCluster = 0 then
      begin
        for s := 0 to LongInt(RootDirSectors) - 1 do
          FindAndNuke(RootDirLba + Cardinal(s), formattedName, callerUID,
            callerGID, fatBuf, sectorBuf, deleted, errorCode);
      end
      else
      begin
        cluster := CurrentDirCluster;
        while IsValidCluster(cluster) do
        begin
          clusterLba := FAT16_ClusterLba_Pas(FirstDataSector, cluster,
                         CachedBPB.SectorsPerCluster);
          for s := 0 to LongInt(CachedBPB.SectorsPerCluster) - 1 do
            FindAndNuke(clusterLba + Cardinal(s), formattedName, callerUID,
              callerGID, fatBuf, sectorBuf, deleted, errorCode);
          cluster := GetFatEntry(cluster, fatBuf);
        end;
      end;
      FlushCacheIPC;

      if errorCode = 4 then
      begin
        App_Print(W('[!] Access Denied! You do not own this directory.'#13#10));
        App_SendIPC(client, FS_RMRF_RESULT, 0);
      end
      else
        App_SendIPC(client, FS_RMRF_RESULT, errorCode);
    end

    else if msgType = FS_SIGTERM then
    begin
      App_Print(W('[*] FAT16: SIGTERM received. Sweeping workspace and signing off. Goodbye!'#13#10));
      { Push anything still dirty to the drive before going. The kernel
        keeps the ATA daemon alive until last, so this IPC has a receiver. }
      FlushCacheIPC;
      App_Exit;
    end;
  end;
end;

end.
