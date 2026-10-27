{
  =========================================================================
  NekkoOS - A 64-bit x86-64 Educational Operating System
  Copyright (C) 2026 Nguyen Duy Thanh (Nekkochan)
  Licensed under the GNU General Public License v3.0 (GPLv3)
  =========================================================================
  MODULE: kstate - Cross-module kernel globals.

  PURPOSE: Some state is genuinely shared between modules that must not
  depend on each other. The prime example is the shared-memory window: the
  syscall layer allocates it, but VMM.DestroyUserSpace must know its address
           so it does not free the very pages an app is still using.

  A direct Pascal unit cycle (syscall uses vmm, vmm uses syscall) will not
  compile, and the alternative - passing the value through every call site -
  spreads a kernel-wide invariant across dozens of functions. This unit is
  the single owner of such state, depended on by everyone, depending on
  nobody. It must therefore stay free of dependencies: no uses clause, no
  hardware access, no allocation.

  Keep this list short. If a value has exactly one owner, it belongs in that
  owner's unit instead.
  =========================================================================
}

unit kstate;

{$mode objfpc}
{$h+}
{$TYPEINFO OFF}
{$M-}

interface

var
  { Physical base of the shared-memory window handed out by syscall 101.
    VMM skips these pages when tearing down a process's address space, so
    freeing them would corrupt a live mapping. 0 = not allocated. }
  kstate_SharedRAM_Phys: QWord = 0;

  { Physical address of the MPU trap page. Also protected from teardown: the
    kernel maps it deliberately and expects it to outlive any process. }
  kstate_MpuTrapPage_Phys: QWord = 0;

  { Number of pages in the shared window. 0 = not allocated. }
  kstate_SharedRAM_Pages: QWord = 0;

  { Lock around reads/writes of the shared-memory window. Taken by the syscall
    layer, the FAT16/ATA kernel drivers and the IPC fast paths. }
  kstate_SharedMemLock: Cardinal = 0;

  { Physical address of the ACPI RSDP, as found by the bootloader. Returned by
    syscall 11 for the ACPI daemon. }
  kstate_AcpiRsdp: QWord = 0;

{ ── Scheduler state that non-scheduler modules need to observe ─────────────

  The APIC initialisation pass must map its MMIO window into every live
  thread's address space, so it has to walk the thread table. But the
  scheduler already calls into the APIC (to read it and to check whether it
  is awake), so a direct dependency would be a cycle.

  The thread table pointer and its live count are therefore published here by
  the scheduler and read by the APIC. The record layout stays private to the
  scheduler; callers that need to inspect a thread use the accessors below,
  which keeps the layout in one place. }

var
  kstate_Threads: Pointer = nil;
  kstate_ThreadCount: Integer = 0;

  { The global scheduler lock. APIC init walks the thread table while
    holding it, exactly as the scheduler's own paths do. }
  kstate_SchedLock: Cardinal = 0;

function Kstate_AcquireSchedLock: Byte;
procedure Kstate_ReleaseSchedLock(irq: Byte);

implementation

uses arch_interface;

{ The scheduler lock is the global one in Hardware.asm, the same lock
  Sched_AcquireSchedLockSafe takes; a private lock here would not exclude the
  scheduler at all. }
function Kstate_AcquireSchedLock: Byte;
begin
  Kstate_AcquireSchedLock := Ord(Arch_InterruptsEnabled <> 0);
  Arch_DisableInterrupts;
  Arch_LockScheduler;
end;

procedure Kstate_ReleaseSchedLock(irq: Byte);
begin
  Arch_UnlockScheduler;
  if irq <> 0 then Arch_EnableInterrupts;
end;

{ Until the scheduler itself is Pascal, its C# owner publishes the thread table
  here so apic.pas can walk it. }
procedure Kstate_PublishThreads_Pas(threads: Pointer; count: Integer); cdecl; public name 'Kstate_PublishThreads_Pas';
begin
  kstate_Threads := threads;
  kstate_ThreadCount := count;
end;

{ Addresses of the shared cells, for the C# glue that still reads them by
  reference. }
function Kstate_SharedRamPtr_Pas: PQWord; cdecl; public name 'Kstate_SharedRamPtr_Pas';
begin
  Kstate_SharedRamPtr_Pas := @kstate_SharedRAM_Phys;
end;

function Kstate_MpuTrapPtr_Pas: PQWord; cdecl; public name 'Kstate_MpuTrapPtr_Pas';
begin
  Kstate_MpuTrapPtr_Pas := @kstate_MpuTrapPage_Phys;
end;

function Kstate_SharedMemLockPtr_Pas: PCardinal; cdecl; public name 'Kstate_SharedMemLockPtr_Pas';
begin
  Kstate_SharedMemLockPtr_Pas := @kstate_SharedMemLock;
end;

procedure Kstate_SetAcpiRsdp_Pas(rsdp: QWord); cdecl; public name 'Kstate_SetAcpiRsdp_Pas';
begin
  kstate_AcpiRsdp := rsdp;
end;

end.
