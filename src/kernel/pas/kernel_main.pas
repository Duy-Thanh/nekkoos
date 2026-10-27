{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: kernel_main - the kernel entry point and boot sequence.
  PORTED FROM: src/kernel/Kernel.cs.

  The bootloader (UEFI, src/boot) hands over a NekkoBootInfo and jumps to
  KernelMain. Phases, in the order that matters:

    1  console and serial, so there is somewhere to complain
    2  memory: PMM bitmap from the UEFI map, paging, heap, shadow buffer
    3  interrupts: GDT/TSS, IDT, remap the legacy PIC, purge PCI bus-master DMA
    4  scheduler core: PIT, IPC, PRNG, vDSO, strands, scheduler; interrupts on
    5  platform authenticity gate
    6  ring-3 daemons: ACPI, then (once the APICs are known) SMP and IOAPIC,
       then ATA, FAT16 and MOUSE; wait for their IPC handshakes; start login

  Every wait is bounded and every bound is written in milliseconds and
  converted with Hal_MsToTicks. The PIT runs at 250 Hz: one tick is 4 ms, so
  a bare tick constant is four times what it looks like (AGENTS.md section 14).
  =========================================================================
}
unit kernel_main;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

implementation

uses arch_interface, arch_hal, io, kstring, libc, pmm, memmap_scan, heap,
  ipc_kernel, prng, strandscheduler, scheduler, ata_kernel, fat16_kernel,
  input_drv, pe_loader, console, terminal, kstate, kernel_core;

const
  { How long a daemon may take to report ready before it is treated as stuck. }
  DAEMON_READY_MS = 45000;
  { How long the ACPI daemon may take to find the IOAPIC. }
  ACPI_WAIT_MS = 40000;
  { A wedged mouse daemon is killed and respawned this many times before the
    boot proceeds without one. }
  MOUSE_RESTARTS = 1;

  TICK_FREQUENCY_HZ = 250;

  IPC_ATA_READY   = 9;
  IPC_FAT16_READY = 39;
  IPC_MOUSE_READY = 44;


{ ── Helpers ──────────────────────────────────────────────────────────────── }

procedure Say(color: Cardinal; const msg: AnsiString);
begin
  Con_SetColor(color);
  Con_Print(W(msg));
end;

procedure HaltForever;
begin
  while True do Io_Cli;
end;

{ Terminate a thread if it exists. The id may be -1 (never spawned) and
  killing thread 0, the boot thread running this very loop, would end the
  system on the spot. }
procedure KillThread(id: Integer);
begin
  if (id <= 0) or (id >= Sched_GetThreadCount) then Exit;
  if Sched_GetThreadPriority(id) = SCHED_IDLE_PRIORITY then Exit;
  Sched_TerminateTask(id);
end;

{ Drain the boot thread's mailbox, recording who answered the handshake. }
procedure DrainHandshakes;
var
  rType, rSender: Cardinal;
  rPayload: QWord;
begin
  rType := 0; rSender := 0; rPayload := 0;
  while IpcK_ReceiveForRaw(0, rType, rSender, rPayload) do
  begin
    if rType = IPC_ATA_READY then
    begin
      Ata_SetDaemonId(rSender);
      Ata_SetUseDaemon(True);
    end
    else if rType = IPC_FAT16_READY then
    begin
      Fat16K_SetDaemonId(rSender);
      Fat16K_SetUseDaemon(True);
    end
    else if rType = IPC_MOUSE_READY then
    begin
      Mouse_SetDaemonId(rSender);
      Mouse_SetUseDaemon(True);
    end;
  end;
end;

{ Idle-loop work specific to this platform. Only the boot thread may read the
  boot thread's mailbox: this runs on the idle task of every other core too,
  and when those drained it they swallowed handshake messages they did not
  handle (the mouse's type 44 in particular), so the boot thread waited out its
  deadline for a daemon that had in fact reported ready. And only until the
  daemons are up: afterwards receiver 0 also carries keyboard scancodes (IRQ1
  broadcasts to it), which must not be eaten. }
procedure IdleHook;
begin
  if (Sched_GetCurrentThreadId = 0) and
     ((not Ata_GetUseDaemon) or (not Fat16K_GetUseDaemon)) then
    DrainHandshakes;
end;

{ Load a daemon image from the volume and start it as a root background
  process. Returns its thread id, or -1; halts the machine if the file is
  missing and `required`. }
function SpawnDaemon(name: PWord; required: Boolean; priority: Byte): Integer;
var
  size: Cardinal;
  raw: PByte;
  tid: Integer;
begin
  SpawnDaemon := -1;
  size := 0;
  raw := Fat16K_ReadFile(name, @size, -1);
  if raw = nil then
  begin
    if required then
    begin
      Con_SetColor($00FF0000);
      Con_Print(W('[!] FATAL KERNEL ERROR: '));
      Con_Print(name);
      Con_Print(W(' is missing or corrupted!'#13#10));
      HaltForever;
    end;
    Exit;
  end;
  tid := PELoader_LoadAndRun(raw, True, False, True, name, priority);
  SpawnDaemon := tid;
end;

{ ── Boot ─────────────────────────────────────────────────────────────────── }

type
  PBootInfo = PByte;

{ NekkoBootInfo field offsets (src/boot/BootContract.cs):
    0 FrameBufferBase u64 | 8 FrameBufferSize u64 | 16 HorizontalResolution u32
    20 VerticalResolution u32 | 24 PixelsPerScanLine u32 | 32 MemoryMap ptr
    40 MemoryMapSize u64 | 48 DescriptorSize u64 | 56 AcpiRsdp u64 }
function BI_Q(bi: PBootInfo; off: Integer): QWord; inline;
begin
  BI_Q := PQWord(bi + off)^;
end;

function BI_D(bi: PBootInfo; off: Integer): Cardinal; inline;
begin
  BI_D := PCardinal(bi + off)^;
end;

procedure KernelMain(bootInfo: PBootInfo); cdecl; public name 'KernelMain';
var
  totalPages, freePages, largestFreeStart, largestFreePages, maxPhysicalAddr: QWord;
  numEntries, addr: QWord;
  dummyIsr: Pointer;
  i: Integer;
  acpiWaitStart, daemonWaitStart, elapsedTicks: QWord;
  mouseDaemonId, newMouseId, oldMouseId, fatDaemonId, mouseRestarts: Integer;
  rType, rSender: Cardinal;
  rPayload: QWord;
  size: Cardinal;
  raw: PByte;
begin
  { First sign of life on COM1, before any driver exists. }
  Arch_WritePort8($3F8, Ord('K'));
  Arch_WritePort8($3F8, Ord('M'));
  Arch_WritePort8($3F8, 13);
  Arch_WritePort8($3F8, 10);

  { The scheduler lock starts held in the asm data; the first thing a core
    must do is release it. }
  Arch_UnlockScheduler;

  { ── Phase 1: console ── }
  Hal_EarlyInit;

  kstate_AcpiRsdp := BI_Q(bootInfo, 56);
  Con_Init(BI_Q(bootInfo, 0), BI_D(bootInfo, 16), BI_D(bootInfo, 20), BI_D(bootInfo, 24));

  Say($0000FF00, '================================================='#13#10);
  Con_Print(W('                    NEKKO OS'#13#10));
  Con_Print(W('================================================='#13#10#13#10));

  { ── Phase 2: memory ── }
  Say($0000FFFF, '[*] Reading memory map...'#13#10);

  numEntries := BI_Q(bootInfo, 40) div BI_Q(bootInfo, 48);
  ScanMemmap_Pas(Pointer(BI_Q(bootInfo, 32)), numEntries, BI_Q(bootInfo, 48),
    BI_Q(bootInfo, 0), BI_Q(bootInfo, 8),
    totalPages, freePages, largestFreeStart, largestFreePages, maxPhysicalAddr);

  Pmm_Init(PByte(BI_Q(bootInfo, 32)), BI_Q(bootInfo, 40), BI_Q(bootInfo, 48), largestFreeStart);

  Hal_InitMemory(maxPhysicalAddr);

  Say($00FF00FF, '[*] Enforcing 8GB Strict Identity Paging against UEFI fragmentation...'#13#10);

  Heap_Init;
  Con_EnableShadowBuffer;
  Fat16K_Init;

  { ── Phase 3: interrupts ── }
  Hal_InitInterrupts;

  Say($0000FF00, '[+] IDT Shield & Nuclear DMA Purge Active! Boot Sequence Proceeding...'#13#10);

  { ── Phase 4: scheduler core ── }
  Hal_StartTimer(TICK_FREQUENCY_HZ);

  Kernel_SetIdleHook(Pointer(@IdleHook));
  Kernel_InitServices;

  Hal_EnableInterrupts;

  { ── Phase 5: platform gate ── }
  Hal_PlatformGate;

  { ── Phase 6: daemons ── }
  SpawnDaemon(W('ACPI.EXE'), True, 3);

  Say($00FFFF00, '[*] Kernel: Waiting for ACPI Daemon to discover IOAPIC...'#13#10);

  acpiWaitStart := Hal_Ticks;
  while not Hal_InterruptControllersKnown do
  begin
    Arch_CompilerFence;

    if Hal_Ticks - acpiWaitStart > Hal_MsToTicks(ACPI_WAIT_MS) then
    begin
      Say($00FF0000, '[!] TIMEOUT: ACPI Daemon failed to discover IOAPIC after 40s'#13#10);
      Con_Print(W('[!] System halted. Check ACPI.EXE for errors.'#13#10));
      HaltForever;
    end;

    Sched_Yield;
  end;

  Say($0000FF00, '[+] ACPI Discovery Complete! Initializing SMP and IOAPIC...'#13#10);

  Hal_StartSecondaryCores;

  { Clear any stale handshakes before the next daemons start. }
  rType := 0; rSender := 0; rPayload := 0;
  while IpcK_ReceiveForRaw(0, rType, rSender, rPayload) do Arch_CompilerFence;

  SpawnDaemon(W('ATA.EXE'), True, 3);

  { Record the FAT16 daemon's thread id the moment it is spawned, before it can
    call ATA at all. Syscall 5 uses this, not the (user-chosen) process name, to
    decide who may talk to the ATA daemon directly. }
  fatDaemonId := SpawnDaemon(W('FAT16.EXE'), True, 3);
  Fat16K_SetTrustedThreadId(fatDaemonId);

  { The id is needed later: a lost mouse handshake is repaired by killing this
    thread and starting a fresh one. }
  mouseDaemonId := SpawnDaemon(W('MOUSE.EXE'), True, 3);

  { Wait for the three handshakes. Halt rather than Yield: under KVM a bare
    yield does not always let the daemons run, whereas HLT sleeps until the
    next timer tick has driven the scheduler. }
  daemonWaitStart := Hal_Ticks;
  mouseRestarts := 0;
  while not (Ata_GetUseDaemon and Fat16K_GetUseDaemon and Mouse_GetUseDaemon) do
  begin
    Arch_CompilerFence;

    DrainHandshakes;

    if Ata_GetUseDaemon and Fat16K_GetUseDaemon and Mouse_GetUseDaemon then Break;

    if Hal_Ticks - daemonWaitStart > Hal_MsToTicks(DAEMON_READY_MS) then
    begin
      Con_SetColor($00FF0000);
      { ATA and FAT16 cannot be restarted: login is read off the FAT16 volume,
        so without them there is nothing to boot into. They are given up on. }
      if not Ata_GetUseDaemon then
      begin
        Con_Print(W('[!] Timeout waiting for ATA handshake! Proceeding anyway.'#13#10));
        Ata_SetUseDaemon(True);
      end;
      if not Fat16K_GetUseDaemon then
      begin
        Con_Print(W('[!] Timeout waiting for FAT16 handshake! Proceeding anyway.'#13#10));
        Fat16K_SetUseDaemon(True);
      end;

      if not Mouse_GetUseDaemon then
      begin
        { The mouse handshake fails on roughly half of all boots and the cause
          was never found: instrumenting this loop changes its timing enough to
          hide the failure. So repair rather than diagnose: terminate the stuck
          daemon and start a fresh one. Its handshake is the first thing it
          does, so a clean start is the best repair available. }
        if mouseRestarts < MOUSE_RESTARTS then
        begin
          Inc(mouseRestarts);
          oldMouseId := mouseDaemonId;

          { Spawn the replacement BEFORE killing the old one so a failed spawn
            cannot leave the system without any mouse daemon. }
          newMouseId := SpawnDaemon(W('MOUSE.EXE'), False, 3);

          if newMouseId >= 0 then
          begin
            { Measured before the baseline is reset, or it reports one tick. }
            elapsedTicks := Hal_Ticks - daemonWaitStart;

            KillThread(oldMouseId);
            mouseDaemonId := newMouseId;
            Mouse_SetUseDaemon(False);
            Mouse_SetDaemonId(0);
            { The replacement gets a whole deadline of its own. }
            daemonWaitStart := Hal_Ticks;

            Con_SetColor($0000FF00);
            Con_Print(W('[TIMER] mouse deadline hit after '));
            Terminal_PrintDec_Pas(elapsedTicks * 1000 div Hal_TickFrequency);
            Con_Print(W(' ms ('));
            Terminal_PrintDec_Pas(elapsedTicks);
            Con_Print(W(' ticks)'#13#10));
            Con_Print(W('[!] Mouse handshake timed out - killed the daemon, respawned a fresh one.'#13#10));
            Con_SetColor($00FFFFFF);
            Continue;
          end;

          { No replacement could be loaded. Kill the wedged thread anyway. }
          KillThread(oldMouseId);
          mouseDaemonId := -1;
          Con_Print(W('[!] Timeout waiting for Mouse handshake, and no replacement could be loaded. Proceeding anyway.'#13#10));
          Mouse_SetUseDaemon(True);
        end
        else
        begin
          Con_Print(W('[!] Timeout waiting for Mouse handshake after restart. Proceeding anyway.'#13#10));
          Mouse_SetUseDaemon(True);
        end;
      end;
      Con_SetColor($00FFFFFF);
      Break;
    end;

    Io_Hlt;
  end;

  size := 0;
  raw := Fat16K_ReadFile(W('SYSLOGON.EXE'), @size, -1);
  if raw <> nil then
    PELoader_LoadAndRun(raw, False, False, True, W('SYSLOGON.EXE'), 2)
  else
    HaltForever;

  { This thread becomes core 0's idle task. }
  Sched_SetThreadPriority(0, SCHED_IDLE_PRIORITY);
  Kernel_IdleLoop;
end;

end.
