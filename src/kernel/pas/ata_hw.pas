{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: ata_hw - Kernel-side ATA/IDE PIO block driver (Pascal port)
  PORTED FROM: src/kernel/ATA.cs (431 lines, kept until this unit is wired)

  Owns the cooperative Ring-0 side of the disk stack: PIO sector I/O, disk
  geometry detection, the FAT16/ATA daemon handshake, and the shared
  KernelSharedMemBlock window that the userland daemons read and write.

  DEPENDENCY LAYERING (no cycles - see docs/PASCAL_PORTING.md 6):
    fat16fs -> ata_hw -> arch_interface, io, pmm, ipc, libc, kstring,
                          terminal, kstate
  Nothing uses ata_hw, so it can be linked in any order. fat16fs only needs
  the sector I/O plus the shared window and the kernel bindings registered
  here, so all of that lives in this unit rather than being duplicated.

  NAMING: every public symbol carries the AtaHw_ prefix. The bare ATA_*
  namespace already belongs to ata_driver.pas (an earlier, unwired attempt at
  the same port) and FAT16_* to fat16.pas, so reusing either would produce
  duplicate exported symbols and break the link.

  FAITHFULNESS NOTES (behaviour deliberately preserved from ATA.cs):
    - WriteSector's daemon path leaks the async lock when the shared window
      cannot be resolved: it returns without calling ReleaseAtaAsync. Kept as
      is; fixing it changes observable behaviour for the caller.
    - ReadSector/WriteSector validate the LBA before taking the hardware
      lock, and IsLbaInRange takes and releases the same lock internally to
      run IDENTIFY DEVICE. The lock is therefore not held across detection.
    - FlushCache and WriteSector use $E7 (CACHE FLUSH) as in the C# original.
  =========================================================================
}

unit ata_hw;

{$mode objfpc}
{$h+}
{$inline on}
{$TYPEINFO OFF}
{$M-}
{$PACKRECORDS 1}

interface

const
  { ── KernelSharedMemBlock (src/kernel/FAT16.cs, Pack = 1) ──────────────
    fixed byte ShellCommandBuffer[4096];  // +0
    fixed byte FatRequestName[4096];      // +4096
    fixed byte FatResponseData[8192];     // +8192
    fixed byte AtaRawBuffer[4096];        // +16384   -> 20480 bytes = 5 pages }
  KSM_SHELL_COMMAND_SIZE = 4096;
  KSM_FAT_REQUEST_SIZE   = 4096;
  KSM_FAT_RESPONSE_SIZE  = 8192;
  KSM_ATA_RAW_SIZE       = 4096;
  KSM_TOTAL_SIZE         = KSM_SHELL_COMMAND_SIZE + KSM_FAT_REQUEST_SIZE
                         + KSM_FAT_RESPONSE_SIZE + KSM_ATA_RAW_SIZE;   { 20480 }
  KSM_TOTAL_PAGES        = 5;

  KSM_OFF_SHELL_COMMAND  = 0;
  KSM_OFF_FAT_REQUEST    = 4096;
  KSM_OFF_FAT_RESPONSE   = 8192;
  KSM_OFF_ATA_RAW        = 16384;

  { ── Thread (src/kernel/Thread.cs, Pack = 1) fields this unit touches ──
    Rsp 0 | Active 8 | ... | SharedMemVirt 72 | Name 80 | CpuTicks 96 |
    PhysPages 104 | VirtPages 108 | WakeUpTick 112 | ... | FpuState 144
    Stride 656, verified against the C# struct and scheduler.pas' TThread. }
  THREAD_STRIDE          = 656;
  THREAD_ACTIVE_OFF      = 8;
  THREAD_WAKEUP_TICK_OFF = 112;

  { ── ATA primary channel I/O ports ─────────────────────────────────── }
  ATA_PORT_DATA       = $1F0;
  ATA_PORT_SECTOR_CNT = $1F2;
  ATA_PORT_LBA_LOW    = $1F3;
  ATA_PORT_LBA_MID    = $1F4;
  ATA_PORT_LBA_HIGH   = $1F5;
  ATA_PORT_DRIVE      = $1F6;
  ATA_PORT_STATUS     = $1F7;

  { ── ATA status register bits ─────────────────────────────────────── }
  ATA_ST_ERR = $01;   { error }
  ATA_ST_DRQ = $08;   { data request ready }
  ATA_ST_DSC = $20;   { device seek complete (read error bit in ATA.cs) }
  ATA_ST_BSY = $80;   { busy }

  { ── ATA command register opcodes used here ───────────────────────── }
  ATA_CMD_READ_PIO    = $20;
  ATA_CMD_WRITE_PIO   = $30;
  ATA_CMD_IDENTIFY    = $EC;
  ATA_CMD_CACHE_FLUSH = $E7;

  ATA_SECTOR_SIZE     = 512;
  ATA_MAX_LBA         = $FFFFFF;
  ATA_IDENTIFY_WORDS  = 256;

{ ═══════════════════════════════════════════════════════════════════════
  KERNEL BINDINGS

  Everything the ported code needs from C# state that has no Pascal owner
  yet is registered once at init. Until a binding is registered the matching
  accessor degrades safely (thread id 0, unsynchronised terminal output),
  which is exactly the state the C# code was in before those statics existed.
  ═══════════════════════════════════════════════════════════════════════ }

{ aCurrentThreadIdFn   : function: Integer cdecl  (Scheduler.CurrentThreadId)
  aThreads             : Thread* table base
  aThreadCountPtr      : &Scheduler.ThreadCount
  aScreenLockAcquireFn : function: Byte cdecl    (Terminal.ScreenLock.AcquireSafe)
  aScreenLockReleaseFn : procedure(irq: Byte) cdecl
  aIpcQueue            : IPC.queue
  aIpcMaxMessages      : IPC.MAX_MESSAGES }
procedure AtaHw_SetKernelHooks(aCurrentThreadIdFn: Pointer; aThreads: Pointer;
    aThreadCountPtr: PInteger; aScreenLockAcquireFn: Pointer;
    aScreenLockReleaseFn: Pointer; aIpcQueue: Pointer;
    aIpcMaxMessages: Integer); cdecl;

{ Syscall.SharedMemLock - a separate lock from the screen lock. It guards
  the KernelSharedMemBlock window, which the userland daemons write to
  concurrently with the kernel. }
procedure AtaHw_SetSharedMemLock(acquireFn: Pointer; releaseFn: Pointer); cdecl;
function  AtaHw_SharedMemLockAcquire: Byte; cdecl;
procedure AtaHw_SharedMemLockRelease(irq: Byte); cdecl;

{ Publish Syscall.GlobalSharedRAM_Phys into this unit (0 = not allocated). }
procedure AtaHw_SetSharedRamPhys(phys: QWord); cdecl;
function  AtaHw_GetSharedRamPhys: QWord; cdecl;

{ Handshake state, formerly Driver.ATA.UseDaemon / Driver.ATA.DaemonId.
  Kernel.cs sets these when the ATA.EXE daemon reports in (IPC type 9). }
procedure AtaHw_SetDaemon(useDaemon: Boolean; daemonId: Cardinal); cdecl;
function  AtaHw_GetUseDaemon: Boolean; cdecl;
function  AtaHw_GetDaemonId: Cardinal; cdecl;

{ Driver.FAT16.TrustedThreadId is FAT16-side, but Syscall.cs case 5 compares
  both daemon ids, so both live behind the same binding. }
procedure AtaHw_SetTrustedThreadId(tid: Integer); cdecl;
function  AtaHw_GetTrustedThreadId: Integer; cdecl;

{ Public in ATA.cs: other kernel code may take the block layer directly. }
function  AtaHw_HardwareLockPtr: PCardinal; cdecl;

{ ═══════════════════════════════════════════════════════════════════════
  SHARED WINDOW
  ═══════════════════════════════════════════════════════════════════════ }

{ ATA.cs semantics: allocates the window on first use and reports a
  dedicated message when the allocation fails. }
function  AtaHw_GetSharedMem: Pointer; cdecl;

{ FAT16.cs semantics: same allocation, but a failure falls through to the
  range check so the caller emits its own "Invalid GlobalSharedRAM_Phys"
  message instead of the ATA-specific one. }
function  AtaHw_GetSharedMemSilent: Pointer; cdecl;

{ Field accessors over the validated window. nil when the window is not
  allocated or the base address is outside physical memory. }
function  AtaHw_SharedBase: PByte; cdecl;
function  AtaHw_SharedFatRequestName: PWord; cdecl;
function  AtaHw_SharedFatResponseData: PByte; cdecl;
function  AtaHw_SharedAtaRawBuffer: PByte; cdecl;

{ Terminal.ScreenLock equivalent, so the ported code reproduces the
  screen-lock discipline of Terminal.Print / DrawChar / PrintDec. }
function  AtaHw_ScreenLockAcquire: Byte; cdecl;
procedure AtaHw_ScreenLockRelease(irq: Byte); cdecl;

procedure AtaHw_Print(str: PWord); cdecl;
procedure AtaHw_DrawChar(c: Word); cdecl;
procedure AtaHw_PrintDec(val: QWord); cdecl;
procedure AtaHw_PrintHex(val: QWord); cdecl;
procedure AtaHw_SetColor(color: Cardinal); cdecl;

{ ═══════════════════════════════════════════════════════════════════════
  SCHEDULER / IPC HELPERS
  ═══════════════════════════════════════════════════════════════════════ }

function  AtaHw_CurrentThreadId: Integer; cdecl;
function  AtaHw_AcquireSchedLockSafe: Byte; cdecl;
procedure AtaHw_ReleaseSchedLockSafe(irq: Byte); cdecl;
procedure AtaHw_Yield; cdecl;
function  AtaHw_ThreadCount: Integer; cdecl;
function  AtaHw_ThreadAt(id: Cardinal): Pointer; cdecl;

{ IPC.Send / IPC.ReceiveForRaw, including the wakeup policy that IPC.cs
  keeps on the C# side. }
function  AtaHw_IpcSend(msgType, sender, receiver: Cardinal; payload: QWord): Boolean; cdecl;
function  AtaHw_IpcReceiveForRaw(receiverId: Cardinal; out msgType, sender: Cardinal;
    out payload: QWord): Boolean; cdecl;

{ Wake the registered daemon thread (ATA.cs WakeDaemon). }
procedure AtaHw_WakeDaemon; cdecl;

{ ═══════════════════════════════════════════════════════════════════════
  BLOCK DEVICE API
  ═══════════════════════════════════════════════════════════════════════ }

procedure Ata_ReadSector(lba: Cardinal; buffer: PByte); cdecl;
procedure Ata_WriteSector(lba: Cardinal; buffer: PByte); cdecl;
procedure Ata_FlushCache; cdecl;
procedure Ata_AcquireAsync; cdecl;
procedure Ata_ReleaseAsync; cdecl;

{ Ring-0 PIO paths, exposed so a future userless caller can skip the daemon
  handshake. The caller must hold AtaHw_HardwareLockPtr(). }
procedure Ata_DetectDiskSize; cdecl;
function  Ata_IsLbaInRange(lba: Cardinal): Boolean; cdecl;
function  Ata_DetectedSectorCount: Cardinal; cdecl;
function  Ata_WaitHardware: Boolean; cdecl;

implementation

uses arch_interface, io, pmm, ipc, libc, kstring, terminal, kstate, spinlock;

{ ── Records: implementation only, never reachable from the interface,
     so FPC emits no RTTI for them (docs/PASCAL_PORTING.md 4). ──────────── }
type
  TKernelSharedMemBlock = packed record
    ShellCommandBuffer: array[0 .. KSM_SHELL_COMMAND_SIZE - 1] of Byte;
    FatRequestName:     array[0 .. KSM_FAT_REQUEST_SIZE - 1] of Byte;
    FatResponseData:    array[0 .. KSM_FAT_RESPONSE_SIZE - 1] of Byte;
    AtaRawBuffer:       array[0 .. KSM_ATA_RAW_SIZE - 1] of Byte;
  end;
  PKernelSharedMemBlock = ^TKernelSharedMemBlock;

  { IDENTIFY DEVICE payload. ATA.cs stackallocs ushort[256]; a module-level
    array is equivalent because DetectDiskSize only ever runs under
    AtaHw_HardwareLock, so there is never a second concurrent reader. }
  TIdentifyData = packed array[0 .. ATA_IDENTIFY_WORDS - 1] of Word;

{ ── Registered kernel bindings ───────────────────────────────────────── }
var
  cb_CurrentThreadId:   Pointer = nil;
  cb_Threads:           Pointer = nil;
  cb_ThreadCount:       PInteger = nil;
  cb_ScreenLockAcquire: Pointer = nil;
  cb_ScreenLockRelease: Pointer = nil;
  cb_SharedLockAcquire: Pointer = nil;
  cb_SharedLockRelease: Pointer = nil;
  cb_IpcQueue:          Pointer = nil;
  cb_IpcMaxMessages:    Integer = 0;

{ ── Driver state (was C# static fields on Driver.ATA) ───────────────── }
var
  AtaHw_UseDaemon: Byte = 0;         { C# bool UseDaemon }
  AtaHw_DaemonId: Cardinal = 0;
  AtaHw_TrustedThreadId: Integer = -1;

  AtaHw_SharedRamPhys: QWord = 0;    { was Syscall.GlobalSharedRAM_Phys }

  AtaHw_AtaStateLock: Cardinal = 0;  { C# AtaStateLock }
  AtaHw_AtaIsBusy: Byte = 0;         { C# AtaIsBusy }
  AtaHw_HardwareLock: Cardinal = 0;  { C# AtaHardwareLock (public) }

  AtaHw_DetectedSectors: Cardinal = 0;

  AtaHw_Identify: TIdentifyData;

{ ── Bound upcalls, cast at the call site (scheduler.pas pattern) ─────── }
function CallCurrentThreadId: Integer; inline;
type TFn = function: Integer; cdecl;
begin
  Result := TFn(cb_CurrentThreadId)();
end;

function CallScreenLockAcquire: Byte; inline;
type TFn = function: Byte; cdecl;
begin
  Result := TFn(cb_ScreenLockAcquire)();
end;

procedure CallScreenLockRelease(irq: Byte); inline;
type TFn = procedure(irq: Byte); cdecl;
begin
  TFn(cb_ScreenLockRelease)(irq);
end;

function CallSharedLockAcquire: Byte; inline;
type TFn = function: Byte; cdecl;
begin
  Result := TFn(cb_SharedLockAcquire)();
end;

procedure CallSharedLockRelease(irq: Byte); inline;
type TFn = procedure(irq: Byte); cdecl;
begin
  TFn(cb_SharedLockRelease)(irq);
end;

{ ═══════════════════════════════════════════════════════════════════════
  BINDINGS
  ═══════════════════════════════════════════════════════════════════════ }

procedure AtaHw_SetKernelHooks(aCurrentThreadIdFn: Pointer; aThreads: Pointer;
    aThreadCountPtr: PInteger; aScreenLockAcquireFn: Pointer;
    aScreenLockReleaseFn: Pointer; aIpcQueue: Pointer;
    aIpcMaxMessages: Integer); cdecl;
begin
  cb_CurrentThreadId   := aCurrentThreadIdFn;
  cb_Threads           := aThreads;
  cb_ThreadCount       := aThreadCountPtr;
  cb_ScreenLockAcquire := aScreenLockAcquireFn;
  cb_ScreenLockRelease := aScreenLockReleaseFn;
  cb_IpcQueue          := aIpcQueue;
  cb_IpcMaxMessages    := aIpcMaxMessages;
end;

procedure AtaHw_SetSharedMemLock(acquireFn: Pointer; releaseFn: Pointer); cdecl;
begin
  cb_SharedLockAcquire := acquireFn;
  cb_SharedLockRelease := releaseFn;
end;

function AtaHw_SharedMemLockAcquire: Byte; cdecl;
begin
  if cb_SharedLockAcquire = nil then
  begin
    AtaHw_SharedMemLockAcquire := 0;
    Exit;
  end;
  AtaHw_SharedMemLockAcquire := CallSharedLockAcquire;
end;

procedure AtaHw_SharedMemLockRelease(irq: Byte); cdecl;
begin
  if cb_SharedLockRelease = nil then Exit;
  CallSharedLockRelease(irq);
end;

procedure AtaHw_SetSharedRamPhys(phys: QWord); cdecl;
begin
  AtaHw_SharedRamPhys := phys;
  kstate_SharedRAM_Phys := phys;
end;

function AtaHw_GetSharedRamPhys: QWord; cdecl;
begin
  AtaHw_GetSharedRamPhys := AtaHw_SharedRamPhys;
end;

procedure AtaHw_SetDaemon(useDaemon: Boolean; daemonId: Cardinal); cdecl;
begin
  if useDaemon then AtaHw_UseDaemon := 1 else AtaHw_UseDaemon := 0;
  AtaHw_DaemonId := daemonId;
end;

function AtaHw_GetUseDaemon: Boolean; cdecl;
begin
  AtaHw_GetUseDaemon := AtaHw_UseDaemon <> 0;
end;

function AtaHw_GetDaemonId: Cardinal; cdecl;
begin
  AtaHw_GetDaemonId := AtaHw_DaemonId;
end;

procedure AtaHw_SetTrustedThreadId(tid: Integer); cdecl;
begin
  AtaHw_TrustedThreadId := tid;
end;

function AtaHw_GetTrustedThreadId: Integer; cdecl;
begin
  AtaHw_GetTrustedThreadId := AtaHw_TrustedThreadId;
end;

function AtaHw_HardwareLockPtr: PCardinal; cdecl;
begin
  AtaHw_HardwareLockPtr := @AtaHw_HardwareLock;
end;

function AtaHw_ThreadCount: Integer; cdecl;
begin
  AtaHw_ThreadCount := 0;
  if cb_ThreadCount = nil then Exit;
  AtaHw_ThreadCount := cb_ThreadCount^;
end;

{ Bounds-checked Thread* accessor. The C# indexed Threads[] unguarded; an
  out-of-range daemon id would corrupt an adjacent page, so the check is
  kept here even though it is a strict addition to the original. }
function AtaHw_ThreadAt(id: Cardinal): Pointer; cdecl;
begin
  AtaHw_ThreadAt := nil;
  if (cb_Threads = nil) or (id = 0) then Exit;
  if Integer(id) >= AtaHw_ThreadCount then Exit;
  AtaHw_ThreadAt := Pointer(PByte(cb_Threads) + QWord(id) * THREAD_STRIDE);
end;

{ ═══════════════════════════════════════════════════════════════════════
  SHARED WINDOW
  ═══════════════════════════════════════════════════════════════════════ }

function SharedInRange: Boolean; inline;
begin
  SharedInRange := (AtaHw_SharedRamPhys <> 0) and
                   (AtaHw_SharedRamPhys < PMM_GetTotalPages * 4096);
end;

{ Allocate the 5-page window on first use. Serialised by the scheduler lock
  exactly as in the C# original so two threads cannot both allocate. }
function EnsureSharedRam: Boolean;
var
  irq: Byte;
  phys: QWord;
begin
  EnsureSharedRam := True;
  if AtaHw_SharedRamPhys <> 0 then Exit;

  irq := AtaHw_AcquireSchedLockSafe;
  if AtaHw_SharedRamPhys = 0 then
  begin
    phys := QWord(Pmm_AllocateContiguousPages(KSM_TOTAL_PAGES));
    if phys <> 0 then
    begin
      AtaHw_SharedRamPhys := phys;
      kstate_SharedRAM_Phys := phys;
      MemSet(PByte(phys), 0, KSM_TOTAL_SIZE);
    end;
  end;
  AtaHw_ReleaseSchedLockSafe(irq);

  EnsureSharedRam := AtaHw_SharedRamPhys <> 0;
end;

function AtaHw_GetSharedMem: Pointer; cdecl;
begin
  AtaHw_GetSharedMem := nil;

  if not EnsureSharedRam then
  begin
    AtaHw_SetColor($00FF0000);
    AtaHw_Print(W('[!] FATAL: Failed to allocate shared memory for ATA!'#13#10));
    Exit;
  end;

  if not SharedInRange then
  begin
    AtaHw_SetColor($00FF0000);
    AtaHw_Print(W('[!] FATAL: Invalid GlobalSharedRAM_Phys in ATA GetSharedMem!'#13#10));
    Exit;
  end;

  AtaHw_GetSharedMem := Pointer(AtaHw_SharedRamPhys);
end;

function AtaHw_GetSharedMemSilent: Pointer; cdecl;
begin
  { FAT16.cs ignores the allocation result here and lets the range check
    below report it, so the failure is deliberately not announced here. }
  EnsureSharedRam;

  AtaHw_GetSharedMemSilent := nil;
  if not SharedInRange then
  begin
    AtaHw_SetColor($00FF0000);
    AtaHw_Print(W('[!] FATAL: Invalid GlobalSharedRAM_Phys in GetSharedMem!'#13#10));
    Exit;
  end;

  AtaHw_GetSharedMemSilent := Pointer(AtaHw_SharedRamPhys);
end;

function AtaHw_SharedBase: PByte; cdecl;
begin
  AtaHw_SharedBase := nil;
  if not SharedInRange then Exit;
  AtaHw_SharedBase := PByte(AtaHw_SharedRamPhys);
end;

function AtaHw_SharedFatRequestName: PWord; cdecl;
begin
  AtaHw_SharedFatRequestName := nil;
  if AtaHw_SharedBase = nil then Exit;
  AtaHw_SharedFatRequestName := PWord(AtaHw_SharedBase + KSM_OFF_FAT_REQUEST);
end;

function AtaHw_SharedFatResponseData: PByte; cdecl;
begin
  AtaHw_SharedFatResponseData := nil;
  if AtaHw_SharedBase = nil then Exit;
  AtaHw_SharedFatResponseData := AtaHw_SharedBase + KSM_OFF_FAT_RESPONSE;
end;

function AtaHw_SharedAtaRawBuffer: PByte; cdecl;
begin
  AtaHw_SharedAtaRawBuffer := nil;
  if AtaHw_SharedBase = nil then Exit;
  AtaHw_SharedAtaRawBuffer := AtaHw_SharedBase + KSM_OFF_ATA_RAW;
end;

{ ═══════════════════════════════════════════════════════════════════════
  TERMINAL (screen-lock disciplined, like Terminal.Print / DrawChar)
  ═══════════════════════════════════════════════════════════════════════ }

function AtaHw_ScreenLockAcquire: Byte; cdecl;
begin
  if cb_ScreenLockAcquire = nil then
  begin
    AtaHw_ScreenLockAcquire := 0;
    Exit;
  end;
  AtaHw_ScreenLockAcquire := CallScreenLockAcquire;
end;

procedure AtaHw_ScreenLockRelease(irq: Byte); cdecl;
begin
  if cb_ScreenLockRelease = nil then Exit;
  CallScreenLockRelease(irq);
end;

procedure AtaHw_SetColor(color: Cardinal); cdecl;
begin
  { Terminal.SetColor is a direct alias of Terminal_SetColor_Pas, unlocked. }
  Terminal_SetColor_Pas(color);
end;

procedure AtaHw_Print(str: PWord); cdecl;
var
  irq: Byte;
begin
  if str = nil then Exit;
  irq := AtaHw_ScreenLockAcquire;
  Terminal_Print_Pas(str);
  AtaHw_ScreenLockRelease(irq);
end;

procedure AtaHw_DrawChar(c: Word); cdecl;
var
  irq: Byte;
begin
  irq := AtaHw_ScreenLockAcquire;
  Terminal_DrawChar_Pas(c);
  AtaHw_ScreenLockRelease(irq);
end;

procedure AtaHw_PrintDec(val: QWord); cdecl;
var
  irq: Byte;
begin
  irq := AtaHw_ScreenLockAcquire;
  Terminal_PrintDec_Pas(val);
  AtaHw_ScreenLockRelease(irq);
end;

procedure AtaHw_PrintHex(val: QWord); cdecl;
var
  irq: Byte;
begin
  irq := AtaHw_ScreenLockAcquire;
  Terminal_PrintHex_Pas(val);
  AtaHw_ScreenLockRelease(irq);
end;

{ ═══════════════════════════════════════════════════════════════════════
  SCHEDULER / IPC
  ═══════════════════════════════════════════════════════════════════════ }

function AtaHw_CurrentThreadId: Integer; cdecl;
begin
  if cb_CurrentThreadId = nil then
  begin
    AtaHw_CurrentThreadId := 0;
    Exit;
  end;
  AtaHw_CurrentThreadId := CallCurrentThreadId;
end;

function AtaHw_AcquireSchedLockSafe: Byte; cdecl;
begin
  { Scheduler.AcquireSchedLockSafe: save IF, cli, lock. }
  AtaHw_AcquireSchedLockSafe := 0;
  if (Arch_GetFlags and $200) <> 0 then AtaHw_AcquireSchedLockSafe := 1;
  Arch_DisableInterrupts;
  Arch_LockScheduler;
end;

procedure AtaHw_ReleaseSchedLockSafe(irq: Byte); cdecl;
begin
  Arch_UnlockScheduler;
  if irq <> 0 then Arch_EnableInterrupts;
end;

procedure AtaHw_Yield; cdecl;
begin
  Arch_ForceYield;
end;

function AtaHw_IpcSend(msgType, sender, receiver: Cardinal; payload: QWord): Boolean; cdecl;
var
  needsWakeup: Byte;
  wakeReceiverId: Cardinal;
  success: Byte;
  irq: Byte;
  t: PByte;
begin
  AtaHw_IpcSend := False;
  if cb_IpcQueue = nil then Exit;

  success := IPC_SendCore(cb_IpcQueue, cb_IpcMaxMessages, msgType, sender,
                          receiver, payload, needsWakeup, wakeReceiverId);
  if (success = 0) or (needsWakeup = 0) then Exit;

  { CVE-2026-001 policy from IPC.cs: a sleeping receiver only becomes runnable
    under the scheduler lock, and the wake tick is cleared with it. }
  t := PByte(AtaHw_ThreadAt(wakeReceiverId));
  if t = nil then Exit;

  irq := AtaHw_AcquireSchedLockSafe;
  if t[THREAD_ACTIVE_OFF] = 2 then
  begin
    t[THREAD_ACTIVE_OFF] := 1;
    PQWord(t + THREAD_WAKEUP_TICK_OFF)^ := 0;
  end;
  AtaHw_ReleaseSchedLockSafe(irq);

  AtaHw_IpcSend := True;
end;

function AtaHw_IpcReceiveForRaw(receiverId: Cardinal; out msgType, sender: Cardinal;
    out payload: QWord): Boolean; cdecl;
var
  success: Byte;
begin
  AtaHw_IpcReceiveForRaw := False;
  msgType := 0;
  sender := 0;
  payload := 0;
  if cb_IpcQueue = nil then Exit;

  success := IPC_ReceiveFor(cb_IpcQueue, cb_IpcMaxMessages, receiverId,
                            msgType, sender, payload);
  AtaHw_IpcReceiveForRaw := success <> 0;
end;

procedure AtaHw_WakeDaemon; cdecl;
var
  irq: Byte;
  t: PByte;
begin
  { ATA.cs: only nudge a thread that already exists and is not dead. }
  if (AtaHw_DaemonId = 0) or (AtaHw_DaemonId >= Cardinal(AtaHw_ThreadCount)) then Exit;

  t := PByte(AtaHw_ThreadAt(AtaHw_DaemonId));
  if t = nil then Exit;

  irq := AtaHw_AcquireSchedLockSafe;
  if t[THREAD_ACTIVE_OFF] <> 0 then
    t[THREAD_ACTIVE_OFF] := 1;
  AtaHw_ReleaseSchedLockSafe(irq);
end;

{ ═══════════════════════════════════════════════════════════════════════
  ASYNC LOCK
  ═══════════════════════════════════════════════════════════════════════ }

procedure Ata_AcquireAsync; cdecl;
var
  irq: Byte;
begin
  { Spinlock + yield, exactly like ATA.cs AcquireAtaAsync. }
  while true do
  begin
    irq := Spinlock_AcquireSafe_Pas(@AtaHw_AtaStateLock);
    if AtaHw_AtaIsBusy = 0 then
    begin
      AtaHw_AtaIsBusy := 1;
      Spinlock_ReleaseSafe_Pas(@AtaHw_AtaStateLock, irq);
      Exit;
    end;
    Spinlock_ReleaseSafe_Pas(@AtaHw_AtaStateLock, irq);
    AtaHw_Yield;
  end;
end;

procedure Ata_ReleaseAsync; cdecl;
var
  irq: Byte;
begin
  irq := Spinlock_AcquireSafe_Pas(@AtaHw_AtaStateLock);
  AtaHw_AtaIsBusy := 0;
  Spinlock_ReleaseSafe_Pas(@AtaHw_AtaStateLock, irq);
end;

{ ═══════════════════════════════════════════════════════════════════════
  PIO CORE
  ═══════════════════════════════════════════════════════════════════════ }

function Ata_WaitHardware: Boolean; cdecl;
var
  timeout: Integer;
begin
  { Busy bit clear = drive is ready for a new command. }
  timeout := 1000000;
  while timeout > 0 do
  begin
    if (Io_In8(ATA_PORT_STATUS) and ATA_ST_BSY) = 0 then
    begin
      Ata_WaitHardware := True;
      Exit;
    end;
    Dec(timeout);
  end;
  Ata_WaitHardware := False;
end;

procedure Ata_DetectDiskSize; cdecl;
var
  status: Byte;
  timeout: Integer;
  totalSectors: Cardinal;
  i: Integer;
begin
  { Real capacity, never hardcoded: IDENTIFY DEVICE, words 60/61. }
  if not Ata_WaitHardware then Exit;

  Io_Out8(ATA_PORT_DRIVE, $A0);
  Io_Out8(ATA_PORT_SECTOR_CNT, 0);
  Io_Out8(ATA_PORT_LBA_LOW, 0);
  Io_Out8(ATA_PORT_LBA_MID, 0);
  Io_Out8(ATA_PORT_LBA_HIGH, 0);
  Io_Out8(ATA_PORT_STATUS, ATA_CMD_IDENTIFY);

  status := Io_In8(ATA_PORT_STATUS);
  if status = 0 then Exit;

  timeout := 1000000;
  while timeout > 0 do
  begin
    status := Io_In8(ATA_PORT_STATUS);
    if (status and ATA_ST_BSY) = 0 then Break;
    Dec(timeout);
  end;
  if (timeout <= 0) or ((status and ATA_ST_ERR) <> 0) then Exit;

  while true do
  begin
    status := Io_In8(ATA_PORT_STATUS);
    if (status and ATA_ST_ERR) <> 0 then Exit;
    if (status and ATA_ST_DRQ) <> 0 then Break;
  end;

  for i := 0 to ATA_IDENTIFY_WORDS - 1 do
    AtaHw_Identify[i] := Io_In16(ATA_PORT_DATA);

  totalSectors := Cardinal(AtaHw_Identify[60]) or
                  (Cardinal(AtaHw_Identify[61]) shl 16);
  if totalSectors > 0 then AtaHw_DetectedSectors := totalSectors;
end;

function Ata_DetectedSectorCount: Cardinal; cdecl;
begin
  Ata_DetectedSectorCount := AtaHw_DetectedSectors;
end;

function Ata_IsLbaInRange(lba: Cardinal): Boolean; cdecl;
var
  irq: Byte;
begin
  { The C# takes AtaHardwareLock (not the scheduler lock) around detection. }
  irq := Spinlock_AcquireSafe_Pas(@AtaHw_HardwareLock);
  if AtaHw_DetectedSectors = 0 then Ata_DetectDiskSize;
  Spinlock_ReleaseSafe_Pas(@AtaHw_HardwareLock, irq);

  if AtaHw_DetectedSectors <> 0 then
    Ata_IsLbaInRange := lba < AtaHw_DetectedSectors
  else
    Ata_IsLbaInRange := lba <= ATA_MAX_LBA;
end;

procedure Ata_ReadSector(lba: Cardinal; buffer: PByte); cdecl;
var
  status: Byte;
  ptr: PWord;
  i: Integer;
  callerThread: Integer;
  sharedBase: QWord;
  raw: PByte;
  msgType, sender: Cardinal;
  payload: QWord;
  hwIrq, smIrq: Byte;
begin
  if buffer = nil then
  begin
    AtaHw_SetColor($00FF0000);
    AtaHw_Print(W('[!] FATAL: Null buffer in ATA ReadSector!'#13#10));
    AtaHw_SetColor($00FFFFFF);
    Exit;
  end;

  if not Ata_IsLbaInRange(lba) then
  begin
    AtaHw_SetColor($00FF0000);
    AtaHw_Print(W('[!] FATAL: Invalid LBA address in ATA ReadSector!'#13#10));
    AtaHw_SetColor($00FFFFFF);
    Exit;
  end;

  callerThread := AtaHw_CurrentThreadId;

  if AtaHw_UseDaemon <> 0 then
  if callerThread <> 0 then
  begin
    Ata_AcquireAsync;

    AtaHw_IpcSend(10, Cardinal(callerThread), AtaHw_DaemonId, QWord(lba));
    AtaHw_WakeDaemon;

    while true do
    begin
      if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload) then
      begin
        if msgType = 11 then
        begin
          if AtaHw_GetSharedMem = nil then
          begin
            AtaHw_SetColor($00FF0000);
            AtaHw_Print(W('[!] FATAL: Failed to get shared memory in ATA ReadSector!'#13#10));
            AtaHw_SetColor($00FFFFFF);
            Ata_ReleaseAsync;
            Exit;
          end;

          { AtaRawBuffer must sit inside the physical window. }
          sharedBase := AtaHw_SharedRamPhys;
          raw := AtaHw_SharedAtaRawBuffer;
          if (sharedBase = 0) or (raw = nil) or
             (sharedBase + KSM_OFF_ATA_RAW + ATA_SECTOR_SIZE >
              PMM_GetTotalPages * 4096) then
          begin
            AtaHw_SetColor($00FF0000);
            AtaHw_Print(W('[!] FATAL: Shared memory AtaRawBuffer out of bounds in ATA ReadSector!'#13#10));
            AtaHw_SetColor($00FFFFFF);
            Ata_ReleaseAsync;
            Exit;
          end;

          smIrq := AtaHw_SharedMemLockAcquire;
          MemCopy(buffer, raw, ATA_SECTOR_SIZE);
          AtaHw_SharedMemLockRelease(smIrq);
          Ata_ReleaseAsync;
          Exit;
        end
        else if msgType = 111 then
        begin
          AtaHw_SetColor($00FF0000);
          AtaHw_Print(W('[!] ATA Ring 0: Read Error from Daemon!'#13#10));
          AtaHw_SetColor($00FFFFFF);
          Ata_ReleaseAsync;
          Exit;
        end;
      end;
      AtaHw_Yield;
    end;
  end;

  hwIrq := Spinlock_AcquireSafe_Pas(@AtaHw_HardwareLock);

  Io_Out8(ATA_PORT_DRIVE, Byte($E0 or ((lba shr 24) and $0F)));

  if not Ata_WaitHardware then
  begin
    AtaHw_SetColor($00FF0000);
    AtaHw_Print(W('[!] ATA HW Read Error: Drive Select Timeout!'#13#10));
    AtaHw_SetColor($00FFFFFF);
    Spinlock_ReleaseSafe_Pas(@AtaHw_HardwareLock, hwIrq);
    Exit;
  end;

  Io_Out8(ATA_PORT_SECTOR_CNT, 1);
  Io_Out8(ATA_PORT_LBA_LOW, Byte(lba and $FF));
  Io_Out8(ATA_PORT_LBA_MID, Byte((lba shr 8) and $FF));
  Io_Out8(ATA_PORT_LBA_HIGH, Byte((lba shr 16) and $FF));
  Io_Out8(ATA_PORT_STATUS, ATA_CMD_READ_PIO);

  while true do
  begin
    status := Io_In8(ATA_PORT_STATUS);

    if (status and ATA_ST_BSY) <> 0 then Continue;

    if ((status and ATA_ST_ERR) <> 0) or ((status and ATA_ST_DSC) <> 0) then
    begin
      AtaHw_SetColor($00FF0000);
      AtaHw_Print(W('[!] ATA HW Read Error!'#13#10));
      AtaHw_SetColor($00FFFFFF);
      Spinlock_ReleaseSafe_Pas(@AtaHw_HardwareLock, hwIrq);
      Exit;
    end;

    if (status and ATA_ST_DRQ) <> 0 then Break;
  end;

  ptr := PWord(buffer);
  for i := 0 to ATA_SECTOR_SIZE div 2 - 1 do
  begin
    ptr^ := Io_In16(ATA_PORT_DATA);
    Inc(ptr);
  end;

  Spinlock_ReleaseSafe_Pas(@AtaHw_HardwareLock, hwIrq);
end;

procedure Ata_WriteSector(lba: Cardinal; buffer: PByte); cdecl;
var
  status: Byte;
  ptr: PWord;
  i: Integer;
  callerThread: Integer;
  raw: PByte;
  msgType, sender: Cardinal;
  payload: QWord;
  hwIrq, smIrq: Byte;
begin
  if buffer = nil then
  begin
    AtaHw_SetColor($00FF0000);
    AtaHw_Print(W('[!] FATAL: Null buffer in ATA WriteSector!'#13#10));
    AtaHw_SetColor($00FFFFFF);
    Exit;
  end;

  if not Ata_IsLbaInRange(lba) then
  begin
    AtaHw_SetColor($00FF0000);
    AtaHw_Print(W('[!] FATAL: Invalid LBA address in ATA WriteSector!'#13#10));
    AtaHw_SetColor($00FFFFFF);
    Exit;
  end;

  callerThread := AtaHw_CurrentThreadId;

  if AtaHw_UseDaemon <> 0 then
  if callerThread <> 0 then
  begin
    Ata_AcquireAsync;

    if AtaHw_GetSharedMem = nil then
    begin
      AtaHw_SetColor($00FF0000);
      AtaHw_Print(W('[!] FATAL: Failed to get shared memory in ATA WriteSector!'#13#10));
      AtaHw_SetColor($00FFFFFF);
      { Faithful to ATA.cs: the async lock is NOT released on this path. }
      Exit;
    end;

    raw := AtaHw_SharedAtaRawBuffer;
    if raw = nil then
    begin
      AtaHw_SetColor($00FF0000);
      AtaHw_Print(W('[!] FATAL: Shared memory AtaRawBuffer out of bounds in ATA WriteSector!'#13#10));
      AtaHw_SetColor($00FFFFFF);
      Exit;
    end;

    smIrq := AtaHw_SharedMemLockAcquire;
    MemCopy(raw, buffer, ATA_SECTOR_SIZE);
    AtaHw_SharedMemLockRelease(smIrq);

    AtaHw_IpcSend(12, Cardinal(callerThread), AtaHw_DaemonId, QWord(lba));
    AtaHw_WakeDaemon;

    while true do
    begin
      if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload) then
      begin
        if msgType = 13 then
        begin
          Ata_ReleaseAsync;
          Exit;
        end
        else if msgType = 111 then
        begin
          AtaHw_SetColor($00FF0000);
          AtaHw_Print(W('[!] ATA Ring 0: Write Error from Daemon!'#13#10));
          AtaHw_SetColor($00FFFFFF);
          Ata_ReleaseAsync;
          Exit;
        end;
      end;
      AtaHw_Yield;
    end;
  end;

  hwIrq := Spinlock_AcquireSafe_Pas(@AtaHw_HardwareLock);

  if not Ata_WaitHardware then
  begin
    Spinlock_ReleaseSafe_Pas(@AtaHw_HardwareLock, hwIrq);
    Exit;
  end;

  Io_Out8(ATA_PORT_DRIVE, Byte($E0 or ((lba shr 24) and $0F)));

  if not Ata_WaitHardware then
  begin
    AtaHw_SetColor($00FF0000);
    AtaHw_Print(W('[!] ATA HW Write Error: Drive Select Timeout!'#13#10));
    AtaHw_SetColor($00FFFFFF);
    Spinlock_ReleaseSafe_Pas(@AtaHw_HardwareLock, hwIrq);
    Exit;
  end;

  Io_Out8(ATA_PORT_SECTOR_CNT, 1);
  Io_Out8(ATA_PORT_LBA_LOW, Byte(lba and $FF));
  Io_Out8(ATA_PORT_LBA_MID, Byte((lba shr 8) and $FF));
  Io_Out8(ATA_PORT_LBA_HIGH, Byte((lba shr 16) and $FF));
  Io_Out8(ATA_PORT_STATUS, ATA_CMD_WRITE_PIO);

  while true do
  begin
    status := Io_In8(ATA_PORT_STATUS);
    if (status and ATA_ST_BSY) <> 0 then Continue;

    if ((status and ATA_ST_ERR) <> 0) or ((status and ATA_ST_DSC) <> 0) then
    begin
      AtaHw_SetColor($00FF0000);
      AtaHw_Print(W('[!] ATA HW Write error: DRQ Timeout!'#13#10));
      AtaHw_SetColor($00FFFFFF);
      Spinlock_ReleaseSafe_Pas(@AtaHw_HardwareLock, hwIrq);
      Exit;
    end;
    if (status and ATA_ST_DRQ) <> 0 then Break;
  end;

  ptr := PWord(buffer);
  for i := 0 to ATA_SECTOR_SIZE div 2 - 1 do
  begin
    Io_Out16(ATA_PORT_DATA, ptr^);
    Inc(ptr);
  end;

  Io_Out8(ATA_PORT_STATUS, ATA_CMD_CACHE_FLUSH);

  while true do
  begin
    status := Io_In8(ATA_PORT_STATUS);
    if (status and ATA_ST_BSY) <> 0 then Continue;

    if ((status and ATA_ST_ERR) <> 0) or ((status and ATA_ST_DSC) <> 0) then
    begin
      AtaHw_SetColor($00FF0000);
      AtaHw_Print(W('[!] ATA HW Write error: Platter write/flush failed!'#13#10));
      AtaHw_SetColor($00FFFFFF);
      Spinlock_ReleaseSafe_Pas(@AtaHw_HardwareLock, hwIrq);
      Exit;
    end;
    Break;
  end;

  Spinlock_ReleaseSafe_Pas(@AtaHw_HardwareLock, hwIrq);
end;

procedure Ata_FlushCache; cdecl;
var
  status: Byte;
  callerThread: Integer;
  msgType, sender: Cardinal;
  payload: QWord;
  hwIrq: Byte;
begin
  callerThread := AtaHw_CurrentThreadId;

  if AtaHw_UseDaemon <> 0 then
  if callerThread <> 0 then
  begin
    Ata_AcquireAsync;

    AtaHw_IpcSend(14, Cardinal(callerThread), AtaHw_DaemonId, 0);
    AtaHw_WakeDaemon;

    while true do
    begin
      if AtaHw_IpcReceiveForRaw(Cardinal(callerThread), msgType, sender, payload) then
      begin
        if msgType = 15 then
        begin
          Ata_ReleaseAsync;
          Exit;
        end
        else if msgType = 111 then
        begin
          AtaHw_SetColor($00FF0000);
          AtaHw_Print(W('[!] ATA Ring 0: Flush Error from Daemon!'#13#10));
          AtaHw_SetColor($00FFFFFF);
          Ata_ReleaseAsync;
          Exit;
        end;
      end;
      AtaHw_Yield;
    end;
  end;

  hwIrq := Spinlock_AcquireSafe_Pas(@AtaHw_HardwareLock);

  Io_Out8(ATA_PORT_STATUS, ATA_CMD_CACHE_FLUSH);

  while true do
  begin
    status := Io_In8(ATA_PORT_STATUS);
    if (status and ATA_ST_BSY) = 0 then Break;
    if (status and ATA_ST_ERR) <> 0 then
    begin
      AtaHw_SetColor($00FF0000);
      AtaHw_Print(W('[!] ATA HW Write error: Cache flush failed!'#13#10));
      AtaHw_SetColor($00FFFFFF);
      Spinlock_ReleaseSafe_Pas(@AtaHw_HardwareLock, hwIrq);
      Exit;
    end;
  end;

  Spinlock_ReleaseSafe_Pas(@AtaHw_HardwareLock, hwIrq);
end;

end.
