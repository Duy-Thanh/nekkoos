{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: power - graceful shutdown / reboot sequencing.
  PORTED FROM: src/drivers/x86-legacy/Power.cs.

  Shutdown and Reboot were two near-identical 100-line blocks in C#; they
  differ only in wording, the IPC code sent to the ACPI daemon (0xDEAD vs
  0xBEEF) and the final fallback, so they share one routine here.

  Order matters, and each step exists because skipping it once lost data:
    1. Ask every ordinary thread to exit (0xDEAD), except the ACPI and ATA
       daemons and ourselves.
    2. Wait for them; force-deactivate the stubborn ones. No INIT IPI yet:
       it resets every secondary core regardless of what runs on it and would
       kill the ACPI daemon before it could power the machine off.
    3. Only now stop the ATA daemon, since FAT16 and friends depend on it.
    4. Flush the disk cache through the direct driver.
    5. Let the ACPI daemon do the real power-off / reset.
    6. If it did not, wait for the ATA hardware lock to drop (never cut a PIO
       transfer in half), freeze the other cores and fall back to the HAL.

  Tick arithmetic keeps the original constants. The timer runs at 250 Hz, so
  5000 ticks is 20 s, 1000 is 4 s and 3000 is 12 s.
  =========================================================================
}
unit power;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

procedure Power_Shutdown;
procedure Power_Reboot;
procedure Power_HardReboot;
procedure Power_LegacyReboot;

implementation

uses arch_interface, io, kstring, terminal, scheduler, ipc_kernel, ata_kernel, apic;

procedure HAL_Reboot; cdecl; external name 'HAL_Reboot';
procedure HAL_Shutdown; cdecl; external name 'HAL_Shutdown';
function  HAL_GetTickCount: QWord; cdecl; external name 'HAL_GetTickCount';

const
  IPC_SHUTDOWN = $DEAD;
  IPC_REBOOT   = $BEEF;

procedure BroadcastApocalypse;
begin
  if not Apic_IsAwake then Exit;
  { INIT IPI (not NMI: there is no IDT vector 2) puts every other core into
    wait-for-SIPI. }
  Apic_Write($300, $000C4500);
end;

{ Give a running ATA PIO transfer up to spinLimit halts to finish. }
procedure WaitAtaIdleBeforeApocalypse(spinLimit: Integer);
var
  spins: Integer;
begin
  spins := 0;
  while Ata_HwLockIsLocked and (spins < spinLimit) do
  begin
    Io_Hlt;
    Inc(spins);
  end;
end;

function NameIs(t: Integer; a, b, c: Char): Boolean;
var
  n: PByte;
begin
  n := Sched_GetThreadName(t);
  NameIs := (n <> nil) and (n[0] = Ord(a)) and (n[1] = Ord(b)) and (n[2] = Ord(c));
end;

function NameIsAcpi(t: Integer): Boolean;
var
  n: PByte;
begin
  n := Sched_GetThreadName(t);
  NameIsAcpi := (n <> nil) and (n[0] = Ord('A')) and (n[1] = Ord('C')) and
                (n[2] = Ord('P')) and (n[3] = Ord('I'));
end;

procedure FindDaemons(out acpiPid, ataPid: Integer);
var
  i: Integer;
  irq: Boolean;
begin
  acpiPid := -1;
  ataPid := -1;
  irq := Sched_AcquireSchedLockSafe;
  for i := 1 to Sched_GetThreadCount - 1 do
  begin
    if (Sched_GetThreadActive(i) <> 0) and NameIsAcpi(i) then acpiPid := i;
    { ATA is killed LAST: FAT16 and the others wait on it for flush/write
      replies, and would hang forever if it died first. }
    if (Sched_GetThreadActive(i) <> 0) and NameIs(i, 'A', 'T', 'A') then ataPid := i;
  end;
  Sched_ReleaseSchedLockSafe(irq);
end;

function IsOrdinary(i, acpiPid, ataPid: Integer): Boolean;
begin
  { Idle tasks (priority 99) are never touched. }
  IsOrdinary := not ((i = Sched_GetCurrentThreadId) or (i = acpiPid) or (i = ataPid))
                and (Sched_GetThreadActive(i) <> 0)
                and (Sched_GetThreadPriority(i) <> 99);
end;

{ Shared body of Shutdown and Reboot. }
procedure GracefulStop(isShutdown: Boolean);
var
  acpiPid, ataPid, i: Integer;
  irq, allDead, ataDead: Boolean;
  timeout, ataTimeout, acpiTimeout: QWord;
  acpiCode: Cardinal;
begin
  Io_EnableInterrupts;
  Terminal_Clear_Pas($00000000);
  if isShutdown then
  begin
    Terminal_SetColor_Pas($00FF0000);
    Terminal_Print_Pas(W(#13#10#13#10'   [*] INITIATING GRACEFUL SHUTDOWN...'#13#10));
    acpiCode := IPC_SHUTDOWN;
  end
  else
  begin
    Terminal_SetColor_Pas($00FFFF00);
    Terminal_Print_Pas(W(#13#10#13#10'   [*] INITIATING GRACEFUL REBOOT SEQUENCE...'#13#10));
    acpiCode := IPC_REBOOT;
  end;

  FindDaemons(acpiPid, ataPid);

  { 1. Ask everyone else to leave. The lock is dropped around each send
       because IpcK_Send takes it again to wake the receiver. }
  irq := Sched_AcquireSchedLockSafe;
  if isShutdown and (not irq) then
  begin
    Terminal_SetColor_Pas($00FF0000);
    Terminal_Print_Pas(W('[!] FATAL: Failed to acquire scheduler lock in Shutdown!'#13#10));
    Exit;
  end;
  for i := 1 to Sched_GetThreadCount - 1 do
  begin
    if IsOrdinary(i, acpiPid, ataPid) then
    begin
      Sched_ReleaseSchedLockSafe(irq);
      IpcK_Send(IPC_SHUTDOWN, 0, Cardinal(i), 0);
      irq := Sched_AcquireSchedLockSafe;
    end;
  end;
  Sched_ReleaseSchedLockSafe(irq);

  { 2. Wait for them. Interrupts stay on so the scheduler keeps running; no
       Yield here, a nested INT 0x81 from ring 0 would misalign the frame. }
  timeout := HAL_GetTickCount + 5000;
  allDead := False;
  while HAL_GetTickCount < timeout do
  begin
    allDead := True;
    irq := Sched_AcquireSchedLockSafe;
    for i := 1 to Sched_GetThreadCount - 1 do
      if IsOrdinary(i, acpiPid, ataPid) then
      begin
        allDead := False;
        Break;
      end;
    Sched_ReleaseSchedLockSafe(irq);
    if allDead then Break;
    Io_Hlt;
  end;

  if not allDead then
  begin
    { Deactivate the holdouts rather than touching the cores themselves. }
    irq := Sched_AcquireSchedLockSafe;
    for i := 1 to Sched_GetThreadCount - 1 do
    begin
      if (i = Sched_GetCurrentThreadId) or (i = acpiPid) or (i = ataPid) then Continue;
      if Sched_GetThreadPriority(i) <> 99 then
      begin
        Sched_SetThreadActive(i, 0);
        Sched_SetThreadUID(i, 9999);
      end;
    end;
    Sched_ReleaseSchedLockSafe(irq);
  end;

  { 3. ATA daemon last. }
  if ataPid <> -1 then
  begin
    IpcK_Send(IPC_SHUTDOWN, 0, Cardinal(ataPid), 0);
    ataTimeout := HAL_GetTickCount + 1000;
    while HAL_GetTickCount < ataTimeout do
    begin
      irq := Sched_AcquireSchedLockSafe;
      ataDead := Sched_GetThreadActive(ataPid) = 0;
      Sched_ReleaseSchedLockSafe(irq);
      if ataDead then Break;
      Io_Hlt;
    end;
  end;

  { 4. From here the kernel talks to the disk itself. }
  Ata_SetUseDaemon(False);
  Ata_FlushCache;

  { 5. Delegate the power operation to the ACPI daemon. }
  if acpiPid <> -1 then
  begin
    if isShutdown then
      Terminal_Print_Pas(W('   [*] Delegating Hardware Power-off to ACPI Daemon...'#13#10))
    else
      Terminal_Print_Pas(W('   [*] Delegating Hardware Reboot to ACPI Daemon...'#13#10));
    IpcK_Send(acpiCode, 0, Cardinal(acpiPid), 0);

    Io_EnableInterrupts;
    acpiTimeout := HAL_GetTickCount + 3000;
    while HAL_GetTickCount < acpiTimeout do Io_Hlt;
  end;

  { 6. The daemon failed. This is the only place the other cores get frozen. }
  Sched_SetReady(False);
  Io_Cli;
  WaitAtaIdleBeforeApocalypse(2000);
  BroadcastApocalypse;

  Terminal_SetColor_Pas($00FF0000);
  if isShutdown then
  begin
    Terminal_Print_Pas(W(#13#10'   [!!!] FATAL: ACPI DAEMON FAILED TO SHUTDOWN HARDWARE! SYSTEM HALTED!'#13#10));
    HAL_Shutdown;
  end
  else
  begin
    Terminal_Print_Pas(W(#13#10'   [!!!] FATAL: ACPI DAEMON FAILED TO REBOOT HARDWARE! SYSTEM HALTED!'#13#10));
    Power_HardReboot;
    while True do Io_Hlt;
  end;
end;

procedure Power_Shutdown;
begin
  GracefulStop(True);
end;

procedure Power_Reboot;
begin
  GracefulStop(False);
end;

procedure Power_HardReboot;
begin
  HAL_Reboot;
end;

procedure Power_LegacyReboot;
begin
  HAL_Reboot;
end;

{ ── cdecl exports for the C# glue ── }

procedure Power_Shutdown_Pas; cdecl; public name 'Power_Shutdown_Pas';
begin
  Power_Shutdown;
end;

procedure Power_Reboot_Pas; cdecl; public name 'Power_Reboot_Pas';
begin
  Power_Reboot;
end;

procedure Power_HardReboot_Pas; cdecl; public name 'Power_HardReboot_Pas';
begin
  Power_HardReboot;
end;

procedure Power_LegacyReboot_Pas; cdecl; public name 'Power_LegacyReboot_Pas';
begin
  Power_LegacyReboot;
end;

end.
